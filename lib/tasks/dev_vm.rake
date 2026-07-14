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

    # Generates one idempotent script for all the Mac-side (sudo) networking a
    # dev cluster needs so guests are reachable from the workstation: joins the
    # socket_vmnet L2 as the primary-network gateway and routes each host's guest
    # (tinc) subnet through that host. Run it once with a single sudo:
    #   sudo sh $(bundle exec rake dev:vm:mac_network | tail -1)  [up|down]
    desc "Generate the sudo script for Mac-side routing to reach the dev guests"
    task mac_network: :environment do
      hosts = CloudModel::Host.all.to_a.select do |h|
        h.respond_to?(:vm_disk_paths) && h.vm_disk_paths.present? && h.deploy_state == :finished
      end
      abort "No deployed QEMU VM hosts found." if hosts.empty?

      # The workstation joins the primary L2 on a free host address (NOT the
      # gateway .1 — that is a host/router) so it can route to the guest subnets.
      gateway = hosts.first.primary_address.gateway.to_s.sub(/\.\d+\z/, '.254')
      # socket_vmnet's bridge = the iface holding its --vmnet-gateway address.
      vmnet_gw = `ps ax -o args= 2>/dev/null | sed -n 's/.*--vmnet-gateway=\\([0-9.]*\\).*/\\1/p' | head -1`.strip
      vmnet_gw = '192.168.105.1' if vmnet_gw.empty?

      routes = hosts.map do |h|
        pn = h.private_network
        next unless pn && pn.ip
        "#{pn.ip}/#{pn.subnet} #{h.primary_address.ip}  # #{h.name} guests"
      end.compact

      script_path = File.join(CloudModel.config.api.qemu.vm_dir, 'mac-network.sh')
      File.write script_path, <<~SH
        #!/bin/sh
        # Generated by `rake dev:vm:mac_network`. Mac-side routing so QEMU dev
        # guests are reachable from the workstation. Run with one sudo:
        #   sudo sh #{script_path} up      # (default)
        #   sudo sh #{script_path} down
        VMNET_GW=#{vmnet_gw}
        GW=#{gateway}
        # the socket_vmnet bridge = the interface that HOLDS the vmnet gateway IP.
        # (route -n get returns lo0 for the Mac's own IPs, so scan interfaces.)
        BRIDGE=""
        for i in $(ifconfig -l 2>/dev/null); do
          ifconfig "$i" 2>/dev/null | grep -qw "$VMNET_GW" && { BRIDGE="$i"; break; }
        done
        [ -z "$BRIDGE" ] && BRIDGE=bridge100
        ROUTES="#{routes.join("\n")}"

        case "${1:-up}" in
        up)
          echo "Joining $BRIDGE as $GW/16 ..."
          ifconfig "$BRIDGE" alias "$GW" 255.255.0.0 2>/dev/null || true
          echo "$ROUTES" | while read net via _; do
            [ -z "$net" ] && continue
            # delete-then-add so the route always re-resolves onto the vmnet
            # bridge (a stale route added before the alias binds to en0).
            route -n delete -net "$net" 2>/dev/null
            route -n add -net "$net" "$via"
            echo "  route $net -> $via"
          done
          ;;
        down)
          echo "$ROUTES" | while read net via _; do
            [ -z "$net" ] && continue
            route -n delete -net "$net" "$via" 2>/dev/null || true
          done
          ifconfig "$BRIDGE" -alias "$GW" 2>/dev/null || true
          echo "removed."
          ;;
        *) echo "usage: $0 [up|down]"; exit 1 ;;
        esac
      SH

      puts "Wrote Mac-network script. Bring it up with ONE sudo:"
      puts "  sudo sh #{script_path} up"
      puts "  sudo sh #{script_path} down   # to remove"
      puts ""
      puts "Routes it will add (guest tinc subnet -> host):"
      routes.each { |r| puts "  #{r}" }
      puts script_path
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
