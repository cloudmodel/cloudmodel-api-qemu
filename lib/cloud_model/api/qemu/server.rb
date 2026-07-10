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
            ['qemu-img',       { brew: 'qemu', apt: 'qemu-utils' }],
            [@cfg.qemu_binary, { brew: 'qemu', apt: 'qemu-system-x86 / qemu-system-arm' }],
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
          bin = `which #{@cfg.qemu_binary.shellescape}`.strip
          return if system("#{bin.shellescape} -version > /dev/null 2>&1")

          raise <<~MSG
            #{@cfg.qemu_binary} exits immediately — the binary may have an invalid code signature.

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

        def arm64?
          RbConfig::CONFIG['host_cpu'] =~ /arm|aarch64/
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

        def ensure_base_image
          return if File.exist?(@cfg.base_image_path)
          FileUtils.mkdir_p(File.dirname(@cfg.base_image_path))
          url = resolve_base_image_url
          log "Downloading Debian base image to #{@cfg.base_image_path} ..."
          log "  URL: #{url}"
          system("curl -L --progress-bar -o #{@cfg.base_image_path.shellescape} #{url.shellescape}") \
            or raise "Base image download failed"
        end

        # Resolves the Debian genericcloud image URL for the current architecture.
        # If base_image_url is explicitly configured, that value is used as-is.
        # Otherwise, uses the stable bookworm genericcloud image from cloud.debian.org.
        def resolve_base_image_url
          return @cfg.base_image_url if @cfg.instance_variable_get(:@base_image_url)

          arch = arm64? ? 'arm64' : 'amd64'
          "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-#{arch}.qcow2"
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
            system("qemu-img create -f qcow2 -b #{@cfg.base_image_path.shellescape} " \
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
          pubkey = File.read("#{CloudModel.config.data_directory}/keys/id_rsa.pub").strip

          meta_data = "instance-id: #{@host.name}\nlocal-hostname: #{@host.name}\n"

          # Root password login stays enabled: CloudModel::Host#ssh_connection
          # authenticates with initial_root_pw (password) as long as it is set —
          # exactly like a Hetzner rescue system.  The CloudModel pubkey is
          # installed additionally for wait_for_ssh and manual access.
          user_data = <<~YAML
            #cloud-config
            disable_root: false
            ssh_pwauth: true
            chpasswd:
              list: "root:#{@cfg.root_password}"
              expire: false
            ssh_authorized_keys:
              - #{pubkey}
            packages:
              - gdisk
              - mdadm
              - parted
              - e2fsprogs
              - dosfstools
              - debootstrap
            runcmd:
              - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
              - systemctl restart ssh
          YAML

          # QEMU user-mode NAT always provides DHCP on its own 10.0.2.0/24 subnet
          # with 10.0.2.2 as the gateway.  A static IP from the CloudModel address
          # pool is not routable inside the NAT and prevents package installation.
          # The VM's real primary_address is only relevant outside the VM (loopback
          # alias + hostfwd on the host), so let DHCP handle the guest side.
          #
          # NICs are matched by MAC address — the kernel's predictable interface
          # names (enp0s1, …) vary by machine type, so matching by name would
          # leave the interface unconfigured and boot hang in networkd-wait-online.
          network_config = {
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

          log "Creating cloud-init seed..."
          macos? ? create_seed_macos(meta_data, user_data, network_config)
                 : create_seed_linux(meta_data, user_data, network_config)
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

        def start_qemu(macs)
          FileUtils.mkdir_p(vm_dir)

          cmd = [@cfg.qemu_binary]

          # Machine type & acceleration
          if arm64?
            cmd += ['-M', 'virt', '-cpu', 'host', '-accel', 'hvf']
            fw = @cfg.qemu_firmware
            cmd += ['-bios', fw] if fw
          else
            cmd += ['-accel', 'kvm']
          end

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

          if boot_rescue
            # Rescue disk (vda) — boots Debian directly, no ISO/UEFI dance
            cmd += ['-drive', "file=#{rescue_disk_path},if=virtio,cache=writeback,id=rescue"]
          end

          # System disks — empty at first, CloudModel installs Debian onto them.
          # Attached as emulated NVMe instead of virtio-blk: QEMU's NVMe
          # controller implements the SMART/health log, so smartmontools and
          # cloudmodel's UNMODIFIED smart check_mk plugin (it scans
          # /dev/nvme*n1; virtio vd* it would skip) see real data. Bonus:
          # nvme0n1/nvme1n1 names don't shift when the rescue disk goes away.
          @host.vm_disk_paths.each_with_index do |path, i|
            cmd += ['-drive', "file=#{path},if=none,cache=writeback,id=drive#{i}"]
            cmd += ['-device', "nvme,drive=drive#{i},serial=#{@host.name}-disk#{i}"]
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

          # NICs — user-mode NAT; first NIC forwards high port → VM:22
          primary_ip = @host.primary_address.ip
          ssh_port   = vm_ssh_port(primary_ip)
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

          log "Starting QEMU: #{@cfg.qemu_binary} " \
              "(rescue: Debian, hostfwd 127.0.0.1:#{ssh_port} → VM:22#{headless ? '' : ', display on'}) ..."
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
        def wait_for_ssh(ip)
          deadline = Time.now + @cfg.boot_timeout
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
          @host.arch            = arm64? ? 'arm64' : 'amd64'
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
