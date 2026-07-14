require 'spec_helper'
require 'cloud_model/api/qemu/apt_cache_daemon'

describe CloudModel::Api::Qemu::AptCacheDaemon do
  describe '.cacheable?' do
    it 'caches immutable package artifacts' do
      expect(described_class.cacheable?('http://deb.debian.org/debian/pool/main/b/bash/bash_5.2_amd64.deb')).to be true
      expect(described_class.cacheable?('http://deb.debian.org/debian/pool/main/l/linux/linux-image_6.1.deb')).to be true
    end

    it 'never caches repository metadata (changes and is hash-verified)' do
      expect(described_class.cacheable?('http://deb.debian.org/debian/dists/bookworm/InRelease')).to be false
      expect(described_class.cacheable?('http://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.gz')).to be false
    end

    it 'tolerates unparseable URIs' do
      expect(described_class.cacheable?('gopher://[!')).to be false
    end
  end

  describe '.cache_path' do
    it 'lays cache files out by host and path' do
      path = described_class.cache_path('/cache', 'http://deb.debian.org/debian/pool/main/b/bash/bash_5.2_amd64.deb')
      expect(path).to eq '/cache/deb.debian.org/debian/pool/main/b/bash/bash_5.2_amd64.deb'
    end

    it 'sanitizes unexpected characters' do
      path = described_class.cache_path('/cache', 'http://mirror/po ol/x;rm -rf/pkg.deb')
      expect(path).not_to include(' ', ';')
    end
  end
end

describe CloudModel::Api::Qemu::AptCache do
  describe '.proxy_url' do
    it "points at QEMU's host gateway with the configured port" do
      CloudModel.config.api.qemu.apt_cache_port = 3333
      expect(described_class.proxy_url).to eq 'http://10.0.2.2:3333'
    end
  end

  describe '.ensure_running!' do
    it 'does nothing when disabled' do
      CloudModel.config.api.qemu.apt_cache = false
      expect(Process).not_to receive(:spawn)
      expect(described_class.ensure_running!).to be false
    end
  end
end
