# Role: common

Shared pre-task utilities used by the playbooks, the same `nodes` handling as `../cluster-automation`.

## `node_check.yml`

Normalises the `nodes` extra-var, validates it against `hostname_map` (`inventories/homelab/group_vars/all/node_map.yml`) and sets:

| Fact | Meaning |
|------|---------|
| `nodes_list` | logical node names: `-e nodes=omv,jellyfin` split into a list, or every key of `hostname_map` when `nodes` is not given |
| `resolved_hosts` | the matching inventory hostnames |
| `node_host_map` | node name → inventory hostname |

An unknown node fails the run with the list of valid names. Nodes here are the guests the Proxmox host manages (`ubuntu`, `win11`, `omv`, `jellyfin`). `-e debug=true` prints what was selected.

Usage (from a `localhost` play):

```yaml
- name: Check parameters for valid nodes
  ansible.builtin.include_role:
    name: common
    tasks_from: node_check.yml
```
