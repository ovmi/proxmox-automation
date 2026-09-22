# Role: status_check

Read-only status check of the whole stack. Each host runs the checks that belong to it; every check prints an `OK …` or `FAIL …` line, and the run fails if any check fails. Nothing is changed. Applied by `playbooks/status_check.yml` (`make status`, and the last step of `playbooks/boot.yml`).

## Task flow

`main.yml` includes one task file per inventory group the host belongs to:

| Task file | Runs on | Checks |
|-----------|---------|--------|
| `proxmox.yml` | `proxmox` | every guest in `proxmox_managed_guests` is running (`qm status` / `pct status`), and `homelab_share_root` is an NFS mount on the Proxmox host |
| `omv.yml` | `omv` | OMV exports `omv_nfs_export_path` over NFS (`showmount -e localhost`) |
| `jellyfin.yml` | `jellyfin` | `jellyfin_share_mount_point` is mounted in the LXC (`mountpoint -q`) |

The read-only queries use `check_mode: false`, so the checks also give real results under `--check` (`make boot-check`). The Proxmox host's two checks are ignored individually so both always run, then a final task fails if either did.

## Variables

The role has no defaults of its own; it reads inventory variables:

| Variable | Defined in | Meaning |
|----------|-----------|---------|
| `proxmox_managed_guests` | `inventories/homelab/group_vars/all/main.yml` | guests to check (`vmid`, `type`, `name`) |
| `homelab_share_root` | same | where the share is mounted on the Proxmox host |
| `omv_nfs_export_path` | same | path OMV exports over NFS |
| `jellyfin_share_mount_point` | same | where the share appears inside the Jellyfin LXC |

## Usage

```bash
make status        # or: ansible-playbook -i inventories/homelab/hosts playbooks/status_check.yml
```
