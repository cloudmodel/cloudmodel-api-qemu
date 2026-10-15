module CloudModel
  module Api
    module Qemu
      # Mixin included into CloudModel::Host by the consuming application's
      # initializer.  Adds VM-specific fields and lifecycle methods.
      #
      # @example In config/initializers/cloud_model_setup.rb
      #   CloudModel::Host.include CloudModel::Api::Qemu::Host
      module Host
        def self.included(base)
          base.field :vm_disk_paths, type: Array, default: []
          base.field :vm_pid_path,   type: String
          base.field :vm_extra_nics, type: Integer, default: 0
          # true: boot the Debian rescue disk (vda) — initial provisioning.
          # false: boot the installed system from the system disks (EDK2 has no
          # persistent NVRAM here, so boot order is controlled by what is attached).
          base.field :vm_boot_rescue, type: Mongoid::Boolean, default: true
        end

        # Create disk images, boot the rescue disk, bootstrap SSH and packages,
        # then populate system_disks and initial_root_pw on the Host document.
        #
        # @param options [Hash]
        # @option options [Integer] :extra_ips  Number of additional IP addresses
        #   (each maps to an additional NIC in the VM). Default: 0.
        # @option options [Boolean] :force  Re-create even if disks already exist.
        def create_vm!(options = {})
          CloudModel::Api::Qemu::Server.new(self).create(options)
        end

        # Start a previously created (but stopped) VM.
        def start_vm!
          CloudModel::Api::Qemu::Server.new(self).start
        end

        # Gracefully stop the VM (sends ACPI power-off via QEMU monitor).
        def stop_vm!
          CloudModel::Api::Qemu::Server.new(self).stop
        end

        # Immediately terminate the QEMU process (like pulling the power).
        # Prefer {#restart_vm!}: a hard kill is what corrupts the nested ZFS pool.
        def kill_vm!
          CloudModel::Api::Qemu::Server.new(self).kill
        end

        # Graceful restart (ACPI power-off, kill only after the timeout, start).
        def restart_vm!(timeout: 90)
          CloudModel::Api::Qemu::Server.new(self).restart(timeout: timeout)
        end

        # @return [Boolean] true when the guest answers SSH
        def vm_healthy?(timeout: 10)
          CloudModel::Api::Qemu::Server.new(self).healthy?(timeout: timeout)
        end

        # Rescue-boot the VM and enable zfs_recover on its installed system
        # (see Server#repair_zfs!).
        def repair_vm_zfs!
          CloudModel::Api::Qemu::Server.new(self).repair_zfs!
        end

        # Remove disk images and all state files for this VM.
        def destroy_vm!
          CloudModel::Api::Qemu::Server.new(self).destroy
        end

        # @return [Boolean] true when the QEMU process is running
        def vm_running?
          CloudModel::Api::Qemu::Server.new(self).running?
        end

        # @return [Hash] state snapshot (:running, :pid, :ip, :ssh_port, :disks, :vm_dir)
        def vm_status
          CloudModel::Api::Qemu::Server.new(self).status
        end
      end
    end
  end
end
