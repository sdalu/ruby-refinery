require 'fileutils'
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
                        fn = fn.sub(/\A\.+/, '')
                        fn = fn.gsub(/\s+/, ' ')
                        fn = fn.strip
                        # Override destination (unless sanitizing emptied it)
                        d  = fn unless fn.empty?
                    end
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
                File.open(d, "wb", mode).tap { opened = true }
            end

            response = run_request(method, url, body, headers) do |req|
                req.params.update(params) if params
                block&.call(req)

                on_data = req.options.on_data

                req.options.on_data = proc do |chunk, overall_size, env|
                    on_data&.call(chunk, overall_size, env)
                    io ||= open_dest.call(env)
                    io&.write(chunk)
                end
            end

            # An empty body yields no on_data callbacks, so the destination was
            # never opened; create it now if requested.
            io = open_dest.call(response.env) if io.nil? && create_empty

            response
        ensure
            io&.close if opened
        end
    end
end
end
end
