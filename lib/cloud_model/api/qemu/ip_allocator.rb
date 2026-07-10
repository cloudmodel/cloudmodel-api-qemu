require 'netaddr'
require 'set'

module CloudModel
  module Api
    module Qemu
      # Allocates the address set for a new VM host from the two configured
      # network blocks (extracted from dev:create_vm_host for testability):
      #
      #   tinc_network              — one /25 per host for private_network
      #   config.api.qemu.external_network (≥ /16) — partitioned as:
      #     x.x.0.1-254             — primary_address IPs (one per host)
      #     x.x.1.0/24, x.x.2.0/24… — one guest `addresses` subnet per host
      #
      # Purely functional over the given host documents — nothing is persisted.
      class IpAllocator
        def initialize(hosts, tinc_network:, external_network:)
          @hosts    = hosts.to_a
          @tinc_net = NetAddr.parse_net(tinc_network)
          @ext_net  = NetAddr.parse_net(external_network)
        end

        # Next free auto-name following the host01, host02, … convention.
        def next_name
          used = @hosts.map(&:name).grep(/\Ahost\d+\z/)
            .map { |n| n.sub('host', '').to_i }.to_set
          n = (1..).find { |i| !used.include?(i) }
          "host#{n.to_s.rjust(2, '0')}"
        end

        # @return [Hash] ip/subnet/gateway for the host's primary_address
        def primary_address
          used = @hosts.map { |h| h.primary_address&.ip }.compact
            .select { |ip| ip.start_with?("#{ext_prefix}.0.") }
            .map    { |ip| ip.split('.').last.to_i }.to_set

          octet = (1..254).find { |i| !used.include?(i) } \
            or raise "No free IPs left in #{ext_prefix}.0.0/24"

          { ip: "#{ext_prefix}.0.#{octet}", subnet: 24, gateway: "#{ext_prefix}.0.1" }
        end

        # @return [Hash] ip/subnet/gateway of the next free guest /24
        def guest_address
          used = @hosts.flat_map { |h| Array(h.addresses).map(&:ip) }.compact
            .select { |ip|
              parts = ip.split('.')
              parts[0..1].join('.') == ext_prefix && parts[2].to_i >= 1 && parts[3] == '0'
            }
            .map { |ip| ip.split('.')[2].to_i }.to_set

          octet = (1..254).find { |i| !used.include?(i) } \
            or raise "No free guest subnets left in #{ext_prefix}.1-254.0/24"

          { ip: "#{ext_prefix}.#{octet}.0", subnet: 24, gateway: "#{ext_prefix}.#{octet}.1" }
        end

        # @return [Hash] ip/subnet/gateway of the next free /25 inside tinc_network
        def private_network
          used = @hosts.map(&:private_network).compact
            .map    { |n| NetAddr.parse_net("#{n.ip}/#{n.subnet}") rescue nil }.compact
            .select { |cidr| @tinc_net.contains(cidr.network) rescue false }
            .sort_by { |cidr| cidr.network.addr } # numeric — string order breaks at the 10th /25

          cidr = if used.empty?
            NetAddr::IPv4Net.new(@tinc_net.nth(1), NetAddr::Mask32.new(25))
          else
            used.last.next_sib
          end

          unless cidr and (@tinc_net.contains(cidr.network) rescue false)
            raise "No free /25 left in tinc_network #{@tinc_net}"
          end

          { ip: cidr.network.to_s, subnet: 25, gateway: cidr.nth(1).to_s }
        end

        private

        def ext_prefix
          @ext_prefix ||= @ext_net.network.to_s.split('.')[0..1].join('.')
        end
      end
    end
  end
end
