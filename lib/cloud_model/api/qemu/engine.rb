module CloudModel
  module Api
    module Qemu
      class Engine < ::Rails::Engine
        isolate_namespace CloudModel::Api::Qemu

        rake_tasks do
          load File.expand_path('../../../../tasks/dev_vm.rake', __FILE__)
        end
      end
    end
  end
end
