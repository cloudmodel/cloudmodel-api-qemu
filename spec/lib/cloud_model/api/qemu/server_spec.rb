require 'spec_helper'
require 'tmpdir'

describe CloudModel::Api::Qemu::Server do
  let(:primary_address) { double 'Address', ip: '10.66.0.3' }
  let(:host_arch) { CloudModel::Api::Qemu::Config.workstation_arch }
  let(:host) do
    double 'Host',
      name: 'host23',
      arch: host_arch,
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

    it "defaults to the Debian bookworm genericcloud image for the HOST's arch" do
      config.instance_variable_set(:@base_image_url, nil)
      url = server.send(:resolve_base_image_url)
      expect(url).to eq "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-#{host_arch}.qcow2"
    end
  end

  describe 'architecture handling' do
    context 'host arch matches the workstation' do
      it 'is not cross-arch and uses hardware acceleration' do
        expect(server.send(:cross_arch?)).to be false
        args = server.send(:qemu_machine_args)
        expect(args.join(' ')).to include '-cpu host'
        expect(args).to include '-accel'
      end
    end

    context 'host arch differs from the workstation' do
      let(:host_arch) { CloudModel::Api::Qemu::Config.workstation_arch == 'arm64' ? 'amd64' : 'arm64' }

      it 'runs fully TCG-emulated with -cpu max' do
        expect(server.send(:cross_arch?)).to be true
        args = server.send(:qemu_machine_args)
        expect(args.join(' ')).to include '-cpu max'
        expect(args).not_to include '-accel'
      end

      it 'selects the qemu binary for the VM arch' do
        expected = host_arch == 'arm64' ? 'qemu-system-aarch64' : 'qemu-system-x86_64'
        expect(server.send(:qemu_binary)).to eq expected
      end

      it 'selects the base image for the VM arch' do
        config.vm_dir = '/vms'
        expect(server.send(:base_image_path)).to eq "/vms/debian-base-#{host_arch}.qcow2"
      end

      it 'scales the boot timeout for TCG emulation' do
        config.boot_timeout = 100
        expect(server.send(:effective_boot_timeout)).to eq 600
      end
    end

    it 'uses the machine type of the VM arch' do
      args = { 'arm64' => 'virt', 'amd64' => 'q35' }
      expect(args).to have_key host_arch
      expect(server.send(:qemu_machine_args)).to include args[host_arch]
    end

    describe 'UEFI firmware attachment' do
      it 'passes arm64 firmware via -bios' do
        allow(config).to receive(:qemu_firmware).with('arm64').and_return('/fw/edk2-aarch64.fd')
        allow(host).to receive(:arch).and_return('arm64')
        args = server.send(:qemu_machine_args)
        expect(args.each_cons(2)).to include ['-bios', '/fw/edk2-aarch64.fd']
      end

      it 'passes amd64 firmware as read-only pflash (code-only image)' do
        allow(config).to receive(:qemu_firmware).with('amd64').and_return('/fw/edk2-x86_64.fd')
        allow(host).to receive(:arch).and_return('amd64')
        args = server.send(:qemu_machine_args)
        expect(args.join(' ')).to include 'if=pflash,format=raw,readonly=on,file=/fw/edk2-x86_64.fd'
        expect(args).not_to include '-bios'
      end
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
      expect(user_data).to start_with "#cloud-config\n"
      expect(user_data).to include 'disable_root: false'
      expect(user_data).to include 'ssh_pwauth: true'
      expect(user_data).to match(/list: ['"]?root:#{config.root_password}/)
      expect(user_data).to include 'ssh-rsa AAAATEST comment'
      expect(user_data).to include 'PermitRootLogin yes'
      # Tools CloudModel's host deploy needs on the rescue system:
      %w(gdisk mdadm debootstrap).each { |pkg| expect(user_data).to include "- #{pkg}" }
    end

    context 'with the apt cache proxy running' do
      before { allow(CloudModel::Api::Qemu::AptCache).to receive(:running?).and_return(true) }

      it 'routes apt (conf file) and debootstrap (http_proxy env) through it' do
        user_data = server.send(:cloud_init_user_data)
        expect(user_data).to include '/etc/apt/apt.conf.d/01cloudmodel-cache'
        expect(user_data).to include 'Acquire::http::Proxy "http://10.0.2.2:3142"'
        expect(user_data).to include "echo 'http_proxy=http://10.0.2.2:3142' >> /etc/environment"
      end

      it 'stays out when disabled by config' do
        config.apt_cache = false
        expect(server.send(:cloud_init_user_data)).not_to include '10.0.2.2:3142'
      end
    end

    it 'does not configure a proxy while the cache is not running' do
      allow(CloudModel::Api::Qemu::AptCache).to receive(:running?).and_return(false)
      expect(server.send(:cloud_init_user_data)).not_to include '10.0.2.2'
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
