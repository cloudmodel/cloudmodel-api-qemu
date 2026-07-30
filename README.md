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

## Reaching the dev cloud from the workstation (`dev:net`)

QEMU user-mode NAT isolates the VMs, so the workstation cannot reach the dev
guests (and their hardcoded public hostnames don't point at the dev IPs). The
`dev:net` tasks fix both, session-scoped and idempotent — no permanent daemon,
nothing persisted across reboots:

```bash
bin/install.sh                     # one-time: checks deps, marks helpers executable
bundle exec rake dev:net:plan      # show what would change (no sudo)
bundle exec rake dev:net:up        # routing + split-horizon DNS up (sudo once)
bundle exec rake dev:net:status    # verify: routes present + names resolve to dev IPs
bundle exec rake dev:net:down      # remove everything (sudo once)
```

Two problems are solved, both derived from live state (nothing hardcoded):

- **Routing** — for every deployed host, its guest (tinc) subnet is routed via
  the host's `primary_address`; on macOS the workstation also joins the
  socket_vmnet L2 so the guest publics are on-link.
- **Split-horizon DNS** — a tiny session-scoped forwarder
  (`libexec/cm-dev-net-dns`, `127.0.0.1:5354`) that resolves in three tiers:
  1. **static overrides** — the hand-pinned `config.additional_hosts` names
     (snapshotted at start; they rarely change);
  2. **live database** — any *other* name under a dev zone is looked up on
     demand in the `CloudModel::AddressResolution` registry, so a **freshly
     deployed guest resolves immediately, without re-running anything** (answers
     are cached ~5 s). A live answer is only served if the name is under a dev
     zone *and* its IP is inside the dev networks, so the DB can never point a
     name outside the dev cloud;
  3. **forward** — everything else goes to the real upstream resolvers (captured
     before we install ourselves), so unknown names under the same zone still
     resolve publicly instead of NXDOMAIN.

  The platform resolver glue scopes only the dev zones at it: `/etc/resolver/<zone>`
  on macOS, `resolvectl` on Linux (systemd-resolved required). The dev zone is
  the direct parent of the pinned names (`auth.dev.example.com` → `dev.example.com`),
  so the real public parent (`example.com`) is never touched.

Only the routes and the resolver glue need privileges. They are applied by a
small standalone executor (`libexec/cm-dev-net-exec`) that re-validates the
plan against a strict IP/domain whitelist and runs only fixed argv arrays — no
shell, so nothing is ever interpolated into a root command.

The live database tier keeps names current on its own, so you rarely need to
touch the forwarder. Only the *snapshotted* inputs — the static
`additional_hosts` map, the dev zone, and the upstream resolvers — are fixed
when the forwarder starts. When one of *those* changes, re-run `dev:net:up`: it
always **restarts** the forwarder (binding with `SO_REUSEADDR` for an immediate
rebind) rather than reusing a stale one from an earlier run, so it can never
keep serving names from a previous dev zone.

> Live DB resolution needs the `mongo` gem, which is why `dev:net:up` launches
> the forwarder in the app's bundle. If it is unavailable the forwarder logs it
> and simply falls back to tiers 1 + 3 (static overrides + upstream forwarding).

### Local CA for the dev zones

Dev guests serve names under a private dev zone (the direct parent domain of the
configured names) that no public CA will certify. `dev:net:ca` mints a local CA
and a leaf certificate whose SANs cover `<zone>` and `*.<zone>` for every dev
zone, then trusts the CA on the workstation:

```bash
bundle exec rake dev:net:ca:create    # generate CA + leaf under <vm_dir>/dev-net-ca (no sudo)
bundle exec rake dev:net:ca:trust      # trust the CA in the system keychain (sudo once)
bundle exec rake dev:net:ca:untrust    # remove it again (sudo once)
```

Pure Ruby OpenSSL (no external tools). The CA is written once and left stable
across runs (so the trust anchor doesn't churn); the leaf is re-issued only when
the set of zones changes. Install the leaf cert + key on the dev guests' nginx,
and the CA cert wherever other clients need to trust it.

## Sleep guard (macOS)

The single biggest source of instability is **the Mac sleeping while a VM
runs**: QEMU is frozen mid-I/O, and on wake the guest clock jumps — which
repeatedly wedges the nested LXD/ZFS state (stuck mounts, and in the worst case
a corrupt `guests` pool). The sleep guard removes the trigger by pausing the VM
cleanly *before* the host sleeps:

- `rake dev:vm:pause_all` — send the QEMU monitor `stop` to every running VM,
  quiescing its vCPUs (no in-flight guest I/O to corrupt).
- `rake dev:vm:resume_all` — `cont` each VM and nudge its clock forward.

Wire these to the host's sleep/wake events with [`sleepwatcher`](https://formulae.brew.sh/formula/sleepwatcher):

```bash
bundle exec rake dev:vm:sleep_guard   # writes on-sleep.sh / on-wake.sh under <vm_dir>
brew install sleepwatcher
ln -sf <vm_dir>/on-sleep.sh ~/.sleep
ln -sf <vm_dir>/on-wake.sh  ~/.wakeup
brew services start sleepwatcher
```

(The generated hooks pin this Ruby's `bin` on `PATH` so `bundle` resolves inside
sleepwatcher's minimal launchd environment.) Once enabled, sleeping the Mac
pauses the VMs and waking resumes them — no more mid-I/O freeze.

## Recovering a wedged VM or a corrupt guests pool

Nested LXD+ZFS on qcow2 has a few sharp edges. In rough order of severity:

- **`device or resource busy` on a container mount** (e.g. a deploy fails at
  "attach web release"): a stuck LXD mount, usually from container churn. Fix
  *without* a force-kill — delete the failed container and restart LXD:
  `lxc delete -f <container>; systemctl restart lxd`. A stubborn mount yields to
  `umount -l <path>` then the delete. **Do not force-kill the VM for this** — see
  below.
- **NEVER issue a discard/TRIM on the emulated NVMe** (`blkdiscard`, `fstrim` on
  a raw `nvme*` partition, `zpool trim`). The emulated NVMe controller faults on
  a large discard and drops off the bus, and on the qcow2-backed mirror a trim
  can corrupt the pool. To wipe a partition, use plain `dd` (zero the first and
  last ~16 MB), never discard.
- **A force-kill mid-I/O can corrupt the `guests` pool** (a hung `zfs`/`zpool`
  task in `D` state, then a `space_map` PANIC on the next import that wedges the
  whole boot — sshd never comes up). This is exactly what the sleep guard exists
  to prevent. If it happens, the pool is on dedicated GPT partitions
  (`guests0`/`guests1`) and the guests are rebuildable, so the fastest recovery
  is to **rebuild the pool** rather than chase a rewind:
  1. Set `host.vm_boot_rescue = true` and relaunch — the rescue disk boots with
     an explicit `bootindex=0` (EDK2 has no persistent NVRAM, so without it the
     firmware would boot the installed system, which auto-imports and re-wedges).
  2. In the rescue system (which has no ZFS, so it can't import the bad pool),
     `dd`-zero the ZFS labels off the `guests0`/`guests1` partitions
     (front + back ~16 MB each; **not** `blkdiscard`).
  3. Set `vm_boot_rescue = false` and relaunch. The `guest_zpool` service's
     `zpool create` recreates a fresh pool; `lxc delete` any stale container
     records left in the LXD database, then redeploy the guests.
- **A graceful `systemctl reboot` inside the guest** is always safer than a
  force-kill — it syncs and quiesces first.

## License

MIT — see [LICENSE](LICENSE).
