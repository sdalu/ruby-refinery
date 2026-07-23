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
        return str[0, max] if keep <= 0
        head = keep / 2
        tail = keep - head
        "#{str[0, head]}#{ellipsis}#{tail.zero? ? '' : str[-tail..]}"
    end

    def call(env)
        on_data    = env.request.on_data
        bar        = TTY::ProgressBar.new(options[:format], **options[:options])
        filename   = nil
        configured = false

        env.request.on_data = proc do |chunk, overall_size, resp_env|
            on_data&.call(chunk, overall_size, resp_env)
            unless configured
                total = resp_env.response_headers['content-length']&.to_i
                total = nil if total&.zero?
                bar.update(total:)

                # Prefer the filename resolved by the downloader (final saved
                # name), falling back to the basename extracted from the uri.
                filename   = resp_env[:download_filename] ||
                             File.basename(resp_env.url.path.to_s)
                filename   = self.class.shorten(filename, options[:shorten]) \
                                 if options[:shorten]
                configured = true
            end
            bar.advance(chunk.bytesize, filename:)
        end

        super
    end
end
end
end

# Register it
Faraday::Response.register_middleware(progress_bar: Refinery::Faraday::ProgressBar)
