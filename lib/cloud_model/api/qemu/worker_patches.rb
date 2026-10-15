module CloudModel
  module Api
    module Qemu
      # Worker overrides that make CloudModel's host deploy work on local QEMU
      # VMs.  All overrides are no-ops (call super) unless the host is a VM
      # (has vm_disk_paths), so real hardware deploys are unaffected.
      #
      # Differences to bare-metal:
      #
      # * UEFI instead of BIOS boot: QEMU aarch64 (and modern x86_64) boots via
      #   EDK2 firmware.  The BIOS-grub layout (ef02 partition + grub-pc) cannot
      #   boot here, so the partition table gets an additional ESP as partition 1
      #   (plain FAT32 per disk, no RAID — firmware cannot read mdraid 1.2) and
      #   grub-efi is installed with --removable (fallback path EFI/BOOT/BOOT*.EFI,
      #   no NVRAM entries needed).  All other partitions shift up by one; the
      #   md device numbering stays identical to bare-metal.
      #
      # * Networking: the deployed static primary_address is not routable inside
      #   QEMU's user-mode NAT, so the installed system runs DHCP on eth0 instead
      #   (hostfwd keeps SSH reachable from outside).  A systemd .link file pins
      #   the NIC to the name eth0 by MAC address, as CloudModel templates expect.
      module WorkerPatches
        def self.install!
          CloudModel::Workers::HostWorker.prepend HostWorkerPatch unless CloudModel::Workers::HostWorker < HostWorkerPatch
          CloudModel::Workers::HostTemplateWorker.prepend HostTemplateWorkerPatch unless CloudModel::Workers::HostTemplateWorker < HostTemplateWorkerPatch
          CloudModel::Host.prepend HostPatch unless CloudModel::Host < HostPatch
          CloudModel::Workers::GuestWorker.prepend GuestWorkerPatch unless CloudModel::Workers::GuestWorker < GuestWorkerPatch
        end

        # Makes the local dev-net names resolvable and its CA trusted *inside*
        # every guest, so a guest service can already reach a sibling guest by
        # its *.<zone> name over verified TLS while its own config is written —
        # e.g. an OIDC consumer that fetches a discovery doc during deploy.
        #
        # This runs at the top of config_services (before the per-service loop),
        # because cloudmodel writes /etc/hosts only later in config_network,
        # which is too late for services provisioned in the loop. config_network
        # re-renders /etc/hosts afterwards; it keeps the same additional_hosts
        # entries, so the runtime file is identical.
        #
        # Dev-only and self-disabling: the CA step is skipped when the CA file is
        # absent (real clouds), and nothing here ever fails a deploy.
        module GuestWorkerPatch
          def config_services
            prime_dev_net_trust
            super
          end

          # LXD re-applies its baked /etc/hosts image template when it first
          # instantiates the container, clobbering the additional_hosts written
          # during config. That template only fires on create/copy (not plain
          # start), so re-adding the names into the now-running container makes
          # them stick across restarts — needed so the guest's own services can
          # resolve sibling *.<zone> names at runtime (e.g. an OIDC token
          # exchange), not just during deploy.
          def start_lxd_container
            super
            add_dev_net_hosts_to_running_container
          end

          private

          def prime_dev_net_trust
            guest.deploy_path = "#{@lxc.mountpoint}/rootfs"
            # dev names → /etc/hosts (reuses the stock template, which renders
            # CloudModel.config.additional_hosts) so services provisioned during
            # config_services can already resolve them
            render_to_remote "/cloud_model/guest/etc/hosts", "#{guest.deploy_path}/etc/hosts", container_name: @lxc.name
            install_dev_net_ca
          rescue => e
            Rails.logger.warn "cloudmodel-api-qemu: dev-net trust priming skipped: #{e.message}"
          end

          def add_dev_net_hosts_to_running_container
            entries = (CloudModel.config.additional_hosts || {}).reject { |name, ip| name.to_s.strip.empty? || ip.to_s.strip.empty? }
            return if entries.empty?

            script = entries.map do |name, ip|
              line = "#{ip} #{name}"
              "grep -qxF #{line.shellescape} /etc/hosts || echo #{line.shellescape} >> /etc/hosts"
            end.join(' ; ')
            host.exec "/usr/bin/lxc exec #{@lxc.name.shellescape} -- sh -c #{script.shellescape}"
          rescue => e
            Rails.logger.warn "cloudmodel-api-qemu: runtime /etc/hosts update skipped: #{e.message}"
          end

          def install_dev_net_ca
            ca_path = File.join(CloudModel.config.api.qemu.vm_dir, 'dev-net-ca', 'ca.crt')
            return unless File.exist?(ca_path)

            dest_dir = "#{guest.deploy_path}/usr/local/share/ca-certificates"
            mkdir_p dest_dir
            host.sftp.file.open("#{dest_dir}/cloudmodel-dev-ca.crt", 'w') { |f| f.write File.read(ca_path) }
            chroot guest.deploy_path, 'update-ca-certificates'
          end
        end

        module HostPatch
          # A host counts as local VM when the QEMU host mixin gave it disk
          # image paths. All overrides below are no-ops for real hardware.
          def vm_host?
            respond_to?(:vm_disk_paths) and vm_disk_paths.present?
          end

          # Host#ssh_address returns ssh_connection.host, which Net::SSH has
          # already resolved via ~/.ssh/config to 127.0.0.1 — but WITHOUT the
          # forwarded port.  scp/rsync commands built from it would hit
          # 127.0.0.1:22.  Returning the primary IP lets the ssh CLI resolve
          # the ~/.ssh/config mapping (HostName + Port) itself.
          def ssh_address
            if vm_host?
              primary_address.ip
            else
              super
            end
          end

          # firewall_stop/firewall_start flush the nat table and with it the
          # DNAT rule vm-network.sh set up at boot (hostfwd traffic → primary
          # address). Restore it immediately over the still-open connection,
          # otherwise every NEW ssh connection from the workstation is
          # dropped and the VM is locked out until the next reboot.
          def restart_firewall
            ret = super
            if vm_host?
              # Find the NAT NIC by its user-mode-NAT DHCP address (10.0.2.x) —
              # not "first non-lo", which with socket_vmnet would wrongly pick the
              # vmnet eth0. Restore the hostfwd → primary DNAT on it.
              exec %{DHCP_IP=$(ip -4 -o addr show | awk '$4 ~ /^10\\.0\\.2\\./ {print $4; exit}' | cut -d/ -f1); [ -n "$DHCP_IP" ] && { iptables -t nat -C PREROUTING -d "$DHCP_IP" -p tcp -j DNAT --to-destination #{primary_address.ip} 2>/dev/null || iptables -t nat -A PREROUTING -d "$DHCP_IP" -p tcp -j DNAT --to-destination #{primary_address.ip}; }}
            end
            ret
          end

          # Skip the private-network (tinc VPN) attempt for local VMs: the VPN
          # is not routable from the workstation, so every connection would
          # first burn the 15s connect timeout before falling back.
          def ssh_connection
            if vm_host? and initial_root_pw.blank?
              @ssh_connection ||= Net::SSH.start(primary_address.ip, 'root',
                keys: ["#{CloudModel.config.data_directory}/keys/id_rsa"],
                keys_only: true,
                password: '',
                **CloudModel::Host::SSH_OPTIONS
              )
            else
              super
            end
          end
        end

        module VmHostCheck
          private

          def vm_host?
            @host.respond_to?(:vm_disk_paths) and @host.vm_disk_paths.present?
          end

          def vm_grub_efi_target
            @host.arch == 'arm64' ? 'arm64-efi' : 'x86_64-efi'
          end

          def vm_grub_efi_package
            @host.arch == 'arm64' ? 'grub-efi-arm64' : 'grub-efi-amd64'
          end
        end

        module HostWorkerPatch
          include VmHostCheck

          # The RAID-1 initial resync mirrors every block — on sparse qcow2
          # images that materializes the FULL partition sizes on the
          # workstation disk (~180G per VM for nothing). The disks are
          # brand-new and identical (all zeros), so skip the resync.
          def init_raid_device md_data, md
            return super unless vm_host?

            if md_data =~ /#{md[:device]} \: active raid1/
              comment_sub_step "Skip RAID device #{md[:device]} for #{md[:name]}, as already active", indent: 4
            else
              comment_sub_step "Init RAID device #{md[:device]} for #{md[:name]} (no resync on fresh sparse images)", indent: 4
              devs = @host.system_disks.map{|dev| "/dev/#{disk_partition_device dev, md[:partition]}"}
              @host.exec "mdadm --zero-superblock #{devs * ' '}"
              @host.exec "mdadm --create -e1 -f --assume-clean /dev/#{md[:device]} --level=1 --raid-devices=#{devs.size} #{devs * ' '}"
            end
          end

          # virtio disks partition as vdb1, vdb2, … (no 'p' separator like nvme)
          def disk_partition_device device, number
            if device =~ /\Avd/
              raise "Partition number must be a positive integer value. First partition is 1." if !number.is_a?(Integer) or number < 1
              "#{device}#{number}"
            else
              super
            end
          end

          # UEFI partition layout (sizes in MiB, 1 block = 2048 sectors):
          #   1 esp     512M  ef00  FAT32 per disk (no RAID)
          #   2 boot    512M  fd00  md0 ext2 /boot
          #   3 swap    256G  8200
          #   4 root_a   32G  fd00  md2
          #   5 root_b   32G  fd00  md3
          #   6 cloud    96G  fd00  md1
          #   7 lxd      24G  fd00  md4
          #   8 guests  rest  8300  zpool mirror
          def init_system_disk
            return super unless vm_host?

            comment_sub_step 'Partition system disks (UEFI layout)'

            block_size = 2048
            offset_size = 1
            esp_size = 512
            boot_size = 512
            swap_size = 256*1024
            root_size = 32*1024
            cloud_size = 96*1024
            lxd_size = 24*1024

            part_cmd = "sgdisk -go "
            part_cmd += "-n 1:#{offset_size*block_size}:#{(offset_size+esp_size)*block_size-1} -t 1:ef00 -c 1:esp "
            offset_size += esp_size
            part_cmd += "-n 2:#{offset_size*block_size}:#{(offset_size+boot_size)*block_size-1} -t 2:fd00 -c 2:boot "
            offset_size += boot_size
            part_cmd += "-n 3:#{offset_size*block_size}:#{(offset_size+swap_size)*block_size-1} -t 3:8200 -c 3:swap "
            offset_size += swap_size
            part_cmd += "-n 4:#{offset_size*block_size}:#{(offset_size+root_size)*block_size-1} -t 4:fd00 -c 4:root_a "
            offset_size += root_size
            part_cmd += "-n 5:#{offset_size*block_size}:#{(offset_size+root_size)*block_size-1} -t 5:fd00 -c 5:root_b "
            offset_size += root_size
            part_cmd += "-n 6:#{offset_size*block_size}:#{(offset_size+cloud_size)*block_size-1} -t 6:fd00 -c 6:cloud "
            offset_size += cloud_size
            part_cmd += "-n 7:#{offset_size*block_size}:#{(offset_size+lxd_size)*block_size-1} -t 7:fd00 -c 7:lxd "
            offset_size += lxd_size
            part_cmd += "-N 8 -t 8:8300 "

            # Partition 8 gets a per-disk GPT label (guests0, guests1, …): the
            # zpool is created via /dev/disk/by-partlabel because plain device
            # names shift (vdb → vda) once the rescue disk is detached.
            @host.system_disks.each_with_index do |dev, i|
              @host.exec! part_cmd + "-c 8:guests#{i} /dev/#{dev}", "Failed to create partitions on #{dev}"
            end

            comment_sub_step 'Make RAID'

            if md_data = @host.exec('cat /proc/mdstat') and md_data[0] and md_data = md_data[1]
              init_raid_device md_data, name: 'boot', device: 'md0', partition: 2
              init_raid_device md_data, name: 'cloud', device: 'md1', partition: 6
              init_raid_device md_data, name: 'root_a', device: 'md2', partition: 4
              init_raid_device md_data, name: 'root_b', device: 'md3', partition: 5
              init_raid_device md_data, name: 'lxd', device: 'md4', partition: 7
            else
              raise 'Failed to stat md data'
            end

            comment_sub_step 'Make swap space'

            # Labeled: device names shift (vdb → vda) once the rescue disk is
            # detached for system boot, so fstab must not use /dev/vdX paths.
            @host.system_disks.each_with_index do |dev, i|
              @host.exec! "mkswap -L swap#{i} /dev/#{disk_partition_device dev, 3}", "Failed to create swap on #{dev}"
            end

            comment_sub_step 'Format boot array'

            @host.exec! 'mkfs.ext2 /dev/md0', 'Failed to create boot filesystem'

            comment_sub_step 'Format cloud array'

            # A retry after a failed deploy leaves the arrays mounted (md4
            # even twice: /var/lib/lxd AND /mnt/newroot/var/lib/lxd) — mkfs
            # refuses mounted devices.
            @host.exec 'umount --all-targets /dev/md1'
            @host.exec! 'mkfs.ext4 /dev/md1', 'Failed to create cloud filesystem'
            @host.exec 'mkdir -p /cloud'
            @host.exec! 'mount /dev/md1 /cloud', 'Failed to mount cloud filesystem'

            comment_sub_step 'Format lxd array'

            @host.exec 'umount --all-targets /dev/md4'
            @host.exec! 'mkfs.ext4 /dev/md4', 'Failed to create lxd filesystem'
            @host.exec 'mkdir -p /var/lib/lxd'
            @host.exec! 'mount /dev/md4 /var/lib/lxd', 'Failed to mount lxd filesystem'
          end

          # Swap by label — device names shift when the rescue disk is detached
          # for system boot (vdb → vda), so /dev/vdX3 paths would break.
          def config_fstab
            return super unless vm_host?
            render_to_remote '/cloud_model/host/etc/fstab', "#{root}/etc/fstab", host: @host, timestamp: @timestamp,
              swap_disks: @host.system_disks.each_with_index.map{|_, i| "disk/by-label/swap#{i}"}
          end

          # guests zpool moved from partition 7 to 8 in the UEFI layout; devices
          # by partlabel because names shift once the rescue disk is detached.
          def render_guest_zpool_service
            return super unless vm_host?
            render_to_remote "/cloud_model/host/etc/systemd/system/guest_zpool.service", "#{root}/etc/systemd/system/guest_zpool.service",
              guests_init_string: "mirror #{@host.system_disks.each_with_index.map{|_, i| "disk/by-partlabel/guests#{i}"} * ' '}", host: @host
            mkdir_p "#{root}/etc/systemd/system/basic.target.wants"
            chroot! root, "ln -sf /etc/systemd/system/guest_zpool.service /etc/systemd/system/basic.target.wants/guest_zpool.service", "Failed to add guest_zpool to autostart"
          end

          def config_deploy_root
            result = super
            if vm_host?
              configure_vm_network
              configure_vm_fake_hardware
              configure_vm_apt_cache
            end
            result
          end

          def boot_deploy_root options={}
            return super unless vm_host?

            comment_sub_step 'Ensure /boot is mounted'
            @host.unmount_boot_fs

            unless @host.mount_boot_fs root
              raise "Failed to mount /boot to chroot"
            end

            comment_sub_step 'Copy kernel and grub to /boot'
            chroot root, "cd /kernel; tar cf - * | ( cd /boot; tar xfp -)"

            configure_vm_zfs_recovery root

            comment_sub_step 'Setup grub bootloader (UEFI)'
            chroot! root, "mdadm --detail --scan >> /etc/mdadm/mdadm.conf", "Failed to update mdadm.conf"
            chroot! root, "update-initramfs -u", "Failed to update initram"

            @host.system_disks.each do |dev|
              esp = disk_partition_device dev, 1
              chroot! root, "mkfs.vfat -F32 /dev/#{esp}", "Failed to format ESP on #{dev}"
              chroot! root, "mkdir -p /boot/efi", "Failed to create /boot/efi"
              chroot! root, "mount /dev/#{esp} /boot/efi", "Failed to mount ESP on #{dev}"
              begin
                chroot! root, "grub-install --target=#{vm_grub_efi_target} --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram --recheck", "Failed to install grub on #{dev}"
              ensure
                chroot root, "umount /boot/efi"
              end
            end
            chroot! root, "grub-mkconfig -o /boot/grub/grub.cfg", 'Failed to config grub'

            unless options[:no_reboot]
              vm_boot_installed_system
            end
          end

          # A plain reboot would boot the rescue disk again (EDK2 boots the
          # first bootable drive, and there is no persistent NVRAM).  Power the
          # guest off, detach rescue disk + seed, and start from the system
          # disks instead.  The installed sshd only allows key auth, so
          # initial_root_pw is cleared — CloudModel switches to key-based SSH.
          # Dev VMs get hard power-offs (Mac sleep, kills); the nested ZFS pool
          # then occasionally fails its import with a panic that blocks the
          # whole boot. zfs_recover turns that into a warning so the host comes
          # up and can scrub. Set via modprobe.d AND the kernel command line
          # (the pool may be imported from the initramfs); grub.cfg regenerated
          # before the grub-mkconfig of boot_deploy_root picks it up.
          def configure_vm_zfs_recovery root
            comment_sub_step 'Enable zfs_recover (dev VM: survive pool import panics)'
            @host.exec! "printf 'options zfs zfs_recover=1\\n' > #{root}/etc/modprobe.d/zfs-recover.conf", 'Failed to write zfs-recover.conf'
            @host.exec! "grep -q 'zfs.zfs_recover=1' #{root}/etc/default/grub || sed -i 's/^GRUB_CMDLINE_LINUX=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX=\"\\1 zfs.zfs_recover=1\"/' #{root}/etc/default/grub", 'Failed to add zfs_recover to the kernel command line'
            # grub.cfg is generated by the grub-mkconfig that follows in boot_deploy_root
          end

          def vm_boot_installed_system
            comment_sub_step 'Boot installed system (VM: detach rescue disk)'
            @host.update_attribute :deploy_state, :booting

            begin
              @host.exec 'poweroff'
            rescue IOError, Errno::ECONNRESET, Net::SSH::Disconnect
              # connection dies with the guest — expected
            end

            server = CloudModel::Api::Qemu::Server.new(@host)
            deadline = Time.now + 90
            sleep 1 while server.running? && Time.now < deadline
            server.kill if server.running?

            @host.update_attributes vm_boot_rescue: false, initial_root_pw: nil
            server.start
          end

          private

          # Static primary_address networking does not work inside QEMU user-mode
          # NAT — replace the rendered network.service with a variant matched to
          # the QEMU NIC layout. With socket_vmnet (Config#vmnet) the vmnet NIC is
          # the *external* interface and is named **eth0** so cloudmodel's whole
          # eth0-based config (primary_address, guest public IPs, tinc
          # BindToInterface, firewall) targets it natively — that is what makes
          # cross-host guest routing work locally. The user-mode NAT NIC then
          # becomes eth1 and carries only internet/apt (default route) and the
          # hostfwd SSH ingress. Without vmnet the NAT NIC keeps the eth0 role and
          # primary_address lives on lo (isolated single-host mode).
          # Writes a systemd .link file that renames the NIC with +mac+ to +name+.
          def write_link(path, mac, name)
            @host.sftp.file.open(path, 'w') do |f|
              f.write <<~LINK
                [Match]
                MACAddress=#{mac}

                [Link]
                Name=#{name}
              LINK
            end
          end

          def configure_vm_network
            comment_sub_step 'Override network config for QEMU user-mode NAT (VM host)'

            nat_mac = begin
              File.read(File.join(CloudModel.config.api.qemu.vm_dir, @host.name, 'macs.txt')).split("\n").first.to_s.strip
            rescue
              nil
            end

            vmnet     = CloudModel.config.api.qemu.vmnet
            vmnet_mac = CloudModel::Api::Qemu.vmnet_mac(@host.primary_address.ip) if vmnet
            # The external interface (eth0) is the vmnet NIC when socket_vmnet is
            # used, otherwise the NAT NIC.
            ext_mac   = vmnet ? vmnet_mac : nat_mac

            mkdir_p "#{root}/etc/systemd/network"
            write_link "#{root}/etc/systemd/network/10-eth0.link", ext_mac, 'eth0' if ext_mac
            # NAT NIC is the secondary interface (eth1) only when vmnet took eth0.
            write_link "#{root}/etc/systemd/network/10-eth1.link", nat_mac, 'eth1' if vmnet && nat_mac

            # Guest public IPs cloudmodel would put on eth0 (network_service.erb) —
            # so peers and the workstation reach the guests over the vmnet segment.
            ext_ips = []
            if vmnet
              @host.addresses.each do |address|
                next unless address.ip_version == 4
                address.list_ips.each { |ip| ext_ips << "#{ip}/#{address.subnet}" }
              end
            end

            mkdir_p "#{root}/usr/local/sbin"
            @host.sftp.file.open("#{root}/usr/local/sbin/vm-network.sh", 'w') do |f|
              f.write <<~SCRIPT
                #!/bin/sh
                # QEMU VM network setup (cloudmodel-api-qemu). NICs are found by their
                # fixed MACs, so this works whether or not the .link rename applied.
                NAT_MAC="#{nat_mac}"
                VMNET_MAC="#{vmnet_mac}"
                nic_for() { ip -o link show | grep -i "$1" | awk -F': ' '{print $2}' | head -1; }
                NAT=$(nic_for "$NAT_MAC")
                VMNET=""
                [ -n "$VMNET_MAC" ] && VMNET=$(nic_for "$VMNET_MAC")

                # NAT NIC: internet/apt via user-mode NAT + the default route.
                # Static, not DHCP — QEMU SLIRP hands out fixed addresses
                # (guest 10.0.2.15, gateway 10.0.2.2, DNS 10.0.2.3), so we pin
                # them like prod does its static eth0 instead of running dhclient
                # (which, on the wrong NIC, was fragile). This is the only NIC
                # that carries the default route / internet.
                ip link set "$NAT" up
                ip addr add 10.0.2.15/24 dev "$NAT" 2>/dev/null || true
                ip route replace default via 10.0.2.2 dev "$NAT"
                grep -q '^nameserver 10.0.2.3' /etc/resolv.conf 2>/dev/null || echo 'nameserver 10.0.2.3' > /etc/resolv.conf

                if [ -n "$VMNET" ]; then
                  # socket_vmnet NIC = eth0 = external interface: primary_address
                  # (real, peer-reachable /24) plus the guest public IPs.
                  ip link set "$VMNET" up
                  ip addr add #{@host.primary_address.ip}/24 dev "$VMNET" 2>/dev/null || true
                  for cidr in #{ext_ips.join(' ')}; do
                    ip addr add "$cidr" dev "$VMNET" 2>/dev/null || true
                  done
                else
                  # No vmnet NIC (config.api.qemu.vmnet=false): keep primary on lo
                  # so local services can still bind to it (single-host mode).
                  ip addr add #{@host.primary_address.ip}/32 dev lo 2>/dev/null || true
                fi

                # CloudModel's firewall only ACCEPTs traffic addressed to the
                # primary_address — hostfwd SSH packets arrive on the NAT DHCP
                # address though. DNAT them so all firewall rules apply as on
                # real hardware.
                DHCP_IP=$(ip -4 -o addr show dev "$NAT" scope global | awk '{print $4}' | cut -d/ -f1)
                if [ -n "$DHCP_IP" ]; then
                  iptables -t nat -C PREROUTING -d "$DHCP_IP" -p tcp -j DNAT --to-destination #{@host.primary_address.ip} 2>/dev/null || \
                    iptables -t nat -A PREROUTING -d "$DHCP_IP" -p tcp -j DNAT --to-destination #{@host.primary_address.ip}
                fi
                echo 1 >/proc/sys/net/ipv4/ip_forward
                echo 1 >/proc/sys/net/ipv6/conf/all/forwarding
                exit 0
              SCRIPT
            end
            chroot! root, "chmod 755 /usr/local/sbin/vm-network.sh", "Failed to chmod vm-network.sh"

            @host.sftp.file.open("#{root}/etc/systemd/system/network.service", 'w') do |f|
              f.write <<~UNIT
                [Unit]
                Description=Ethernet Network Connectivity (QEMU VM: DHCP via user-mode NAT)

                [Service]
                Type=oneshot
                RemainAfterExit=yes

                ExecStart=/usr/local/sbin/vm-network.sh

                [Install]
                WantedBy=network.target
              UNIT
            end
          end

          # QEMU emulates no hwmon sensors and its vCPU reports no model name.
          # Instead of touching cloudmodel's plugins/monitoring (that is the
          # code under test!), fake it at the "hardware"/OS level: /usr/local/
          # bin shadows /usr/bin in both systemd's and sshd's default PATH, so
          # the unmodified sensors check_mk plugin (`sensors -u`) and
          # Host#cpu_name (`lscpu` fallback) pick these up transparently.
          # SMART needs no fake at all — the system disks are emulated NVMe
          # with a real SMART/health log (see api/qemu/server.rb).
          def configure_vm_fake_hardware
            comment_sub_step 'Fake sensors + CPU model for QEMU (VM host)'

            cpu_brand = `sysctl -n machdep.cpu.brand_string 2>/dev/null`.strip
            cpu_brand = `uname -m 2>/dev/null`.strip if cpu_brand.empty? # non-macOS workstation

            @host.sftp.file.open("#{root}/usr/local/bin/sensors", 'w') do |f|
              f.write <<~'SCRIPT'
                #!/bin/bash
                # Fake lm_sensors (cloudmodel-api-qemu): QEMU exposes no hwmon
                # devices. Emits `sensors -u` format with a little jitter so
                # monitoring time series look alive. Shadows /usr/bin/sensors.
                echo "qemu-virtual-isa-0000"
                echo "Adapter: Virtual device"
                for core in 0 1; do
                  echo "Core $core:"
                  echo "  temp$((core + 1))_input: $((40 + core + RANDOM % 7)).$((RANDOM % 900 + 100))"
                  echo "  temp$((core + 1))_max: 84.000"
                  echo "  temp$((core + 1))_crit: 96.000"
                done
              SCRIPT
            end

            @host.sftp.file.open("#{root}/usr/local/bin/lscpu", 'w') do |f|
              f.write <<~SCRIPT
                #!/bin/sh
                # QEMU's vCPU reports "Model name: -" — substitute the
                # workstation's CPU brand (cloudmodel-api-qemu).
                /usr/bin/lscpu "$@" | sed 's/^Model name:.*/Model name:  QEMU vCPU (#{cpu_brand})/'
              SCRIPT
            end

            chroot! root, "chmod 755 /usr/local/bin/sensors /usr/local/bin/lscpu", "Failed to chmod fake hardware tools"
          end

          # Route apt (conf file) and debootstrap (http_proxy env for SSH
          # sessions) of the installed system through the workstation's
          # package cache — see AptCache. No-op when the cache is disabled
          # or not running.
          def configure_vm_apt_cache
            return unless CloudModel.config.api.qemu.apt_cache and CloudModel::Api::Qemu::AptCache.running?

            comment_sub_step 'Route apt through the workstation package cache (VM host)'
            url = CloudModel::Api::Qemu::AptCache.proxy_url

            @host.sftp.file.open("#{root}/etc/apt/apt.conf.d/01cloudmodel-cache", 'w') do |f|
              f.write %(Acquire::http::Proxy "#{url}";\n)
            end
            chroot! root, "grep -q '^http_proxy=' /etc/environment 2>/dev/null || echo 'http_proxy=#{url}' >> /etc/environment",
              'Failed to set http_proxy in /etc/environment'
          end
        end

        module HostTemplateWorkerPatch
          include VmHostCheck

          # UEFI boot needs grub-efi instead of grub-pc/grub2; dosfstools for
          # formatting the ESPs; isc-dhcp-client for the DHCP network override.
          def install_grub
            return super unless vm_host?
            chroot! build_path, "apt-get install #{vm_grub_efi_package} dosfstools -y", "Failed to install Grub (EFI)"
            render_to_remote "/cloud_model/host/etc/default/grub", "#{build_path}/etc/default/grub"
          end

          def install_network
            super
            if vm_host?
              comment_sub_step 'Install dhcp client (VM host)'
              chroot! build_path, "apt-get install isc-dhcp-client -y", "Failed to install isc-dhcp-client"
            end
          end
        end
      end
    end
  end
end
