require 'rake/clean'
require 'rake/testtask'

# What a build leaves behind: yard's object database, then the rendered
# documentation and packaged gems.  Each is a path this repository's own
# tasks write, and each is in .gitignore.
CLEAN.include('.yardoc')
CLOBBER.include('doc', 'pkg', '*.gem')

Rake::TestTask.new do |t|
    t.test_files = FileList['test/test_*.rb']
    t.verbose    = true
    t.warning    = false
end

task :default => :test

begin
    require 'yard'
    YARD::Rake::YardocTask.new do |t|
        t.files   = [ 'lib/**/*.rb' ]
        t.options = [ '-m', 'markdown' ]
    end
rescue LoadError
    # yard not installed: no documentation task
end
