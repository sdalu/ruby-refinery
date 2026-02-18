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
                  "enable warnings" do
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

            self.on "-v", "--verbose"

            self.on "-V", "--version" do
                puts Version
                exit
            end

            self.separator ""
        end
    end

    def self.process(opts, logger: nil)
        logger.level = opts[:verbose] ? :info : :warn if logger
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
