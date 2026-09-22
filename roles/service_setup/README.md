# Role: service_setup

Installs and removes the `proxmox-automation` systemd service on the machine that runs the playbook (the Proxmox host). The unit runs `ansible-playbook playbooks/boot.yml` from this checkout in place — nothing is copied. Driven by `playbooks/service_setup.yml` with `-e service_setup_mode=install|uninstall`.

## Task flow

| Task file | Runs when `service_setup_mode` is | Description |
|-----------|-------------------------------------|-------------|
| `install.yml` | `install` | Checks the checkout has `playbooks/boot.yml`, creates `/etc/proxmox-automation/`, renders `templates/proxmox-automation.service.j2` to `/etc/systemd/system/`, reloads systemd, and optionally enables and starts the service |
| `uninstall.yml` | `uninstall` | Stops and disables the service if the unit exists, removes the unit, reloads systemd, and optionally removes `/etc/proxmox-automation/` |

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `service_setup_mode` | `none` | Required: `install` or `uninstall` (the playbook validates it) |
| `service_setup_repo_root` | one level above `playbook_dir` | Checkout the service runs from |
| `service_setup_enable` | `false` | `install`: enable and start the service now |
| `service_setup_purge` | `false` | `uninstall`: also remove `service_setup_config_dir` |
| `service_setup_unit` | `/etc/systemd/system/proxmox-automation.service` | Where the unit is written |
| `service_setup_config_dir` | `/etc/proxmox-automation` | Directory for an optional `proxmox-automation.env` of `VAR=value` overrides |

## Usage

```bash
ansible-playbook playbooks/service_setup.yml -e service_setup_mode=install                               # installed, not enabled
ansible-playbook playbooks/service_setup.yml -e service_setup_mode=install -e service_setup_enable=true  # enable + start now
ansible-playbook playbooks/service_setup.yml -e service_setup_mode=uninstall -e service_setup_purge=true
```

Run as root. If you move the checkout, run the install again.
