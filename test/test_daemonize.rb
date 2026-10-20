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
