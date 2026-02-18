# -*- encoding: utf-8 -*-
$:.unshift File.expand_path("../lib", __FILE__)
require "refinery/_version"

Gem::Specification.new do |s|
  s.name          = "refinery"
  s.version       = Refinery::VERSION
  s.authors       = [ "Stephane D'Alu" ]
  s.email         = [ "sdalu@sdalu.com" ]
  s.homepage      = "https://github.com/sdalu/ruby-refinery"
  s.summary       = "Collection of ruby refinements"

  s.add_development_dependency "irb"
  s.add_development_dependency "yard"
  s.add_development_dependency "rake"

  s.license       = 'MIT'

  s.files         = %w[ LICENSE Gemfile refinery.gemspec ] +
		     Dir['lib/**/*.rb']
end
