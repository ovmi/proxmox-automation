# Role: proxmox

Runs on the Proxmox host (`pve`) and owns everything that has to happen at the hypervisor layer: guest status, power lifecycle, mounting OMV's NFS share on the host, the LXC bind mount that exposes it to Jellyfin, and unprivileged-LXC UID/GID mapping.

## Task flow

| Task file | Runs when `proxmox_action` is | Description |
|-----------|-------------------------------|--------------|
| `status.yml` | `status` (default) | `qm status` / `pct status` for every target vmid (report only; `playbooks/status_check.yml` is the checking version) |
| `power.yml` + `_power_guest.yml` | `start`, `stop`, `restart` | Power-cycles guests in `proxmox_boot_order` / `proxmox_shutdown_order`; a start of a running guest (or a shutdown of a stopped one) is skipped |
| `nfs_mount.yml` | `nfs_mount` | Waits for OMV to boot and answer NFS, then mounts the export at `proxmox_nfs_mount_point` and persists it in `/etc/fstab` |
| `mounts.yml` | `mounts` | Creates the host share directory and configures the LXC bind mount (`pct set -mp0 …`) |
| `unprivileged_lxc.yml` | `unprivileged_lxc` | Grants subuid/subgid range, writes `lxc.idmap` for bind-mount access |

## Variables

See `defaults/main.yml` for the full list. Key ones:

| Variable | Default | Description |
|----------|---------|--------------|
| `proxmox_action` | `status` | Dispatches which task file runs |
| `proxmox_target_vmids` | all managed guests | The vmids an action applies to; `playbooks/proxmox.yml` sets it from `-e nodes=omv,jellyfin` |
| `proxmox_shutdown_timeout` | `60` | Seconds a graceful `qm/pct shutdown` gets before it is forced (`--forceStop`), so a hung guest cannot stall a `stop`/`restart` |
| `proxmox_power_parallel` | `false` | `false` = one guest at a time, in order; `true` = fire-and-forget, no completion wait |
| `proxmox_nfs_server` | OMV's `ansible_host` | NFS server address |
| `proxmox_nfs_export` | `omv_nfs_export_path` without the `/export` NFSv4 pseudo-root (`/homelab-share`) | Path the host mounts; OMV exports over NFSv4 relative to `/export` |
| `proxmox_nfs_mount_point` | `homelab_share_root` (`/mnt/homelab-share`) | Where the share is mounted on the host |
| `proxmox_nfs_mount_options` | `nfsvers=4.2,_netdev,nofail` | Mount options (also written to `/etc/fstab`) |
| `proxmox_nfs_wait_timeout` | `300` | Seconds to wait for OMV to boot (SSH answers) |
| `proxmox_nfs_service_timeout` | `60` | Then seconds to wait for its NFS server (port 2049); fails after this if the export was never created |
| `proxmox_mounts` | bind mount of the host share into LXC 204 at `/shared` | LXC bind mount definitions |
| `proxmox_unprivileged_lxc_vmids` | `[204]` | LXCs to idmap for bind-mount access |

## Usage

```bash
# Status of every managed guest (report only)
ansible-playbook playbooks/proxmox.yml -e proxmox_action=status

# Start / stop / restart guests: playbooks/power_manager.yml -e mode=…
# (skips guests already in the target state). Scope to some guests: nodes are
# ubuntu, win11, omv, jellyfin.
ansible-playbook playbooks/power_manager.yml -e mode=start
ansible-playbook playbooks/power_manager.yml -e nodes=jellyfin -e mode=restart

# Mount OMV's NFS share on the host, then (re)configure the LXC bind mount
ansible-playbook playbooks/proxmox.yml -e proxmox_action=nfs_mount
ansible-playbook playbooks/proxmox.yml -e proxmox_action=mounts
ansible-playbook playbooks/proxmox.yml -e proxmox_action=unprivileged_lxc
```

`playbooks/boot.yml` chains these actions (start OMV, `nfs_mount`, start the rest) with `include_role`. See [`README.md`](../../README.md#power-management-power_manageryml) for why start/stop/restart have their own playbook.

## Notes

- The NFS export itself is created in the OMV web UI (OMV regenerates `/etc/exports`, so a templated file would be overwritten). Until it exists, `nfs_mount` fails after the wait; `boot.yml` reports that and carries on.
- The LXC bind mount only exposes the host mount point to the container. Start Jellyfin (204) after the share is mounted, otherwise it sees the empty directory underneath. A change to a running container's mount points applies after it is restarted.
- `mounts.yml` uses `pct set`, which replaces the container's `mp0`; check `pct config 204` first if it already has a different bind mount.
- `unprivileged_lxc.yml` edits `/etc/pve/lxc/<vmid>.conf` directly (no Ansible module covers `lxc.idmap`); the target container must be **stopped** for the edit to be safe and must be **restarted** afterward to pick up the new mapping.
- See [`README.md`](../../README.md#unprivileged-lxc-access-unprivileged_lxc) for why UID mapping matters for bind-mounted media shares.
