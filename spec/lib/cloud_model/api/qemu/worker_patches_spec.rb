require 'spec_helper'

describe CloudModel::Api::Qemu::WorkerPatches do
  describe '.install!' do
    it 'prepends the patches exactly once' do
      described_class.install!
      described_class.install!
      expect(CloudModel::Workers::HostWorker.ancestors.count { |m| m == described_class::HostWorkerPatch }).to eq 1
      expect(CloudModel::Host.ancestors.count { |m| m == described_class::HostPatch }).to eq 1
    end
  end

  describe 'HostWorkerPatch#init_raid_device' do
    let(:host) do
      double 'Host', vm_disk_paths: ['/vms/x/disk1.qcow2'],
        system_disks: %w[nvme0n1 nvme1n1]
    end
    subject(:worker) do
      described_class.install!
      CloudModel::Workers::HostWorker.new(host).tap { |w| allow(w).to receive(:comment_sub_step) }
    end

    it 'skips the RAID initial resync on fresh sparse images' do
      allow(host).to receive(:exec).with(/--zero-superblock/)
      expect(host).to receive(:exec).with(%r{mdadm --create -e1 -f --assume-clean /dev/md0 --level=1 --raid-devices=2 /dev/nvme0n1p2 /dev/nvme1n1p2})

      worker.init_raid_device '', {name: 'boot', device: 'md0', partition: 2}
    end

    it 'leaves already active arrays alone' do
      expect(host).not_to receive(:exec)
      worker.init_raid_device 'md0 : active raid1 nvme0n1p2 nvme1n1p2', {name: 'boot', device: 'md0', partition: 2}
    end
  end

  describe 'HostWorkerPatch#disk_partition_device' do
    let(:host)   { double 'Host' }
    subject(:worker) do
      described_class.install!
      CloudModel::Workers::HostWorker.new host
    end

    it 'appends the partition number directly for virtio disks' do
      expect(worker.disk_partition_device('vdb', 7)).to eq 'vdb7'
    end

    it 'keeps cloudmodel behaviour for NVMe (p separator) and SATA disks' do
      expect(worker.disk_partition_device('nvme0n1', 7)).to eq 'nvme0n1p7'
      expect(worker.disk_partition_device('sda', 2)).to eq 'sda2'
    end

    it 'rejects invalid partition numbers' do
      expect { worker.disk_partition_device('vdb', 0) }.to raise_error(/positive integer/)
    end
  end

  describe 'HostPatch' do
    let(:host_class) do
      described_class.install!
      CloudModel::Host
    end

    context 'on a QEMU VM host' do
      subject(:host) do
        host_class.new primary_address: { ip: '10.66.0.3', subnet: 24 },
          vm_disk_paths: ['/vms/x/disk1.qcow2']
      end

      it { expect(host.vm_host?).to be true }

      it 'uses the primary IP as ssh_address (resolved via ~/.ssh/config)' do
        expect(host.ssh_address).to eq '10.66.0.3'
      end

      it 'restores the hostfwd DNAT rule after a firewall restart' do
        allow_any_instance_of(CloudModel::Workers::FirewallWorker).to receive(:write_scripts)
        expect(host).to receive(:exec!).with(%r{firewall_stop && .*firewall_start}, anything)
        expect(host).to receive(:exec).with(/iptables -t nat .*DNAT --to-destination 10\.66\.0\.3/)
        host.restart_firewall
      end
    end

    context 'on a hardware host' do
      subject(:host) { host_class.new(primary_address: { ip: '198.51.100.10', subnet: 24 }) }

      it 'is not a vm host (field absent or empty)' do
        expect(host.vm_host?).to be false
      end

      it 'does not touch iptables after a firewall restart' do
        allow_any_instance_of(CloudModel::Workers::FirewallWorker).to receive(:write_scripts)
        expect(host).to receive(:exec!).with(%r{firewall_stop && .*firewall_start}, anything)
        expect(host).not_to receive(:exec)
        host.restart_firewall
      end
    end
  end
end
