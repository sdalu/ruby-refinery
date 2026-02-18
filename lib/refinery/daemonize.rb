# frozen_string_literal: true

# See: https://codeincomplete.com/articles/ruby-daemons/#pid-file-management

module Refinery
module Daemonize
    refine Process.singleton_class do
        def pid_write(file)
            File.write(file, Process.pid.to_s,
                       mode: ::File::CREAT | ::File::EXCL | ::File::WRONLY)
            at_exit do
                File.delete(file) if File.exist?(file)
            end
        rescue Errno::EEXIST
            Process.pid_check!(file)
            retry
        end

        def pid_check!(file)
            case pid_status(file)
            when :running, :not_owned
                $stderr.puts "A server is already running. Check #{file}"
                exit(1)
            when :dead
                ::File.delete(file)
            end
        end

        def pid_status(file)
            return :exited unless ::File.exist?(file)
            pid = ::File.read(file).to_i
            return :dead if pid == 0
            Process.kill(0, pid)      # check process status
            :running
        rescue Errno::ESRCH
            :dead
        rescue Errno::EPERM
            :not_owned
        end
    end
end
end
