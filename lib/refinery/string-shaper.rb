module Refinery
module StringShaper
    refine String do
        # "fooBar" / "FooBar" => "foo_bar".  An uppercase letter starts
        # a word only after a lowercase letter or a digit, so a run of
        # capitals stays one word: "HTTPServer" => "httpserver".
        def snakize
            self.gsub(/([a-z\d])([A-Z])/) do
                "#{$1}_#{$2}"
            end.downcase
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
