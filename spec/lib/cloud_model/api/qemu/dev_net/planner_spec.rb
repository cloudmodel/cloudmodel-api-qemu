require 'spec_helper'
require 'cloud_model/api/qemu/dev_net'

RSpec.describe CloudModel::Api::Qemu::DevNet::Planner do
  # Plain-object doubles (no DB, no system) so the planner is exercised in
  # isolation. It reads config + the injected hosts and computes. Uniquely-named
  # to avoid clobbering global constants (e.g. stdlib/mongo Net).
  DnAddr = Struct.new(:ip, :gateway)
  DnNet  = Struct.new(:ip, :subnet)
  DnHost = Struct.new(:vm_disk_paths, :deploy_state, :private_network, :primary_address)

  let(:config) do
    qemu = Struct.new(:external_network).new('10.66.0.0/16')
    api  = Struct.new(:qemu).new(qemu)
    Struct.new(:additional_hosts, :tinc_network, :api).new(
      { 'auth.example.com' => '10.67.1.124' }, '10.67.0.0/16', api
    )
  end

  let(:hosts) do
    [DnHost.new(['/vm/disk1'], :finished, DnNet.new('10.67.1.0', 25), DnAddr.new('10.66.0.23', '10.66.0.1'))]
  end

  def build(**over)
    described_class.new(config: config, hosts: hosts,
                        platform: 'darwin', upstreams: ['192.168.2.1'], **over).build
  end

  it 'emits a whitelist-clean plan' do
    plan, validator = build
    expect { validator.validate_plan!(plan) }.not_to raise_error
    expect(plan['platform']).to eq 'darwin'
    expect(plan['scope_domains']).to eq ['example.com']
  end

  it 'routes each host guest subnet via its primary address and joins the vmnet L2' do
    plan, = build
    expect(plan['ops']).to include('op' => 'route_add', 'net' => '10.67.1.0/25', 'via' => '10.66.0.23')
    join = plan['ops'].find { |o| o['op'] == 'vmnet_join' }
    expect(join).to include('ip' => '10.66.0.254', 'prefix' => 16)
    expect(join['vmnet_gw']).to match(/\A\d+\.\d+\.\d+\.\d+\z/)
  end

  it 'writes a resolver op per scope domain' do
    plan, = build
    resolver = plan['ops'].select { |o| o['op'] == 'resolver_file' }
    expect(resolver.map { |o| o['domain'] }).to eq ['example.com']
    expect(resolver.first).to include('nameserver' => '127.0.0.1', 'port' => 5354)
  end

  it 'snapshots only the static config names as overrides (DB is resolved live)' do
    plan, = build
    expect(plan['dns']['overrides']).to eq('auth.example.com' => '10.67.1.124')
    expect(plan['dns']['zones']).to eq ['example.com']
    expect(plan['dns']['live_cidrs']).to include('10.67.0.0/16', '10.66.0.0/16')
  end

  it 'drops static config names pointing outside the dev networks' do
    config.additional_hosts = { 'auth.example.com' => '10.67.1.124', 'evil.example.com' => '203.0.113.9' }
    plan, = build
    expect(plan['dns']['overrides']).to have_key('auth.example.com')
    expect(plan['dns']['overrides']).not_to have_key('evil.example.com')
  end

  context 'with a dedicated dev subzone (auth.dev.example.com)' do
    let(:config) do
      qemu = Struct.new(:external_network).new('10.66.0.0/16')
      api  = Struct.new(:qemu).new(qemu)
      Struct.new(:additional_hosts, :tinc_network, :api).new(
        { 'auth.dev.example.com' => '10.67.1.124' }, '10.67.0.0/16', api
      )
    end

    it 'scopes only the dev subzone, leaving the public parent untouched' do
      plan, = build
      expect(plan['scope_domains']).to eq ['dev.example.com']
      expect(plan['dns']['zones']).to eq ['dev.example.com']
      expect(plan['ops'].select { |o| o['op'] == 'resolver_file' }.map { |o| o['domain'] })
        .to eq ['dev.example.com']
    end
  end

  it 'raises when there are no dev zones to configure' do
    empty = config.dup
    empty.additional_hosts = {}
    expect { described_class.new(config: empty, hosts: hosts, platform: 'darwin', upstreams: ['1.1.1.1']).build }
      .to raise_error(CloudModel::Api::Qemu::DevNet::Error, /No dev DNS zones/)
  end
end
