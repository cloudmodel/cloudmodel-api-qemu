ENV["RAILS_ENV"] ||= 'test'

require File.expand_path("../dummy/config/environment", __FILE__)
require 'rspec/rails'

# Same wiring a consuming app does in its initializer (see README).
CloudModel::Host.include CloudModel::Api::Qemu::Host

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.order = :random
  Kernel.srand config.seed

  # The QEMU config singleton is memoized on CloudModel.config.api — restore
  # every attribute after each example so config-tweaking specs can't leak.
  config.around(:each) do |example|
    qemu_config = CloudModel.config.api.qemu
    saved = qemu_config.instance_variables.to_h { |v| [v, qemu_config.instance_variable_get(v)] }
    example.run
  ensure
    (qemu_config.instance_variables - saved.keys).each { |v| qemu_config.remove_instance_variable(v) }
    saved.each { |v, val| qemu_config.instance_variable_set(v, val) }
  end
end
