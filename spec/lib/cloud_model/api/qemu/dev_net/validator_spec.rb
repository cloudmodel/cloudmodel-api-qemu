require 'spec_helper'
require 'cloud_model/api/qemu/dev_net/validator'

RSpec.describe CloudModel::Api::Qemu::DevNet::Validator do
  subject(:validator) do
    described_class.new(allowed_cidrs: %w[10.67.0.0/16 10.66.0.0/16], scope_domains: %w[example.com])
  end

  describe 'address predicates' do
    it 'accepts dev IPs inside the allowed networks' do
      expect(validator.ip_allowed?('10.67.1.124')).to be true
      expect(validator.ip_allowed?('10.66.0.254')).to be true
    end

    it 'rejects addresses outside the allowed networks' do
      expect(validator.ip_allowed?('8.8.8.8')).to be false
      expect(validator.ip_allowed?('192.168.1.5')).to be false
    end

    it 'rejects non-IPv4 and garbage' do
      expect(validator.ip_allowed?('::1')).to be false
      expect(validator.ip_allowed?('not-an-ip')).to be false
      expect(validator.ipv4?('10.0.0.0/8')).to be false
    end

    it 'classifies loopback and rfc1918' do
      expect(validator.loopback?('127.0.0.1')).to be true
      expect(validator.loopback?('10.0.0.1')).to be false
      expect(validator.rfc1918?('192.168.105.1')).to be true
      expect(validator.rfc1918?('8.8.8.8')).to be false
    end
  end

  describe '#cidr_allowed?' do
    it 'accepts a dev subnet with a sane prefix' do
      expect(validator.cidr_allowed?('10.67.1.0/25')).to be true
    end

    it 'rejects subnets outside the allowed ranges or malformed' do
      expect(validator.cidr_allowed?('192.168.0.0/24')).to be false
      expect(validator.cidr_allowed?('10.67.1.0')).to be false
      expect(validator.cidr_allowed?('10.67.1.0/40')).to be false
    end
  end

  describe '#domain? / #scope_domain?' do
    it 'accepts names under a scope domain' do
      expect(validator.domain?('auth.example.com')).to be true
      expect(validator.domain?('example.com')).to be true
      expect(validator.domain?('a.b.example.com')).to be true
    end

    it 'rejects names outside scope and syntactically invalid names' do
      expect(validator.domain?('auth.evil.com')).to be false
      expect(validator.domain?('-bad.example.com')).to be false
      expect(validator.domain?('foo..example.com')).to be false
    end

    it 'scope_domain? matches only the base domain exactly' do
      expect(validator.scope_domain?('example.com')).to be true
      expect(validator.scope_domain?('auth.example.com')).to be false
    end
  end

  describe '#validate_plan!' do
    let(:good_plan) do
      {
        'ops' => [
          { 'op' => 'vmnet_join', 'vmnet_gw' => '192.168.105.1', 'ip' => '10.66.0.254', 'prefix' => 16 },
          { 'op' => 'route_add', 'net' => '10.67.1.0/25', 'via' => '10.66.0.23' },
          { 'op' => 'resolver_file', 'domain' => 'example.com', 'nameserver' => '127.0.0.1', 'port' => 5354 }
        ],
        'dns' => {
          'listen' => '127.0.0.1', 'port' => 5354, 'upstreams' => ['192.168.2.1'],
          'overrides' => { 'auth.example.com' => '10.67.1.124' }
        }
      }
    end

    it 'passes a clean plan' do
      expect(validator.validate_plan!(good_plan)).to be true
    end

    it 'rejects a route via an address outside the dev networks' do
      good_plan['ops'][1]['via'] = '8.8.8.8'
      expect { validator.validate_plan!(good_plan) }.to raise_error(described_class::Error, /invalid via/)
    end

    it 'rejects an unknown op verb' do
      good_plan['ops'] << { 'op' => 'rm_rf', 'path' => '/' }
      expect { validator.validate_plan!(good_plan) }.to raise_error(described_class::Error, /unknown op/)
    end

    it 'rejects a resolver pointed at a non-loopback nameserver' do
      good_plan['ops'][2]['nameserver'] = '10.67.1.124'
      expect { validator.validate_plan!(good_plan) }.to raise_error(described_class::Error, /nameserver/)
    end

    it 'rejects a loopback upstream (would loop back into the forwarder)' do
      good_plan['dns']['upstreams'] = ['127.0.0.53']
      expect { validator.validate_plan!(good_plan) }.to raise_error(described_class::Error, /loopback/)
    end

    it 'rejects an override name outside the scope domain' do
      good_plan['dns']['overrides'] = { 'evil.attacker.com' => '10.67.1.124' }
      expect { validator.validate_plan!(good_plan) }.to raise_error(described_class::Error, /override name/)
    end

    it 'rejects an override pointing outside the dev networks' do
      good_plan['dns']['overrides'] = { 'auth.example.com' => '203.0.113.5' }
      expect { validator.validate_plan!(good_plan) }.to raise_error(described_class::Error, /override ip/)
    end
  end
end
