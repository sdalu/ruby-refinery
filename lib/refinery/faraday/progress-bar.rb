require 'faraday'
require 'tty-progressbar'

module Refinery
module Faraday
class ProgressBar < ::Faraday::Middleware
    DEFAULT_OPTIONS = {
        :format  => "[:bar] :current_byte/:total_byte :percent ETA::eta",
        :options => { bar_format: :box, clear: true }
    }.freeze

    def call(env)
        on_data    = env.request.on_data
        bar        = TTY::ProgressBar.new(options[:format], **options[:options])
        configured = false

        env.request.on_data = proc do |chunk, overall_size, resp_env|
            on_data&.call(chunk, overall_size, resp_env)
            unless configured
                total = resp_env.response_headers['content-length']&.to_i
                total = nil if total&.zero?
                bar.update(total:)
                configured = true
            end
            bar.advance(chunk.bytesize)
        end

        super
    end
end
end
end

# Register it
Faraday::Response.register_middleware(progress_bar: Refinery::Faraday::ProgressBar)
