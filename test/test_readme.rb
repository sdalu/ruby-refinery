require_relative 'helper'

# The README names each refinement by constant and each file by require
# path, and nothing else ties either to the code: it said
# `Refinery::FaradayDownloader` and `require 'refinery/downloader'`,
# neither of which existed, and left `Refinery::StringTo` out entirely.
class TestReadme < Minitest::Test
    include Subprocess

    README   = File.read(File.join(ROOT, 'README.md')).freeze
    REQUIRES = README.scan(/^require '(refinery\/[^']+)'/).flatten.freeze
    OPTIONAL = %w[ faraday tty-progressbar mqtt ].freeze

    def lib_files
        Dir.glob('refinery/**/*.rb', base: File.join(ROOT, 'lib'))
           .map { it.delete_suffix('.rb') } - %w[ refinery/_version ]
    end

    def test_every_documented_require_is_a_file
        refute_empty REQUIRES
        assert_empty REQUIRES - lib_files
    end

    # The Faraday utils come in through the downloader, and refinery/time
    # is an alias the README names in prose
    def test_every_file_is_documented
        assert_empty lib_files - REQUIRES - %w[ refinery/faraday/utils refinery/time ]
    end

    # Those whose gem is absent here cannot be checked, and are skipped
    # one by one rather than taking the rest down with them
    NEEDS = { 'Refinery::Faraday::Downloader' => 'faraday',
              'Refinery::MQTTResilient'       => 'mqtt' }.freeze

    def test_every_documented_refinement_exists
        names = README.scan(/^### `(Refinery::[\w:]+)`/).flatten
        assert_operator names.size, :>=, 15
        _, err, st = ruby_run(<<~RUBY)
            absent = []
            #{REQUIRES.inspect}.each do |f|
                require f
            rescue LoadError => e
                raise unless #{OPTIONAL.inspect}.include?(e.path)
                absent << e.path
            end
            names   = #{names.inspect}.reject { absent.include?(#{NEEDS.inspect}[it]) }
            missing = names.reject { Object.const_defined?(it) }
            abort "undefined: \#{missing.join(' ')}" unless missing.empty?
            warn "not checked, gem absent: \#{absent.uniq.join(' ')}" unless absent.empty?
        RUBY
        assert st.success?, err
    end

    def test_the_documented_test_command_is_the_one_that_runs
        assert_match(/^rake test$/, README)
        assert_match(/Rake::TestTask/, File.read(File.join(ROOT, 'Rakefile')))
    end
end
