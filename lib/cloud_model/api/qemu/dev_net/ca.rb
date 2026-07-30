# frozen_string_literal: true

require 'openssl'
require 'fileutils'
require 'json'

module CloudModel
  module Api
    module Qemu
      module DevNet
        # A tiny local Certificate Authority for the dev cloud's own DNS zones.
        #
        # The dev guests serve names under a private dev zone that no public CA
        # will (or should) certify, so we mint our own: one CA and one leaf cert
        # whose SANs cover `<zone>` and `*.<zone>` for every dev zone. The CA is
        # then trusted on the workstation (and installed on the guests) so browsers
        # accept the dev TLS without warnings.
        #
        # Pure stdlib OpenSSL, no external tools. Everything lives under
        # `<vm_dir>/dev-net-ca/` and is regenerated only when missing or when the
        # set of zones changes. Zone names come from the caller (derived from
        # config) — nothing app-specific is baked in here.
        class Ca
          CA_KEY   = 'ca.key'
          CA_CERT  = 'ca.crt'
          LEAF_KEY = 'dev.key'
          LEAF_CRT = 'dev.crt'
          MARKER   = 'zones.json'

          # 20 years — a dev CA that never silently expires mid-project.
          CA_YEARS   = 20
          LEAF_YEARS = 5

          attr_reader :dir

          def initialize(dir:)
            @dir = dir
          end

          def ca_key_path  = File.join(@dir, CA_KEY)
          def ca_cert_path = File.join(@dir, CA_CERT)
          def leaf_key_path = File.join(@dir, LEAF_KEY)
          def leaf_cert_path = File.join(@dir, LEAF_CRT)

          def ca_exists? = File.exist?(ca_key_path) && File.exist?(ca_cert_path)

          def leaf_current?(zones)
            return false unless File.exist?(leaf_key_path) && File.exist?(leaf_cert_path) && File.exist?(File.join(@dir, MARKER))
            JSON.parse(File.read(File.join(@dir, MARKER))) == zones.sort
          rescue StandardError
            false
          end

          # Ensure the CA and a leaf cert covering `zones` exist. Idempotent:
          # regenerates the leaf only when zones change; never rewrites a valid CA
          # (so the trust anchor on the Mac stays stable across runs).
          # @return [Hash] paths + a human summary
          def ensure!(zones)
            raise DevNet::Error, 'no dev zones to certify' if zones.nil? || zones.empty?
            FileUtils.mkdir_p(@dir)
            File.chmod(0o700, @dir)

            created_ca = false
            unless ca_exists?
              generate_ca!
              created_ca = true
            end

            regenerated = false
            unless leaf_current?(zones)
              generate_leaf!(zones)
              File.write(File.join(@dir, MARKER), JSON.generate(zones.sort))
              regenerated = true
            end

            {
              ca_cert: ca_cert_path, leaf_cert: leaf_cert_path, leaf_key: leaf_key_path,
              zones: zones.sort, created_ca: created_ca, regenerated_leaf: regenerated
            }
          end

          private

          def generate_ca!
            key = OpenSSL::PKey::RSA.new(4096)
            name = OpenSSL::X509::Name.parse('/O=cloudmodel dev/CN=cloudmodel-api-qemu dev CA')
            cert = base_cert(key.public_key, name, name, CA_YEARS)

            ef = OpenSSL::X509::ExtensionFactory.new
            ef.subject_certificate = cert
            ef.issuer_certificate  = cert
            cert.add_extension ef.create_extension('basicConstraints', 'CA:TRUE', true)
            cert.add_extension ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true)
            cert.add_extension ef.create_extension('subjectKeyIdentifier', 'hash', false)
            cert.sign(key, OpenSSL::Digest.new('SHA256'))

            write_secret(ca_key_path, key.to_pem)
            File.write(ca_cert_path, cert.to_pem)
          end

          def generate_leaf!(zones)
            ca_key  = OpenSSL::PKey::RSA.new(File.read(ca_key_path))
            ca_cert = OpenSSL::X509::Certificate.new(File.read(ca_cert_path))

            key  = OpenSSL::PKey::RSA.new(2048)
            # CN is just the first zone's wildcard; the SANs are what matter.
            name = OpenSSL::X509::Name.parse("/O=cloudmodel dev/CN=*.#{zones.sort.first}")
            cert = base_cert(key.public_key, name, ca_cert.subject, LEAF_YEARS)

            sans = zones.flat_map { |z| ["DNS:#{z}", "DNS:*.#{z}"] }.join(',')
            ef = OpenSSL::X509::ExtensionFactory.new
            ef.subject_certificate = cert
            ef.issuer_certificate  = ca_cert
            cert.add_extension ef.create_extension('basicConstraints', 'CA:FALSE', true)
            cert.add_extension ef.create_extension('keyUsage', 'digitalSignature,keyEncipherment', true)
            cert.add_extension ef.create_extension('extendedKeyUsage', 'serverAuth', false)
            cert.add_extension ef.create_extension('subjectAltName', sans, false)
            cert.sign(ca_key, OpenSSL::Digest.new('SHA256'))

            write_secret(leaf_key_path, key.to_pem)
            File.write(leaf_cert_path, cert.to_pem)
          end

          def base_cert(public_key, subject, issuer, years)
            cert = OpenSSL::X509::Certificate.new
            cert.version = 2
            # Deterministic-ish serial from the subject (no wall clock available in
            # all contexts); uniqueness across CA/leaf is enough here.
            cert.serial  = OpenSSL::BN.new(OpenSSL::Digest.new('SHA256').digest(subject.to_s + years.to_s)[0, 8].unpack1('H*'), 16)
            cert.subject = subject
            cert.issuer  = issuer
            cert.public_key = public_key
            cert.not_before = Time.now - 3600
            cert.not_after  = Time.now + (years * 365 * 24 * 3600)
            cert
          end

          def write_secret(path, pem)
            File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(pem) }
          end
        end
      end
    end
  end
end
