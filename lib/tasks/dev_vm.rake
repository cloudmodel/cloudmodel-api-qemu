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
    require 'netaddr'

    extra_ips = args[:extra_ips].to_i

    name = args[:name]&.strip
    if name.nil? || name.empty?
      used_numbers = CloudModel::Host.all.map(&:name)
        .grep(/\Ahost\d+\z/)
        .map { |n| n.sub('host', '').to_i }
        .to_set
      n = (1..).find { |i| !used_numbers.include?(i) }
      name = "host#{n.to_s.rjust(2, '0')}"
      puts "No name given, using '#{name}'"
    end

    abort "Invalid name: only a-z, 0-9, hyphens and underscores allowed" \
      unless name =~ /\A[a-z0-9\-_]+\z/

    if CloudModel::Host.where(name: name).exists?
      puts "Host '#{name}' already exists — skipping."
      exit 0
    end

    vm_cfg       = CloudModel.config.api.qemu
    tinc_net     = NetAddr.parse_net(CloudModel.config.tinc_network)
    ext_net      = NetAddr.parse_net(vm_cfg.external_network)

    # Derive the two external sub-pools from ext_net (requires at least /16):
    #   primary pool : x.x.0.0/24  (third octet = 0)
    #   guest pool   : x.x.1.0/24 … (third octet = 1, 2, …)
    ext_parts     = ext_net.network.to_s.split('.')
    ext_prefix    = ext_parts[0..1].join('.')   # e.g. "10.66"
    primary_cidr  = "#{ext_prefix}.0.0/24"

    existing_hosts = CloudModel::Host.all.to_a

    # ── primary_address: next free host slot in x.x.0.0/24 ──────────────────
    used_primary_octets = existing_hosts
      .map  { |h| h.primary_address&.ip }
      .compact
      .select { |ip| ip.start_with?("#{ext_prefix}.0.") }
      .map    { |ip| ip.split('.').last.to_i }
      .to_set

    primary_octet = (1..254).find { |i| !used_primary_octets.include?(i) } \
      or abort "No free IPs left in #{primary_cidr}"

    primary_ip      = "#{ext_prefix}.0.#{primary_octet}"
    primary_gateway = "#{ext_prefix}.0.1"

    # ── host.addresses: next free /24 starting at x.x.1.0 ───────────────────
    used_guest_octets = existing_hosts
      .flat_map { |h| Array(h.addresses).map(&:ip) }
      .compact
      .select   { |ip|
        parts = ip.split('.')
        parts[0..1].join('.') == ext_prefix && parts[2].to_i >= 1 && parts[3] == '0'
      }
      .map      { |ip| ip.split('.')[2].to_i }
      .to_set

    guest_third_octet = (1..254).find { |i| !used_guest_octets.include?(i) } \
      or abort "No free guest subnets left in #{ext_prefix}.1-254.0/24"

    guest_subnet  = "#{ext_prefix}.#{guest_third_octet}.0"
    guest_gateway = "#{ext_prefix}.#{guest_third_octet}.1"

    # ── private_network: next free /25 within tinc_network ───────────────────
    used_private_nets = existing_hosts
      .map { |h| h.private_network }
      .compact
      .map { |n| NetAddr.parse_net("#{n.ip}/#{n.subnet}") rescue nil }
      .compact
      .select { |cidr| tinc_net.contains(cidr.network) rescue false }
      .sort_by(&:to_s)

    private_cidr = if used_private_nets.empty?
      NetAddr::IPv4Net.new(tinc_net.nth(1), NetAddr::Mask32.new(25))
    else
      used_private_nets.last.next_sib
    end

    abort "private_network #{private_cidr} is outside tinc_network #{tinc_net}" \
      unless tinc_net.contains(private_cidr.network)

    private_ip      = private_cidr.network.to_s
    private_gateway = private_cidr.nth(1).to_s

    # ── Create CloudModel::Host ───────────────────────────────────────────────
    puts "Allocating:"
    puts "  primary_address : #{primary_ip}/24  (gateway: #{primary_gateway})"
    puts "  guest addresses : #{guest_subnet}/24  (gateway: #{guest_gateway})"
    puts "  private_network : #{private_ip}/25  (gateway: #{private_gateway})"
    puts ""

    host = CloudModel::Host.new(
      name:            name,
      primary_address: { ip: primary_ip,  subnet: 24, gateway: primary_gateway },
      private_network: { ip: private_ip,  subnet: 25, gateway: private_gateway },
      system_disks:    vm_cfg.disk_count.times.map { |i| "vd#{('a'.ord + i).chr}" }
    )
    host.addresses.build(ip: guest_subnet, subnet: 24, gateway: guest_gateway)

    host.save(validate: false) or abort "Failed to persist Host document"
    puts "Host '#{name}' created (id: #{host.id})"

    # ── Provision VM ─────────────────────────────────────────────────────────
    puts "Provisioning VM (extra_ips: #{extra_ips})..."
    host.create_vm!(extra_ips: extra_ips)
  end
end
