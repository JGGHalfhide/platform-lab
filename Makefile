.PHONY: host up down verify

host:
	./scripts/host-bootstrap.sh

up: host
	cd terraform && terraform init -upgrade && terraform apply -auto-approve
	cd ansible && ansible-playbook -i inventory.ini site.yml

down:
	cd terraform && terraform destroy -auto-approve

verify:
	kubectl --kubeconfig kubeconfig get nodes -o wide
