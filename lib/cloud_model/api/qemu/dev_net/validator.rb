# frozen_string_literal: true

require 'ipaddr'

module CloudModel
  module Api
    module Qemu
      module DevNet
        # Strict whitelist validator shared by the (unprivileged) planner and the
        # (root) executor.
        #
        # Everything the executor runs as root is checked against this on BOTH
        # sides: the planner refuses to emit a plan that does not validate, and
        # the executor refuses to APPLY a plan that does not re-validate as root
        # (defense in depth — the root side never trusts the on-disk plan blindly).
        # Combined with the executor only ever running fixed argv arrays (never a
        # shell string), a tampered plan can at most select a different *allowed*
        # operation on an *allowed* address — never inject a command.
        #
        # This file is pure stdlib on purpose: the standalone root executor
        # requires it directly, without Rails or the cloudmodel engine loaded.
        class Validator
          class Error < StandardError; end

          # One DNS label: 1-63 chars, a-z0-9-, no leading/trailing hyphen.
          LABEL     = '(?!-)[a-z0-9-]{1,63}(?<!-)'
          DOMAIN_RE = /\A(?=.{1,253}\z)#{LABEL}(\.#{LABEL})*\z/i
          IFACE_RE  = /\A[a-z][a-z0-9]{0,14}\z/i
          LOOPBACK  = IPAddr.new('127.0.0.0/8')
          RFC1918   = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16].map { |c| IPAddr.new(c) }.freeze

          # Verbs the executor knows how to apply. Anything else is rejected before
          # a single command runs.
          KNOWN_OPS = %w[vmnet_join route_add ip_route_add resolver_file resolvectl].freeze

          attr_reader :allowed_cidrs, :scope_domains

          # @param allowed_cidrs [Array<String,IPAddr>] every routed net/via IP must
          #   fall inside one of these (the dev tinc + external networks). Prevents a
          #   plan from ever touching a route outside the dev cloud's own ranges.
          # @param scope_domains [Array<String>] the split-horizon base domains
          #   (e.g. ["example.com"]); every override name must be one or a subdomain.
          def initialize(allowed_cidrs:, scope_domains:)
            @allowed_cidrs = Array(allowed_cidrs).map { |c| c.is_a?(IPAddr) ? c : IPAddr.new(c.to_s) }
            @scope_domains = Array(scope_domains).map { |d| d.to_s.downcase }
          end

          def ipv4?(str)
            s = str.to_s
            return false if s.include?('/') # a bare address, not a network
            IPAddr.new(s).ipv4?
          rescue IPAddr::Error, ArgumentError
            false
          end

          def ip_in?(str, cidrs)
            return false unless ipv4?(str)
            ip = IPAddr.new(str.to_s)
            cidrs.any? { |c| c.include?(ip) }
          end

          def ip_allowed?(str)  = ip_in?(str, @allowed_cidrs)
          def loopback?(str)    = ip_in?(str, [LOOPBACK])
          def rfc1918?(str)     = ip_in?(str, RFC1918)

          # "10.0.5.0/25" — parses, IPv4, prefix 8..32, network contained in an
          # allowed cidr.
          def cidr_allowed?(str)
            s = str.to_s
            return false unless s =~ %r{\A\d{1,3}(\.\d{1,3}){3}/\d{1,2}\z}
            prefix = s.split('/').last.to_i
            return false unless prefix.between?(8, 32)
            net = IPAddr.new(s)
            return false unless net.ipv4?
            @allowed_cidrs.any? { |c| c.include?(net) }
          rescue IPAddr::Error, ArgumentError
            false
          end

          # A name we may override: syntactically valid AND under a scope domain.
          def domain?(str)
            s = str.to_s.downcase
            return false unless s =~ DOMAIN_RE
            @scope_domains.any? { |d| s == d || s.end_with?(".#{d}") }
          end

          # Exactly one of the scope base domains (used for the /etc/resolver/<d> file).
          def scope_domain?(str) = @scope_domains.include?(str.to_s.downcase)

          def port?(n)  = n.is_a?(Integer) && n.between?(1, 65_535)
          def iface?(s) = !(s.to_s =~ IFACE_RE).nil?

          # Full structural + value validation of a plan hash (string- or
          # symbol-keyed). Raises Validator::Error on the first violation.
          def validate_plan!(plan)
            p = sym(plan)
            ops = p[:ops]
            raise Error, 'plan.ops must be an array' unless ops.is_a?(Array)
            ops.each_with_index { |op, i| validate_op!(sym(op), i) }
            validate_dns!(sym(p[:dns])) if p[:dns]
            true
          end

          def validate_op!(op, idx)
            case op[:op]
            when 'vmnet_join'
              bad(idx, 'vmnet_gw') unless rfc1918?(op[:vmnet_gw])
              bad(idx, 'ip')       unless ip_allowed?(op[:ip])
              bad(idx, 'prefix')   unless op[:prefix].is_a?(Integer) && op[:prefix].between?(8, 32)
            when 'route_add', 'ip_route_add'
              bad(idx, 'net') unless cidr_allowed?(op[:net])
              bad(idx, 'via') unless ip_allowed?(op[:via])
            when 'resolver_file', 'resolvectl'
              bad(idx, 'domain')     unless scope_domain?(op[:domain])
              bad(idx, 'nameserver') unless loopback?(op[:nameserver])
              bad(idx, 'port')       unless port?(op[:port])
              bad(idx, 'link') if op[:op] == 'resolvectl' && !iface?(op[:link])
            else
              raise Error, "op ##{idx}: unknown op #{op[:op].inspect} (allowed: #{KNOWN_OPS.join(', ')})"
            end
          end

          def validate_dns!(dns)
            up = dns[:upstreams]
            raise Error, 'dns.upstreams must be a non-empty array' unless up.is_a?(Array) && !up.empty?
            up.each do |u|
              raise Error, "dns upstream #{u.inspect} is not IPv4"   unless ipv4?(u)
              raise Error, "dns upstream #{u.inspect} is loopback"   if loopback?(u) # would loop back into us
            end
            raise Error, 'dns.listen must be a loopback address' unless loopback?(dns[:listen])
            raise Error, 'dns.port invalid' unless port?(dns[:port])
            ov = dns[:overrides] || {}
            raise Error, 'dns.overrides must be a hash' unless ov.is_a?(Hash)
            ov.each do |name, ip|
              raise Error, "override name #{name.inspect} invalid" unless domain?(name)
              raise Error, "override ip #{ip.inspect} invalid"     unless ip_allowed?(ip)
            end
            true
          end

          private

          def bad(idx, field) = raise(Error, "op ##{idx}: invalid #{field}")

          def sym(h)
            return {} if h.nil?
            return h unless h.is_a?(Hash)
            h.each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
          end
        end
      end
    end
  end
end
