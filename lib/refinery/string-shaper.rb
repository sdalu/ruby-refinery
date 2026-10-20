module Refinery
module StringShaper
    refine String do
        # "fooBar" / "FooBar" => "foo_bar".  A run of two or more
        # capitals (or digits) is a word of its own: "HTTPServer" =>
        # "http_server", while "IPv6Address" => "ipv6_address".  With
        # +split_acronyms+ false, an uppercase letter starts a word only
        # after a lowercase letter or a digit, so a run of capitals
        # merges with the next word: "HTTPServer" => "httpserver".
        def snakize(split_acronyms: true)
            s = self
            s = s.gsub(/([A-Z\d]{2,})([A-Z][a-z])/, '\1_\2') if split_acronyms
            s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        end

        # snakize's opposite: "foo_bar" => "fooBar", or "FooBar" with
        # +upper+.  Empty words (a doubled, leading or trailing
        # underscore) are dropped.
        def camelize(upper: false)
            first, *rest = self.split('_').reject(&:empty?)
            return '' if first.nil?
            first = upper ? first.capitalize : first.downcase
            first + rest.map(&:capitalize).join
        end
    end
end
end
