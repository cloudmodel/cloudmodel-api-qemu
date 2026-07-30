# frozen_string_literal: true

require 'ipaddr'
require 'cloud_model/api/qemu/dev_net/validator'

module CloudModel
  module Api
    module Qemu
      module DevNet
        # Turns the cloudmodel dev-cloud state into a fully-validated, purely
        # declarative plan of privileged operations. Runs UNPRIVILEGED — it only
        # reads config + the database and computes; nothing here touches the
        # system. The plan it emits is what the root executor applies.
        #
        # Two independent problems are solved, both derived from a single source
        # of truth (no hardcoding):
        #
        #   * Routing — reach the QEMU dev guests from the workstation. For every
        #     deployed host, route its guest (tinc) subnet via the host's primary
        #     address; on macOS also join the socket_vmnet L2 so the guest publics
        #     are on-link.
        #
        #   * Split-horizon DNS for the dev cloud's domains. Two name sources are
        #     merged (a static override wins a conflict):
        #       1. CloudModel.config.additional_hosts — hand-pinned public names
        #          the deployed apps hardcode (e.g. app.example.com -> dev IP).
        #       2. CloudModel::AddressResolution — the database's own name<->IP
        #          registry, so every deployed guest resolves automatically.
        #     The set of base domains to scope is derived from the names, so a new
        #     guest under a new domain gets its own /etc/resolver file for free.
        class Planner
          DNS_LISTEN     = '127.0.0.1'
          DNS_PORT       = 5354
          # Dummy interface systemd-resolved binds the split-DNS routing domain to
          # on Linux (<=15 chars, matches Validator::IFACE_RE).
          LINUX_DNS_LINK = 'cmdevdns'

          def self.build(**kw) = new(**kw).build

          def initialize(config: CloudModel.config, hosts: nil, platform: nil, upstreams: nil)
            @config    = config
            @hosts     = hosts
            @platform  = platform || (RUBY_PLATFORM =~ /darwin/ ? 'darwin' : 'linux')
            @upstreams = upstreams
          end

          # @return [Array(Hash, Validator)] the validated plan and the validator
          #   (so callers can reuse the same whitelist for status checks).
          def build
            overrides, scope_domains, sources = dns_overrides
            raise Error, 'No dev DNS zones found — set config.additional_hosts to the ' \
                         'dev names (their parent domains become the scoped dev zones).' if scope_domains.empty?

            allowed = allowed_cidrs

            validator = Validator.new(allowed_cidrs: allowed, scope_domains: scope_domains)

            ops = routing_ops + resolver_ops(scope_domains)

            plan = {
              'version'       => 1,
              'platform'      => @platform,
              'allowed_cidrs' => allowed,
              'scope_domains' => scope_domains,
              'ops'           => ops,
              'dns'           => {
                'listen'    => DNS_LISTEN,
                'port'      => DNS_PORT,
                'upstreams' => upstream_dns,
                # Static, authoritative overrides (the hand-pinned public names).
                'overrides' => overrides,
                # The forwarder resolves everything else under these zones LIVE
                # against the database (see #mongo_config), so newly-deployed
                # guests resolve without re-running `up`. Zones + allowed CIDRs
                # bound what a live DB answer may claim.
                'zones'       => scope_domains,
                'live_cidrs'  => allowed,
                'mongo'       => mongo_config
              },
              # Advisory only — lets `status`/`plan` show where names come from.
              'meta' => { 'sources' => sources }
            }

            # The planner refuses to emit anything that isn't whitelist-clean.
            validator.validate_plan!(plan)
            [plan, validator]
          end

          private

          def allowed_cidrs
            [@config.tinc_network, @config.api.qemu.external_network].compact.map(&:to_s)
          end

          # ── DNS name sources ─────────────────────────────────────────────────
          # @return [Array(Hash{String=>String}, Array<String>, Hash)] the static
          #   overrides, the dev zones to scope, and a per-source note for display.
          #
          # Only the hand-pinned `additional_hosts` names are snapshotted here
          # (they rarely change). Everything else under the dev zones is resolved
          # LIVE from the database by the forwarder, so a freshly-deployed guest
          # resolves immediately without re-running `up`.
          def dns_overrides
            allowed = allowed_cidrs.map { |c| IPAddr.new(c) }
            static  = config_names.select { |_n, ip| valid_dev_ip?(ip, allowed) }

            # The dev zones are the direct parent domains of the hand-pinned names
            # (auth.dev.example.com -> dev.example.com). We scope ONLY these, so the
            # public parent domain (example.com) is never touched.
            dev_zones = static.keys.map { |n| parent_zone(n) }.uniq
            sources   = { 'config' => static.keys.sort, 'database' => 'resolved live (mongodb)' }
            [static, dev_zones.sort, sources]
          end

          # Direct parent domain of a name, without ever descending below a
          # two-label apex (so a bare "example.com" stays "example.com", never "com").
          def parent_zone(name)
            labels = name.split('.')
            labels.length <= 2 ? name : labels.drop(1).join('.')
          end

          def config_names
            (@config.additional_hosts || {}).each_with_object({}) do |(name, ip), h|
              h[name.to_s.downcase] = ip.to_s
            end
          end

          # Mongo connection the forwarder uses for LIVE name resolution against
          # the AddressResolution registry. Derived from the app's own Mongoid
          # client (no hardcoding). Nil if Mongoid isn't available — the forwarder
          # then serves the static overrides only and forwards the rest.
          def mongo_config
            return nil unless defined?(Mongoid) && Mongoid.respond_to?(:default_client)
            return nil unless defined?(CloudModel::AddressResolution)
            client = Mongoid.default_client
            {
              'hosts'      => client.cluster.addresses.map(&:to_s),
              'database'   => client.database.name,
              # Derived from the model, so the Mongoid namespace prefix
              # (cloud_model_address_resolutions) is honoured — never hardcoded.
              'collection' => CloudModel::AddressResolution.collection.name
            }
          rescue StandardError
            nil
          end

          # A DB/config IP is usable only if it is IPv4 and inside the dev cloud's
          # own networks — a name pointing anywhere else can't be reached through
          # the routes we add, so we don't advertise it.
          def valid_dev_ip?(ip, allowed)
            addr = IPAddr.new(ip.to_s)
            addr.ipv4? && allowed.any? { |c| c.include?(addr) }
          rescue IPAddr::Error, ArgumentError
            false
          end

          # ── Routing ──────────────────────────────────────────────────────────
          def deployed_hosts
            @hosts ||= CloudModel::Host.all.to_a.select do |h|
              h.respond_to?(:vm_disk_paths) && h.vm_disk_paths.present? && h.deploy_state == :finished
            end
          end

          def routing_ops
            hosts = deployed_hosts
            return [] if hosts.empty?

            ops = []
            if @platform == 'darwin' && (join = vmnet_join_op(hosts))
              ops << join
            end
            verb = @platform == 'darwin' ? 'route_add' : 'ip_route_add'
            hosts.each do |h|
              pn = h.private_network
              next unless pn&.ip && pn.subnet
              ops << { 'op' => verb, 'net' => "#{pn.ip}/#{pn.subnet}", 'via' => h.primary_address.ip.to_s }
            end
            ops
          end

          # The workstation joins the socket_vmnet L2 on the .254 host of the
          # primary network, as a /16 so the guest publics are on-link.
          def vmnet_join_op(hosts)
            gw = hosts.first.primary_address&.gateway&.to_s
            return nil unless gw
            alias_ip = gw.sub(/\.\d+\z/, '.254')
            { 'op' => 'vmnet_join', 'vmnet_gw' => vmnet_gateway, 'ip' => alias_ip, 'prefix' => 16 }
          end

          # socket_vmnet's bridge carries its --vmnet-gateway address; find it from
          # the running daemon's args (the executor then locates the interface that
          # actually holds this IP). Falls back to the documented default.
          def vmnet_gateway
            out = `ps ax -o args= 2>/dev/null`
            out[/--vmnet-gateway=([0-9.]+)/, 1] || '192.168.105.1'
          rescue StandardError
            '192.168.105.1'
          end

          # ── DNS resolver glue ────────────────────────────────────────────────
          def resolver_ops(scope_domains)
            scope_domains.map do |d|
              base = { 'domain' => d, 'nameserver' => DNS_LISTEN, 'port' => DNS_PORT }
              if @platform == 'darwin'
                base.merge('op' => 'resolver_file')
              else
                base.merge('op' => 'resolvectl', 'link' => LINUX_DNS_LINK)
              end
            end
          end

          # Real upstream resolvers, captured BEFORE we install our own — so the
          # forwarder relays non-dev names to them without looping back into
          # itself. Never hardcodes a public resolver.
          def upstream_dns
            return @upstreams if @upstreams
            ips = (@platform == 'darwin' ? scutil_upstreams : linux_upstreams)
            ips = ips.select { |ip| ip =~ /\A\d{1,3}(\.\d{1,3}){3}\z/ && !ip.start_with?('127.') }.uniq
            raise Error, 'Could not determine an upstream DNS server to forward to.' if ips.empty?
            ips
          end

          def scutil_upstreams
            `scutil --dns 2>/dev/null`.scan(/nameserver\[\d+\]\s*:\s*([0-9.]+)/).flatten
          rescue StandardError
            []
          end

          def linux_upstreams
            # /run/systemd/resolve/resolv.conf holds the REAL upstreams; the plain
            # /etc/resolv.conf under systemd-resolved is the 127.0.0.53 stub (which
            # would loop). Prefer the former.
            path = ['/run/systemd/resolve/resolv.conf', '/etc/resolv.conf'].find { |f| File.exist?(f) }
            return [] unless path
            File.readlines(path).grep(/^\s*nameserver\s+/).map { |l| l.split[1] }
          rescue StandardError
            []
          end
        end
      end
    end
  end
end
