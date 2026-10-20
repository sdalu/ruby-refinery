require 'fileutils'
require 'securerandom'
require 'uri'

require 'faraday'

require_relative 'utils'


module Refinery
module Faraday
module Downloader
    using Utils

    refine ::Faraday::Connection do
        def download(url, dest = nil, dir: nil,
                     content_disposition: false, create_empty: true,
                     umask: File.umask, mode: 0644 & ~umask,
                     method: :get, body: nil, headers: nil, params: nil, &block)
            io     = nil
            opened = false
            # A file is written as <path>.<random>.part and renamed into place once
            # the response is a success: an error response, or a transfer
            # failing partway, leaves the old copy untouched.  A
            # caller-provided IO gets the body as it comes, whatever the
            # status.
            # A Pathname is a path: taken for an IO, its #write rewrote
            # the whole file with each chunk
            dest     = dest.to_path if defined?(::Pathname) && dest.is_a?(::Pathname)
            to_file  = dest.nil? || dest.is_a?(String)
            final    = nil
            part     = nil
            received = 0
            start    = nil      # a caller IO's position before the body

            # Resolve the final destination from the response. Returns either a
            # String path (a file to open) or the caller-provided IO.
            resolve = lambda do |env|
                d = dest.nil? ? File.basename(URI(url).path) : dest
                return d unless d.is_a?(String)

                if content_disposition
                    cd = env.response_headers['Content-Disposition']
                    kv = ::Faraday::Utils.parse_content_disposition(cd)
                    if fn = kv['filename*'] || kv['filename']
                        # Sanitizing
                        fn = fn.delete("\x00")
                        fn = fn.split(/[\/\\]/).last || ''
                        fn = fn.gsub(/\s+/, ' ')
                        # Control characters (C0, DEL, C1) would reach the
                        # disk, and the terminal through the progress bar
                        fn = fn.gsub(/[[:cntrl:]]/, '_')
                        # Dots and blanks together: ' ..' and '. .' are
                        # dots once stripped
                        fn = fn.sub(/\A[.\s]+/, '')
                        fn = fn.strip
                        # Override the file name (unless sanitizing emptied
                        # it), in dest's directory when dest is given
                        unless fn.empty?
                            d = dest ? File.join(File.dirname(dest), fn) : fn
                        end
                    end
                end
                # A root URL names no file: '/' would become dir: itself
                if [ '', '/', '.', '..' ].include?(d)
                    raise ArgumentError,
                          "no file name in #{url.inspect}: pass dest, or content_disposition: true"
                end
                dir ? ::Faraday::Utils.clean_path(d, dir) : d
            end

            # Open the destination for writing, creating parent dirs. For a
            # caller-provided IO nothing is opened; the IO is returned as-is.
            open_dest = lambda do |env|
                d = resolve.call(env)
                next d unless d.is_a?(String)

                # Publish the final saved filename so that downstream consumers
                # (eg: progress bar) can display it instead of guessing.
                env[:download_filename] = File.basename(d)
                FileUtils.mkdir_p(File.dirname(d), mode: 0777 & ~umask)
                # A name no one can guess, created afresh and not through
                # a link: <dest>.part, opened following links, overwrote
                # the target of a symlink planted there, and two downloads
                # to one path shared it
                final = d
                part  = "#{d}.#{SecureRandom.hex(6)}.part"
                File.open(part, ::File::WRONLY | ::File::CREAT | ::File::EXCL |
                                ::File::NOFOLLOW | ::File::BINARY, mode)
                    .tap { opened = true }
            end

            response = run_request(method, url, body, headers) do |req|
                req.params.update(params) if params
                block&.call(req)

                on_data = req.options.on_data

                req.options.on_data = proc do |chunk, overall_size, env|
                    on_data&.call(chunk, overall_size, env)
                    # An empty body still gets one call, with an empty
                    # chunk: leave that to create_empty below.
                    next if io.nil? && chunk.empty?
                    next if to_file && !env.success?
                    if io.nil?
                        io    = open_dest.call(env)
                        start = (io.pos rescue nil) unless opened
                    end
                    # A middleware retrying (faraday-retry) runs the request
                    # again, and the adapter counts afresh: a first chunk,
                    # overall_size its own size, after bytes already
                    # written.  Start over, rather than append to the
                    # failed attempt.
                    if received > 0 && overall_size == chunk.bytesize
                        if opened
                            io.rewind
                            io.truncate(0)
                        elsif start && io.respond_to?(:truncate)
                            io.seek(start)
                            io.truncate(start)
                        else
                            raise IOError, "a retried download cannot start over in a #{io.class}"
                        end
                        received = 0
                    end
                    io&.write(chunk)
                    received += chunk.bytesize
                end
            end

            # Net::HTTP ignores a body ending before its Content-Length:
            # count, so that a truncated body is not a success.  Not for a
            # content-encoded one, whose length counts the bytes before
            # the adapter inflated them (a gzip cut short fails there)
            coding = response.headers['content-encoding'].to_s.downcase
            if response.success? && method != :head &&
               (coding.empty? || coding == 'identity') &&
               (length = response.headers['content-length']) &&
               length.to_i != received
                raise ::Faraday::ConnectionFailed,
                      "body truncated: #{received} of #{length.to_i} bytes"
            end

            if response.success?
                # An empty body never opened the destination; create it
                # now if requested.
                io = open_dest.call(response.env) if io.nil? && create_empty
                if opened
                    io.close
                    File.rename(part, final)
                    part = nil
                end
            end

            response
        ensure
            io.close if opened && !io.closed?
            File.delete(part) if part && File.exist?(part)
        end
    end
end
end
end
