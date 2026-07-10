require "cloud_model/config_modules/api"

module CloudModel
  module Api
    module Qemu
      class Config
        # Directory where VM disk images and state files are stored.
        # Defaults to <cloudmodel_data_dir>/vms
        attr_writer :vm_dir
        def vm_dir
          @vm_dir || File.join(CloudModel.config.data_directory, 'vms')
        end

        # Path to the cached Debian genericcloud base image (qcow2).
        # Shared across all VMs — never modified in place.
        attr_writer :base_image_path
        def base_image_path
          @base_image_path || File.join(vm_dir, 'debian-base.qcow2')
        end

        # Download URL for the Debian genericcloud image.
        # Defaults to the latest Debian bookworm genericcloud qcow2 for the current arch.
        # Override if you need a specific version or a local mirror:
        #   config.api.qemu.base_image_url = "https://mirror.example.com/debian-12-genericcloud-amd64.qcow2"
        attr_accessor :base_image_url

        # Disk image size for new system disks (qemu-img format, e.g. "80G")
        attr_writer :disk_size
        def disk_size
          @disk_size || '80G'
        end

        # RAM in MB
        attr_writer :ram
        def ram
          @ram || 4096
        end

        # Number of vCPUs
        attr_writer :cpus
        def cpus
          @cpus || 2
        end

        # QEMU system binary.  Auto-detected from host architecture when nil.
        attr_writer :qemu_binary
        def qemu_binary
          @qemu_binary || case RbConfig::CONFIG['host_cpu']
                          when /arm|aarch64/ then 'qemu-system-aarch64'
                          else 'qemu-system-x86_64'
                          end
        end

        # UEFI firmware path.  Required for aarch64; optional for x86_64.
        attr_writer :qemu_firmware
        def qemu_firmware
          return @qemu_firmware if @qemu_firmware
          candidates = [
            '/opt/homebrew/share/qemu/edk2-aarch64-code.fd',
            '/usr/local/share/qemu/edk2-aarch64-code.fd',
            '/usr/share/qemu/OVMF.fd'
          ]
          candidates.find { |f| File.exist?(f) }
        end

        # Root password set on the rescue VM and stored as initial_root_pw.
        attr_writer :root_password
        def root_password
          @root_password || 'rescue'
        end

        # Number of system disk images to create (1 = single disk / degraded RAID,
        # 2 = full RAID-1 like a real server).
        # The rescue disk (Debian) is additional and not counted here.
        attr_writer :disk_count
        def disk_count
          @disk_count || 2
        end

        # Seconds to wait for SSH after VM boot before giving up.
        attr_writer :boot_timeout
        def boot_timeout
          @boot_timeout || 300
        end

        # External network block for VM host IPs (must be at least a /16).
        # The first /24 (third octet 0) is reserved for primary_address IPs.
        # Each subsequent /24 (third octet 1, 2, …) is allocated as a guest
        # address subnet (host.addresses) for one VM host.
        # Example: "10.66.0.0/16"
        attr_writer :external_network
        def external_network
          @external_network || raise("config.api.qemu.external_network is not set")
        end
      end
    end
  end
end

module CloudModel::Api::Qemu::ConfigInclude
  def qemu
    @qemu ||= CloudModel::Api::Qemu::Config.new
  end
end

CloudModel::ConfigModules::Api.class_eval { include CloudModel::Api::Qemu::ConfigInclude }
