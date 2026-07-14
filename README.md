# cloudmodel-api-qemu

Local QEMU VMs as `CloudModel::Host`s — for developing and testing
[CloudModel](https://github.com/cloudmodel/cloudmodel) deployments without real
hardware.

Each VM mimics a bare-metal server the way CloudModel expects to find it:

- **vda** — a Debian *genericcloud* rescue disk (copy-on-write clone of a shared
  base image), analogous to a Hetzner rescue system: root login with the
  configured `initial_root_pw` **and** the CloudModel SSH key, `sgdisk`,
  `mdadm`, `parted`, `debootstrap` preinstalled via cloud-init.
- **nvme0n1, nvme1n1, …** — empty system disks (`disk_count`, default 2) for
  CloudModel to partition, RAID and install onto (`host.system_disks`).
  Attached as emulated NVMe: `smartmontools` sees a real SMART/health log, so
  disk monitoring works like on hardware, and the device names stay stable
  when the rescue disk is detached for the installed-system boot.
- Sensors and CPU model name (which QEMU cannot emulate) are faked at the
  OS level inside the VM (`/usr/local/bin/sensors`, `lscpu` wrapper), keeping
  CloudModel's monitoring plugins unmodified.

## Networking model

QEMU user-mode NAT (`-netdev user`) — no root, no bridge, no DHCP server needed.

- Inside the VM: DHCP on QEMU's `10.0.2.0/24`.
- Outside: the VM's `primary_address` IP is mapped via `hostfwd` to
  `127.0.0.1:<22000 + last IP octet>` and an entry in `~/.ssh/config`
  (`Include ~/.ssh/cloudmodel_vms`) makes `ssh root@<primary_ip>` — and thereby
  `Net::SSH`/CloudModel — work transparently.
- Optionally a loopback alias for the IP is added (`sudo`, best effort).

Full host deploys work: worker patches switch the installed system to DHCP on
QEMU's NAT, DNAT incoming hostfwd traffic to the host's `primary_address` (so
CloudModel's firewall rules apply as on real hardware, restored after firewall
restarts), and boot the installed system via UEFI/grub-efi once the deploy
finishes. **Limitation:** only SSH (port 22) is forwarded from the outside;
other services on the VM are reachable from within the VM/guests only.

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
rake dev:create_vm_host[name,0,amd64] # explicit architecture (see below)

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

## Architectures

The VM's architecture comes from `host.arch` (set on creation, default: the
workstation's arch). A VM matching the workstation runs hardware-accelerated
(HVF on macOS, KVM on Linux); any other arch runs fully TCG-emulated — an
order of magnitude slower, but true to the target platform. That lets an
arm64 workstation (Apple Silicon) exercise the production amd64 stack
end-to-end. Base images, QEMU binary and UEFI firmware are selected per
arch; CloudModel builds and manages templates per arch, so mixed-arch host
fleets work — configure `config.build_host_name` as a hash
(`{'arm64' => 'host22', 'amd64' => 'host24'}`) to pin template build hosts
per arch (an arch without an entry builds on the deploy target itself).

`QEMU_DISPLAY=1 rake dev:vm:start[name]` opens a graphical console window
instead of running headless (log: `<vm_dir>/qemu.log`).

## Package cache

A small caching proxy on the workstation (started automatically with the
first VM, `rake dev:apt_cache:status|start|stop`) serves the VMs' apt and
debootstrap downloads from `<vm_dir>/apt-cache` — repeated template builds
are mostly network-free, which matters double under TCG emulation. Only
immutable pool artifacts are cached, never repository metadata. The VMs
reach it as `http://10.0.2.2:<apt_cache_port>` (QEMU's host gateway); apt
is configured via `apt.conf.d`, debootstrap via `http_proxy` in
`/etc/environment`. Disable with `config.api.qemu.apt_cache = false`.

## IP allocation (dev:create_vm_host)

- `config.tinc_network` — a /25 per host is carved out for `private_network`.
- `config.api.qemu.external_network` (≥ /16) — partitioned as:
  - `x.x.0.1-254` — `primary_address` per host,
  - `x.x.1.0/24`, `x.x.2.0/24`, … — one guest `addresses` subnet per host.

## License

MIT — see [LICENSE](LICENSE).
