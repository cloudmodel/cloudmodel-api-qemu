require 'spec_helper'

describe CloudModel::Api::Qemu::Config do
  subject(:config) { CloudModel.config.api.qemu }

  it 'is reachable as CloudModel.config.api.qemu' do
    expect(config).to be_a CloudModel::Api::Qemu::Config
  end

  describe '#vm_dir' do
    it 'defaults to <data_directory>/vms' do
      allow(CloudModel.config).to receive(:data_directory).and_return('/data/dir')
      expect(config.vm_dir).to eq '/data/dir/vms'
    end

    it 'can be overridden' do
      config.vm_dir = '/elsewhere'
      expect(config.vm_dir).to eq '/elsewhere'
    end
  end

  describe '#base_image_path' do
    it 'defaults to debian-base.qcow2 inside vm_dir' do
      config.vm_dir = '/vms'
      expect(config.base_image_path).to eq '/vms/debian-base.qcow2'
    end
  end

  describe 'defaults' do
    it { expect(config.disk_size).to eq '80G' }
    it { expect(config.ram).to eq 4096 }
    it { expect(config.cpus).to eq 2 }
    it { expect(config.disk_count).to eq 2 }
    it { expect(config.boot_timeout).to eq 300 }
    it { expect(config.root_password).to eq 'rescue' }

    it 'auto-detects a qemu system binary for the current arch' do
      expect(%w[qemu-system-aarch64 qemu-system-x86_64]).to include config.qemu_binary
    end
  end

  describe 'overrides' do
    it 'respects configured values' do
      config.disk_size = '10G'
      config.ram = 1024
      config.cpus = 8
      config.disk_count = 1
      config.boot_timeout = 60
      config.root_password = 'secret'
      config.qemu_binary = 'qemu-system-riscv64'

      expect(config.disk_size).to eq '10G'
      expect(config.ram).to eq 1024
      expect(config.cpus).to eq 8
      expect(config.disk_count).to eq 1
      expect(config.boot_timeout).to eq 60
      expect(config.root_password).to eq 'secret'
      expect(config.qemu_binary).to eq 'qemu-system-riscv64'
    end
  end

  describe '#external_network' do
    it 'raises a clear error when unset' do
      config.instance_variable_set(:@external_network, nil)
      expect { config.external_network }.to raise_error(/external_network is not set/)
    end

    it 'returns the configured block' do
      config.external_network = '10.66.0.0/16'
      expect(config.external_network).to eq '10.66.0.0/16'
    end
  end

  describe '#qemu_firmware' do
    it 'prefers an explicitly configured path' do
      config.qemu_firmware = '/fw/edk2.fd'
      expect(config.qemu_firmware).to eq '/fw/edk2.fd'
    end

    it 'falls back to the first existing well-known firmware path' do
      config.instance_variable_set(:@qemu_firmware, nil)
      allow(File).to receive(:exist?).and_return(false)
      allow(File).to receive(:exist?).with('/usr/local/share/qemu/edk2-aarch64-code.fd').and_return(true)
      expect(config.qemu_firmware).to eq '/usr/local/share/qemu/edk2-aarch64-code.fd'
    end
  end
end
