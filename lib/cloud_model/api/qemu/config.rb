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

        # The architecture of the machine the VMs run on ('arm64'/'amd64').
        # VMs of this arch use hardware acceleration (HVF/KVM); any other
        # arch is fully emulated via TCG — slower, but lets an arm64
        # workstation exercise the production amd64 stack and vice versa.
        def self.workstation_arch
          RbConfig::CONFIG['host_cpu'] =~ /arm|aarch64/ ? 'arm64' : 'amd64'
        end

        # Path to the cached Debian genericcloud base image (qcow2) for the
        # given architecture. Shared across all VMs — never modified in place.
        attr_writer :base_image_path
        def base_image_path arch = nil
          @base_image_path || File.join(vm_dir, "debian-base-#{arch || Config.workstation_arch}.qcow2")
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

        # QEMU system binary for the given VM architecture.
        # QEMU system binary for the given VM (Debian) architecture. Only
        # amd64/arm64 are boot-wired; the others are mapped for future use.
        attr_writer :qemu_binary
        def qemu_binary arch = nil
          return @qemu_binary if @qemu_binary
          case (arch || Config.workstation_arch)
          when 'arm64'   then 'qemu-system-aarch64'
          when 'amd64'   then 'qemu-system-x86_64'
          when 'ppc64el' then 'qemu-system-ppc64'
          when 'riscv64' then 'qemu-system-riscv64'
          when 'loong64' then 'qemu-system-loongarch64'
          else 'qemu-system-x86_64'
          end
        end

        # UEFI firmware path for the given VM architecture. Required for
        # aarch64 and for amd64 systems installed via grub-efi --removable.
        attr_writer :qemu_firmware
        def qemu_firmware arch = nil
          return @qemu_firmware if @qemu_firmware

          names = if (arch || Config.workstation_arch) == 'arm64'
            %w[edk2-aarch64-code.fd QEMU_EFI.fd]
          else
            %w[edk2-x86_64-code.fd OVMF.fd]
          end
          dirs = %w[/opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu /usr/share/OVMF]

          dirs.product(names).map { |dir, name| File.join(dir, name) }.find { |f| File.exist?(f) }
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

        # Caching apt/debootstrap proxy on the workstation (reachable from
        # the VMs as http://10.0.2.2:<port>). Downloads of immutable package
        # artifacts are cached in <vm_dir>/apt-cache, making repeated
        # template builds mostly network-free. Set to false to disable.
        attr_writer :apt_cache
        def apt_cache
          @apt_cache.nil? ? true : @apt_cache
        end

        attr_writer :apt_cache_port
        def apt_cache_port
          @apt_cache_port || 3142
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

        # Shared inter-VM L2 segment via socket_vmnet. QEMU user-mode NAT isolates
        # every VM behind its own NAT, so VMs cannot reach each other's
        # primary_address — which breaks the tinc VPN underlay and therefore all
        # cross-host guest routing (in prod the primary network is real hardware;
        # locally it is not). To restore it, every VM gets a second NIC bound to
        # the socket_vmnet daemon: a real L2 segment shared by all VMs *and* the
        # workstation (the vmnet gateway), so peers — and tinc — reach each other
        # over the primary_address. QEMU stays unprivileged; the daemon (started
        # once via `brew services start socket_vmnet`) holds the vmnet privilege.
        # QEMU's own `socket,mcast` backend does NOT loop between VM processes on
        # macOS (verified), which is why socket_vmnet is used instead of plain
        # multicast. Auto-enabled when the daemon socket exists; false to disable.
        attr_writer :vmnet
        def vmnet
          @vmnet.nil? ? File.exist?(vmnet_socket) : @vmnet
        end

        # Path to the socket_vmnet daemon's unix socket (see {#vmnet}).
        attr_writer :vmnet_socket
        def vmnet_socket
          @vmnet_socket || '/opt/homebrew/var/run/socket_vmnet'
        end

        # Path to the `socket_vmnet_client` helper that opens {#vmnet_socket} on
        # fd 3 and execs QEMU with `-netdev socket,fd=3`.
        attr_writer :vmnet_client
        def vmnet_client
          @vmnet_client || '/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet_client'
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
