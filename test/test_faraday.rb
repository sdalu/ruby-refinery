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
        @thread = Thread.new { loop { serve(@server.accept) } }
    end

    def url = "http://127.0.0.1:#{@server.addr[1]}"

    def get(path, body, headers = {}) = @routes[path] = [ body, headers ]

    def close
        @thread.kill
        @server.close
    end

    private

    def serve(sock)
        path = sock.gets.to_s.split[1]
        nil until sock.gets.to_s.strip.empty?
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
