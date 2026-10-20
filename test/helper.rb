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
    # Run a Ruby snippet against lib/, returning [stdout, stderr, status]
    def ruby_run(code)
        Open3.capture3(RbConfig.ruby, '-I', File.join(ROOT, 'lib'),
                       '-e', code)
    end
end
