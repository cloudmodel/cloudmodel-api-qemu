# cloudmodel-api-qemu

Local QEMU VMs as `CloudModel::Host`s — develop and test
[CloudModel](https://github.com/cloudmodel/cloudmodel) deployments on a
workstation, no real hardware needed. A full dev cloud (hosts, guest
containers, deployed apps with TLS + DNS) runs on a single machine.

- [How it works](#how-it-works)
- [Quickstart](#quickstart)
- [VM lifecycle](#vm-lifecycle)
- [Architectures](#architectures)
- [Networking](#networking)
  - [Per-VM NAT + SSH](#per-vm-nat--ssh)
  - [Inter-VM network (socket_vmnet)](#inter-vm-network-socket_vmnet)
  - [IP allocation](#ip-allocation)
- [Reaching the dev cloud: `dev:net`](#reaching-the-dev-cloud-devnet)
  - [Split-horizon DNS](#split-horizon-dns)
  - [Local CA](#local-ca)
- [Package cache](#package-cache)
- [Sleep guard (macOS)](#sleep-guard-macos)
- [Troubleshooting & recovery](#troubleshooting--recovery)
- [License](#license)

## How it works

Each VM mimics a bare-metal server the way CloudModel expects to find one:

| Piece | What it is |
| --- | --- |
| `vda` | Debian *genericcloud* **rescue disk** (CoW clone of a shared base image) — like a hosting provider's rescue system: root login via `initial_root_pw` + the CloudModel SSH key; `sgdisk`, `mdadm`, `parted`, `debootstrap` preinstalled via cloud-init. |
| `nvme0n1`, `nvme1n1`, … | Empty **system disks** (`disk_count`, default 2) that CloudModel partitions, RAIDs and installs onto. Emulated NVMe so `smartmontools` sees a real SMART log (unmodified disk monitoring) and device names stay stable when the rescue disk is detached. |
| Sensors / CPU name | Faked inside the VM (`sensors` and `lscpu` wrappers) — QEMU can't emulate them, CloudModel's monitoring plugins stay unmodified. |

A full host deploy works end to end: boot rescue → partition/RAID → build +
install the host system → reboot into it via UEFI/grub-efi → deploy guest
containers (LXD + ZFS) onto it.

## Quickstart

**1. Install dependencies**

```bash
brew install qemu                    # macOS
# apt-get install qemu-system-x86 qemu-utils dosfstools mtools   # Linux

# optional but recommended: inter-VM networking + sleep protection (macOS)
brew install socket_vmnet && sudo brew services start socket_vmnet
brew install sleepwatcher
```

A CloudModel keypair must exist at `<data_directory>/keys/id_rsa[.pub]`.

**2. Wire the gem into the app**

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

**3. Create and deploy a host**

```bash
bundle exec rake dev:create_vm_host[host01]   # create VM + Host document, boot rescue
# then deploy it like any CloudModel host (UI or console):
#   CloudModel::Host.find_by(name: 'host01').deploy!
```

**4. Make the dev cloud reachable** — see [`dev:net`](#reaching-the-dev-cloud-devnet)
and enable the [sleep guard](#sleep-guard-macos).

## VM lifecycle

```bash
rake dev:create_vm_host               # auto-name (host01, host02, …)
rake dev:create_vm_host[name]         # explicit name
rake dev:create_vm_host[name,2]       # 1 primary + 2 extra IPs/NICs
rake dev:create_vm_host[name,0,amd64] # explicit architecture
```

| Task | Effect |
| --- | --- |
| `rake dev:vm:list` | All hosts with VM state |
| `rake dev:vm:start[name]` | Start a stopped VM |
| `rake dev:vm:stop[name]` | Graceful ACPI power-off |
| `rake dev:vm:kill[name]` | Hard kill (pull the power — see [recovery notes](#troubleshooting--recovery)) |
| `rake dev:vm:destroy[name]` | Remove disks/state, keep the Host document |
| `rake dev:vm:purge[name]` | Destroy + delete the Host document |
| `rake dev:vm:ssh[name]` | Print the SSH command |
| `rake dev:vm:pause_all` / `resume_all` | Quiesce/resume all running VMs (see [sleep guard](#sleep-guard-macos)) |

From Ruby: `host.create_vm!`, `host.start_vm!`, `host.stop_vm!`,
`host.kill_vm!`, `host.destroy_vm!`, `host.vm_running?`, `host.vm_status`.

`QEMU_DISPLAY=1 rake dev:vm:start[name]` opens a graphical console window
instead of running headless (QEMU log: `<vm_dir>/qemu.log`; serial console:
`<vm_dir>/serial.log`, interactive via `nc -U <vm_dir>/serial.sock`).

## Architectures

The VM's architecture comes from `host.arch` (set on creation; default: the
workstation's). A VM matching the workstation runs hardware-accelerated (HVF on
macOS, KVM on Linux); any other arch runs fully TCG-emulated — an order of
magnitude slower, but true to the target platform, so an Apple-Silicon
workstation can exercise an amd64 production stack end to end.

Base image, QEMU binary and UEFI firmware are selected per arch. CloudModel
builds templates per arch too — configure `config.build_host_name` as a hash
(`{'arm64' => 'host23', 'amd64' => 'host24'}`) to pin template build hosts per
arch; an arch without an entry builds on the deploy target itself.

## Networking

### Per-VM NAT + SSH

Every VM has a QEMU user-mode NAT NIC (`-netdev user`) — no root, no bridge,
no DHCP server needed. It provides internet access, and SSH reaches the VM via
a host port forward: `primary_address` ⇒ `127.0.0.1:<22000 + last IP octet>`.
An `Include`d `~/.ssh/config` maps `ssh root@<primary_ip>` to that forward, so
`Net::SSH`/CloudModel work transparently. Only port 22 is forwarded — other
services are reachable via [`dev:net`](#reaching-the-dev-cloud-devnet) routing
instead.

### Inter-VM network (socket_vmnet)

User-mode NAT isolates every VM, which would break everything inter-host
(the tinc VPN underlay, cross-host guest routing, template syncs). On macOS,
[`socket_vmnet`](https://github.com/lima-vm/socket_vmnet) fixes this: a small
root daemon owns one vmnet L2 segment, and every VM attaches to it
**unprivileged** as its **first** NIC — the kernel names it `eth0`, which is
exactly the interface CloudModel targets for `primary_address`, guest public
IPs, tinc binding and firewall rules. No core changes, no manual steps.

```bash
brew install socket_vmnet
sudo brew services start socket_vmnet
```

Auto-detected: when the daemon socket exists, new VM launches attach to it
(`config.api.qemu.vmnet` to override). The NAT NIC becomes `eth1` (internet +
SSH forward only). With this in place, VM↔VM traffic, tinc between hosts and
guest↔guest across hosts all work as in production.

### IP allocation

`dev:create_vm_host` allocates from two configured blocks:

| Config | Carving |
| --- | --- |
| `config.tinc_network` | one /25 per host → `private_network` (guest/tinc subnet) |
| `config.api.qemu.external_network` (≥ /16) | `x.x.0.1-254` → one `primary_address` per host; `x.x.1.0/24`, `x.x.2.0/24`, … → one guest-public subnet per host |

## Reaching the dev cloud: `dev:net`

The workstation itself is *outside* the VMs' networks: it cannot reach the
guests, and the dev guests' hostnames don't resolve to the dev IPs. The
`dev:net` tasks fix both — session-scoped and idempotent, no permanent daemon,
nothing persisted across reboots:

```bash
bin/install.sh                     # one-time: checks deps, marks helpers executable
bundle exec rake dev:net:plan      # show what would change (no sudo)
bundle exec rake dev:net:up        # routing + split-horizon DNS up (sudo once)
bundle exec rake dev:net:status    # verify: routes present + names resolve to dev IPs
bundle exec rake dev:net:down      # remove everything (sudo once)
```

Everything is derived from live state (config + database), nothing hardcoded:

- **Routing** — for every deployed host, its guest (tinc) subnet is routed via
  the host's `primary_address`; on macOS the workstation also joins the
  socket_vmnet L2 so the guest publics are on-link.
- **DNS** — see below.

Only the routes and resolver glue need privileges, applied by a standalone
executor (`libexec/cm-dev-net-exec`) that **re-validates a strict IP/domain
whitelist as root and runs only fixed argv arrays** — no shell, so no value can
ever be interpolated into a root command.

### Split-horizon DNS

The deployed apps often hardcode their public hostnames, so the dev cloud
serves a **dedicated dev subzone** (e.g. `dev.example.com` — pick one whose
names have **no public DNS records**, otherwise the OS may prefer the public
answer). Set the pinned names in the app config:

```ruby
config.additional_hosts = {
  'auth.dev.example.com' => '10.67.1.124',
  'git.dev.example.com'  => '10.67.1.117',
}
```

The dev **zone** is the direct parent of those names (`dev.example.com`); only
that zone is scoped to the local forwarder — the real public parent
(`example.com`) is never touched. The forwarder (`libexec/cm-dev-net-dns`, a
small stdlib DNS server on `127.0.0.1:5354`) answers in three tiers:

1. **Static overrides** — the pinned `additional_hosts` names (snapshotted at
   start).
2. **Live database** — any *other* name under the dev zone is looked up on
   demand in the `CloudModel::AddressResolution` registry (cached ~5 s), so a
   freshly deployed guest resolves immediately without re-running anything. A
   live answer is only served if the name is in-zone **and** its IP is inside
   the dev networks — the database can never point a name outside the dev cloud.
3. **Forward** — everything else goes to the real upstream resolvers (captured
   before we install ourselves), so unknown in-zone names still resolve
   publicly instead of NXDOMAIN.

Platform glue: `/etc/resolver/<zone>` on macOS, `resolvectl` on a dummy link on
Linux (systemd-resolved required). Because tier 2 is live, you rarely touch the
forwarder — only when a *snapshotted* input changes (the pinned names, the
zone, upstreams) re-run `dev:net:up`; it always **restarts** the forwarder so a
stale process can never keep serving a previous zone.

> Live DB resolution needs the `mongo` gem, which is why `dev:net:up` launches
> the forwarder inside the app's bundle. Without it, the forwarder logs the fact
> and serves tiers 1 + 3 only.

### Local CA

No public CA certifies a private dev zone, so `dev:net:ca` mints a local CA and
one leaf whose SANs cover `<zone>` + `*.<zone>` for every dev zone:

```bash
bundle exec rake dev:net:ca:create    # CA + leaf under <vm_dir>/dev-net-ca (no sudo)
bundle exec rake dev:net:ca:trust     # trust the CA in the system keychain (sudo once)
bundle exec rake dev:net:ca:untrust   # remove that trust again (sudo once)
```

Pure Ruby OpenSSL. The CA is created once and kept stable (the trust anchor
doesn't churn); the leaf is re-issued only when the zone set changes. Install
the leaf cert + key on the dev guests (e.g. as a `CloudModel::Certificate`
attached to their nginx service) and the CA cert wherever else clients need it.

## Package cache

A caching proxy on the workstation (started automatically with the first VM;
`rake dev:apt_cache:status|start|stop`) serves the VMs' apt + debootstrap
downloads from `<vm_dir>/apt-cache`, making repeated template builds mostly
network-free — which matters double under TCG emulation. Only immutable pool
artifacts are cached, never repository metadata. VMs reach it as
`http://10.0.2.2:<apt_cache_port>` (QEMU's host gateway). Disable with
`config.api.qemu.apt_cache = false`.

## Sleep guard (macOS)

The single biggest source of instability is **the Mac sleeping while a VM
runs**: QEMU freezes mid-I/O, and on wake the guest clock jumps — which
repeatedly wedges the nested LXD/ZFS state (stuck mounts, worst case a corrupt
`guests` pool). The sleep guard removes the trigger by pausing VMs cleanly
*before* the host sleeps:

- `rake dev:vm:pause_all` — QEMU monitor `stop` for every running VM (vCPUs
  quiesced, no in-flight guest I/O left to corrupt).
- `rake dev:vm:resume_all` — `cont` each VM and nudge its clock forward.

Wire them to the host's sleep/wake events with
[`sleepwatcher`](https://formulae.brew.sh/formula/sleepwatcher):

```bash
bundle exec rake dev:vm:sleep_guard   # writes on-sleep.sh / on-wake.sh under <vm_dir>
brew install sleepwatcher
ln -sf <vm_dir>/on-sleep.sh ~/.sleep
ln -sf <vm_dir>/on-wake.sh  ~/.wakeup
brew services start sleepwatcher
```

The generated hooks pin the app's Ruby `bin` on `PATH` so `bundle` resolves
inside sleepwatcher's minimal launchd environment. Once enabled: Mac sleeps →
VMs pause; Mac wakes → VMs resume. No more mid-I/O freeze.

## Troubleshooting & recovery

Nested LXD + ZFS on qcow2 has sharp edges. In rough order of severity:

**A deploy fails with `device or resource busy` on a container mount**
(e.g. at "attach web release"): a stuck LXD mount from container churn. Fix it
*without* touching the VM:

```bash
lxc delete -f <failed-container>
systemctl restart lxd
umount -l <mountpoint>   # only if a mount is stubborn, then delete again
```

**Never issue a discard/TRIM against the emulated NVMe** (`blkdiscard`,
`zpool trim`, `fstrim` on raw `nvme*` partitions). The emulated controller
faults on large discards and drops off the bus; on the qcow2-backed mirror a
trim can corrupt the pool. To reclaim workstation disk space use `fstrim -av`
on the *filesystems* inside the VM; to wipe a partition use plain `dd` (zero
the first and last ~16 MB), never discard.

**Force-killing a VM mid-I/O can corrupt the `guests` pool** — symptoms: a
`zfs`/`zpool` task hangs in `D` state, or after a reboot the pool import
panics (`space_map` VERIFY/PANIC in dmesg) and wedges the whole boot so sshd
never comes up. This is exactly what the [sleep guard](#sleep-guard-macos)
prevents. Recovery — the pool lives on dedicated GPT partitions
(`guests0`/`guests1`) and dev guests are rebuildable from templates, so
rebuilding beats forensic rewinds:

1. `host.vm_boot_rescue = true`, then relaunch the VM. The rescue disk boots
   with an explicit `bootindex=0` (EDK2 keeps no NVRAM here; without the flag
   the firmware boots the installed system, which auto-imports and re-wedges).
2. In the rescue system (no ZFS → cannot import the bad pool), zero the ZFS
   labels off the `guests0`/`guests1` partitions with `dd` (first + last
   ~16 MB each — **not** `blkdiscard`, see above).
3. `vm_boot_rescue = false`, relaunch. The host's `guest_zpool` service
   recreates a fresh pool via `zpool create`; `lxc delete` any stale container
   records left in LXD's database, then redeploy the guests.

**Prefer a graceful `systemctl reboot` inside the VM** over `dev:vm:kill`
whenever the VM still responds — it syncs and quiesces first.

## License

MIT — see [LICENSE](LICENSE).
