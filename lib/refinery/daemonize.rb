# frozen_string_literal: true

# See: https://codeincomplete.com/articles/ruby-daemons/#pid-file-management

module Refinery
module Daemonize
    refine Process.singleton_class do
        # The pid is written aside and linked into place (link(2) fails
        # if the pidfile exists), so that the pidfile never exists empty:
        # created empty then written, another start reading it in between
        # found no pid, ruled it dead and took it over.
        def pid_write(file)
            owner = Process.pid
            tmp   = "#{file}.#{owner}.tmp"
            File.write(tmp, owner.to_s)
            begin
                loop do
                    File.link(tmp, file)
                    break
                rescue Errno::EEXIST
                    Process.pid_check!(file)
                end
            ensure
                File.delete(tmp) if File.exist?(tmp)
            end

            # Only in this process: a forked child inherits the handler,
            # and must not take the pidfile with it when it ends; nor
            # once the pidfile is another's
            at_exit do
                if Process.pid == owner &&
                   (::File.read(file).to_i == owner rescue false)
                    File.delete(file)
                end
            end
        end

        def pid_check!(file)
            case pid_status(file)
            when :running, :not_owned
                # Our own pid, in a pidfile not yet written: a stale one
                # whose pid came round again
                if ::File.read(file).to_i == Process.pid
                    ::File.delete(file)
                    return
                end
                $stderr.puts "A server is already running. Check #{file}"
                exit(1)
            when :dead
                ::File.delete(file)
            end
        rescue Errno::ENOENT     # removed meanwhile
            nil
        end

        # A pidfile still empty and recent is one being written (as an
        # older version did, in two steps): :running.
        def pid_status(file)
            return :exited unless ::File.exist?(file)
            data = ::File.read(file)
            if data.strip.empty?
                return Time.now - ::File.mtime(file) < 5 ? :running : :dead
            end
            pid = data.to_i
            return :dead if pid == 0
            Process.kill(0, pid)      # check process status
            :running
        rescue Errno::ENOENT     # removed meanwhile
            :exited
        rescue Errno::ESRCH
            :dead
        rescue Errno::EPERM
            :not_owned
        end
    end
end
end
