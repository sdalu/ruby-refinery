require_relative 'helper'
require 'refinery/cli'

class TestCLI < Minitest::Test
    include Subprocess

    # Regression: cli.rb refined OptionParser without loading it
    def test_loads_on_its_own
        _, err, st = ruby_run("require 'refinery/cli'")
        assert st.success?, err
    end

    using Refinery::CLI::OptRuby
    using Refinery::CLI::OptCommon
    using Refinery::CLI::OptProcess

    def parse(*argv)
        opts = {}
        OptionParser.new {|o|
            o.options_ruby
            o.options_common
            o.options_process
        }.parse!(argv, into: opts)
        opts
    end

    def test_verbosity_counts
        assert_equal 2, parse('-v', '-v')[:verbose]
        assert_equal 3, parse('-vvv')[:verbose]
    end

    # -v takes no argument: what follows it stays a positional
    def test_verbose_leaves_the_next_argument_alone
        argv = %w[ -v file.txt ]
        opts = {}
        OptionParser.new { it.options_common }.parse!(argv, into: opts)
        assert_equal 1, opts[:verbose]
        assert_equal %w[ file.txt ], argv
    end

    def test_level
        level = Refinery::CLI::OptCommon.method(:level)
        assert_equal 'warn',  level.(parse)
        assert_equal 'info',  level.(parse('-v'))
        assert_equal 'debug', level.(parse('-vv'))
        assert_equal 'debug', level.(parse('-vvvv'))
        assert_equal 'error', level.(parse('-q', '-vv'))
    end

    def test_process_options
        opts = parse('-d', '-p', '-l', 'x.log')
        assert opts[:daemonize]
        assert opts.include?(:pid)
        assert_nil opts[:pid]
        assert_equal 'x.log', opts[:log]
    end

    def test_refuses_an_unknown_option
        assert_raises(OptionParser::InvalidOption) { parse('--nope') }
    end
end
