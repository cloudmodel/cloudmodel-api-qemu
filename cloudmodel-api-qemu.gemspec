require_relative "lib/cloud_model/api/qemu/version"

Gem::Specification.new do |spec|
  spec.name        = "cloudmodel-api-qemu"
  spec.version     = CloudModel::Api::Qemu::VERSION
  spec.authors     = ["Sven G. Brönstrup (StarPeak)"]
  spec.email       = ["info@cloud-model.org"]
  spec.homepage    = "http://cloud-model.org/"
  spec.summary     = "QEMU virtual server emulation to test CloudModel actions locally"
  spec.description = "Emulates virtual servers with QEMU so CloudModel host and guest " \
                     "deploys can be exercised end-to-end on a workstation — no real " \
                     "hardware needed. Provisions VMs with a Debian rescue system, " \
                     "registers them as CloudModel hosts, emulates NVMe disks with SMART " \
                     "data, and adapts CloudModel's workers to the QEMU environment " \
                     "(UEFI boot, user-mode NAT networking). For development and CI."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/cloudmodel/cloudmodel-api-qemu"

  spec.files = Dir["{app,config,lib}/**/*", "LICENSE", "Rakefile", "README.md"]

  spec.add_dependency "rails",      "~> 8.0"
  spec.add_dependency "cloudmodel", "~> 0.4.0"
  spec.add_dependency "net-ssh",    ">= 7.0"
end
