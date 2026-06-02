require_relative "lib/cloud_model/api/qemu/version"

Gem::Specification.new do |spec|
  spec.name        = "cloudmodel-api-qemu"
  spec.version     = CloudModel::Api::Qemu::VERSION
  spec.authors     = ["Sven G. Brönstrup (StarPeak)"]
  spec.email       = ["info@cloud-model.org"]
  spec.homepage    = "http://cloud-model.org/"
  spec.summary     = "Local QEMU/VM support for CloudModel"
  spec.description = "Provision and manage local QEMU virtual machines as CloudModel hosts. " \
                     "Boots a Debian live ISO, bootstraps SSH, and registers the VM as a " \
                     "CloudModel::Host — useful for development and CI environments."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/cloudmodel/cloudmodel-api-qemu"

  spec.files = Dir["{app,config,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]

  spec.add_dependency "rails",      "~> 8.0"
  spec.add_dependency "cloudmodel", "~> 0.3.0"
  spec.add_dependency "net-ssh",    ">= 7.0"
end
