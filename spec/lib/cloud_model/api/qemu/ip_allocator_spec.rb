require 'spec_helper'

describe CloudModel::Api::Qemu::IpAllocator do
  # Lightweight stand-ins for CloudModel::Host documents — the allocator only
  # reads name, primary_address.ip, addresses[].ip, and private_network.
  Addr = Struct.new(:ip, :subnet, :gateway)

  def host(name: 'host01', primary: nil, guests: [], private_net: nil)
    double name: name,
      primary_address: (primary && Addr.new(primary, 24, nil)),
      addresses: guests.map { |ip| Addr.new(ip, 24, nil) },
      private_network: (private_net && Addr.new(*private_net))
  end

  def allocator(hosts)
    described_class.new hosts,
      tinc_network: '10.67.0.0/16', external_network: '10.66.0.0/16'
  end

  describe '#next_name' do
    it 'starts with host01' do
      expect(allocator([]).next_name).to eq 'host01'
    end

    it 'fills the first gap in the hostNN sequence' do
      hosts = [host(name: 'host01'), host(name: 'host03')]
      expect(allocator(hosts).next_name).to eq 'host02'
    end

    it 'ignores names outside the hostNN convention' do
      hosts = [host(name: 'buildbox'), host(name: 'host1x')]
      expect(allocator(hosts).next_name).to eq 'host01'
    end
  end

  describe '#primary_address' do
    it 'allocates the first primary slot on an empty pool' do
      expect(allocator([]).primary_address).to eq ip: '10.66.0.1', subnet: 24, gateway: '10.66.0.1'
    end

    it 'skips used last octets and fills gaps' do
      hosts = [host(primary: '10.66.0.1'), host(primary: '10.66.0.3')]
      expect(allocator(hosts).primary_address[:ip]).to eq '10.66.0.2'
    end

    it 'ignores primary addresses outside the external pool' do
      hosts = [host(primary: '192.168.0.1')]
      expect(allocator(hosts).primary_address[:ip]).to eq '10.66.0.1'
    end

    it 'raises a clear error when the pool is exhausted' do
      hosts = (1..254).map { |i| host(primary: "10.66.0.#{i}") }
      expect { allocator(hosts).primary_address }.to raise_error(/No free IPs left/)
    end
  end

  describe '#guest_address' do
    it 'allocates the first guest /24' do
      expect(allocator([]).guest_address).to eq ip: '10.66.1.0', subnet: 24, gateway: '10.66.1.1'
    end

    it 'skips used third octets' do
      hosts = [host(guests: ['10.66.1.0']), host(guests: ['10.66.2.0'])]
      expect(allocator(hosts).guest_address[:ip]).to eq '10.66.3.0'
    end

    it 'only counts subnet base addresses of the external pool' do
      hosts = [host(guests: ['10.66.1.5', '10.9.1.0'])] # neither is a used pool subnet
      expect(allocator(hosts).guest_address[:ip]).to eq '10.66.1.0'
    end

    it 'raises a clear error when all guest subnets are used' do
      hosts = (1..254).map { |i| host(guests: ["10.66.#{i}.0"]) }
      expect { allocator(hosts).guest_address }.to raise_error(/No free guest subnets/)
    end
  end

  describe '#private_network' do
    it 'starts with the first /25 of the tinc network' do
      expect(allocator([]).private_network).to eq ip: '10.67.0.0', subnet: 25, gateway: '10.67.0.1'
    end

    it 'continues with the sibling of the last used /25' do
      hosts = [host(private_net: ['10.67.0.0', 25]), host(private_net: ['10.67.0.128', 25])]
      expect(allocator(hosts).private_network).to eq ip: '10.67.1.0', subnet: 25, gateway: '10.67.1.1'
    end

    it 'sorts used networks numerically, not lexically' do
      # Lexically "10.67.9.128" sorts AFTER "10.67.10.0", so a string sort
      # would take 9.128 as the last used /25 and re-allocate 10.67.10.0.
      hosts = [host(private_net: ['10.67.9.128', 25]), host(private_net: ['10.67.10.0', 25])]
      expect(allocator(hosts).private_network[:ip]).to eq '10.67.10.128'
    end

    it 'ignores private networks outside the tinc network' do
      hosts = [host(private_net: ['10.99.0.0', 25])]
      expect(allocator(hosts).private_network[:ip]).to eq '10.67.0.0'
    end

    it 'raises a clear error when the tinc network is exhausted' do
      hosts = [host(private_net: ['10.67.255.128', 25])]
      expect { allocator(hosts).private_network }.to raise_error(/No free \/25/)
    end
  end
end
