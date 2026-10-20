require 'faraday'
require 'tty-progressbar'

module Refinery
module Faraday
class ProgressBar < ::Faraday::Middleware
    DEFAULT_OPTIONS = {
        :format  => "[:bar] :filename :current_byte/:total_byte :percent ETA::eta",
        :shorten => false,
        :options => { bar_format: :box, clear: true }
    }.freeze

    # Shorten a string by eliding its middle, keeping the head and tail,
    # e.g. "biglongfile" with max 10 => "big...file".
    #
    # @param str      [String]  the string to shorten
    # @param max      [Integer] maximum resulting length
    # @param ellipsis [String]  marker inserted in place of the elided middle
    #
    # @return [String]
    def self.shorten(str, max, ellipsis: '...')
        return str if max.nil? || str.length <= max
        keep = max - ellipsis.length
        return str[0, [max, 0].max] if keep <= 0
        head = keep / 2
        tail = keep - head
        "#{str[0, head]}#{ellipsis}#{tail.zero? ? '' : str[-tail..]}"
    end

    def call(env)
        on_data = env.request.on_data
        # Only a request already streaming (a download): an on_data of
        # ours would make any other one stream, and leave its body empty
        return super unless on_data
        bar     = nil

        env.request.on_data = proc do |chunk, overall_size, resp_env|
            on_data&.call(chunk, overall_size, resp_env)
            bar ||= new_bar(resp_env)
            bar.advance(chunk.bytesize)
        end

        super
    end

    private

    # The bar is built on the first chunk, once the filename is known, with
    # the filename written into the format: TTY::ProgressBar sizes the bar
    # from the format, so a :filename token filled in later would make the
    # line wider than the terminal, and every redraw would wrap.
    def new_bar(env)
        total = env.response_headers['content-length']&.to_i
        total = nil if total&.zero?
        format = options[:format].gsub(':filename') { filename(env) }
        TTY::ProgressBar.new(format, **options[:options], total:)
    end

    # Prefer the filename resolved by the downloader (final saved name),
    # falling back to the basename extracted from the uri.
    #
    # The name is spliced into the format, which TTY::ProgressBar reads:
    # a control character would reach the terminal as is, and a :bar or
    # :percent in the name would be drawn.  So controls show as '?', and
    # ':' as its look-alike U+2236 (the file itself keeps its ':').
    def filename(env)
        name = env[:download_filename] || File.basename(env.url.path.to_s)
        name = name.gsub(/[[:cntrl:]]/, '?').tr(':', "∶")
        options[:shorten] ? self.class.shorten(name, options[:shorten]) : name
    end
end
end
end

# Register it
Faraday::Response.register_middleware(progress_bar: Refinery::Faraday::ProgressBar)
