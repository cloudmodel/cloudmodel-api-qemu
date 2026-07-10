require 'spec_helper'
require 'tmpdir'

describe CloudModel::Api::Qemu::Server do
  let(:primary_address) { double 'Address', ip: '10.66.0.3' }
  let(:host) do
    double 'Host',
      name: 'host23',
      primary_address: primary_address,
      vm_disk_paths: ['/vms/host23/disk1.qcow2', '/vms/host23/disk2.qcow2']
  end
  let(:config) { CloudModel.config.api.qemu }

  subject(:server) { described_class.new(host) }

  around do |example|
    Dir.mktmpdir('qemu-spec') do |tmpdir|
      @tmpdir = tmpdir
      config.vm_dir = tmpdir
      example.run
    end
  end

  describe '#vm_ssh_port' do
    it 'maps the primary IP last octet onto 22000+' do
      expect(server.send(:vm_ssh_port, '10.66.0.3')).to eq 22003
      expect(server.send(:vm_ssh_port, '10.66.0.254')).to eq 22254
    end
  end

  describe 'MAC handling' do
    before { FileUtils.mkdir_p File.join(@tmpdir, 'host23') }

    it 'generates QEMU-prefixed locally administered MACs and persists them' do
      macs = server.send(:generate_macs, 3)
      expect(macs.size).to eq 3
      macs.each { |mac| expect(mac).to match(/\A52:54:00(:[0-9a-f]{2}){3}\z/) }
      expect(server.send(:stored_macs)).to eq macs
    end

    it 'returns an empty list when no MACs were stored' do
      expect(server.send(:stored_macs)).to eq []
    end
  end

  describe '#running?' do
    let(:pid_path) { File.join(@tmpdir, 'host23', 'qemu.pid') }

    before { FileUtils.mkdir_p File.dirname(pid_path) }

    it 'is false without a pid file' do
      expect(server.running?).to be false
    end

    it 'is true while the recorded process is alive' do
      File.write pid_path, Process.pid.to_s
      expect(server.running?).to be true
    end

    it 'is false when the recorded process is gone' do
      dead_pid = Process.spawn('true')
      Process.wait dead_pid
      File.write pid_path, dead_pid.to_s
      expect(server.running?).to be false
    end
  end

  describe '#status' do
    it 'reports name, ip, ssh port and disks' do
      status = server.status
      expect(status).to include name: 'host23', running: false, ip: '10.66.0.3', ssh_port: 22003
      expect(status[:disks]).to eq host.vm_disk_paths
    end
  end

  describe '#resolve_base_image_url' do
    it 'uses an explicitly configured URL as-is' do
      config.base_image_url = 'https://mirror.example.com/img.qcow2'
      expect(server.send(:resolve_base_image_url)).to eq 'https://mirror.example.com/img.qcow2'
    end

    it 'defaults to the Debian bookworm genericcloud image for the current arch' do
      config.instance_variable_set(:@base_image_url, nil)
      url = server.send(:resolve_base_image_url)
      expect(url).to match %r{\Ahttps://cloud\.debian\.org/images/cloud/bookworm/latest/debian-12-genericcloud-(arm64|amd64)\.qcow2\z}
    end
  end

  describe 'cloud-init seed contents' do
    before do
      allow(CloudModel.config).to receive(:data_directory).and_return(@tmpdir)
      FileUtils.mkdir_p File.join(@tmpdir, 'keys')
      File.write File.join(@tmpdir, 'keys', 'id_rsa.pub'), "ssh-rsa AAAATEST comment\n"
    end

    it 'identifies the instance by host name' do
      expect(server.send(:cloud_init_meta_data)).to eq "instance-id: host23\nlocal-hostname: host23\n"
    end

    it 'enables root password login (Hetzner-rescue semantics) and installs the key' do
      user_data = server.send(:cloud_init_user_data)
      expect(user_data).to include 'disable_root: false'
      expect(user_data).to include 'ssh_pwauth: true'
      expect(user_data).to include %(list: "root:#{config.root_password}")
      expect(user_data).to include 'ssh-rsa AAAATEST comment'
      expect(user_data).to include 'PermitRootLogin yes'
      # Tools CloudModel's host deploy needs on the rescue system:
      %w(gdisk mdadm debootstrap).each { |pkg| expect(user_data).to include "- #{pkg}" }
    end

    it 'matches NICs by MAC address and uses DHCP (user-mode NAT)' do
      yaml = YAML.safe_load server.send(:cloud_init_network_config, ['52:54:00:aa:bb:cc', '52:54:00:dd:ee:ff'])
      expect(yaml['version']).to eq 1
      expect(yaml['config'].size).to eq 2
      expect(yaml['config'].first).to include(
        'type' => 'physical', 'name' => 'eth0', 'mac_address' => '52:54:00:aa:bb:cc'
      )
      expect(yaml['config'].first['subnets']).to eq [{ 'type' => 'dhcp' }]
    end
  end

  describe 'ssh config management' do
    around do |example|
      original_home = ENV['HOME']
      ENV['HOME'] = @tmpdir
      example.run
    ensure
      ENV['HOME'] = original_home
    end

    it 'writes a host stanza and hooks the include into ~/.ssh/config' do
      server.send(:write_ssh_config, '10.66.0.3', 22003)

      main = File.read File.join(@tmpdir, '.ssh', 'config')
      expect(main).to include 'Include'
      expect(main).to include '.ssh/cloudmodel_vms'

      vms = File.read File.join(@tmpdir, '.ssh', 'cloudmodel_vms')
      expect(vms).to include "Host 10.66.0.3"
      expect(vms).to include 'HostName 127.0.0.1'
      expect(vms).to include 'Port 22003'
    end

    it 'replaces an existing stanza instead of appending a duplicate' do
      server.send(:write_ssh_config, '10.66.0.3', 22003)
      server.send(:write_ssh_config, '10.66.0.3', 22004)

      vms = File.read File.join(@tmpdir, '.ssh', 'cloudmodel_vms')
      expect(vms.scan('Host 10.66.0.3').size).to eq 1
      expect(vms).to include 'Port 22004'
      expect(vms).not_to include 'Port 22003'
    end

    it 'does not duplicate the include line in ~/.ssh/config' do
      server.send(:write_ssh_config, '10.66.0.3', 22003)
      server.send(:write_ssh_config, '10.66.0.4', 22004)

      main = File.read File.join(@tmpdir, '.ssh', 'config')
      expect(main.scan('cloudmodel_vms').size).to eq 1
    end

    it 'removes only the given host stanza' do
      server.send(:write_ssh_config, '10.66.0.3', 22003)
      server.send(:write_ssh_config, '10.66.0.4', 22004)
      server.send(:remove_ssh_config, '10.66.0.3')

      vms = File.read File.join(@tmpdir, '.ssh', 'cloudmodel_vms')
      expect(vms).not_to include 'Host 10.66.0.3'
      expect(vms).to include 'Host 10.66.0.4'
    end
  end

  describe '#persist_host' do
    it 'records NVMe system disk names matching disk_count' do
      config.disk_count = 2
      expect(host).to receive(:system_disks=).with(%w[nvme0n1 nvme1n1])
      expect(host).to receive(:initial_root_pw=).with(config.root_password)
      allow(host).to receive(:vm_extra_nics=)
      expect(host).to receive(:arch=).with(satisfy { |a| %w[arm64 amd64].include?(a) })
      expect(host).to receive(:save!)
      server.send(:persist_host)
    end
  end
end
