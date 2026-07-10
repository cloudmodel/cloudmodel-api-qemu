# cloudmodel-api-qemu

Local QEMU VMs as `CloudModel::Host`s — for developing and testing
[CloudModel](https://github.com/cloudmodel/cloudmodel) deployments without real
hardware.

Each VM mimics a bare-metal server the way CloudModel expects to find it:

- **vda** — a Debian *genericcloud* rescue disk (copy-on-write clone of a shared
  base image), analogous to a Hetzner rescue system: root login with the
  configured `initial_root_pw` **and** the CloudModel SSH key, `sgdisk`,
  `mdadm`, `parted`, `debootstrap` preinstalled via cloud-init.
- **vdb, vdc, …** — empty system disks (`disk_count`, default 2) for CloudModel
  to partition, RAID and install onto (`host.system_disks`).

## Networking model

QEMU user-mode NAT (`-netdev user`) — no root, no bridge, no DHCP server needed.

- Inside the VM: DHCP on QEMU's `10.0.2.0/24`.
- Outside: the VM's `primary_address` IP is mapped via `hostfwd` to
  `127.0.0.1:<22000 + last IP octet>` and an entry in `~/.ssh/config`
  (`Include ~/.ssh/cloudmodel_vms`) makes `ssh root@<primary_ip>` — and thereby
  `Net::SSH`/CloudModel — work transparently.
- Optionally a loopback alias for the IP is added (`sudo`, best effort).

**Limitation:** only SSH (port 22) is forwarded. Deployed network configuration
with static IPs from the CloudModel address pool will not be reachable after a
reboot into the installed system — full host deploys need a bridged/vmnet setup
(not implemented yet).

## Setup

```ruby
# Gemfile
gem 'cloudmodel-api-qemu', path: '../cloudmodel-api-qemu', require: 'cloud_model/api/qemu'
```

```ruby
# config/initializers/cloud_model_config.rb
CloudModel::Host.include CloudModel::Api::Qemu::Host

CloudModel.configure do |config|
  config.api.qemu.external_network = '10.66.0.0/16'  # required, ≥ /16
  # config.api.qemu.disk_count    = 2
  # config.api.qemu.disk_size     = '80G'
  # config.api.qemu.ram           = 4096
  # config.api.qemu.cpus          = 2
  # config.api.qemu.root_password = 'rescue'
  # config.api.qemu.boot_timeout  = 300
end
```

Requirements: `qemu` (`brew install qemu` / `apt-get install qemu-system-x86 qemu-utils`),
on Linux additionally `dosfstools` and `mtools` for the cloud-init seed.
A CloudModel keypair must exist at `<data_directory>/keys/id_rsa[.pub]`.

## Usage

```bash
rake dev:create_vm_host              # auto-name (host01, host02, …)
rake dev:create_vm_host[name]        # explicit name
rake dev:create_vm_host[name,2]      # 1 primary + 2 extra IPs/NICs

rake dev:vm:list                     # all hosts + VM state
rake dev:vm:start[name]
rake dev:vm:stop[name]               # ACPI power-off
rake dev:vm:kill[name]               # hard kill
rake dev:vm:destroy[name]            # remove disks/state, keep Host document
rake dev:vm:purge[name]              # destroy + delete Host document
rake dev:vm:ssh[name]                # print SSH command
```

From Ruby: `host.create_vm!`, `host.start_vm!`, `host.stop_vm!`, `host.kill_vm!`,
`host.destroy_vm!`, `host.vm_running?`, `host.vm_status`.

`QEMU_DISPLAY=1 rake dev:vm:start[name]` opens a graphical console window
instead of running headless (log: `<vm_dir>/qemu.log`).

## IP allocation (dev:create_vm_host)

- `config.tinc_network` — a /25 per host is carved out for `private_network`.
- `config.api.qemu.external_network` (≥ /16) — partitioned as:
  - `x.x.0.1-254` — `primary_address` per host,
  - `x.x.1.0/24`, `x.x.2.0/24`, … — one guest `addresses` subnet per host.

## License

MIT — see MIT-LICENSE.
