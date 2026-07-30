# frozen_string_literal: true

module CloudModel
  module Api
    module Qemu
      # Host-side network + split-horizon DNS setup for the local QEMU dev cloud.
      #
      # Solves two problems, each derived from a single source of truth (nothing
      # hardcoded): routing from the workstation to the dev guest subnets, and
      # domain-scoped DNS for the dev cloud's names (merged from
      # CloudModel.config.additional_hosts and the CloudModel::AddressResolution
      # registry). Session-scoped: `up`/`down`, idempotent, nothing persisted
      # across reboots, no permanent root daemon.
      #
      # See lib/tasks/dev_net.rake for the `dev:net:{up,down,status,plan}` tasks.
      # The privileged executor (libexec/cm-dev-net-exec) and the DNS forwarder
      # (libexec/cm-dev-net-dns) are standalone stdlib scripts.
      module DevNet
        class Error < StandardError; end

        # Absolute path to a shipped standalone helper under libexec/.
        def self.libexec(name)
          File.expand_path(File.join('..', '..', '..', '..', 'libexec', name), __dir__)
        end
      end
    end
  end
end

require 'cloud_model/api/qemu/dev_net/validator'
require 'cloud_model/api/qemu/dev_net/planner'
require 'cloud_model/api/qemu/dev_net/status'
require 'cloud_model/api/qemu/dev_net/ca'
