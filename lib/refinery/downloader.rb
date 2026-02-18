require 'strscan'
require 'uri'
require 'faraday'


module Refinery
module FaradayDownloader
    refine Faraday::Utils.singleton_class do
        def clean_path(path, root = nil)
            parts = path.split(::File::SEPARATOR)
            parts.unshift(root) unless root.nil?
            clean_path = parts.reduce([]) do |stack, part|
                unless part.empty? || part == '.'
                    part == '..' ? stack.pop : stack << part
                end
                stack
            end.join(::File::SEPARATOR).tap {
                it.prepend("/") if parts.empty? ||
                                   parts.first.empty?
            }
        end

        # Parse a Content-Disposition header value.
        # Returns { key => value, … }
        #
        # Handles:
        #   - RFC 6266 basic params (quoted / unquoted)
        #   - RFC 5987 ext-value   (charset'lang'pct-encoded)
        #   - RFC 2231 continuation (key*0=; key*1=; …)
        #   - RFC 2231 continuation + encoding (key*0*=charset'lang'…; key*1*=…)
        #   - Mixed case, extra whitespace, trailing/double semicolons
        #   - Missing disposition type → defaults to "attachment"
        def parse_content_disposition(data)
            params = {}
            parts  = {}
            s      = StringScanner.new(data&.strip || '')

            until s.eos?
                # Consume separation delimiter
                s.skip(/[\s;]+/)

                # Look for a key (everything except [ =;])
                #   if not well formed consumed until next delimiter
                if key = s.scan(/[^ =;]+/)&.downcase
                    next unless key =~ /\A[\w\-!#$&+.^]+(?:\*\d+\*?|\*)?\z/i
                else
                    s.scan(/[^;]*/)
                    next
                end

                # Look for a value assignment
                #   if not store it without value
                unless s.skip(/\s*=\s*/)
                    params[key] ||= true
                    next
                end

                # Retrieve value
                #   if string quoted un-escape it
                value = if s.peek(1) == '"'
                        then s.scan(/"((?:\\.|[^"\\])*)"?/)[0].gsub(/\\(.)/, '\1')
                        else s.scan(/[^\s;]*/) || ''
                        end

                # Deal with continuation
                if key =~ /\A(.+)\*(\d+)(\*)?\z/
                    (parts["#{$1}#{$3}"] ||= {})[$2.to_i] = value
                else
                    params[key] ||= value
                end
            end

            parts.each do |key, elts|
                params[key] = elts.sort_by(&:first).map(&:last).join
            end

            params.to_h {|k,v|
                [ k,
                  if k.end_with?('*') &&
                     v =~ /\A([A-Za-z0-9!#$&+\-.^_`{}~]+)'([^']*)'(.*)\z/m
                      charset, encoded = $1, $3
                      decoded = encoded.gsub(/%([0-9A-Fa-f]{2})/) { [$1].pack('H2') }

                      begin
                          decoded.encode('UTF-8', charset)
                      rescue ArgumentError,
                          Encoding::UndefinedConversionError,
                          Encoding::InvalidByteSequenceError
                          decoded.encode('UTF-8', 'BINARY',
                                         invalid: :replace, undef: :replace, replace: '?')
                      end
                  else
                      v
                  end
                ]
            }
        end
    end

    refine Faraday::Connection do
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
                                     kv = Faraday::Utils.parse_content_disposition(cd)
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
                                 dest = Faraday::Utils.clean_path(dest, dir) if dir
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
