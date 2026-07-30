namespace :dev do
  desc <<~DESC
    Create a local QEMU VM and register it as a CloudModel::Host.

    IP allocation uses two configured network blocks:

      config.tinc_network            — /25 per host for private_network (tinc + LXD bridge)
      config.api.qemu.external_network — at least a /16; partitioned as:
        x.x.0.x   — primary_address IPs (one per host, up to 254)
        x.x.1.0/24, x.x.2.0/24, … — host.addresses subnets (one /24 per host)

    Usage:
      rake dev:create_vm_host              # auto-name (host1, host2, …)
      rake dev:create_vm_host[name]        # explicit name, 1 NIC / 1 IP
      rake dev:create_vm_host[name,2]      # explicit name, 1 primary + 2 extra IPs
      rake dev:create_vm_host[name,0,amd64] # explicit architecture — the
        # workstation's arch runs hardware-accelerated, any other arch is
        # fully TCG-emulated (slow, but true to the production platform)
  DESC
  task :create_vm_host, [:name, :extra_ips, :arch] => [:environment] do |_, args|
    extra_ips = args[:extra_ips].to_i

    arch = args[:arch].presence || CloudModel::Api::Qemu::Config.workstation_arch
    abort "Unknown arch '#{arch}' — known: #{CloudModel::Host::ARCHITECTURES.join(', ')}" \
      unless CloudModel::Host::ARCHITECTURES.include?(arch)
    # amd64/arm64 are boot-wired; the others are recognized for future use but
    # their QEMU boot path (firmware/bootloader) is not implemented yet.
    abort "Local QEMU VMs are only implemented for #{CloudModel::Host::TESTED_ARCHITECTURES.join('/')}; '#{arch}' is recognized but untested." \
      unless CloudModel::Host::TESTED_ARCHITECTURES.include?(arch)

    allocator = CloudModel::Api::Qemu::IpAllocator.new(
      CloudModel::Host.all.to_a,
      tinc_network:     CloudModel.config.tinc_network,
      external_network: CloudModel.config.api.qemu.external_network
    )

    name = args[:name]&.strip
    if name.nil? || name.empty?
      name = allocator.next_name
      puts "No name given, using '#{name}'"
    end

    abort "Invalid name: only a-z, 0-9, hyphens and underscores allowed" \
      unless name =~ /\A[a-z0-9\-_]+\z/

    if CloudModel::Host.where(name: name).exists?
      puts "Host '#{name}' already exists — skipping."
      exit 0
    end

    begin
      primary = allocator.primary_address
      guest   = allocator.guest_address
      private_net = allocator.private_network
    rescue RuntimeError => e
      abort e.message
    end

    puts "Allocating:"
    puts "  primary_address : #{primary[:ip]}/#{primary[:subnet]}  (gateway: #{primary[:gateway]})"
    puts "  guest addresses : #{guest[:ip]}/#{guest[:subnet]}  (gateway: #{guest[:gateway]})"
    puts "  private_network : #{private_net[:ip]}/#{private_net[:subnet]}  (gateway: #{private_net[:gateway]})"
    puts ""

    # system_disks is set by create_vm! (NVMe devices; vda is the rescue disk)
    host = CloudModel::Host.new(
      name:            name,
      arch:            arch,
      primary_address: primary,
      private_network: private_net
    )
    host.addresses.build(guest)

    host.save(validate: false) or abort "Failed to persist Host document"
    puts "Host '#{name}' created (id: #{host.id}, arch: #{arch})"

    # ── Provision VM ─────────────────────────────────────────────────────────
    puts "Provisioning VM (extra_ips: #{extra_ips})..."
    host.create_vm!(extra_ips: extra_ips)
  end

  namespace :vm do
    def find_vm_host(name)
      abort "Usage: rake dev:vm:<task>[name]" if name.nil? || name.strip.empty?
      CloudModel::Host.where(name: name.strip).first or abort "No host named '#{name}'"
    end

    desc "Alias for dev:create_vm_host"
    task :create, [:name, :extra_ips] => ['dev:create_vm_host']

    desc "List all hosts with their VM state"
    task list: :environment do
      hosts = CloudModel::Host.all.to_a
      if hosts.empty?
        puts "No hosts defined. Create one with: rake dev:create_vm_host"
        next
      end
      hosts.each do |host|
        s = host.vm_status
        state = s[:running] ? "RUNNING (pid #{s[:pid]})" : "stopped"
        puts format("%-12s %-15s ssh 127.0.0.1:%-6s %s", host.name, s[:ip], s[:ssh_port], state)
      end
    end

    desc "Start a stopped VM"
    task :start, [:name] => [:environment] do |_, args|
      find_vm_host(args[:name]).start_vm!
    end

    desc "Gracefully stop a VM (ACPI power-off)"
    task :stop, [:name] => [:environment] do |_, args|
      find_vm_host(args[:name]).stop_vm!
    end

    desc "Force-kill a VM (like pulling the power)"
    task :kill, [:name] => [:environment] do |_, args|
      find_vm_host(args[:name]).kill_vm!
    end

    desc "Destroy a VM's disks and state files (keeps the Host document)"
    task :destroy, [:name] => [:environment] do |_, args|
      find_vm_host(args[:name]).destroy_vm!
    end

    desc "Destroy a VM and delete its Host document"
    task :purge, [:name] => [:environment] do |_, args|
      host = find_vm_host(args[:name])
      host.destroy_vm!
      host.delete
      puts "Host '#{host.name}' deleted."
    end

    desc "Print the SSH command for a VM"
    task :ssh, [:name] => [:environment] do |_, args|
      host = find_vm_host(args[:name])
      s = host.vm_status
      puts "ssh -i #{CloudModel.config.data_directory}/keys/id_rsa -p #{s[:ssh_port]} root@127.0.0.1"
      puts "# or via ~/.ssh/config mapping:"
      puts "ssh root@#{s[:ip]}"
    end

    # ── Sleep guard ────────────────────────────────────────────────────────────
    # macOS freezing a VM mid-I/O on sleep (and the clock jump on wake) is the
    # root cause of the recurring LXD/ZFS corruption. Pausing the VM's vCPUs with
    # the QEMU monitor ('stop') BEFORE the host sleeps quiesces it at a clean
    # point — no in-flight guest I/O to corrupt — and 'cont' + a clock resync on
    # wake recovers it. Wire pause_all/resume_all to the host's sleep/wake events
    # (see dev:vm:sleep_guard).
    def monitor_send(host, cmd)
      require 'socket'
      sock = File.join(CloudModel.config.api.qemu.vm_dir, host.name, 'monitor.sock')
      return false unless File.socket?(sock)
      UNIXSocket.open(sock) do |s|
        s.readpartial(1024) if s.wait_readable(2) # discard banner
        s.write("#{cmd}\n"); sleep 0.2
        (s.readpartial(4096) if s.wait_readable(1)) rescue nil
      end
      true
    rescue => e
      warn "monitor #{host.name}: #{e.message}"; false
    end

    def running_vm_hosts
      CloudModel::Host.all.to_a.select { |h| h.respond_to?(:vm_status) && (h.vm_status[:running] rescue false) }
    end

    desc "Pause all running dev VMs (QEMU 'stop') — clean quiesce before a Mac sleep"
    task pause_all: :environment do
      hosts = running_vm_hosts
      puts hosts.empty? ? "No running VMs." : "Pausing #{hosts.size} VM(s)…"
      hosts.each { |h| puts "  #{monitor_send(h, 'stop') ? '⏸' : '·'} #{h.name}" }
    end

    desc "Resume all paused dev VMs ('cont') + nudge guest clocks after the freeze"
    task resume_all: :environment do
      hosts = running_vm_hosts
      key = File.join(CloudModel.config.data_directory, 'keys', 'id_rsa')
      hosts.each do |h|
        monitor_send(h, 'cont')
        port = h.vm_status[:ssh_port]
        # best-effort, detached: step the clock forward after the pause
        system("ssh -i #{key} -p #{port} -o StrictHostKeyChecking=no -o ConnectTimeout=4 " \
               "-o BatchMode=yes root@127.0.0.1 'chronyc makestep 2>/dev/null || " \
               "hwclock -s 2>/dev/null || systemctl restart systemd-timesyncd 2>/dev/null || true' " \
               ">/dev/null 2>&1 &")
        puts "  ▶ #{h.name}"
      end
      puts "No running VMs." if hosts.empty?
    end

    desc "Install sleep/wake hooks so dev VMs pause on Mac sleep (needs sleepwatcher)"
    task sleep_guard: :environment do
      app  = Rails.root.to_s
      ruby = RbConfig.ruby
      dir  = File.join(CloudModel.config.api.qemu.vm_dir)
      sleep_sh = File.join(dir, 'on-sleep.sh')
      wake_sh  = File.join(dir, 'on-wake.sh')
      # Prepend this Ruby's bin to PATH so `bundle` resolves to the right one in
      # sleepwatcher's minimal launchd environment (a bare `ruby -S bundle` there
      # can't find the bundler executable).
      rubybin = File.dirname(ruby)
      hook = ->(task) { "#!/bin/sh\nexport PATH=#{rubybin}:$PATH\ncd #{app} && bundle exec rake #{task} >> #{dir}/sleep-guard.log 2>&1\n" }
      File.write(sleep_sh, hook.call('dev:vm:pause_all'))
      File.write(wake_sh,  hook.call('dev:vm:resume_all'))
      File.chmod(0o755, sleep_sh); File.chmod(0o755, wake_sh)

      have_sw = !`which sleepwatcher 2>/dev/null`.strip.empty?
      puts "Wrote sleep/wake hooks:\n  #{sleep_sh}\n  #{wake_sh}"
      puts ""
      if have_sw
        puts "sleepwatcher is installed. Enable the guard with:"
      else
        puts "Install sleepwatcher, then enable the guard:"
        puts "  brew install sleepwatcher"
      end
      puts "  ln -sf #{sleep_sh} ~/.sleep"
      puts "  ln -sf #{wake_sh}  ~/.wakeup"
      puts "  brew services start sleepwatcher"
      puts ""
      puts "Then VMs pause on Mac sleep and resume on wake — no more mid-I/O freeze."
    end
  end

  # Workstation-side caching proxy for the VMs' apt/debootstrap traffic
  namespace :apt_cache do
    desc "Show apt cache proxy status"
    task status: :environment do
      CloudModel::Api::Qemu::AptCache.status.each { |k, v| puts format("%-14s %s", "#{k}:", v) }
    end

    desc "Start the apt cache proxy"
    task start: :environment do
      CloudModel::Api::Qemu::AptCache.ensure_running!
    end

    desc "Stop the apt cache proxy"
    task stop: :environment do
      puts CloudModel::Api::Qemu::AptCache.stop ? 'stopped' : 'was not running'
    end
  end
end
