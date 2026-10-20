require 'minitest/autorun'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'lib')

# Load an optional dependency's refinement, or skip: faraday, mqtt and
# tty-progressbar are not runtime dependencies of the gem, so a host
# without one cannot test what needs it -- and says so, rather than
# passing quietly.
def require_optional(path)
    require path
    true
rescue LoadError => e
    warn "skipping #{path}: #{e.message}"
    false
end

module Subprocess
    # Run a Ruby snippet against lib/, returning [stdout, stderr, status].
    # The child puts lib/ first itself, once RUBYOPT has run: under
    # `bundle exec`, RUBYOPT's bundler/setup puts the bundle's copy of
    # the refinery ahead of -I, and the child tested that copy instead.
    # The environment is kept, so that the child still finds the
    # bundle's other gems (mqtt).  Same line, so line numbers hold.
    def ruby_run(code)
        lib = File.join(ROOT, 'lib')
        Open3.capture3(RbConfig.ruby, '-I', lib,
                       '-e', "$LOAD_PATH.unshift(#{lib.inspect}); #{code}")
    end
end
