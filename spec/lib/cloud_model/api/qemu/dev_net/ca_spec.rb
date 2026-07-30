require 'spec_helper'
require 'cloud_model/api/qemu/dev_net'
require 'tmpdir'

RSpec.describe CloudModel::Api::Qemu::DevNet::Ca do
  around do |ex|
    Dir.mktmpdir('dev-net-ca-spec') { |d| @dir = d; ex.run }
  end

  subject(:ca) { described_class.new(dir: @dir) }

  it 'creates a CA and a leaf whose SANs cover each zone and its wildcard' do
    r = ca.ensure!(%w[dev.example.com dev.example.org])
    expect(r[:created_ca]).to be true
    expect(r[:regenerated_leaf]).to be true

    leaf = OpenSSL::X509::Certificate.new(File.read(ca.leaf_cert_path))
    san  = leaf.extensions.find { |e| e.oid == 'subjectAltName' }.value
    %w[dev.example.com *.dev.example.com dev.example.org *.dev.example.org].each do |name|
      expect(san).to include("DNS:#{name}")
    end
  end

  it 'issues a leaf that chains to the CA' do
    ca.ensure!(%w[dev.example.com])
    store = OpenSSL::X509::Store.new
    store.add_cert(OpenSSL::X509::Certificate.new(File.read(ca.ca_cert_path)))
    leaf = OpenSSL::X509::Certificate.new(File.read(ca.leaf_cert_path))
    expect(store.verify(leaf)).to be true
  end

  it 'is idempotent and keeps the CA stable while re-issuing on zone change' do
    ca.ensure!(%w[dev.example.com])
    ca_pem = File.read(ca.ca_cert_path)

    same = ca.ensure!(%w[dev.example.com])
    expect(same[:created_ca]).to be false
    expect(same[:regenerated_leaf]).to be false

    changed = ca.ensure!(%w[dev.example.com other.example.net])
    expect(changed[:created_ca]).to be false          # trust anchor unchanged
    expect(changed[:regenerated_leaf]).to be true
    expect(File.read(ca.ca_cert_path)).to eq ca_pem    # CA cert byte-identical
  end

  it 'writes the private keys 0600' do
    ca.ensure!(%w[dev.example.com])
    expect(File.stat(ca.ca_key_path).mode & 0o777).to eq 0o600
    expect(File.stat(ca.leaf_key_path).mode & 0o777).to eq 0o600
  end

  it 'refuses to run with no zones' do
    expect { ca.ensure!([]) }.to raise_error(CloudModel::Api::Qemu::DevNet::Error, /no dev zones/)
  end
end
