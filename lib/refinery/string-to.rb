require 'cgi'

module Refinery
module StringTo
    refine String do
        def to_filename      = gsub(%r{[/\0]}, "_").strip
        def to_html          = CGI.escapeHTML(self)
        def to_uri_component = CGI.escapeURIComponent(self)
    end
end
end
