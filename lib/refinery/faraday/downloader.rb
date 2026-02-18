require 'uri'
require 'faraday'

require_relative 'utils'


module Refinery
module Faraday
module Downloader
    using Utils

    refine ::Faraday::Connection do
        def download(url, dest = nil, dir: nil,
                     content_disposition: false,
                     umask: File.umask, mode: 0644 & ~umask,
                     method: :get, body: nil, headers: nil, params: nil, &block)
            io = nil

            run_request(method, url, body, headers) do |req|
                req.params.update(params) if params
                block&.call(req)

                on_data    = req.options.on_data
                configured = false

                req.options.on_data = proc do |chunk, overall_size, env|
                    on_data&.call(chunk, overall_size, env)

                    unless configured
                        dest = File.basename(URI(url).path) if dest.nil?

                        io = if dest.is_a?(String)
                                 if content_disposition
                                     cd = env.response_headers['Content-Disposition']
                                     kv = ::Faraday::Utils.parse_content_disposition(cd)
                                     if fn = kv['filename*'] || kv['filename']
                                         # Sanitizing
                                         fn = fn.delete("\x00")
                                         fn = fn.split(/[\/\\]/).last || ''
                                         # Perhaps a bit too much
                                         fn = fn.sub(/\A\.+/, '')
                                         fn = fn.gsub(/\s+/, ' ')
                                         fn = fn.strip
                                         # Override destination
                                         dest = fn
                                     end
                                 end
                                 dest = ::Faraday::Utils.clean_path(dest, dir) if dir
                                 FileUtils.mkdir_p(File.dirname(dest), mode: 0777 & ~umask)
                                 File.open(dest, "wb", mode)
                             else
                                 dest
                             end
                        configured = true
                    end

                    io&.write(chunk)
                end
            end

            io&.close if io != dest
        end
    end
end
end
end
