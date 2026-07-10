require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)
# The entry file diverges from the gem name (cloud_model/api/qemu), so
# Bundler.require does not pick it up automatically — same as consuming
# apps, which declare `require: 'cloud_model/api/qemu'` in their Gemfile.
require "cloud_model/api/qemu"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = false

    # The dummy app exists only to boot the cloudmodel engine (whose worker
    # classes the QEMU patches prepend into) for the spec suite.
    config.generators do |g|
      g.orm :mongoid
      g.test_framework :rspec
    end
  end
end
