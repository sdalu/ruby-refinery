require 'cgi'

module Refinery
module StringTo
    refine String do
        # '', '.' and '..' name no file of their own: underscores
        def to_filename
            name = gsub(%r{[/\0]}, "_").strip
            name.match?(/\A\.{0,2}\z/) ? '_' * [ name.size, 1 ].max : name
        end

        def to_html          = CGI.escapeHTML(self)
        def to_uri_component = CGI.escapeURIComponent(self)
    end
end
end
