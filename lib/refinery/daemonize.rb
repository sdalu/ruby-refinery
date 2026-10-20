# frozen_string_literal: true

# See: https://codeincomplete.com/articles/ruby-daemons/#pid-file-management

require 'securerandom'

module Refinery
module Daemonize
    refine Process.singleton_class do
        # The pid is written aside and linked into place (link(2) fails
        # if the pidfile exists), so that the pidfile never exists empty:
        # created empty then written, another start reading it in between
        # found no pid, ruled it dead and took it over.
        #
        # Check, delete and link happen under pid_lock: two starters over
        # a stale pidfile both found it dead, and the slower deleted the
        # faster's fresh pidfile by path, and linked its own.
        def pid_write(file)
            owner = Process.pid
            # A name no one can guess, created afresh and not through a
            # link: <pidfile>.<pid>.tmp, written following links, overwrote
            # the target of a symlink planted there (in /tmp, by anyone),
            # and the pidfile became a hard link to it.  A name of its own,
            # beside the pidfile: the pidfile's name plus a suffix could
            # pass NAME_MAX.
            tmp   = File.join(File.dirname(file), ".#{owner}.#{SecureRandom.hex(6)}.tmp")
            ::File.open(tmp, ::File::WRONLY | ::File::CREAT | ::File::EXCL |
                             ::File::NOFOLLOW, 0644) { it.write(owner.to_s) }
            begin
                Process.pid_lock(file) do
                    loop do
                        File.link(tmp, file)
                        break
                    rescue Errno::EEXIST
                        Process.pid_check!(file)
                    end
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
            Process.pid_lock(file) do
                case pid_status(file)
                when :running, :not_owned
                    # Our own pid, in a pidfile not yet written: a stale
                    # one whose pid came round again
                    if ::File.read(file).to_i == Process.pid
                        ::File.delete(file)
                        next
                    end
                    $stderr.puts "A server is already running. Check #{file}"
                    exit(1)
                when :dead
                    ::File.delete(file)
                end
            end
        rescue Errno::ENOENT     # removed meanwhile
            nil
        end

        # An exclusive flock on <file>.lock, around the block; reentrant
        # within a thread (pid_write's check runs under its own lock).
        # The lock file stays: removing it would let a waiter lock an
        # unlinked file while another locks a new one.
        def pid_lock(file)
            held = (Thread.current[:refinery_pid_locks] ||= {})
            return yield if held[file]
            # (not through a link: a symlink planted there would have the
            # lock create a file wherever it points)
            ::File.open("#{file}.lock", ::File::RDWR | ::File::CREAT | ::File::NOFOLLOW,
                        0644) do |lock|
                lock.flock(::File::LOCK_EX)
                held[file] = true
                yield
            ensure
                held.delete(file)
            end
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
            # Not a process: 0 and below would ask kill(2) about a whole
            # process group, past a C int it raises RangeError
            return :dead unless pid.positive?
            Process.kill(0, pid)      # check process status
            :running
        rescue RangeError
            :dead
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
