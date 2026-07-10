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
  DESC
  task :create_vm_host, [:name, :extra_ips] => [:environment] do |_, args|
    extra_ips = args[:extra_ips].to_i

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
      primary_address: primary,
      private_network: private_net
    )
    host.addresses.build(guest)

    host.save(validate: false) or abort "Failed to persist Host document"
    puts "Host '#{name}' created (id: #{host.id})"

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
  end
end
