INVENTORY := inventories/homelab/hosts

.PHONY: collections
collections:
	ansible-galaxy collection install -r ansible/collections/requirements.yml

.PHONY: ping
ping:
	ansible 'all:!windows' -i $(INVENTORY) -m ping

.PHONY: lint
lint:
	ansible-lint
	shellcheck -x -P SCRIPTDIR scripts/*.sh

.PHONY: status
status:
	ansible-playbook -i $(INVENTORY) playbooks/status_check.yml

.PHONY: boot
boot:
	ansible-playbook -i $(INVENTORY) playbooks/boot.yml

.PHONY: boot-check
boot-check:
	ansible-playbook -i $(INVENTORY) playbooks/boot.yml --check --diff

.PHONY: provision
provision:
	scripts/cluster_full_provision.sh

# Both need root (they write /etc/systemd) and take extra ansible-playbook flags via
# ARGS, e.g. make install ARGS="-e service_setup_enable=true".
.PHONY: install
install:
	ansible-playbook -i $(INVENTORY) playbooks/service_setup.yml -e service_setup_mode=install $(ARGS)

.PHONY: uninstall
uninstall:
	ansible-playbook -i $(INVENTORY) playbooks/service_setup.yml -e service_setup_mode=uninstall $(ARGS)
