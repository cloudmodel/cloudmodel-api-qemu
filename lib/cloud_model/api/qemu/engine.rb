module CloudModel
  module Api
    module Qemu
      class Engine < ::Rails::Engine
        isolate_namespace CloudModel::Api::Qemu

        # NOTE: lib/tasks/**/*.rake is loaded automatically by Rails::Engine —
        # an explicit rake_tasks block here would register every task twice
        # (and rake executes accumulated task bodies twice).

        # Workers are reloadable app classes of the cloudmodel engine, so the
        # VM overrides must be (re-)prepended on every code reload.
        config.to_prepare do
          CloudModel::Api::Qemu::WorkerPatches.install!
        end
      end
    end
  end
end
