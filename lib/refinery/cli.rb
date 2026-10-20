require_relative 'daemonize'

module Refinery
module CLI

using Refinery::Daemonize

module OptRuby
    refine OptionParser do
        def options_ruby
            self.separator "Ruby options:"

            self.on "-I", "--include PATH",  String,
                  "an additional $LOAD_PATH" do |val|
                $LOAD_PATH.unshift(*val.split(':').map{|v| File.expand_path(v)})
            end

            self.on "--debug",
                  "set $DEBUG to true" do
                $DEBUG = true
            end

            self.on "--warn",
                  "enable ruby warnings" do
                $-w    = true
            end

            self.separator ""
        end
    end
end

module OptCommon
    refine OptionParser do
        def options_common
            self.separator "Common options:"

            self.on "-h", "--help" do
                puts self.to_s
                exit
            end

            # Repeatable, so the option holds a count: -v info, -vv debug
            verbosity = 0
            self.on "-v", "--verbose",
                    "Verbose output, repeat for more (-v info, -vv debug)" do
                verbosity += 1
            end

            self.on "-q", "--quiet",
                    "Quiet mode (errors only)"

            self.on "-V", "--version" do
                puts Version
                exit
            end

            self.separator ""
        end
    end

    LEVELS = %w[ warn info debug ].freeze

    # The log level the options ask for: warn, info with -v, debug with
    # -vv, error with -q
    def self.level(opts)
        return 'error' if opts[:quiet]
        LEVELS[opts[:verbose].to_i.clamp(0, LEVELS.size - 1)]
    end

    def self.process(opts, logger: nil)
        logger.level = level(opts) if logger
    end
end

module OptProcess
    refine OptionParser do
        def options_process
            self.separator "Process options:"

            self.on "-d", "--daemonize",
                    "run daemonized in the background"

            self.on "-p", "--pid [PIDFILE]", String,
                    "the pid filename"

            self.on "-l", "--log [LOGFILE]", String,
                    "the log filename (default: stdout)"

            self.separator ""
        end
    end

    def self.process(opts, logger: nil, progname:)
        $pidfile = if opts.include?(:pid)
                       opts[:pid] || File.join('/tmp', progname)
                   end
        # Process startup
        Process.pid_check!($pidfile) if $pidfile
        Process.daemon               if opts[:daemonize]
        Process.pid_write($pidfile)  if $pidfile

        # Logger
        logger.reopen(opts[:log])    if logger && opts[:log]
    end
end

end
end
