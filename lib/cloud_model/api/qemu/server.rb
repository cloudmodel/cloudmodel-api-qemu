require 'net/ssh'
require 'net/http'
require 'rbconfig'
require 'fileutils'
require 'tmpdir'
require 'timeout'

module CloudModel
  module Api
    module Qemu
      # Manages the QEMU process lifecycle for a single CloudModel::Host.
      #
      # Boot model:
      #   Each VM has a small Debian genericcloud rescue disk (cloned from a shared
      #   base image) as vda, plus disk_count empty system disks attached as
      #   emulated NVMe (nvme0n1, …) for CloudModel to partition and install
      #   Debian onto.
      #
      #   A cloud-init NoCloud seed image (FAT, labeled CIDATA) is attached as
      #   the last virtio device.  It pre-configures SSH (CloudModel key), root
      #   password, static IP, and rescue packages (gdisk, mdadm) before first
      #   boot completes.
      #
      # Networking model:
      #   QEMU uses user-mode NAT (-netdev user) on all platforms — no special
      #   privileges, no socket_vmnet, no DHCP detection.
      #
      #   The VM's primary_address IP is added as a loopback alias on the host
      #   and exposed via QEMU hostfwd on a unique high port (22000 + last octet).
      #   An ~/.ssh/config entry maps primary_address:22 → 127.0.0.1:high_port
      #   so Net::SSH and the ssh CLI connect transparently.
      class Server
        # timeout also bounds the SSH banner exchange: QEMU's hostfwd accepts
        # the TCP connection immediately even while the guest is still booting,
        # so without it every probe hangs for minutes waiting for a banner.
        SSH_OPTS = {
          auth_methods:    ['publickey'],
          verify_host_key: :never,
          non_interactive: true,
          timeout:         10
        }.freeze

        def initialize(host)
          @host = host
          @cfg  = CloudModel.config.api.qemu
        end

        # ── Public lifecycle ────────────────────────────────────────────────────

        def create(options = {})
          extra_ips = options.fetch(:extra_ips, 0).to_i
          nic_count = 1 + extra_ips

          if running?
            raise "VM '#{@host.name}' is already running — stop/kill it first (or destroy_vm! to start over)" unless options[:force]
            kill
          end

          check_dependencies
          AptCache.ensure_running!
          ensure_base_image
          create_disks(options[:force])

          macs       = generate_macs(nic_count)
          primary_ip = @host.primary_address.ip
          ssh_port   = vm_ssh_port(primary_ip)

          create_cloud_init_seed(macs)
          add_loopback_alias(primary_ip)
          write_ssh_config(primary_ip, ssh_port)
          start_qemu(macs)

          log "Waiting for SSH on #{primary_ip} (→ 127.0.0.1:#{ssh_port}) ..."
          wait_for_ssh(primary_ip)

          log "Waiting for cloud-init to finish (rescue packages)..."
          wait_for_cloud_init(primary_ip)

          log "Updating Host document..."
          persist_host

          log "Done. VM '#{@host.name}' reachable at #{primary_ip}"
          true
        end

        def start
          return true if running?
          raise "No disk images found — run create_vm! first" if disk_paths.empty?
          macs = stored_macs
          raise "No stored MACs — cannot restart. Destroy and re-create." if macs.empty?
          AptCache.ensure_running! # the VM's apt may be configured to use it
          ip = @host.primary_address.ip
          add_loopback_alias(ip)
          write_ssh_config(ip, vm_ssh_port(ip))
          start_qemu(macs)
        end

        # Sends ACPI power-off and waits up to +timeout+ seconds for the QEMU
        # process to exit.  Returns false if the VM is still running afterwards.
        def stop(timeout: 90)
          return true unless running?
          send_monitor_command('system_powerdown')
          deadline = Time.now + timeout
          sleep 1 while running? && Time.now < deadline
          if running?
            log "VM still running after #{timeout}s — use kill_vm! to force off"
            false
          else
            FileUtils.rm_f(pid_path)
            true
          end
        end

        def kill
          return unless running?
          pid = File.read(pid_path).strip.to_i
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
          # already gone
        ensure
          FileUtils.rm_f(pid_path)
        end

        # Graceful restart: ACPI power-off first (bounded), the hard kill only
        # when the guest does not shut down in time, then start again. Killing
        # a VM mid-transaction is what corrupts the nested ZFS pool; this is
        # the way to bounce a VM that misbehaves.
        def restart(timeout: 90)
          if running? && !stop(timeout: timeout)
            log "ACPI power-off did not finish in #{timeout}s — killing"
            kill
          end
          start
        end

        # The only honest "it runs" signal: the hostfwd port accepts TCP even
        # while the guest is still booting (or hung), so ask the guest's sshd.
        def healthy?(timeout: 10)
          return false unless running?
          ip = @host.primary_address.ip
          Timeout.timeout(timeout) { vm_ssh(ip) { |ssh| ssh.exec!('true') } }
          true
        rescue StandardError, Timeout::Error
          false
        end

        # Repairs a VM whose installed system no longer boots because the ZFS
        # pool import panics ("adding existent segment to range tree" after a
        # hard power-off): boots the rescue disk, mounts the installed root and
        # /boot, enables zfs_recover there (modprobe.d + kernel command line,
        # grub.cfg regenerated), boots the installed system again and starts a
        # scrub. The pool then imports with warnings instead of hanging.
        def repair_zfs!
          ip = @host.primary_address.ip
          log "Booting the rescue system…"
          kill if running?
          @host.update_attributes vm_boot_rescue: true
          start
          wait_for_ssh(ip)

          log "Enabling zfs_recover on the installed root…"
          out = vm_ssh(ip) { |ssh| ssh.exec!(REPAIR_ZFS_SCRIPT.gsub('__POOL__', ZFS_GUEST_POOL)) }.to_s
          log out.lines.last(2).join.strip
          raise "Repair failed:\n#{out}" unless out.include?('REPAIR OK')

          log "Booting the installed system…"
          kill
          @host.update_attributes vm_boot_rescue: false
          start
          wait_for_ssh(ip)
          log vm_ssh(ip) { |ssh| ssh.exec!("zpool status -x #{ZFS_GUEST_POOL} 2>&1; zpool scrub #{ZFS_GUEST_POOL} 2>&1 && echo 'scrub started'") }.to_s.strip
          true
        end

        # cloudmodel's guest pool on every host (see guest_zpool.service).
        ZFS_GUEST_POOL = 'guests'.freeze

        # Runs inside the rescue system. Finds /boot by its grub.cfg, the
        # installed root by the root=UUID grub boots (hosts have A/B root
        # slots), and never touches the pool itself.
        REPAIR_ZFS_SCRIPT = <<~'SH'
          set -e
          mdadm --assemble --scan >/dev/null 2>&1 || true
          mkdir -p /mnt/repair /mnt/repairboot
          boot=""
          for md in /dev/md[0-9]*; do
            [ -b "$md" ] || continue
            mdadm --readwrite "$md" >/dev/null 2>&1 || true
            if mount -o ro "$md" /mnt/repairboot 2>/dev/null; then
              if [ -f /mnt/repairboot/grub/grub.cfg ]; then boot="$md"; umount /mnt/repairboot; break; fi
              umount /mnt/repairboot
            fi
          done
          [ -n "$boot" ] || { echo "REPAIR FAILED: no /boot array with grub.cfg"; exit 1; }
          mount -o ro "$boot" /mnt/repairboot
          uuid=$(grep -o 'root=UUID=[^ ]*' /mnt/repairboot/grub/grub.cfg | head -1 | cut -d= -f3)
          umount /mnt/repairboot
          root=$(blkid -U "$uuid" 2>/dev/null || true)
          [ -n "$root" ] || { echo "REPAIR FAILED: root filesystem $uuid not found"; exit 1; }
          mount "$root" /mnt/repair
          mount "$boot" /mnt/repair/boot
          printf 'options zfs zfs_recover=1\n' > /mnt/repair/etc/modprobe.d/zfs-recover.conf
          grep -q 'zfs.zfs_recover=1' /mnt/repair/etc/default/grub || sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 zfs.zfs_recover=1"/\' /mnt/repair/etc/default/grub
          for d in dev proc sys; do mount --bind /$d /mnt/repair/$d; done
          chroot /mnt/repair update-grub >/dev/null 2>&1 || { echo "REPAIR FAILED: update-grub"; exit 1; }
          grep -q 'zfs.zfs_recover=1' /mnt/repair/boot/grub/grub.cfg || { echo "REPAIR FAILED: grub.cfg lacks zfs_recover"; exit 1; }
          for d in sys proc dev boot; do umount /mnt/repair/$d; done
          umount /mnt/repair; sync
          echo "REPAIR OK: root=$root boot=$boot pool=__POOL__"
        SH

        def destroy
          kill if running?
          ip = @host.primary_address&.ip
          remove_loopback_alias(ip)
          remove_ssh_config(ip) if ip
          FileUtils.rm_rf(vm_dir)
          @host.update_attributes(vm_disk_paths: [], vm_pid_path: nil)
        end

        # Snapshot of the VM state for status displays.
        def status
          ip = @host.primary_address&.ip
          {
            name:     @host.name,
            running:  running?,
            pid:      (File.read(pid_path).strip.to_i if File.exist?(pid_path)),
            ip:       ip,
            ssh_port: (vm_ssh_port(ip) if ip),
            disks:    disk_paths,
            vm_dir:   vm_dir
          }
        end

        def running?
          return false unless File.exist?(pid_path)
          pid = File.read(pid_path).strip.to_i
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        private

        # ── Dependency checks ───────────────────────────────────────────────────

        def check_dependencies
          candidates = [
            ['qemu-img',  { brew: 'qemu', apt: 'qemu-utils' }],
            [qemu_binary, { brew: 'qemu', apt: 'qemu-system-x86 / qemu-system-arm' }],
          ]

          missing = candidates.reject { |bin, _| which(bin) }
          unless missing.empty?
            lines = missing.map do |bin, pkg|
              "  #{bin}\n" \
              "    macOS : brew install #{pkg[:brew]}\n" \
              "    Debian: sudo apt-get install #{pkg[:apt]}"
            end
            raise "Missing required binaries — please install:\n#{lines.join("\n")}"
          end

          check_qemu_runnable
        end

        def check_qemu_runnable
          bin = `which #{qemu_binary.shellescape}`.strip
          return if system("#{bin.shellescape} -version > /dev/null 2>&1")

          raise <<~MSG
            #{qemu_binary} exits immediately — the binary may have an invalid code signature.

            Fix:
              brew reinstall qemu

            Do NOT manually re-sign QEMU with ad-hoc entitlements — macOS 13+ rejects them.
          MSG
        end

        def which(cmd)
          system("which #{cmd.shellescape} > /dev/null 2>&1")
        end

        def macos?
          RUBY_PLATFORM.include?('darwin')
        end

        # ── Architecture ────────────────────────────────────────────────────────
        # The VM's arch comes from the Host document (settable on creation) —
        # matching the workstation runs hardware-accelerated (HVF/KVM), any
        # other arch runs fully TCG-emulated (slower, but true to production).

        def host_arch
          @host.arch.presence || Config.workstation_arch
        end

        def cross_arch?
          host_arch != Config.workstation_arch
        end

        def qemu_binary
          @cfg.qemu_binary(host_arch)
        end

        def process_alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        # ── Loopback alias ───────────────────────────────────────────────────────

        # The loopback alias is a convenience only (lets you ping the VM IP and
        # target it with tools that ignore ~/.ssh/config).  SSH works without it
        # via the hostfwd port mapping, so failure to add it must never block.
        def add_loopback_alias(ip)
          return if ip.nil? || loopback_has?(ip)
          sudo = $stdin.tty? ? 'sudo' : 'sudo -n'
          log "Adding loopback alias #{ip} (sudo required)..."
          ok = if macos?
            system("#{sudo} ifconfig lo0 alias #{ip}/32 2>/dev/null")
          else
            system("#{sudo} ip addr add #{ip}/32 dev lo 2>/dev/null")
          end
          log "WARNING: could not add loopback alias #{ip} (no sudo?) — SSH via ~/.ssh/config still works" unless ok
        end

        def remove_loopback_alias(ip)
          return if ip.nil? || !loopback_has?(ip)
          sudo = $stdin.tty? ? 'sudo' : 'sudo -n'
          system("#{sudo} ifconfig lo0 -alias #{ip} 2>/dev/null") if macos?
          system("#{sudo} ip addr del #{ip}/32 dev lo 2>/dev/null") unless macos?
        end

        def loopback_has?(ip)
          `ifconfig lo0 2>/dev/null || ip addr show lo 2>/dev/null`.include?(ip)
        end

        # ── Base image ───────────────────────────────────────────────────────────
        # The Debian genericcloud qcow2 is downloaded once and shared.
        # Each VM clones it (copy-on-write) as its rescue disk.
        # Debian is used because it has apt-get, making debootstrap and package
        # installation straightforward without extra package manager detection.

        def base_image_path
          @cfg.base_image_path(host_arch)
        end

        def ensure_base_image
          return if File.exist?(base_image_path)
          FileUtils.mkdir_p(File.dirname(base_image_path))
          url = resolve_base_image_url
          log "Downloading Debian base image to #{base_image_path} ..."
          log "  URL: #{url}"
          system("curl -L --progress-bar -o #{base_image_path.shellescape} #{url.shellescape}") \
            or raise "Base image download failed"
        end

        # Resolves the Debian genericcloud image URL for the VM's architecture.
        # If base_image_url is explicitly configured, that value is used as-is.
        # Otherwise, uses the stable bookworm genericcloud image from cloud.debian.org.
        def resolve_base_image_url
          return @cfg.base_image_url if @cfg.instance_variable_get(:@base_image_url)

          "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-#{host_arch}.qcow2"
        end

        # ── Disk images ─────────────────────────────────────────────────────────
        # Layout:
        #   vda      rescue_disk  — Debian rescue system (CoW clone of base image)
        #   nvme0n1  disk1.qcow2  — empty system disk 1 (for CloudModel's install)
        #   nvme1n1  disk2.qcow2  — empty system disk 2 (RAID mirror)
        #   …
        # system_disks in the Host document maps to nvme0n1, nvme1n1, …

        def vm_dir
          File.join(@cfg.vm_dir, @host.name)
        end

        def rescue_disk_path
          File.join(vm_dir, 'rescue.qcow2')
        end

        def disk_paths
          @host.vm_disk_paths.presence || []
        end

        def create_disks(force = false)
          FileUtils.mkdir_p(vm_dir)

          # Rescue disk: CoW clone of the shared base image (boots immediately)
          if !File.exist?(rescue_disk_path) || force
            log "Cloning Debian base image → rescue disk..."
            system("qemu-img create -f qcow2 -b #{base_image_path.shellescape} " \
                   "-F qcow2 #{rescue_disk_path.shellescape}") \
              or raise "qemu-img clone failed for rescue disk"
          end

          # System disks: empty, for CloudModel's Debian install
          paths = (1..@cfg.disk_count).map { |i| File.join(vm_dir, "disk#{i}.qcow2") }
          paths.each do |path|
            if File.exist?(path) && !force
              log "Disk exists: #{path} (skipping)"
              next
            end
            log "Creating #{@cfg.disk_size} system disk: #{path}"
            system("qemu-img create -f qcow2 #{path.shellescape} #{@cfg.disk_size.shellescape}") \
              or raise "qemu-img create failed for #{path}"
          end

          @host.update_attribute(:vm_disk_paths, paths)
        end

        # ── cloud-init NoCloud seed ──────────────────────────────────────────────
        # A small FAT image labeled CIDATA containing meta-data, user-data, and
        # network-config.  Debian's cloud-init discovers it by label automatically.

        def cloud_init_seed_path
          File.join(vm_dir, macos? ? 'seed.iso' : 'seed.img')
        end

        def create_cloud_init_seed(macs)
          log "Creating cloud-init seed..."
          args = [cloud_init_meta_data, cloud_init_user_data, cloud_init_network_config(macs)]
          macos? ? create_seed_macos(*args) : create_seed_linux(*args)
        end

        def cloud_init_meta_data
          "instance-id: #{@host.name}\nlocal-hostname: #{@host.name}\n"
        end

        # Root password login stays enabled: CloudModel::Host#ssh_connection
        # authenticates with initial_root_pw (password) as long as it is set —
        # exactly like a Hetzner rescue system.  The CloudModel pubkey is
        # installed additionally for wait_for_ssh and manual access.
        def cloud_init_user_data
          pubkey = File.read("#{CloudModel.config.data_directory}/keys/id_rsa.pub").strip

          runcmds = [
            "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config",
            'systemctl restart ssh'
          ]

          data = {
            'disable_root'        => false,
            'ssh_pwauth'          => true,
            'chpasswd'            => { 'list' => "root:#{@cfg.root_password}", 'expire' => false },
            'ssh_authorized_keys' => [pubkey],
            'packages'            => %w(gdisk mdadm parted e2fsprogs dosfstools debootstrap),
            'runcmd'              => runcmds
          }

          if apt_cache_active?
            # apt reads the conf file; debootstrap only honors the http_proxy
            # environment (via /etc/environment for SSH sessions).
            data['write_files'] = [{
              'path'    => '/etc/apt/apt.conf.d/01cloudmodel-cache',
              'content' => %(Acquire::http::Proxy "#{AptCache.proxy_url}";\n)
            }]
            runcmds.unshift "echo 'http_proxy=#{AptCache.proxy_url}' >> /etc/environment"
          end

          "#cloud-config\n" + data.to_yaml.sub(/\A---\n/, '')
        end

        def apt_cache_active?
          @cfg.apt_cache and AptCache.running?
        end

        # QEMU user-mode NAT always provides DHCP on its own 10.0.2.0/24 subnet
        # with 10.0.2.2 as the gateway.  A static IP from the CloudModel address
        # pool is not routable inside the NAT and prevents package installation.
        # The VM's real primary_address is only relevant outside the VM (loopback
        # alias + hostfwd on the host), so let DHCP handle the guest side.
        #
        # NICs are matched by MAC address — the kernel's predictable interface
        # names (enp0s1, …) vary by machine type, so matching by name would
        # leave the interface unconfigured and boot hang in networkd-wait-online.
        def cloud_init_network_config(macs)
          {
            'version' => 1,
            'config'  => macs.each_with_index.map do |mac, i|
              {
                'type'        => 'physical',
                'name'        => "eth#{i}",
                'mac_address' => mac,
                'subnets'     => [{ 'type' => 'dhcp' }]
              }
            end
          }.to_yaml
        end

        def create_seed_macos(meta_data, user_data, network_config)
          path = cloud_init_seed_path
          FileUtils.rm_f(path)

          Dir.mktmpdir('cidata') do |tmpdir|
            File.write("#{tmpdir}/meta-data",      meta_data)
            File.write("#{tmpdir}/user-data",       user_data)
            File.write("#{tmpdir}/network-config",  network_config)

            # hdiutil makehybrid produces a standard ISO9660/Joliet image.
            # cloud-init NoCloud discovers it by the volume label "cidata"
            # via blkid — more reliable than the FAT approach on macOS because
            # hdiutil's FAT images carry Apple partition metadata that confuses blkid.
            # hdiutil appends .iso automatically — pass the stem, not the full path
            stem = path.sub(/\.iso$/, '')
            system("hdiutil makehybrid -o #{stem.shellescape} " \
                   "-iso -joliet -default-volume-name cidata " \
                   "#{tmpdir.shellescape}") \
              or raise "hdiutil makehybrid failed"
          end
        end

        def create_seed_linux(meta_data, user_data, network_config)
          path = cloud_init_seed_path
          FileUtils.rm_f(path)
          system("dd if=/dev/zero of=#{path.shellescape} bs=512 count=2048 2>/dev/null") \
            or raise "dd failed"
          system("mkdosfs -F 12 -n CIDATA #{path.shellescape}") \
            or raise "mkdosfs failed — install dosfstools"

          Dir.mktmpdir('cidata') do |tmpdir|
            File.write("#{tmpdir}/meta-data",     meta_data)
            File.write("#{tmpdir}/user-data",      user_data)
            File.write("#{tmpdir}/network-config", network_config)
            %w[meta-data user-data network-config].each do |f|
              system("mcopy -i #{path.shellescape} #{File.join(tmpdir, f).shellescape} ::#{f}") \
                or raise "mcopy failed for #{f} — install mtools"
            end
          end
        end

        # ── MACs ─────────────────────────────────────────────────────────────────

        def generate_macs(count)
          macs = count.times.map do
            "52:54:00:%02x:%02x:%02x" % [rand(256), rand(256), rand(256)]
          end
          File.write(mac_path, macs.join("\n"))
          macs
        end

        def stored_macs
          return [] unless File.exist?(mac_path)
          File.read(mac_path).split("\n").map(&:strip).reject(&:empty?)
        end

        # ── QEMU command ─────────────────────────────────────────────────────────

        # Machine type, CPU and acceleration for the VM's architecture:
        # native arch → -cpu host with HVF (macOS) / KVM (Linux); foreign
        # arch → full TCG emulation with -cpu max (no accel flag). UEFI
        # firmware is required on both archs — the installed systems boot
        # via grub-efi --removable.
        def qemu_machine_args
          args = ['-M', host_arch == 'arm64' ? 'virt' : 'q35']

          if cross_arch?
            args += ['-cpu', 'max']
          else
            args += ['-cpu', 'host', '-accel', macos? ? 'hvf' : 'kvm']
          end

          # RTC follows the workstation clock so the guest recovers real time
          # when the Mac wakes from sleep (QEMU freezes the VM clock while the
          # host sleeps, so without this the guest drifts hours behind and apt
          # rejects "not valid yet" repo Release files). driftfix=slew smooths
          # small catch-ups instead of hard-stepping.
          args += ['-rtc', 'base=utc,clock=host,driftfix=slew']

          if fw = @cfg.qemu_firmware(host_arch)
            if host_arch == 'arm64'
              args += ['-bios', fw]
            else
              # x86 edk2 images are code-only pflash — `-bios` refuses them
              args += ['-drive', "if=pflash,format=raw,readonly=on,file=#{fw}"]
            end
          end
          args
        end

        def start_qemu(macs)
          FileUtils.mkdir_p(vm_dir)

          cmd = [qemu_binary]
          cmd += qemu_machine_args

          # Resources
          cmd += ['-m', @cfg.ram.to_s, '-smp', @cfg.cpus.to_s]

          # EDK2 has no persistent NVRAM here — it boots the first bootable
          # drive.  Rescue mode: rescue disk (vda) first.  System mode: leave
          # the rescue disk (and seed) away entirely, so the firmware boots
          # grub-efi from the system disks' ESP.
          #
          # NOTE: without the rescue disk the system disks shift to vda/vdb —
          # that's why everything on them is addressed via RAID (md*) or
          # filesystem labels, never via /dev/vdX paths.
          boot_rescue = !@host.respond_to?(:vm_boot_rescue) || @host.vm_boot_rescue

          # discard/detect-zeroes: writes of zeros (mkfs, mdadm) punch holes
          # instead of materializing them in the sparse qcow2, and fstrim in
          # the guest returns freed space to the workstation disk.
          drive_opts = 'cache=writeback,discard=unmap,detect-zeroes=unmap'

          if boot_rescue
            # Rescue disk — boots Debian directly, no ISO/UEFI dance. Explicit
            # bootindex=0 forces the firmware to boot it FIRST; otherwise, once
            # the system disks carry a grub-efi ESP, EDK2 may prefer that and boot
            # the installed system even in rescue mode (there is no persistent
            # NVRAM to pin the order). Attached as a virtio-blk device (not the
            # if=virtio shorthand) so bootindex can be set.
            cmd += ['-drive', "file=#{rescue_disk_path},if=none,#{drive_opts},id=rescue"]
            cmd += ['-device', 'virtio-blk-pci,drive=rescue,bootindex=0']
          end

          # System disks — empty at first, CloudModel installs Debian onto them.
          # Attached as emulated NVMe instead of virtio-blk: QEMU's NVMe
          # controller implements the SMART/health log, so smartmontools and
          # cloudmodel's UNMODIFIED smart check_mk plugin (it scans
          # /dev/nvme*n1; virtio vd* it would skip) see real data. Bonus:
          # nvme0n1/nvme1n1 names don't shift when the rescue disk goes away.
          # In rescue mode they get a bootindex AFTER the rescue disk.
          @host.vm_disk_paths.each_with_index do |path, i|
            cmd += ['-drive', "file=#{path},if=none,#{drive_opts},id=drive#{i}"]
            dev = "nvme,drive=drive#{i},serial=#{@host.name}-disk#{i}"
            dev += ",bootindex=#{i + 1}" if boot_rescue
            cmd += ['-device', dev]
          end

          if boot_rescue
            # cloud-init NoCloud seed (last virtio device, labeled CIDATA)
            cmd += ['-drive', "file=#{cloud_init_seed_path},if=virtio,format=raw,readonly=on,id=cidata"]

            # Tell cloud-init to use the NoCloud datasource.
            # Without this hint, cloud-init's ds-identify doesn't recognise a plain
            # QEMU VM as any known cloud and skips NoCloud, so the CIDATA volume is
            # never scanned regardless of its label.
            cmd += ['-smbios', 'type=1,serial=ds=nocloud']
          end

          primary_ip = @host.primary_address.ip
          ssh_port   = vm_ssh_port(primary_ip)

          # Shared inter-VM segment (see Config#vmnet): a NIC bound to the
          # socket_vmnet daemon so every VM — and the workstation — sit on one L2
          # segment and reach each other over their primary_address (the tinc VPN
          # underlay). User-mode NAT alone isolates the VMs and breaks all
          # cross-host guest routing. socket_vmnet_client (prepended to the command
          # below) opens the daemon socket on fd 3; QEMU attaches via socket,fd=3.
          #
          # Emitted FIRST so it takes the first PCI slot and the kernel names it
          # eth0 — the external interface cloudmodel expects (primary_address,
          # guest publics, tinc BindToInterface, firewall all target eth0). The
          # .link files still pin names by MAC, but matching the natural PCI order
          # avoids an eth0↔eth1 swap that systemd-udev cannot always apply.
          use_vmnet = @cfg.vmnet && primary_ip && File.socket?(@cfg.vmnet_socket)
          if use_vmnet
            vmnet_mac = CloudModel::Api::Qemu.vmnet_mac(primary_ip)
            cmd += ['-netdev', 'socket,id=vmnet,fd=3']
            cmd += ['-device', "virtio-net-pci,netdev=vmnet,mac=#{vmnet_mac}"]
          end

          # NICs — user-mode NAT; first NAT NIC forwards high port → VM:22.
          # With vmnet present these become eth1, eth2, … (internet + hostfwd SSH).
          macs.each_with_index do |mac, i|
            netdev = "user,id=net#{i}"
            netdev += ",hostfwd=tcp:127.0.0.1:#{ssh_port}-:22" if i == 0
            cmd += ['-netdev', netdev]
            cmd += ['-device', "virtio-net-pci,netdev=net#{i},mac=#{mac}"]
          end

          # QEMU monitor socket (for graceful shutdown)
          cmd += ['-monitor', "unix:#{monitor_path},server,nowait"]

          # Display: QEMU_DISPLAY=1 → graphical window; default → headless
          qemu_log = File.join(vm_dir, 'qemu.log')
          headless  = ENV['QEMU_DISPLAY'].to_s.empty?
          if headless
            cmd += ['-display', 'none', '-D', qemu_log]
          else
            cmd += ['-display', macos? ? 'cocoa' : 'gtk']
          end

          # Guest serial console: interactive via unix socket (nc -U serial.sock)
          # AND logged to serial.log — boot problems are invisible otherwise.
          cmd += ['-chardev', "socket,id=serial0,path=#{File.join(vm_dir, 'serial.sock')},server=on,wait=off,logfile=#{File.join(vm_dir, 'serial.log')}"]
          cmd += ['-serial', 'chardev:serial0']

          # socket_vmnet: run QEMU through the client wrapper, which opens the
          # daemon socket on fd 3 (referenced by `-netdev socket,fd=3` above) and
          # execs QEMU — so the tracked pid is still QEMU's and pid handling is
          # unchanged.
          if use_vmnet
            cmd = [@cfg.vmnet_client, @cfg.vmnet_socket, *cmd]
            log "  inter-VM segment via socket_vmnet (#{@cfg.vmnet_socket})"
          end

          log "Starting QEMU: #{qemu_binary} (#{host_arch}#{cross_arch? ? ' via TCG emulation' : ''}, " \
              "hostfwd 127.0.0.1:#{ssh_port} → VM:22#{headless ? '' : ', display on'}) ..."
          spawn_opts = { pgroup: true }
          spawn_opts.merge!(in: '/dev/null', out: qemu_log, err: qemu_log) if headless
          pid = Process.spawn(*cmd, **spawn_opts)
          Process.detach(pid)

          sleep 2
          unless process_alive?(pid)
            detail = File.exist?(qemu_log) ? File.read(qemu_log).strip : '(no log output)'
            raise "QEMU failed to start:\n#{detail}"
          end

          File.write(pid_path, pid.to_s)
          @host.update_attribute(:vm_pid_path, pid_path)
        end

        # ── SSH wait ─────────────────────────────────────────────────────────────
        # Polls until cloud-init has finished and sshd accepts the CloudModel key.

        # Each attempt gets a hard Timeout: QEMU's hostfwd accepts TCP even
        # while the guest is still in firmware, and such an early connection
        # is never answered nor reset — without the hard bound the very first
        # probe would block until boot_timeout expires.
        # TCG emulation boots roughly an order of magnitude slower than
        # HVF/KVM — give cross-arch VMs correspondingly more time.
        def effective_boot_timeout
          cross_arch? ? @cfg.boot_timeout * 6 : @cfg.boot_timeout
        end

        def wait_for_ssh(ip)
          deadline = Time.now + effective_boot_timeout
          begin
            Timeout.timeout(15) do
              vm_ssh(ip) { |ssh| ssh.exec!('true') }
            end
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
                 Errno::ETIMEDOUT, Net::SSH::AuthenticationFailed,
                 Net::SSH::Disconnect, Net::SSH::ConnectionTimeout, Timeout::Error
            raise "Timed out waiting for SSH on #{ip} (127.0.0.1:#{vm_ssh_port(ip)})" if Time.now > deadline
            print '.'
            sleep 3
            retry
          end
          puts ''
        end

        # Blocks until cloud-init has processed the seed (packages installed,
        # sshd reconfigured).  Without this, a deploy right after create_vm!
        # may not find sgdisk/mdadm yet.  Exit status 2 means "done with
        # recoverable errors" — good enough for a rescue system.
        def wait_for_cloud_init(ip)
          vm_ssh(ip) do |ssh|
            ssh.exec! 'cloud-init status --wait'
          end
        rescue => e
          log "WARNING: could not confirm cloud-init completion: #{e.message}"
        end

        # SSH session to the VM using the CloudModel key via the hostfwd port.
        # We connect to 127.0.0.1:<port> explicitly and disable OpenSSH config
        # evaluation, so this works even before ~/.ssh/config was written.
        def vm_ssh(ip, &block)
          key_path = "#{CloudModel.config.data_directory}/keys/id_rsa"
          Net::SSH.start('127.0.0.1', 'root',
            SSH_OPTS.merge(keys: [key_path], port: vm_ssh_port(ip), config: false),
            &block)
        end

        # ── SSH port & config ─────────────────────────────────────────────────────

        def vm_ssh_port(ip)
          22000 + ip.split('.').last.to_i
        end

        def ssh_config_path
          File.expand_path('~/.ssh/cloudmodel_vms')
        end

        def write_ssh_config(ip, port)
          main_config  = File.expand_path('~/.ssh/config')
          include_line = "Include #{ssh_config_path}"
          unless File.exist?(main_config) && File.read(main_config).include?(include_line)
            FileUtils.mkdir_p(File.dirname(main_config))
            FileUtils.touch(main_config)
            File.open(main_config, 'r+') do |f|
              original = f.read
              f.rewind
              f.write("#{include_line}\n\n#{original}")
            end
          end

          stanza = <<~SSH
            Host #{ip}
              HostName 127.0.0.1
              Port #{port}
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
          SSH

          existing = File.exist?(ssh_config_path) ? File.read(ssh_config_path) : ''
          pattern  = /^Host #{Regexp.escape(ip)}\n(?:  [^\n]*\n)*/
          updated  = existing.match?(pattern) ? existing.sub(pattern, stanza) : existing + "\n" + stanza
          File.write(ssh_config_path, updated)
        end

        def remove_ssh_config(ip)
          return unless File.exist?(ssh_config_path)
          existing = File.read(ssh_config_path)
          pattern  = /\n*^Host #{Regexp.escape(ip)}\n(?:  [^\n]*\n)*/
          File.write(ssh_config_path, existing.gsub(pattern, ''))
        end

        # ── Host document ─────────────────────────────────────────────────────────

        def persist_host
          # The rescue disk is virtio (vda); system disks are NVMe devices
          @host.system_disks    = (0...@cfg.disk_count).map { |i| "nvme#{i}n1" }
          @host.initial_root_pw = @cfg.root_password
          @host.vm_extra_nics   = stored_macs.size - 1 if stored_macs.size > 0
          # arch was chosen on host creation and selected the emulated
          # machine — keep it (cloudmodel's deploy re-detects it anyway)
          @host.arch            = host_arch
          @host.save!
        end

        # ── Helpers ──────────────────────────────────────────────────────────────

        def pid_path;     File.join(vm_dir, 'qemu.pid');     end
        def mac_path;     File.join(vm_dir, 'macs.txt');     end
        def monitor_path; File.join(vm_dir, 'monitor.sock'); end

        def send_monitor_command(cmd)
          require 'socket'
          UNIXSocket.open(monitor_path) do |s|
            s.readpartial(1024) if s.wait_readable(2) # discard banner (never block: read(n) would wait for n bytes)
            s.write("#{cmd}\n")
            sleep 0.2
          end
        rescue => e
          log "Monitor error: #{e.message}"
        end

        def log(msg)
          puts "[cloudmodel-api-qemu] #{msg}"
        end
      end
    end
  end
end
