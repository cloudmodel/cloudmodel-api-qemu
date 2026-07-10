source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Specify the gem's dependencies in cloudmodel-api-qemu.gemspec.
gemspec

# cloudmodel is not published to rubygems — resolve it from the sibling
# checkout (same layout the README describes for consuming apps).
gem 'cloudmodel', path: '../cloudmodel'

group :test do
  gem 'rspec-rails'
  gem 'fuubar'
end
