# proxmox-automation

Ansible automation for a Proxmox VE homelab server and its guests. It starts
guests in the required order, mounts the OMV NFS share on the host, validates
the resulting state, and manages the systemd service used for boot-time
automation. Guest selection is supported through -e nodes=, with a wrapper
script providing the complete setup workflow. All operations are designed to
be idempotent and safe to re-run.

```
Proxmox host (192.168.100.200)
 ├─ VM  201  Ubuntu 24.04        192.168.100.201   (AI workloads)
 ├─ VM  202  Windows 11          192.168.100.202   (tools and management)
 ├─ VM  203  OpenMediaVault      192.168.100.203   (media and shared directories)
 └─ LXC 204  Jellyfin            192.168.100.204   (media library, for testing; sees OMV's NFS share)
```

This file is the complete reference: [Scope](#scope), [Quick start](#quick-start),
[Repository layout](#repository-layout), [Architecture](#architecture), then
[Installation and usage](#installation-and-usage) (Part 0 covers building the
Proxmox host and guests from scratch, Part 1 is the step-by-step install with
expected results, Part 2 is day-to-day usage) and [Uninstall](#uninstall).
Each role also has its own `README.md` for its task flow and variables.

## Scope

The homelab is a Proxmox server plus a Raspberry Pi cluster. This repo owns
only the Proxmox side (the four guests above). The Pi cluster (boot
provisioning, K3s, GlusterFS, monitoring, LTE failover) lives in the separate
[`../cluster-automation`](../cluster-automation) repo — don't duplicate it here.
That repo also handles the basic tasks for the Proxmox host and the four guests
(SSH keys, system updates, base configuration) through its `pve_linux`
inventory, so this repo has no such role. Both inventories use the same names for the
same machines (`pve`, `ubuntu`, `omv`, `jellyfin`, `win11`; groups `hypervisor`,
`guests`, `windows`), so `-e nodes=omv` means the same guest in either repo.

## Quick start

```bash
# 1. Install Ansible collections
make collections

# 2. Point the inventory at your environment, then check SSH access
$EDITOR inventories/homelab/hosts inventories/homelab/group_vars/all/*.yml
make ping

# 3. Read-only status check
make status
```

Everything is a playbook, with `make` shortcuts (run from the repo root, as root):

| Command | What it does |
|---|---|
| `make ping` | Check SSH access to the hosts |
| `make status` | Read-only checks: guests running, NFS share mounted and exported |
| `make boot` / `make boot-check` | Run the boot sequence (start OMV, mount the share, start the rest, status check) / preview it |
| `make provision` | `scripts/cluster_full_provision.sh`: start OMV, mount the share, configure the LXC bind mount, start the rest, install the service, status check |
| `make install` / `make uninstall` | `playbooks/service_setup.yml -e service_setup_mode=install\|uninstall`: add/remove the systemd service that runs the boot playbook |
| `make lint` | `ansible-lint` and `shellcheck` |

Playbooks take `-e nodes=ubuntu,omv,...` to pick guests (all by default) and a mode
or action as an extra-var, e.g.
`ansible-playbook playbooks/power_manager.yml -e nodes=jellyfin -e mode=restart`.
Follow [Installation and usage](#installation-and-usage) step by step for the first setup
(Part 0 covers building the Proxmox host and guests from scratch); OMV's NFS
export has to be created in its web UI once.

## Repository layout

Same layout as `../cluster-automation`:

```
proxmox-automation/
├── ansible.cfg
├── .ansible-lint
├── Makefile                      # make status | boot | provision | install | uninstall | lint | ping
├── ansible/collections/requirements.yml
├── inventories/homelab/
│   ├── hosts                     # hosts: pve, ubuntu, omv, jellyfin, win11
│   └── group_vars/all/{main.yml, node_map.yml}
├── playbooks/                    # entry points, one per operational concern
│   ├── boot.yml
│   ├── status_check.yml
│   ├── proxmox.yml
│   ├── power_manager.yml
│   └── service_setup.yml
├── roles/{common, proxmox, status_check, service_setup}
├── scripts/                      # common.sh + cluster_full_provision.sh
└── README.md                     # this file
```

See each role's own `README.md` for its task flow and variables.

## Architecture

### Physical / virtual layout

```
 Proxmox VE host (pve) — 192.168.100.200
 ────────────────────────────────────────────────────────────────────
   qm / pct CLI manages all four guests below
   201 = AI workloads · 202 = tools and management
   203 = media and shared directories · 204 = media library (testing)

   ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐
   │  VM 201    │  │  VM 202    │  │  VM 203    │  │  LXC 204   │
   │  Ubuntu    │  │  Windows   │  │  OMV       │  │  Jellyfin  │
   │  24.04     │  │  11        │  │  (storage) │  │            │
   │  .201      │  │  .202      │  │  .203      │  │  .204      │
   └────────────┘  └────────────┘  └─────┬──────┘  └─────▲──────┘
                                         │ NFS export     │ bind mount (mp0)
                                         ▼                │
   host /mnt/homelab-share  ◄── NFS mount ┘                │
        │                                                  │
        └── bind-mounted into LXC 204 at /shared ──────────┘
```

- **NFS export** — OMV shares its 4 TB data disk over NFS. The shared folder and
  the NFS share are created once in the OMV web UI (OMV regenerates
  `/etc/exports` itself, so Ansible does not template it). The shared folder
  `homelab-share` is exported as `/export/homelab-share` (`omv_nfs_export_path`).
- **NFS mount on the host** — the `nfs_mount` action of the `proxmox` role
  mounts that export at `/mnt/homelab-share` and persists it in `/etc/fstab`.
- **Bind mount** — LXC 204 has `mp0: /mnt/homelab-share,mp=/shared`, so Jellyfin
  sees the share at `/shared`. An unprivileged LXC can't normally mount NFS
  itself, which is why the mount lives on the host and is bind-mounted in.

### Software layers

The logic is Ansible (same layout and conventions as `../cluster-automation`); a
few thin bash scripts only chain playbook runs.

```
┌────────────────────────────────────────────────────────────────────┐
│ scripts/cluster_full_provision.sh   (chains the playbooks below)   │
│                                                                    │
│ systemd: proxmox-automation.service  (role service_setup)          │
│   └─ ansible-playbook playbooks/boot.yml                           │
│        ├─ role proxmox  action=start      (OMV)                    │
│        ├─ role proxmox  action=nfs_mount  (share on host)          │
│        ├─ role proxmox  action=start      (the rest)               │
│        └─ playbooks/status_check.yml    (role status_check)        │
└────────────────────────────────────────────────────────────────────┘
```

| Playbook | Role / purpose |
|---|---|
| `boot.yml` | The boot sequence below; what the service runs. `-e nodes=` limits the guests |
| `status_check.yml` | Applies the `status_check` role: read-only checks; `make status` |
| `proxmox.yml` | One `proxmox` action at a time (`-e proxmox_action=status\|nfs_mount\|mounts\|unprivileged_lxc`) on the guests chosen with `-e nodes=` |
| `power_manager.yml` | Starts/stops/restarts guests (`-e mode=start\|stop\|restart`) chosen with `-e nodes=`, mirroring `../cluster-automation`'s `cluster_power_manager.yml` |
| `service_setup.yml` | `service_setup`: install or remove the systemd unit (`-e service_setup_mode=install\|uninstall`) |

| Role | Purpose |
|---|---|
| [`common`](roles/common/README.md) | `node_check.yml`: turns `-e nodes=` into inventory hosts through `hostname_map` |
| [`proxmox`](roles/proxmox/README.md) | Guest status and power, the NFS mount on the host, the LXC bind mount, unprivileged-LXC idmap (`proxmox_action`) |
| [`status_check`](roles/status_check/README.md) | The read-only checks: guests running, share NFS-mounted, exported by OMV, visible in the LXC |
| [`service_setup`](roles/service_setup/README.md) | Installs or removes the `proxmox-automation` systemd unit (`service_setup_mode`) |

**Nodes.** `-e nodes=omv,jellyfin` picks guests by their logical names
(`ubuntu`, `win11`, `omv`, `jellyfin`, the same names as `../cluster-automation`, defined in
`inventories/homelab/group_vars/all/node_map.yml`); leave it out for all of them.
The `common` role (`node_check.yml`) validates the names, and the playbooks turn
them into Proxmox vmids through each guest's `proxmox_vmid` in the inventory.
Modes and actions are extra-vars too: `proxmox_action`, `mode` (power actions,
via `power_manager.yml`), `service_setup_mode`.

Ansible owns both *what* the desired state is and *when* it is applied (the
systemd unit only runs `boot.yml`). Every action is idempotent: a guest that is
already running is left alone, so re-running `boot.yml` is safe.

### Boot sequence

Triggered by `systemctl start proxmox-automation` (or `make boot`). Proxmox
itself starts no guests (`onboot` is off on every guest), so this playbook is what
brings them up after a host reboot. The service is installed but not enabled by
default (see [step 8](#8-install-the-systemd-service)).

```
 systemd: proxmox-automation.service   (After: network, pve-cluster, pve-guests)
   │
   ▼
 ansible-playbook playbooks/boot.yml
   │
   ├─ play "Bring the stack up"  (hosts: hypervisor)
   │    ├─ 1. start OMV (proxmox_storage_vmids = 203)          skipped if running
   │    ├─ 2. nfs_mount: wait for OMV port 2049, then mount the export on the host
   │    │      └─ on failure: print a warning and continue (rescue)
   │    └─ 3. start the rest of proxmox_boot_order (204, 201, 202)
   │
   └─ import playbooks/status_check.yml
        ├─ every guest running?
        ├─ /mnt/homelab-share an NFS mount on the host?
        ├─ OMV exports omv_nfs_export_path?
        └─ /shared mounted in the Jellyfin LXC?   → the run fails if any check fails
```

#### Why this order

1. **OMV first** — it serves the share the host mounts.
2. **NFS mount before Jellyfin starts** — Jellyfin bind-mounts the host directory;
   if the NFS mount isn't there yet it would see the empty directory underneath, and
   mounting the share under a container that is already running can leave it hanging
   on a graceful shutdown.
3. **A failed mount doesn't stop the boot** — the Ubuntu and Windows VMs don't
   depend on it, so they still start; the status check at the end reports the
   problem and makes the run (and the service) fail loudly.
4. **Ubuntu and Windows last** — nothing depends on them, and they are the
   slowest guests to reach a usable login state.

Step 2 first waits for OMV to boot (SSH answers, up to `proxmox_nfs_wait_timeout`,
default 300 s), then up to `proxmox_nfs_service_timeout` (default 60 s) for its NFS
server. If OMV is up but the export doesn't exist yet, that second wait ends after
60 s with a message saying so, and the boot carries on. The service allows 15
minutes (`TimeoutStartSec=900`).

### Power management (`power_manager.yml`)

Starting, stopping and restarting guests by hand goes through
[`playbooks/power_manager.yml`](playbooks/power_manager.yml)
rather than `proxmox.yml`, so the power actions have their own `-e mode=` entry
point — mirroring `../cluster-automation`'s `cluster_power_manager.yml` (which
takes `-e nodes=` and `-e mode=reboot|shutdown` for the physical cluster nodes).
Same two-play shape:

1. A `localhost` play validates `mode` (`start`/`stop`/`restart`), resolves
   `-e nodes=` through `common`'s `node_check.yml`, and translates the resolved
   hosts into Proxmox vmids via each guest's `proxmox_vmid`.
2. A `hypervisor` play imports those vmids and applies the `proxmox` role with
   `proxmox_action: "{{ mode }}"`.

`proxmox.yml` keeps the other actions (`status`, `mounts`, `nfs_mount`,
`unprivileged_lxc`) — a `status`/config-only entry point that never power-cycles a
guest. `boot.yml` doesn't go through either playbook for its own starts: it
`include_role`s `proxmox` directly with `proxmox_action: start`, because it
already needs to split the target vmids into two phases (storage first, then the
rest) itself.

### Unprivileged LXC access (`unprivileged_lxc`)

The Jellyfin container (vmid 204) is an **unprivileged** LXC, the Proxmox
default. Its UID/GID `0..65535` are mapped to an unprivileged range on the host
(`100000..165535` here, granted to `root` in `/etc/subuid` and `/etc/subgid`),
so container root is host UID 100000, not 0.

A directory bind-mounted from the host (`pct set 204 -mp0 <host dir>,mp=<path>`)
is not remapped. Files owned by host `root` (0:0) belong to a UID that has no
mapping inside the container, so they show up as `nobody:nogroup` and can't be
written, even though `ls -la` on the host looks normal. With the NFS share this
means the ownership OMV presents matters: export with `all_squash,anonuid=…,anongid=…`
(OMV's NFS share options) set to IDs the container can use, or map them with a
custom `lxc.idmap`.

**What the action does.** `proxmox_action=unprivileged_lxc`
(`roles/proxmox/tasks/unprivileged_lxc.yml`) runs on the
Proxmox host for every vmid in `proxmox_unprivileged_lxc_vmids` (default `[204]`):

1. Ensures `root` has a `subuid` and `subgid` range (`proxmox_lxc_subuid_range`
   and `proxmox_lxc_subgid_range`, default `100000:65536`).
2. If `/etc/pve/lxc/<vmid>.conf` has no `lxc.idmap` line yet, appends a managed
   block with `lxc.idmap: u 0 100000 65536` and `lxc.idmap: g 0 100000 65536`.
3. Prints a reminder that the container must be restarted for the mapping to
   apply. It does not restart it.

**Limits.** That mapping is exactly the default unprivileged one, made explicit,
so on its own it does not change what the container sees on a bind mount. To
give the container real access you need to line the two sides up: either set the
ownership the share presents (above), or add a narrower custom `lxc.idmap` (plus
matching `subuid` entries) that maps a specific container UID/GID straight to a
host one. The task does neither today.

**Operational notes**
- Edit `/etc/pve/lxc/<vmid>.conf` while the container is **stopped**, and
  restart it afterwards. The action is run by hand (`-e proxmox_action=unprivileged_lxc`),
  not by `boot.yml`.
- More bind-mounted unprivileged LXCs: add their vmid to
  `proxmox_unprivileged_lxc_vmids` (role defaults or `group_vars`).
- A **privileged** container avoids the mapping altogether, but shares the
  host's UID namespace, so a container-root compromise is effectively a host-root
  compromise. Not used by default.
- `no_root_squash` on the OMV NFS share would let any client that can see the
  export act as root on it; keep the allowed clients in OMV as narrow as the
  LAN's trust allows.

## Installation and usage

How to set up and run everything in this repo, with the result you should see
after each step. The layout and conventions follow `../cluster-automation`: playbooks
in `playbooks/`, roles in `roles/`, the inventory in `inventories/homelab/`, guests
selected with `-e nodes=`, and modes as extra-vars. Run everything as root on the
Proxmox host (`192.168.100.200`), which is also the control machine, from the repo
root (where `ansible.cfg` lives). The `make` targets wrap `ansible-playbook`, and
`scripts/cluster_full_provision.sh` chains the whole setup.

> **Starting from a bare machine?** Part 0 covers installing Proxmox and creating
> the four guests, which this repo does not automate. If Proxmox and the guests
> already exist, skip to Part 1.

> **Before the share exists.** The storage path needs one manual step: OMV must
> export the share over NFS ([step 6](#6-storage-omv-export-and-the-host-mount)).
> Until then `make status` reports the share checks as failed, and `boot.yml` warns
> that the share isn't mounted but still starts every guest. Once it is set up, as
> on this host, `make status` is green and exits 0.

### Part 0 — Proxmox from scratch

This repo starts from a running Proxmox host with the four guests already created:
it starts them in order, mounts the share, checks the result and installs the
service. Installing Proxmox and creating the guests is manual (the commands below
mirror this homelab's live configuration; adapt IDs, sizes and disks to your
hardware). The whole path, in order:

| # | Step | How |
|---|------|-----|
| 0.1 | Install Proxmox VE | manual (installer) |
| 0.2 | Repositories and updates | manual |
| 0.3 | Storage | manual |
| 0.4 | ISOs and container template | manual |
| 0.5 | Create the four guests, install OMV, Jellyfin, Ubuntu and Windows | manual |
| 0.6 | Get this repo and its tools on the host | manual, a few commands |
| Part 1 | SSH keys and updates, connectivity, OMV export, boot playbook, service | Ansible (`make provision` chains most of it) |

Skip Part 1 step 2 (backups) on a host that has nothing to back up yet.

#### 0.1 Install Proxmox VE

Install Proxmox VE 9.x from the ISO onto the boot disk with the default LVM layout
(the `pve` volume group: root, swap and the `data` thin pool, which gives the
`local` directory storage and the `local-lvm` thin storage). Use hostname `pve` and
a fixed address, here `192.168.100.200/24` with gateway `192.168.100.1`. The
installer creates the bridge `vmbr0` on your NIC, which all guests use.

**Expected:** the web UI answers on `https://192.168.100.200:8006`, and on the host:

```bash
pveversion            # pve-manager/9.x ...
ip -br a | grep vmbr0 # vmbr0  UP  192.168.100.200/24
```

#### 0.2 Repositories and updates

Without a subscription, disable the enterprise repository and enable the
no-subscription one, then update:

```bash
# in /etc/apt/sources.list.d/pve-enterprise.sources (and ceph.sources): add the line  Enabled: false
cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update && apt full-upgrade -y
reboot
```

**Expected:** `apt update` finishes without 401 errors from `enterprise.proxmox.com`,
and after the reboot `uname -r` shows the new `-pve` kernel.

#### 0.3 Storage

This homelab uses three storages: `local` (directory: ISOs, container templates,
backups), `local-lvm` (the installer's thin pool, for the Ubuntu and Windows VM
disks) and `media`, a separate LVM volume group on a second disk that holds OMV's
system disk and Jellyfin's root filesystem. Create `media` on a spare disk (find it
with `lsblk`; **this wipes it**):

```bash
pvcreate /dev/sdX                  # the spare disk
vgcreate media /dev/sdX
pvesm add lvm media --vgname media --content images,rootdir
```

OMV's big data disk is not a Proxmox storage: it is passed through raw to VM 203 in
step 0.5. Note the stable path of that disk with `ls -l /dev/disk/by-id/ | grep -v part`.

**Expected:** `pvesm status` lists `local`, `local-lvm` and `media` as `active`.

#### 0.4 ISOs and container template

Upload or download into the `local` storage (web UI: `local` → ISO Images) the
OpenMediaVault ISO, the Ubuntu 24.04 ISO, the Windows 11 ISO and the `virtio-win`
driver ISO. Download the Ubuntu LXC template:

```bash
pveam update
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst   # `pveam available | grep ubuntu-24.04` for the current name
```

**Expected:** `ls /var/lib/vz/template/iso` shows the ISOs, and
`pveam list local` shows the Ubuntu template.

#### 0.5 Create the guests

Guest IDs and addresses are fixed by this repo's inventory
(`inventories/homelab/hosts`): 201 = `.201`, 202 = `.202`, 203 = `.203`,
204 = `.204`. Do **not** set `onboot` on any guest: the boot playbook starts them in
order (see step 7). The commands create the guests; the operating systems are
installed from each VM's console (web UI → guest → Console).

**VM 203, OpenMediaVault (storage).** Create it, pass the data disk through, then
install OMV from the ISO:

```bash
qm create 203 --name omv --memory 4096 --balloon 1024 --cores 2 --cpu x86-64-v2-AES \
  --ostype l26 --scsihw virtio-scsi-single --scsi0 media:64,iothread=1 \
  --ide2 local:iso/openmediavault_8.3.1-amd64.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0,firewall=1 --boot 'order=scsi0;ide2;net0'
qm set 203 --sata1 /dev/disk/by-id/ata-<your-data-disk>     # raw passthrough of the data disk
qm start 203
```

In the installer set the address `192.168.100.203`, and afterwards allow root SSH
login (OMV web UI → Services → SSH). The passed-through disk is set up as a file
system and shared folder in OMV's web UI in step 6. Once installed, detach the
ISO: `qm set 203 --ide2 none,media=cdrom`.

**LXC 204, Jellyfin (media library).** Unprivileged, with `nesting`:

```bash
pct create 204 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname jellyfin --cores 2 --memory 2048 --swap 512 --rootfs media:40 \
  --unprivileged 1 --features nesting=1 --ostype ubuntu \
  --net0 name=eth0,bridge=vmbr0,firewall=1,gw=192.168.100.1,ip=192.168.100.204/24
pct start 204
pct exec 204 -- passwd root      # set a root password (used once, by cluster-automation's bootstrap)
```

Then install Jellyfin inside it following the Jellyfin documentation. The bind mount
of the shared folder (`mp0`, appearing at `/shared`) is added later by this repo
(`make provision`, or `proxmox_action=mounts`); until then Jellyfin has no media.

**VM 201, Ubuntu (AI workloads).** Sized for the GPU workloads; install Ubuntu
24.04 from the ISO:

```bash
qm create 201 --name ubuntu-24.04 --memory 65536 --balloon 0 --cores 16 --sockets 1 --numa 1 \
  --cpu host,flags=+pdpe1gb --machine q35 --bios seabios --agent 1 --ostype l26 \
  --scsihw virtio-scsi-single --scsi0 local-lvm:500,discard=on,iothread=1 \
  --ide2 local:iso/ubuntu-24.04.4-desktop-amd64.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0,firewall=1 --boot 'order=scsi0;ide2'
qm start 201
```

Create the user that `inventories/homelab/hosts` names (`ovmi`) with an address of
`192.168.100.201`, and install `openssh-server`. GPU passthrough is optional and not
automated here: enable IOMMU in the BIOS, check `dmesg | grep -e DMAR -e IOMMU`, bind
the cards to `vfio-pci` (`lspci -nn | grep -i nvidia`, then
`options vfio-pci ids=<vendor:device>` in `/etc/modprobe.d/vfio.conf` and
`update-initramfs -u`), reboot, and attach them:
`qm set 201 --hostpci0 <bus:dev.fn>,pcie=1 --hostpci1 <bus:dev.fn>,pcie=1,rombar=0`.

**VM 202, Windows 11 (tools and management).** UEFI with a TPM, as Windows 11
requires:

```bash
qm create 202 --name windows11 --memory 16384 --cores 4 --sockets 1 --numa 1 \
  --cpu host,hidden=1 --machine q35 --bios ovmf --agent 1 --ostype win11 \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=1 --tpmstate0 local-lvm:1,version=v2.0 \
  --scsihw virtio-scsi-pci --scsi0 local-lvm:80,cache=writeback,ssd=1 \
  --ide2 local:iso/Win11_25H2_English_x64_v2.iso,media=cdrom \
  --ide0 local:iso/virtio-win-0.1.285.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0,firewall=1 --boot 'order=ide2;scsi0'
qm start 202
```

During setup load the storage driver from the `virtio-win` ISO (`vioscsi`) so the
installer sees the disk; afterwards install the guest drivers and QEMU guest agent,
set the address `192.168.100.202`, and switch the boot order to `scsi0`
(`qm set 202 --boot 'order=scsi0'`). The Windows VM is only ever powered on and off
through Proxmox by this repo.

**Expected:**

```bash
qm list     # 201 ubuntu-24.04, 202 windows11, 203 omv, all running after their installs
pct list    # 204 jellyfin  running
qm config 203 | grep -E 'sata1|onboot'   # sata1 is the passed-through disk; no onboot: 1
```

Each guest answers on its address (`ping 192.168.100.20x`). These are the guests the
inventory and `proxmox_managed_guests` describe; the only host-side setting this
repo later changes on them is the Jellyfin bind mount.

#### 0.6 Get this repo and its tools on the host

Run everything as root on the Proxmox host, which is also the control machine:

```bash
apt install -y ansible make sshpass git
git clone <this-repo> proxmox-automation
git clone <cluster-automation-repo> cluster-automation     # sibling directory: SSH keys and base configuration
cd proxmox-automation && make collections
```

**Expected:** `ansible --version` reports ansible-core 2.15 or newer and
`make collections` ends without errors. Then continue with Part 1 from step 1
(skip step 2): set up SSH access with `../cluster-automation` (step 3), create OMV's
NFS export (step 6.1), and run `make provision` for the rest, or follow steps 4–8
one by one.

### Part 1 — Install and configure

Steps 1–5 are safe (read-only or preparatory). Step 6 sets up the shared storage.
Steps 7–8 change how the host boots.

#### 1. Prerequisites

You need `ansible-core` >= 2.15, `make` and the two Ansible collections this repo
uses. On the Proxmox host they are already installed except possibly the
collections:

```bash
git clone <this-repo> proxmox-automation && cd proxmox-automation
make collections
ansible-galaxy collection list | grep -E 'ansible.posix|community.general'
```

**Expected:** both collections are listed (`ansible.posix` >= 1.5.0,
`community.general` >= 8.0.0).

#### 2. Back up first

The playbooks edit real guest and host configuration. Before the first
non-read-only run:

```bash
tar czf /root/pve-config-$(date +%F).tgz /etc/pve          # guest + storage configs
vzdump 204 --mode stop --storage local                      # Jellyfin LXC (briefly stops it)
```

**Expected:** a `pve-config-<date>.tgz` in `/root` and a finished `vzdump` task
for CT 204. Snapshots aren't an option: the `media` storage is plain LVM (no
snapshots) and VM 203 has a raw 4 TB disk passed through. Back up OMV's own
configuration from its web UI, and don't `vzdump` 203 without `backup=0` on the
passed-through disk (it would try to copy all 4 TB).

#### 3. SSH access and base configuration (cluster-automation)

SSH keys, sshd settings, system updates and base packages for the Proxmox host
and all guests are done by the sibling `../cluster-automation` repo, which treats
them as one small cluster (inventory `inventories/pve_linux`). Run everything in
this step from the `cluster-automation` directory. Its
[`docs/pve_linux.md`](../cluster-automation/docs/pve_linux.md) has the full
reference.

| Node (`-e nodes=`) | What | Address | Connection |
|---|---|---|---|
| `pve` | Proxmox host (also the control machine) | 192.168.100.200 | local, as root, no `sudo` |
| `ubuntu` | Ubuntu VM 201 | 192.168.100.201 | SSH as `ovmi`, with sudo |
| `omv` | OpenMediaVault VM 203 | 192.168.100.203 | SSH as root |
| `jellyfin` | Jellyfin LXC 204 | 192.168.100.204 | SSH as root |

The Windows VM (`win11`, 202) is listed in the inventory but never targeted: these
playbooks are `apt`/OpenSSH based. Omit `-e nodes=` to act on all four.

##### 3.1 Prerequisites

```bash
openssl rand -base64 32 > ~/.vault_pass.txt && chmod 600 ~/.vault_pass.txt   # vault passphrase; ansible.cfg reads it
apt install sshpass                                                          # needed for password login in bootstrap mode
ansible-vault create inventories/pve_linux/group_vars/all/vault.yml
#   vault_pve_password / vault_ubuntu_password / vault_omv_password / vault_jellyfin_password
```

Each guest must run `openssh-server` and accept password login for its user until
the key is installed. A stock LXC template ships `PermitRootLogin without-password`,
so `bootstrap` cannot log in as root there (`Permission denied (publickey,password)`).
For such a guest (this was needed for `jellyfin`), install the key from the Proxmox
host instead, then run `config` mode for it:

```bash
pct exec 204 -- bash -c 'apt-get install -y openssh-server && mkdir -p /root/.ssh'
pct push 204 ~/.ssh/id_ed25519_cluster.pub /root/.ssh/authorized_keys --perms 0600
```

##### 3.2 The `ssh_config` playbook

`playbooks/ssh_config.yml` runs on `localhost` and needs `-e ssh_mode=bootstrap`
or `-e ssh_mode=config` (any other value fails the first task). It:

1. validates `ssh_mode`, then checks the Ansible version and that the
   `community.crypto` and `kubernetes.core` collections are installed;
2. resolves `-e nodes=` against `hostname_map` (`group_vars/all/node_map.yml`) into
   the target list (all four nodes by default);
3. runs the `ssh_config` role, which **always** first creates the controller key pair
   `~/.ssh/id_ed25519_cluster` (ed25519) if it doesn't exist, then does one of:

| Mode | What it does on each target |
|---|---|
| `bootstrap` | Logs in **with the password** from the vault and appends the controller public key to `authorized_keys` of the node's `ansible_user` (creating `~/.ssh` if needed). Run it once per new node. |
| `config` | Steady state, over the key: makes sure `~/.ssh` and `/etc/ssh/sshd_config.d/` exist, removes the stale `99-cluster.conf`, writes `/etc/ssh/sshd_config.d/10-cluster.conf` (`PasswordAuthentication yes`, `PubkeyAuthentication yes`, `PermitRootLogin yes`), and restarts `ssh` only on nodes whose config actually changed. |

Optional flags: `-e ssh_cleanup=true` removes the targets' old entries from
`~/.ssh/known_hosts` first (use after re-creating a guest), and `-e debug=true`
prints the resolved target list.

```bash
cd ../cluster-automation
INV="-i inventories/pve_linux/hosts"
ansible-playbook $INV playbooks/ssh_config.yml -e ssh_mode=bootstrap     # first run: install the key everywhere
ansible-playbook $INV playbooks/ssh_config.yml -e ssh_mode=config        # then write the sshd drop-in
ansible-playbook $INV playbooks/ssh_config.yml -e ssh_mode=bootstrap -e nodes=jellyfin   # one node only
```

**Expected:** both runs end with `failed=0` and `unreachable=0`. The first run
creates the key pair; re-running is safe, and nodes that are already configured
report no changes. Verify:

```bash
ls -l ~/.ssh/id_ed25519_cluster*                                          # private (0600) and .pub exist
for t in root@192.168.100.203 root@192.168.100.204 ovmi@192.168.100.201; do
  ssh -i ~/.ssh/id_ed25519_cluster -o IdentitiesOnly=yes -o BatchMode=yes $t hostname
done                                                                      # prints openmediavault, jellyfin, ubuntu with no prompt
ssh -i ~/.ssh/id_ed25519_cluster root@192.168.100.204 cat /etc/ssh/sshd_config.d/10-cluster.conf   # after config mode
```

`config` mode deliberately leaves password and root login enabled on every node it
touches (the same policy as the other targets). The Proxmox host and OMV already
allow both, so the drop-in changes little there.

##### 3.3 Base configuration: `cluster_update`

```bash
ansible-playbook $INV playbooks/cluster_update.yml --check --diff       # preview first
ansible-playbook $INV playbooks/cluster_update.yml -e nodes=ubuntu,jellyfin
```

Per node, one at a time: removes the unwanted packages, runs `apt dist-upgrade`,
installs `vim`, `net-tools`, `python3` and `python3-pip`, and copies a `.vimrc` to
the login user's home. It sets each host's hostname and `/etc/hosts` to the
inventory name, except on `pve` and `omv` (`cluster_update_manage_hosts=false`:
Proxmox needs its node name to resolve to its LAN address, and OMV manages both
itself). Notes: it ignores `-e mode=…` (use `--check` for a dry run); on `pve` the
upgrade installs new Proxmox kernels and needs a reboot, which stops every guest,
so run `-e nodes=pve` on its own at a time you choose. **Expected:** `failed=0`
for every node.

This repo's playbooks use the same key by default
(`ansible_ssh_private_key_file` in `inventories/homelab/group_vars/all/main.yml`), so nothing else needs
configuring here.

#### 4. Check the inventory and connectivity

Edit [`inventories/homelab/hosts`](inventories/homelab/hosts)
so every `ansible_host` and `ansible_user` matches reality, and review
`inventories/homelab/group_vars/all/{main,node_map}.yml`. Then:

```bash
make ping        # ansible 'all:!windows' -m ping (Windows is skipped: WinRM)
```

**Expected:** four `SUCCESS` blocks, each with `"ping": "pong"`:

```
pve | SUCCESS => { ... "ping": "pong" }
ubuntu | SUCCESS => { ... "ping": "pong" }
omv | SUCCESS => { ... "ping": "pong" }
jellyfin | SUCCESS => { ... "ping": "pong" }
```

`UNREACHABLE` means the key isn't installed on that host, or `ansible_user` /
`ansible_host` is wrong.

#### 5. First read-only run

```bash
make status      # ansible-playbook -i inventories/homelab/hosts playbooks/status_check.yml
```

**Expected** on a fresh setup. The share checks fail until step 6, so the run ends with
`failed=1` for `pve` and `omv` and `make` exits non-zero (a deprecation
warning about the `yaml` callback is harmless):

```
OK    ubuntu (vmid 201): running
OK    win11 (vmid 202): running
OK    omv (vmid 203): running
OK    jellyfin (vmid 204): running
FAIL  /mnt/homelab-share is not an NFS mount on the Proxmox host
FAIL  OMV does not export /export/homelab-share over NFS
OK    /shared is mounted in the Jellyfin LXC
```

The last line is `OK` because LXC 204 already bind-mounts the (empty) host
directory; the host check is the one that proves the share is really NFS.

#### 6. Storage: OMV export and the host mount

The data lives on OMV's 4 TB disk, which is passed through to VM 203. The share
reaches Jellyfin in three hops, and only the first is manual:

1. **OMV exports it over NFS** (once, in the OMV web UI — OMV regenerates
   `/etc/exports` itself, so Ansible does not template it). This host's OMV already has
   the data disk mounted and a shared folder named `homelab-share` (on a new OMV, first
   create the file system and a shared folder in **Storage → File Systems / Shared
   Folders**). In **Services → NFS**: on the *Settings* tab tick **Enabled** and save;
   on the *Shares* tab add a share for `homelab-share`, client `192.168.100.200`
   (the Proxmox host) or the LAN `192.168.100.0/24`, permission read/write; then apply
   the pending changes. The **Client** must be an IP address or network: a name that
   doesn't resolve (an OMV user name such as `smb-user` was tried once) makes the
   export fail silently, and `showmount` lists nothing.
   A shared folder named `homelab-share` is exported as `/export/homelab-share`, which
   is `omv_nfs_export_path` in `group_vars/all/main.yml`; change that variable if you
   name it differently. From the Proxmox host:

   ```bash
   showmount -e 192.168.100.203
   ```

   **Expected:** the export list shows the share and OMV's NFSv4 root above it:

   ```
   Export list for 192.168.100.203:
   /export               192.168.100.0/24
   /export/homelab-share 192.168.100.0/24
   ```

   (Your client column shows what you entered.) If the list is empty, check
   `journalctl -u nfs-server` on OMV for `Failed to resolve <client>`.

2. **Ansible mounts it on the Proxmox host** at `/mnt/homelab-share`
   (`homelab_share_root`) and writes it to `/etc/fstab`:

   ```bash
   ansible-playbook playbooks/proxmox.yml -e proxmox_action=nfs_mount
   findmnt /mnt/homelab-share
   ```

   **Expected:** the play ends `failed=0`, and `findmnt` shows
   `192.168.100.203:/homelab-share` with type `nfs4`, and `ls /mnt/homelab-share` lists
   the share's folders. The host mounts `/homelab-share`, not `/export/homelab-share`:
   OMV exports over NFSv4 with `/export` as the root, so a v4 mount path is relative to
   it (`mount.nfs: … No such file or directory` means the full path was used). The role
   derives it from `omv_nfs_export_path`. The host also writes the mount to `/etc/fstab`
   (`nfsvers=4.2,_netdev,nofail`). Re-running changes nothing, and the role never
   touches the share's own ownership or mode.

3. **LXC 204 sees it** through its bind mount (`mp0: /mnt/homelab-share,mp=/shared`,
   already in its config; `proxmox_action=mounts` re-applies it). A container that
   was already running when the share was mounted picks it up, but it can then hang
   on a *graceful* shutdown (its systemd stops at `Failed unmounting shared.mount`),
   so restart it once so it starts with the share already mounted. The restart
   forces the stop after `proxmox_shutdown_timeout` (60 s) if the container hangs:

   ```bash
   ansible-playbook playbooks/power_manager.yml -e nodes=jellyfin -e mode=restart
   pct exec 204 -- findmnt /shared     # 192.168.100.203:/homelab-share  nfs4
   pct exec 204 -- ls /shared
   ```

   If a container is already stuck stopping (`pct status` says `running` for minutes and
   the PVE task ends `unexpected status`), recover it with `pct stop 204 && pct start 204`.

   **Expected:** the folder's contents (on this host `media` and `work`). Point
   Jellyfin's libraries at `/shared/...`. Files show up as `nobody:nogroup` when their
   owner on OMV (here uid 1000) has no mapping in the unprivileged container; they are
   readable but not writable there. If Jellyfin needs to write, or can't read, see
   [Unprivileged LXC access](#unprivileged-lxc-access-unprivileged_lxc)
   (set the ownership in OMV's NFS share options, e.g. `all_squash,anonuid=…,anongid=…`).

**Expected when done:** `make status` reports every check `OK`, ends with
`failed=0` for every host, and exits 0:

```
OK    /mnt/homelab-share is an NFS mount on the Proxmox host
OK    OMV exports /export/homelab-share over NFS
OK    /shared is mounted in the Jellyfin LXC
```

#### 7. Boot order

Starting guests after a host reboot is this repo's job, not Proxmox's. No guest
has `onboot` set (VM 203 had it; it was switched off with `qm set 203 --onboot 0`),
so Proxmox's `pve-guests.service` starts nothing. Until the service from step 8 is
installed and enabled, **no guest starts by itself after a reboot** — run
`make boot` (or `ansible-playbook playbooks/power_manager.yml -e mode=start`).
Keep `onboot` off on every guest so the two don't race. To hand startup back to
Proxmox instead: `qm set 203 --onboot 1 --startup order=1,up=60` and don't enable
the service.

**Expected:** `grep -H '^onboot' /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf`
shows no `onboot: 1`.

#### 8. Install the systemd service

The boot sequence is `playbooks/boot.yml`: start OMV, mount the share on the host,
start the other guests, then run the status check. Preview it, then run it:

```bash
make boot-check      # preview (--check --diff); with step 6 undone, the NFS wait ends after 60 s with a warning
make boot
```

**Expected:** the storage guest and the rest are `skipped` when already running
(`changed=0`); with the step 6 export in place the mount task reports `ok` or
`changed` and the status check ends `failed=0`. Without the export you get the
warning `the NFS share from OMV is not mounted on the host; starting the other
guests anyway`, the remaining guests still start, and the run ends with the two
share checks failing (exit non-zero).

Then install the service:

```bash
make install      # ansible-playbook playbooks/service_setup.yml -e service_setup_mode=install
```

**Expected:** the play ends `ok=6 changed=1 failed=0` (`changed=0` when re-run),
and the unit is installed but **not enabled**: `systemctl is-enabled
proxmox-automation` prints `disabled`, and `systemctl cat proxmox-automation`
shows `ExecStart=/usr/bin/env ansible-playbook playbooks/boot.yml` with
`WorkingDirectory=<repo>`. Nothing is copied: the service runs the
playbooks in this checkout in place, so edits (inventory included) apply
immediately — but don't delete or move the checkout; if you do, re-run
`make install`.

Enable and start it (optional overrides go in
`/etc/proxmox-automation/proxmox-automation.env` as `VAR=value` lines):

```bash
make install ARGS="-e service_setup_enable=true"    # or: systemctl enable --now proxmox-automation
journalctl -u proxmox-automation -f
```

**Expected** (not run on this host yet): the command returns when `boot.yml`
finishes, `systemctl status proxmox-automation` shows `active (exited)` (the
unit is a one-shot that stays "active"), and the journal ends with a `PLAY RECAP`.
After a host reboot the guests come up in order 203, 204, 201, 202 and
`make status` passes.

#### All of it in one go: `make provision`

Once the OMV export exists (step 6.1), `scripts/cluster_full_provision.sh` (also
`make provision`) chains the rest, one `ansible-playbook` call per phase with a
timing table at the end, like `../cluster-automation`'s script of the same name:

1. start the storage VM (`-e nodes=omv`)
2. mount the NFS share on the host (`proxmox_action=nfs_mount`)
3. configure the LXC bind mount, then restart Jellyfin to apply it
4. start the remaining guests
5. install the systemd service (not enabled)
6. run the status check

**Expected:** every phase runs, the time table lists the six stages, and the run
ends with `Done.`; a failing phase stops the run and exits non-zero. Guests that are
already running are left alone, but phase 3 restarts Jellyfin, which briefly
interrupts playback. Without the export, phase 2 stops the run after
`proxmox_nfs_service_timeout` seconds (60) with a message saying OMV is up but not
serving NFS.

### Part 2 — Day-to-day usage

#### Status check (read-only)

```bash
make status          # ansible-playbook -i inventories/homelab/hosts playbooks/status_check.yml
```

Applies the `status_check` role ([`roles/status_check`](roles/status_check/README.md)):
it checks that every guest in `proxmox_managed_guests` is running, that the share is
NFS-mounted on the Proxmox host, that OMV exports `omv_nfs_export_path`, and that
the Jellyfin LXC has `jellyfin_share_mount_point` mounted. It changes nothing.
**Expected:** an `OK …` line per check and exit 0 only if all pass; a failing
check shows a `FAIL …` line, and the other checks still run (see step 5 for
today's output).

`ansible-playbook playbooks/proxmox.yml` (default action `status`) only lists each
guest's state and never fails:

```bash
ansible-playbook playbooks/proxmox.yml -e nodes=omv,jellyfin     # just these guests
```

#### Boot sequence

```bash
make boot          # start OMV, mount the share, start the rest, status check
make boot-check    # the same as a dry run
```

**Expected:** see step 8. Guests that are already running are skipped, so it is
safe to re-run. The systemd service runs exactly this playbook.

#### Selecting guests and modes

Like `../cluster-automation`, playbooks take `-e nodes=` (comma-separated logical
names: `ubuntu`, `win11`, `omv`, `jellyfin`; omit it for all of them) and a mode
or action as an extra-var:

| Playbook | Parameters |
|---|---|
| `proxmox.yml` | `-e nodes=…` and `-e proxmox_action=status\|nfs_mount\|mounts\|unprivileged_lxc` |
| `power_manager.yml` | `-e nodes=…` and `-e mode=start\|stop\|restart` |
| `boot.yml` | `-e nodes=…` (omit `omv` to skip the storage steps) |
| `service_setup.yml` | `-e service_setup_mode=install\|uninstall` (`service_setup_enable`, `service_setup_purge`) |
| `status_check.yml` | none |

An unknown node or mode fails immediately with the list of valid values. Add
`-e debug=true` to any of them to print the resolved nodes/vmids (`proxmox.yml`,
`power_manager.yml` and `boot.yml` all print the vmids they
resolved; the shared `common` role prints the node resolution itself — see
[`roles/common/README.md`](roles/common/README.md)).

#### Single actions

```bash
ansible-playbook playbooks/power_manager.yml -e mode=start   [-e nodes=jellyfin]
ansible-playbook playbooks/power_manager.yml -e mode=stop    [-e nodes=jellyfin]
ansible-playbook playbooks/power_manager.yml -e mode=restart -e nodes=jellyfin
ansible-playbook playbooks/proxmox.yml -e proxmox_action=nfs_mount       # mount OMV's share on the host
ansible-playbook playbooks/proxmox.yml -e proxmox_action=mounts          # (re)configure the LXC bind mount
ansible-playbook playbooks/proxmox.yml -e proxmox_action=unprivileged_lxc
```

`start` follows `proxmox_boot_order` (203, 204, 201, 202) and skips guests that are
already running; `stop` is the reverse with a graceful `qm/pct shutdown` (forced after `proxmox_shutdown_timeout`, 60 s, if the guest hangs) and skips
stopped guests. **Expected:** the play ends `failed=0` and `make status` shows the
guest in its new state. These affect real guests — scope them with
`-e nodes=` and confirm first (nodes are `ubuntu`, `win11`, `omv`, `jellyfin`). `mounts` uses `pct set`, which replaces
the container's `mp0`, and both `mounts` and `unprivileged_lxc` change a
container's configuration (restart it afterwards).

#### Configuration

Settings are Ansible variables: the defaults are in
`roles/proxmox/defaults/main.yml` and `roles/service_setup/defaults/main.yml`,
and the environment-specific ones (guests, boot order, share paths, node names) in
`inventories/homelab/group_vars/all/`.
Override one for a run with `-e`, for example:

```bash
ansible-playbook playbooks/boot.yml -e proxmox_nfs_wait_timeout=30
```

The SSH key comes from `ansible_ssh_private_key_file` in `group_vars/all/main.yml`
(`~/.ssh/id_ed25519_cluster`, or the path in the `HOMELAB_SSH_KEY` environment
variable). For the service, put `VAR=value` lines in
`/etc/proxmox-automation/proxmox-automation.env` (the unit reads it if it
exists), then `systemctl restart proxmox-automation`.

#### Linting

```bash
make lint        # ansible-lint (production profile) on the repo, then shellcheck on scripts/
```

**Expected:** `Passed: 0 failure(s), 0 warning(s) … Profile 'production' was
required, and it passed.` and exit 0. Run it after any change to a playbook or role.

## Uninstall

```bash
make uninstall                                       # removes the service; keeps /etc/proxmox-automation
make uninstall ARGS="-e service_setup_purge=true"  # also removes /etc/proxmox-automation
```

**Expected:** the play ends `failed=0`; the service is stopped and disabled and the
unit file is gone (`systemctl cat proxmox-automation` reports it can't be found).
The repo checkout is not touched, and no VM or LXC is stopped or changed (the unit
has no `ExecStop`). It is safe to re-run (`changed=0`).

## License

[MIT](LICENSE)

## Maintainer

**Author:** Ovidiu
