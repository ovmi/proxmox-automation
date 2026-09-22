#!/usr/bin/env bash
# Full homelab provisioning: starts OMV, mounts its NFS share on the Proxmox host,
# configures the Jellyfin LXC's bind mount of that share and restarts the container
# to apply it, starts the remaining guests, installs the systemd service that runs
# the boot playbook at startup, and finishes with the read-only status check. See
# docs/usage.md for the narrative and the one-time OMV export this depends on.
#
# Prerequisites: SSH access to every guest (../cluster-automation ssh_config), and
# the NFS share exported from OMV's web UI (docs/usage.md step 6) -- phase 2 waits
# for it and stops the run if it never appears.
#
# Safe to re-run: guests already running are left alone. Phase 3b restarts Jellyfin,
# which briefly interrupts playback.
#
# Usage: ./scripts/cluster_full_provision.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# OMV first: it serves the share the host mounts in the next phase.
run_phase "Phase 1: start the storage VM" \
  ansible-playbook -i "$INVENTORY" playbooks/power_manager.yml \
  -e nodes="$STORAGE" -e mode=start

# Waits for OMV's NFS port, mounts the export at /mnt/homelab-share and persists it
# in /etc/fstab.
run_phase "Phase 2: mount the NFS share on the Proxmox host" \
  ansible-playbook -i "$INVENTORY" playbooks/proxmox.yml \
  -e proxmox_action=nfs_mount

# Points the Jellyfin LXC's mp0 at the host mount (appears at /shared).
run_phase "Phase 3a: configure the LXC bind mount" \
  ansible-playbook -i "$INVENTORY" playbooks/proxmox.yml \
  -e proxmox_action=mounts

# Restart applies the bind-mount configuration and gives the container a clean mount
# of the share (starts it if it is stopped). The shutdown is forced after
# proxmox_shutdown_timeout, since a container that was already running when the
# share was mounted can hang on a graceful stop.
run_phase "Phase 3b: restart Jellyfin to apply the bind mount" \
  ansible-playbook -i "$INVENTORY" playbooks/power_manager.yml \
  -e nodes=jellyfin -e mode=restart

# Nothing depends on the Ubuntu and Windows VMs, so they start last.
run_phase "Phase 4: start the remaining guests" \
  ansible-playbook -i "$INVENTORY" playbooks/power_manager.yml \
  -e nodes="$OTHERS" -e mode=start

# Installs (does not enable) the systemd unit that runs playbooks/boot.yml; add
# -e service_setup_enable=true here to enable it.
run_phase "Phase 5: install the systemd service" \
  ansible-playbook -i "$INVENTORY" playbooks/service_setup.yml \
  -e service_setup_mode=install

# Every guest running, the share NFS-mounted on the host, exported by OMV and
# visible in the Jellyfin LXC.
run_phase "Phase 6: status check" \
  ansible-playbook -i "$INVENTORY" playbooks/status_check.yml

print_time_table

phase "Done."
