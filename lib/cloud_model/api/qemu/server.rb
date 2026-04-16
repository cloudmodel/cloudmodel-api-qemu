require 'net/ssh'
require 'net/http'
require 'rbconfig'
require 'fileutils'
require 'tmpdir'

module CloudModel
  module Api
    module Qemu
      # Manages the QEMU process lifecycle for a single CloudModel::Host.
      #
      # Boot model:
      #   Each VM has a small Alpine Linux rescue disk (cloned from a shared base
      #   image) as vda, plus disk_count empty system disks (vdb, vdc, …) for
      #   CloudModel to partition and install Debian onto.
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
        SSH_OPTS = {
          auth_methods:    ['publickey'],
          verify_host_key: :never,
          non_interactive: true
        }.freeze

        def initialize(host)
          @host = host
          @cfg  = CloudModel.config.api.qemu
        end

        # ── Public lifecycle ────────────────────────────────────────────────────

        def create(options = {})
          extra_ips = options.fetch(:extra_ips, 0).to_i
          nic_count = 1 + extra_ips

          check_dependencies
          ensure_base_image
          create_disks(options[:force])

          macs       = generate_macs(nic_count)
          primary_ip = @host.primary_address.ip
          ssh_port   = vm_ssh_port(primary_ip)

          create_cloud_init_seed
          add_loopback_alias(primary_ip)
          write_ssh_config(primary_ip, ssh_port)
          start_qemu(macs)

          log "Waiting for SSH on #{primary_ip} (→ 127.0.0.1:#{ssh_port}) ..."
          wait_for_ssh(primary_ip)

          log "Updating Host document..."
          persist_host

          log "Done. VM '#{@host.name}' reachable at #{primary_ip}"
          true
        end

        def start
          raise "No disk images found — run create_vm! first" if disk_paths.empty?
          macs = stored_macs
          raise "No stored MACs — cannot restart. Destroy and re-create." if macs.empty?
          ip = @host.primary_address.ip
          add_loopback_alias(ip)
          write_ssh_config(ip, vm_ssh_port(ip))
          start_qemu(macs)
        end

        def stop
          return unless running?
          send_monitor_command('system_powerdown')
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
          FileUtils.rm_f(rescue_disk_path)
          FileUtils.rm_f(cloud_init_seed_path)
          disk_paths.each { |p| FileUtils.rm_f(p) }
          [pid_path, mac_path, monitor_path].each { |p| FileUtils.rm_f(p) }
          @host.update_attributes(vm_disk_paths: [], vm_pid_path: nil)
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

        def add_loopback_alias(ip)
          return if ip.nil? || loopback_has?(ip)
          log "Adding loopback alias #{ip} (sudo required)..."
          system("sudo ifconfig lo0 alias #{ip}/32") if macos?
          system("sudo ip addr add #{ip}/32 dev lo 2>/dev/null || true") unless macos?
        end

        def remove_loopback_alias(ip)
          return if ip.nil? || !loopback_has?(ip)
          system("sudo ifconfig lo0 -alias #{ip}") if macos?
          system("sudo ip addr del #{ip}/32 dev lo 2>/dev/null || true") unless macos?
        end

        def loopback_has?(ip)
          `ifconfig lo0 2>/dev/null || ip addr show lo 2>/dev/null`.include?(ip)
        end

        # ── Base image ───────────────────────────────────────────────────────────
        # The Alpine genericcloud qcow2 is downloaded once and shared.
        # Each VM clones it (copy-on-write) as its rescue disk.

        def ensure_base_image
          return if File.exist?(@cfg.base_image_path)
          FileUtils.mkdir_p(File.dirname(@cfg.base_image_path))
          url = resolve_base_image_url
          log "Downloading Alpine base image to #{@cfg.base_image_path} ..."
          log "  URL: #{url}"
          system("curl -L --progress-bar -o #{@cfg.base_image_path.shellescape} #{url.shellescape}") \
            or raise "Base image download failed"
        end

        # Resolves the Alpine cloud image URL for the current architecture.
        # If base_image_url is explicitly configured, that value is used as-is.
        # Otherwise, fetches the CDN directory listing and picks the latest
        # alpine-virt-*.qcow2 for the right arch.
        def resolve_base_image_url
          return @cfg.base_image_url if @cfg.instance_variable_get(:@base_image_url)

          arch    = arm64? ? 'aarch64' : 'x86_64'
          cdn     = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/"
          log "Resolving latest Alpine cloud image for #{arch}..."

          uri      = URI(cdn)
          response = Net::HTTP.get_response(uri)
          raise "Failed to fetch Alpine CDN listing (#{response.code}): #{cdn}" unless response.is_a?(Net::HTTPSuccess)

          # Directory index contains hrefs like:
          #   generic_alpine-3.23.0-aarch64-uefi-cloudinit-r0.qcow2
          # We want the generic (non-metal) cloudinit variant — it has cloud-init
          # pre-installed and is sized for VMs (~200 MB vs ~400 MB metal).
          filename = response.body
            .scan(/generic_alpine-[\d.]+-#{Regexp.escape(arch)}-uefi-cloudinit-r\d+\.qcow2/)
            .reject { |f| f.include?('metal') }
            .uniq
            .max_by { |f| Gem::Version.new(f[/[\d.]+/]) }

          raise "No Alpine cloud image found for #{arch} at #{cdn}" unless filename
          "#{cdn}#{filename}"
        end

        # ── Disk images ─────────────────────────────────────────────────────────
        # Layout:
        #   vda  rescue_disk  — Alpine rescue system (CoW clone of base image)
        #   vdb  disk1.qcow2  — empty system disk 1 (for CloudModel to install Debian)
        #   vdc  disk2.qcow2  — empty system disk 2 (RAID mirror)
        #   …
        # system_disks in the Host document maps to vdb, vdc, …

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
            log "Cloning Alpine base image → rescue disk..."
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
        # network-config.  Alpine's cloud-init discovers it by label automatically.

        def cloud_init_seed_path
          File.join(vm_dir, macos? ? 'seed.iso' : 'seed.img')
        end

        def create_cloud_init_seed
          pubkey     = File.read("#{CloudModel.config.data_directory}/keys/id_rsa.pub").strip
          primary_ip = @host.primary_address.ip
          subnet     = @host.primary_address.subnet || 24
          gateway    = @host.primary_address.gateway

          meta_data = "instance-id: #{@host.name}\nlocal-hostname: #{@host.name}\n"

          user_data = <<~YAML
            #cloud-config
            disable_root: false
            ssh_pwauth: false
            chpasswd:
              list: "root:#{@cfg.root_password}"
              expire: false
            ssh_authorized_keys:
              - #{pubkey}
            packages:
              - gptfdisk
              - mdadm
              - parted
              - e2fsprogs
            runcmd:
              - mkdir -p /root/.ssh
              - chmod 700 /root/.ssh
              - echo #{pubkey.shellescape} > /root/.ssh/authorized_keys
              - chmod 600 /root/.ssh/authorized_keys
              - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
              - rc-update add sshd default
              - rc-service sshd start || rc-service sshd restart
          YAML

          # QEMU user-mode NAT always provides DHCP on its own 10.0.2.0/24 subnet
          # with 10.0.2.2 as the gateway.  A static IP from the CloudModel address
          # pool is not routable inside the NAT and prevents package installation.
          # The VM's real primary_address is only relevant outside the VM (loopback
          # alias + hostfwd on the host), so let DHCP handle the guest side.
          network_config = <<~YAML
            version: 1
            config:
              - type: physical
                name: eth0
                subnets:
                  - type: dhcp
          YAML

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

          # Rescue disk (vda) — boots Alpine directly, no ISO/UEFI dance
          cmd += ['-drive', "file=#{rescue_disk_path},if=virtio,cache=writeback,id=rescue"]

          # System disks (vdb, vdc, …) — empty, for CloudModel's Debian install
          @host.vm_disk_paths.each_with_index do |path, i|
            cmd += ['-drive', "file=#{path},if=virtio,cache=writeback,id=drive#{i}"]
          end

          # cloud-init NoCloud seed (last virtio device, labeled CIDATA)
          cmd += ['-drive', "file=#{cloud_init_seed_path},if=virtio,format=raw,readonly=on,id=cidata"]

          # Tell cloud-init to use the NoCloud datasource.
          # Without this hint, cloud-init's ds-identify doesn't recognise a plain
          # QEMU VM as any known cloud and skips NoCloud, so the CIDATA volume is
          # never scanned regardless of its label.
          cmd += ['-smbios', 'type=1,serial=ds=nocloud']

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

          log "Starting QEMU: #{@cfg.qemu_binary} " \
              "(rescue: Alpine, hostfwd 127.0.0.1:#{ssh_port} → VM:22#{headless ? '' : ', display on'}) ..."
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

        def wait_for_ssh(ip)
          key_path  = "#{CloudModel.config.data_directory}/keys/id_rsa"
          ssh_port  = vm_ssh_port(ip)
          # Net::SSH does not read ~/.ssh/config, so we must supply the forwarded
          # port explicitly.  QEMU hostfwd binds 127.0.0.1:ssh_port → guest:22.
          ssh_opts  = SSH_OPTS.merge(keys: [key_path], port: ssh_port)
          deadline  = Time.now + @cfg.boot_timeout
          loop do
            raise "Timed out waiting for SSH on #{ip} (127.0.0.1:#{ssh_port})" if Time.now > deadline
            begin
              Net::SSH.start('127.0.0.1', 'root', ssh_opts) { break }
            rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
                   Net::SSH::AuthenticationFailed, Net::SSH::Disconnect, Timeout::Error
              sleep 3
              print '.'
            end
          end
          puts ''
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
          # vda is the Alpine rescue disk; system disks start at vdb
          @host.system_disks    = (1..@cfg.disk_count).map { |i| "vd#{('b'.ord + i - 1).chr}" }
          @host.initial_root_pw = @cfg.root_password
          @host.save!
        end

        # ── Helpers ──────────────────────────────────────────────────────────────

        def pid_path;     File.join(vm_dir, 'qemu.pid');     end
        def mac_path;     File.join(vm_dir, 'macs.txt');     end
        def monitor_path; File.join(vm_dir, 'monitor.sock'); end

        def send_monitor_command(cmd)
          require 'socket'
          UNIXSocket.open(monitor_path) do |s|
            s.read(1024) # discard banner
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
