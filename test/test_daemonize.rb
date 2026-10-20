require_relative 'helper'
require 'refinery/daemonize'

class TestDaemonize < Minitest::Test
    include Subprocess
    using Refinery::Daemonize

    def setup
        @dir = Dir.mktmpdir
        @pid = File.join(@dir, 'app.pid')
    end

    def teardown = FileUtils.rm_rf(@dir)

    # A pid that names no process: one that has just been reaped
    def dead_pid
        pid = Process.spawn(RbConfig.ruby, '-e', '')
        Process.wait(pid)
        pid
    end

    def test_status
        assert_equal :exited,  Process.pid_status(@pid)
        File.write(@pid, Process.pid.to_s)
        assert_equal :running, Process.pid_status(@pid)
        File.write(@pid, dead_pid.to_s)
        assert_equal :dead,    Process.pid_status(@pid)
        File.write(@pid, 'garbage')
        assert_equal :dead,    Process.pid_status(@pid)
    end

    def test_pid_write_replaces_a_dead_pidfile_and_removes_it_at_exit
        File.write(@pid, dead_pid.to_s)
        out, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            Process.pid_write(#{@pid.inspect})
            print File.read(#{@pid.inspect})
        RUBY
        assert st.success?, err
        assert_match(/\A\d+\z/, out)
        refute File.exist?(@pid), 'pidfile left behind at exit'
    end

    # Regression: a forked child inherited the at_exit cleanup and took
    # the pidfile with it when it ended
    def test_a_forked_child_leaves_the_pidfile
        out, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            Process.pid_write(#{@pid.inspect})
            Process.wait(fork { })
            print File.exist?(#{@pid.inspect})
        RUBY
        assert st.success?, err
        assert_equal 'true', out
        refute File.exist?(@pid), 'pidfile left behind at exit'
    end

    # Regression: the pidfile was created empty and written after, and
    # an empty one read as pid 0, :dead, so a second start in that
    # window took it over.  It now appears complete or not at all; one
    # found empty is left alone.
    def test_an_empty_pidfile_is_not_taken_over
        File.write(@pid, '')
        _, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            Process.pid_write(#{@pid.inspect})
        RUBY
        assert_equal 1, st.exitstatus, err
        assert_equal '', File.read(@pid)
        File.write(@pid, '')
        File.utime(Time.now - 60, Time.now - 60, @pid)     # long abandoned
        _, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            Process.pid_write(#{@pid.inspect})
        RUBY
        assert st.success?, err
    end

    # Regression: a stale pidfile holding this process's own pid (pid
    # reuse) read as :running, and the start refused
    def test_own_pid_in_a_stale_pidfile_is_stale
        out, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            File.write(#{@pid.inspect}, Process.pid.to_s)
            Process.pid_write(#{@pid.inspect})
            print File.read(#{@pid.inspect})
        RUBY
        assert st.success?, err
        assert_match(/\A\d+\z/, out)
    end

    # The at_exit cleanup leaves a pidfile that is no longer its own
    def test_at_exit_leaves_a_pidfile_now_held_by_another
        _, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            Process.pid_write(#{@pid.inspect})
            File.write(#{@pid.inspect}, '99999999')
        RUBY
        assert st.success?, err
        assert_equal '99999999', File.read(@pid)
    end

    # Regression: two starters over a stale pidfile could both see it
    # dead, the slower deleting the faster's fresh pidfile by path, and
    # both ran.  Check, delete and link now happen under a lock beside
    # the pidfile: a starter waits for it.
    def test_a_starter_waits_for_the_pidfile_lock
        out = File.join(@dir, 'out')
        File.open("#{@pid}.lock", File::RDWR | File::CREAT) do |lock|
            lock.flock(File::LOCK_EX)
            child = Process.spawn(RbConfig.ruby, '-I', File.join(ROOT, 'lib'), '-e', <<~RUBY)
                require 'refinery/daemonize'
                using Refinery::Daemonize
                Process.pid_write(#{@pid.inspect})
                File.write(#{out.inspect}, File.read(#{@pid.inspect}))
            RUBY
            sleep 0.5
            refute File.exist?(out), 'pid_write went ahead under another lock'
            lock.flock(File::LOCK_UN)
            Process.wait(child)
            assert_equal child.to_s, File.read(out)
        end
    end

    def test_refuses_to_start_beside_a_running_one
        File.write(@pid, Process.pid.to_s)
        _, err, st = ruby_run(<<~RUBY)
            require 'refinery/daemonize'
            using Refinery::Daemonize
            Process.pid_write(#{@pid.inspect})
        RUBY
        assert_equal 1, st.exitstatus
        assert_match(/already running/, err)
        assert_equal Process.pid.to_s, File.read(@pid), 'pidfile overwritten'
    end
end
