$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require "mogilefs"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "mogilefs-client"
  s.version     = MogileFS::VERSION
  s.authors     = ["Danga Interactive"]
  s.email       = ["brad@danga.com"]
  s.homepage    = "https://github.com/teknobingo/mogilefs-client"
  s.summary     = "A Ruby MogileFS client"
  s.description = <<THE_END
A Ruby MogileFS client.  MogileFS is a distributed filesystem written
by Danga Interactive.  This client only supports HTTP.
THE_END

  s.files = Dir["{bin,lib}/**/*"] + ["LICENSE.txt", "README.txt"]
  s.test_files = Dir["test/**/*"]

  s.autorequire = 'mogilefs'
end
