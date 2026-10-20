require_relative 'helper'

require 'socket'
require 'zlib'

return unless require_optional('refinery/faraday/downloader')

class TestContentDisposition < Minitest::Test
    using Refinery::Faraday::Utils

    def parse(s) = ::Faraday::Utils.parse_content_disposition(s)

    def test_quoted_and_unquoted
        assert_equal 'a b.txt', parse('attachment; filename="a b.txt"')['filename']
        assert_equal 'a.txt',   parse('ATTACHMENT;  FileName=a.txt ;;')['filename']
        assert_equal true,      parse('attachment')['attachment']
    end

    def test_quoted_escapes
        assert_equal 'a"b', parse('attachment; filename="a\"b"')['filename']
    end

    def test_rfc5987_ext_value
        kv = parse("attachment; filename*=UTF-8''%E2%82%AC%20rates.txt")
        assert_equal '€ rates.txt', kv['filename*']
    end

    def test_rfc2231_continuations_in_order
        kv = parse('attachment; filename*1="part2"; filename*0="part1-"')
        assert_equal 'part1-part2', kv['filename']
        kv = parse("attachment; filename*0*=UTF-8''%C3%A9; filename*1*=t%C3%A9")
        assert_equal 'été', kv['filename*']
    end

    # Regression: encoded and plain segments went under two keys, so a
    # name came out cut short, or still percent-encoded
    def test_rfc2231_mixed_encoded_and_plain_segments
        kv = parse("attachment; filename*0*=UTF-8''%C3%A9t%C3%A9; filename*1=-report.pdf")
        assert_equal 'été-report.pdf', kv['filename*']
        kv = parse('attachment; filename*0=plain-; filename*1*=%C3%A9.pdf')
        assert_equal 'plain-é.pdf', kv['filename*']
        # only the segments marked * are percent-decoded
        kv = parse("attachment; filename*0*=UTF-8''a; filename*1*=b; filename*2=%41.txt")
        assert_equal 'ab%41.txt', kv['filename*']
        kv = parse("attachment; filename*0*=ISO-8859-1''%E9t; filename*1=%E9")
        assert_equal 'ét%E9', kv['filename*']
    end

    # Regression: an unknown charset raised, and bytes invalid in theirs
    # came through as a broken String, on which the downloader raised
    def test_a_bad_charset_or_bad_bytes_never_raise
        [ "attachment; filename*=x-unknown''a.txt",
          "attachment; filename*=UTF-8''%FF%FE.txt",
          "attachment; filename*0*=x-unknown''%FF; filename*1=.txt" ].each do |h|
            v = parse(h)['filename*']
            assert_equal Encoding::UTF_8, v.encoding, h
            assert v.valid_encoding?, h
            assert v.end_with?('.txt'), h
        end
    end

    # Regression: `#$&` in the key check's regex interpolated the last
    # match, so the previous key shaped the check: 'z-a' made an empty
    # range, and #, $ and & were never allowed
    def test_previous_key_does_not_shape_the_key_check
        assert_equal 'r.pdf', parse('attachment; z-a; filename="r.pdf"')['filename']
        assert_equal 'v',     parse('attachment; a#b$c&d=v')['a#b$c&d']
        assert_equal 'x',     parse("attachment; filename*=a&b''x")['filename*']
    end

    # Regression: a rejected key left its value unread, and parsing
    # resumed inside it, where the server could hide a filename
    def test_a_rejected_key_skips_its_value
        kv = parse('attachment; x@y="a;filename=evil.exe"; filename="r.pdf"')
        assert_equal 'r.pdf', kv['filename']
        refute kv.key?('x@y')
    end

    # Regression: the key ended at a space but not at a tab, so
    # `filename\t=` lost the parameter (RFC 7230 allows either)
    def test_a_tab_before_the_equals_sign
        assert_equal 'a.pdf', parse(%Q{attachment; filename\t="a.pdf"})['filename']
        assert_equal 'a.pdf', parse(%Q{attachment;\tfilename\t=\t"a.pdf"})['filename']
    end

    def test_nil_and_garbage
        assert_equal({}, parse(nil))
        assert_kind_of Hash, parse('=;=;"')
    end
end

# A local HTTP server, one canned response per path, so that the
# downloads go through the default adapter (net_http): Faraday's :test
# adapter never calls on_data, and the downloader writes only from it.
class CannedServer
    def initialize
        @routes = {}
        @server = TCPServer.new('127.0.0.1', 0)
        # A thread per connection: a response left stalling must not
        # hold up the next (a client retrying)
        @thread = Thread.new { loop { Thread.new(@server.accept) { serve(it) } } }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def get(path, body, headers = {}) = @routes[path] = [ body, headers ]

    # Responses written raw, one per connection in turn, the last
    # repeating: each a proc given the socket
    def raw(path, *handlers) = @routes[path] = handlers

    def close
        @thread.kill
        @server.close
    end

    private

    def serve(sock)
        path = sock.gets.to_s.split[1]
        nil until sock.gets.to_s.strip.empty?
        route = @routes[path]
        if route&.first.is_a?(Proc)
            (route.size > 1 ? route.shift : route.first).(sock)
            return
        end
        body, headers = @routes.fetch(path, [ 'not found', {} ])
        sock.write "HTTP/1.1 #{@routes.key?(path) ? 200 : 404} X\r\n"
        { 'Content-Length' => body.bytesize, 'Connection' => 'close' }
            .merge(headers).each {|k, v| sock.write "#{k}: #{v}\r\n" }
        sock.write "\r\n#{body}"
    ensure
        sock.close
    end
end

class TestDownloader < Minitest::Test
    using Refinery::Faraday::Downloader

    def setup
        @dir    = Dir.mktmpdir
        @server = CannedServer.new
        @conn   = ::Faraday.new(@server.url)
    end

    def teardown
        @server.close
        FileUtils.rm_rf(@dir)
    end

    def files = Dir.glob('**/*', File::FNM_DOTMATCH, base: @dir)
                   .reject { File.basename(it) == '.' }.sort

    def cd(name) = { 'Content-Disposition' => %(attachment; filename="#{name}") }

    def test_download_to_a_path
        @server.get('/r.pdf', 'data')
        @conn.download('/r.pdf', File.join(@dir, 'sub', 'out.pdf'))
        assert_equal 'data', File.read(File.join(@dir, 'sub', 'out.pdf'))
    end

    def test_name_from_the_url
        @server.get('/x/r.pdf', 'data')
        @conn.download('/x/r.pdf', dir: @dir)
        assert_equal [ 'r.pdf' ], files
        assert_equal 'data', File.read(File.join(@dir, 'r.pdf'))
    end

    def test_download_to_an_io
        @server.get('/r', 'data')
        io = StringIO.new
        @conn.download('/r', io)
        assert_equal 'data', io.string
        refute io.closed?, 'caller IO closed'
    end

    def test_name_from_content_disposition
        @server.get('/export', 'x', cd('rep.csv'))
        @conn.download('/export', dir: @dir, content_disposition: true)
        assert_equal [ 'rep.csv' ], files
    end

    # The guard against a hostile server: its filename is cut down to a
    # basename with no leading dots before it meets the directory
    def test_refuses_a_content_disposition_escaping_the_directory
        [ '../../evil.txt', '/etc/evil.txt', '..\\..\\evil.txt', '.evil.txt',
          ' .evil.txt', '. .evil.txt', "\t..evil.txt" ]
            .each_with_index do |name, i|
            @server.get("/e#{i}", 'x', cd(name))
            @conn.download("/e#{i}", dir: @dir, content_disposition: true)
            assert_equal [ 'evil.txt' ], files, name
            File.delete(File.join(@dir, 'evil.txt'))
        end
    end

    # Whitespace around the dots included: stripped only after the dots
    # were, ' ..' came out as '..', and '. .' as '.'
    def test_a_filename_sanitized_to_nothing_falls_back_to_the_url
        [ '..', ' ..', "\t..", '. .', ' . ' ].each_with_index do |name, i|
            @server.get("/x/fallback#{i}.bin", 'x', cd(name))
            @conn.download("/x/fallback#{i}.bin", dir: @dir,
                           content_disposition: true)
            assert_equal [ "fallback#{i}.bin" ], files, name.inspect
            File.delete(File.join(@dir, "fallback#{i}.bin"))
        end
    end

    def test_empty_body_creates_the_file_unless_told_not_to
        @server.get('/empty', '')
        @conn.download('/empty', File.join(@dir, 'a'))
        @conn.download('/empty', File.join(@dir, 'b'), create_empty: false)
        assert_equal [ 'a' ], files
        assert_equal 0, File.size(File.join(@dir, 'a'))
    end

    # Regression: an error response was written over the destination,
    # even with raise_error raising after it
    def test_an_error_response_leaves_the_destination_alone
        path   = File.join(@dir, 'f.bin')
        strict = ::Faraday.new(@server.url) { it.response :raise_error }
        File.write(path, 'old')

        assert_equal 404, @conn.download('/missing', path).status
        assert_raises(::Faraday::ResourceNotFound) { strict.download('/missing', path) }
        @conn.download('/missing', File.join(@dir, 'new.bin'))
        assert_equal 'old',       File.read(path)
        assert_equal [ 'f.bin' ], files
    end

    # A transfer failing partway leaves the old copy and no .part
    def test_a_failed_transfer_leaves_the_destination_alone
        path = File.join(@dir, 'f.bin')
        File.write(path, 'old')
        @server.get('/big', 'x' * 1_000_000)
        calls = 0
        assert_raises(RuntimeError) do
            @conn.download('/big', path) do |req|
                req.options.on_data = proc { raise "cut" if (calls += 1) == 2 }
            end
        end
        assert_equal 'old',       File.read(path)
        assert_equal [ 'f.bin' ], files
    end

    def test_a_filename_with_bad_bytes_is_still_saved
        @server.get('/r', 'x', 'Content-Disposition' => "attachment; filename*=UTF-8''%FF.txt")
        @conn.download('/r', dir: @dir, content_disposition: true)
        assert_equal [ "�.txt" ], files
    end

    # Regression: Net::HTTP ignores a body ending before Content-Length,
    # so a truncated download was saved as a success
    def test_a_truncated_body_raises_and_leaves_the_destination_alone
        path = File.join(@dir, 'f.bin')
        File.write(path, 'old')
        @server.get('/short', 'abc', 'Content-Length' => 100)
        e = assert_raises(::Faraday::ConnectionFailed) { @conn.download('/short', path) }
        assert_match(/3 of 100 bytes/, e.message)
        assert_equal 'old',       File.read(path)
        assert_equal [ 'f.bin' ], files
        io = StringIO.new
        assert_raises(::Faraday::ConnectionFailed) { @conn.download('/short', io) }
    end

    # Net::HTTP inflates a gzip body and rewrites Content-Length to match:
    # not to be taken for a truncated one
    def test_a_compressed_body_is_not_taken_for_truncated
        data = 'x' * 10_000
        @server.get('/gz', Zlib.gzip(data), 'Content-Encoding' => 'gzip')
        path = File.join(@dir, 'f.bin')
        @conn.download('/gz', path)
        assert_equal data, File.read(path)
    end

    # Regression: a root URL gave the name '/', which clean_path turned
    # into dir: itself -- written beside it, or in its place
    def test_refuses_a_url_without_a_file_name
        @server.get('/', 'x')
        target = File.join(@dir, 'new')
        assert_raises(ArgumentError) { @conn.download('/', dir: target) }
        assert_raises(ArgumentError) { @conn.download('/', dir: @dir) }
        assert_empty files
    end

    def test_a_root_url_is_fine_given_a_name
        @server.get('/', 'x', cd('r.bin'))
        @conn.download('/', dir: @dir, content_disposition: true)
        assert_equal [ 'r.bin' ], files
        @conn.download('/', File.join(@dir, 'given.bin'))
        assert_equal [ 'given.bin', 'r.bin' ], files
    end

    # Regression: a request retried by a middleware (faraday-retry) had
    # its second attempt appended to the first's partial body
    def test_a_retried_download_is_not_appended_to_the_failed_attempt
        skip 'faraday-retry not installed' unless require_optional('faraday/retry')
        full  = '0123456789' * 10
        head  = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        stall = ->(s) { s.write head + "32\r\n#{full[0, 50]}\r\n"; s.flush; sleep 1.5 }
        ok    = ->(s) { s.write head + "64\r\n#{full}\r\n0\r\n\r\n" }
        conn  = ::Faraday.new(@server.url) do |f|
            f.request :retry, max: 1, interval: 0
            f.options.timeout = 0.5
        end
        path = File.join(@dir, 'f.bin')
        @server.raw('/f', stall, ok)
        conn.download('/f', path)
        assert_equal full, File.read(path)
        io = StringIO.new(+'kept:')
        io.seek(0, IO::SEEK_END)
        @server.raw('/g', stall, ok)
        conn.download('/g', io)
        assert_equal "kept:#{full}", io.string
    end

    # Regression: a Pathname was taken for an IO, and Pathname#write
    # rewrote the whole file with each chunk: the last one was left
    def test_a_pathname_dest_is_a_file
        require 'pathname'
        @server.get('/big', 'C' * 200_000)
        @conn.download('/big', Pathname(@dir) / 'p.bin')
        assert_equal 200_000, File.size(File.join(@dir, 'p.bin'))
        assert_equal [ 'p.bin' ], files
    end

    # Regression: <dest>.part had a name anyone could guess and was
    # opened following links: a symlink planted there had its target
    # overwritten, and was itself renamed into place
    def test_a_planted_part_symlink_is_not_followed
        victim = File.join(@dir, 'victim')
        File.write(victim, 'precious')
        dest = File.join(@dir, 'r.pdf')
        File.symlink(victim, "#{dest}.part")
        @server.get('/r.pdf', 'data')
        @conn.download('/r.pdf', dest)
        assert_equal 'precious', File.read(victim)
        refute File.symlink?(dest), 'the planted link renamed into place'
        assert_equal 'data', File.read(dest)
    end

    # Regression: two downloads to one path shared one .part; one raised
    # ENOENT and rewrote the file the other had finished
    def test_two_downloads_to_one_path_do_not_share_a_part
        @server.get('/a', 'A' * 100_000)
        @server.get('/b', 'B' * 100_000)
        dest = File.join(@dir, 'f')
        rs = [ '/a', '/b' ].map { |p| Thread.new { @conn.download(p, dest).status } }.map(&:value)
        assert_equal [ 200, 200 ], rs
        assert_includes [ 'A' * 100_000, 'B' * 100_000 ], File.read(dest)
        assert_equal [ 'f' ], files
    end

    # Regression: control characters passed the sanitiser, to the disk
    # and, through the progress bar, to the terminal
    def test_control_characters_are_removed_from_a_content_disposition_name
        @server.get('/x', 'x', cd("\e]0;PWN\a\e[2Jr\u009b.txt"))
        @conn.download('/x', dir: @dir, content_disposition: true)
        assert_equal [ '_]0;PWN__[2Jr_.txt' ], files
    end

    # Regression: the server's name replaced dest whole, directory
    # included: the file went to the working directory
    def test_a_content_disposition_name_stays_in_dest_directory
        @server.get('/r', 'x', cd('server.pdf'))
        Dir.mkdir(File.join(@dir, 'out'))
        Dir.mkdir(cwd = File.join(@dir, 'cwd'))
        Dir.chdir(cwd) do
            @conn.download('/r', File.join(@dir, 'out', 'mine.pdf'), content_disposition: true)
        end
        assert_equal [ 'cwd', 'out', 'out/server.pdf' ], files
    end

    # Regression: `filename` with no value parsed as true, and the
    # sanitizer called String methods on it: NoMethodError
    def test_a_filename_parameter_without_value_falls_back_to_the_url
        [ 'attachment; filename', 'attachment; filename*' ].each_with_index do |h, i|
            @server.get("/v#{i}.bin", 'x', 'Content-Disposition' => h)
            @conn.download("/v#{i}.bin", dir: @dir, content_disposition: true)
            assert_equal [ "v#{i}.bin" ], files, h
            File.delete(File.join(@dir, "v#{i}.bin"))
        end
    end

    # Regression: an unusable filename* (empty, dots) won over a good
    # filename, then sanitized to nothing: the URL name was used
    def test_an_unusable_filename_star_falls_back_to_filename
        [ %(attachment; filename="report.pdf"; filename*=UTF-8''),
          %(attachment; filename="report.pdf"; filename*=UTF-8''%2E%2E) ].each_with_index do |h, i|
            @server.get("/u#{i}.bin", 'x', 'Content-Disposition' => h)
            @conn.download("/u#{i}.bin", dir: @dir, content_disposition: true)
            assert_equal [ 'report.pdf' ], files, h
            File.delete(File.join(@dir, 'report.pdf'))
        end
    end

    # Regression: <name>.<random>.part was 18 bytes longer than the name,
    # so a valid name of 238 bytes or more could not be written
    def test_a_long_file_name_is_saved
        long = "#{'a' * 240}.txt"
        @server.get('/l.bin', 'x', cd(long))
        @conn.download('/l.bin', dir: @dir, content_disposition: true)
        assert_equal [ long ], files
        @server.get('/m.bin', 'y')
        @conn.download('/m.bin', File.join(@dir, "#{'b' * 251}.bin"))
        assert_includes files, "#{'b' * 251}.bin"
    end

    # A server's name past 255 bytes is cut to 255, its extension kept and
    # no character split
    def test_an_overlong_content_disposition_name_is_cut
        @server.get('/o.bin', 'x', cd("#{'é' * 200}.pdf"))
        @conn.download('/o.bin', dir: @dir, content_disposition: true)
        name = files.first
        assert_operator name.bytesize, :<=, 255
        assert name.end_with?('.pdf'), name
        assert name.valid_encoding?
    end

    def test_a_success_replaces_the_destination
        path = File.join(@dir, 'f.bin')
        File.write(path, 'old')
        @server.get('/r', 'new')
        @conn.download('/r', path)
        assert_equal 'new',       File.read(path)
        assert_equal [ 'f.bin' ], files
    end
end

class TestProgressBarShorten < Minitest::Test
    def setup
        skip 'tty-progressbar not installed' unless
            require_optional('refinery/faraday/progress-bar')
    end

    def shorten(...) = Refinery::Faraday::ProgressBar.shorten(...)

    def test_shorten
        assert_equal 'big...file',  shorten('biglongfile', 10)
        assert_equal 'short',       shorten('short', 10)
        assert_equal 'short',       shorten('short', nil)
        assert_equal 'ab',          shorten('abcdef', 2)
        assert_operator shorten('x' * 100, 20).length, :<=, 20
    end
end

class TestProgressBarMiddleware < Minitest::Test
    using Refinery::Faraday::Downloader

    def setup
        skip 'tty-progressbar not installed' unless
            require_optional('refinery/faraday/progress-bar')
        @server = CannedServer.new
        @out    = StringIO.new
        @out.define_singleton_method(:tty?) { true }   # else no bar is drawn
        @conn   = ::Faraday.new(@server.url) do |f|
            f.response :progress_bar, options: { output: @out }
        end
    end

    def teardown = @server&.close

    # Regression: the middleware made every request a streaming one, and
    # Faraday left the body of a plain request empty
    def test_a_plain_request_keeps_its_body
        @server.get('/api', '{"ok":true}')
        assert_equal '{"ok":true}', @conn.get('/api').body
    end

    # Regression: the name was spliced into the bar's format as is: its
    # escapes reached the terminal, and a :bar in it drew a second bar
    def test_a_hostile_name_neither_escapes_nor_draws
        @server.get('/x', 'x' * 5, 'Content-Disposition' =>
                    %(attachment; filename="\e]0;PWN\a:bar.txt"))
        Dir.mktmpdir do |dir|
            @conn.download('/x', dir: dir, content_disposition: true)
        end
        refute_includes @out.string, "\e]0;"
        assert_includes @out.string, "∶bar.txt"      # shown, not drawn
    end

    # The name from the URL, too: a :token in a path is shown, not drawn
    def test_a_url_name_is_not_a_format
        @server.get('/:percent.bin', 'x' * 5)
        Dir.mktmpdir { |dir| @conn.download('/:percent.bin', dir: dir) }
        assert_includes @out.string, "∶percent.bin"
    end

    def test_a_download_still_shows_a_bar
        @server.get('/f.bin', 'x' * 1000)
        Dir.mktmpdir do |dir|
            @conn.download('/f.bin', File.join(dir, 'f.bin'))
            assert_equal 1000, File.size(File.join(dir, 'f.bin'))
        end
        refute_empty @out.string, 'no bar drawn'
    end
end
