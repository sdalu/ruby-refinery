require 'strscan'
require 'faraday'


module Refinery
module Faraday
module Utils
    # charset'language'percent-encoded (RFC 5987 ext-value, RFC 2231)
    EXT_VALUE = /\A([A-Za-z0-9!\#$&+\-.^_`{}~]+)'([^']*)'(.*)\z/m

    # Percent-escapes decoded, as bytes
    def self.pct_decode(s) = s.b.gsub(/%(\h\h)/n) { $1.hex.chr }

    # An ext-value decoded; without a charset, left as it is
    def self.ext_value(v)
        return to_utf8(v, 'UTF-8') unless v =~ EXT_VALUE
        to_utf8(pct_decode($3), $1)
    end

    # +bytes+ read in +charset+, as a valid UTF-8 String, never raising:
    # a server picks both, and the downloader works on the result.  What
    # an unknown charset or an invalid byte leaves undecodable is U+FFFD.
    def self.to_utf8(bytes, charset)
        enc  = Encoding.find(charset) rescue Encoding::BINARY  # unknown name
        opts = { invalid: :replace, undef: :replace, replace: "�" }
        begin
            bytes.b.force_encoding(enc).encode(Encoding::UTF_8, **opts)
        rescue EncodingError                    # dummy encoding, no converter
            bytes.b.encode(Encoding::UTF_8, **opts)
        end.scrub("�")
    end

    refine ::Faraday::Utils.singleton_class do
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

                # Look for a key (everything except whitespace, = and ;:
                # a tab too may come before =, RFC 7230's BWS)
                #   if not well formed consumed until next delimiter
                # (\# keeps `#$&` literal: unescaped, a regex interpolates
                # the last match into it)
                if key = s.scan(/[^\s=;]+/)&.downcase
                    valid = key.match?(/\A[\w\-!\#$&+.^]+(?:\*\d+\*?|\*)?\z/i)
                else
                    s.scan(/[^;]*/)
                    next
                end

                # Look for a value assignment
                #   if not store it without value
                unless s.skip(/\s*=\s*/)
                    params[key] ||= true if valid
                    next
                end

                # Retrieve value
                #   if string quoted un-escape it
                value = if s.peek(1) == '"'
                            s.scan(/"((?:\\.|[^"\\])*)"?/)
                            (s[1] || '').gsub(/\\(.)/, '\1')
                        else
                            s.scan(/[^\s;]*/) || ''
                        end
                # A key refused still has its value read, so that parsing
                # does not resume inside it
                next unless valid

                # Deal with continuation: key*<n>, or key*<n>* encoded
                if key =~ /\A(.+)\*(\d+)(\*)?\z/
                    (parts[$1] ||= {})[$2.to_i] = [ value, !$3.nil? ]
                elsif key.end_with?('*')
                    params[key] ||= Utils.ext_value(value)
                else
                    params[key] ||= Utils.to_utf8(value, 'UTF-8')
                end
            end

            # RFC 2231 continuations: one value, whose segments may mix
            # encoded and plain ones.  Joined in order, only the encoded
            # ones percent-decoded, all in the charset the first one
            # names; under key* if any segment is encoded, else key.
            parts.each do |key, segs|
                segs = segs.sort_by(&:first).map(&:last)
                if segs.none? {|_, enc| enc }
                    params[key] = Utils.to_utf8(segs.map(&:first).join, 'UTF-8')
                    next
                end
                charset = 'UTF-8'
                if segs[0][1] && segs[0][0] =~ EXT_VALUE
                    charset = $1
                    segs[0] = [ $3, true ]
                end
                bytes = segs.map {|v, enc| enc ? Utils.pct_decode(v) : v.b }.join
                params["#{key}*"] = Utils.to_utf8(bytes, charset)
            end

            params
        end
    end
end
end
end
