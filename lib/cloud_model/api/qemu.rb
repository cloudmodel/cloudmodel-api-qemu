require "cloudmodel"

require "cloud_model/api/qemu/version"
require "cloud_model/api/qemu/config"
require "cloud_model/api/qemu/apt_cache"
require "cloud_model/api/qemu/host"
require "cloud_model/api/qemu/ip_allocator"
require "cloud_model/api/qemu/server"
require "cloud_model/api/qemu/worker_patches"
require "cloud_model/api/qemu/engine"

module CloudModel
  module Api
    module Qemu
      # Deterministic MAC for a VM's shared inter-VM (vmnet) NIC, derived from
      # its primary_address so server.rb (the -device MAC) and worker_patches.rb
      # (the systemd .link that renames the NIC) agree without a stored file.
      # Locally-administered `52:54` prefix + the four IP octets → unique per
      # host as long as primary_addresses are.
      def self.vmnet_mac(ip)
        "52:54:" + ip.to_s.split('.').map { |o| "%02x" % o.to_i }.join(':')
      end
    end
  end
end
