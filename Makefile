ENV_DIR ?= environments/demo
TF      := terraform -chdir=$(ENV_DIR)

.PHONY: help fmt validate lint scan test init plan apply destroy smoke gameday gameday-fault restore-drill

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

fmt: ## Format all Terraform
	terraform fmt -recursive

validate: ## Validate the demo environment (no backend)
	$(TF) init -backend=false -input=false >/dev/null && $(TF) validate

lint: ## tflint across all modules
	tflint --init && tflint --recursive --config "$(CURDIR)/.tflint.hcl"

scan: ## checkov IaC security scan
	checkov --config-file .checkov.yaml -d .

test: ## API unit tests
	python3 -m unittest discover -s tests -v

init: ## Init with backend.hcl
	$(TF) init -backend-config=backend.hcl

plan: ## Plan
	$(TF) plan -out=tfplan

apply: ## Apply the saved plan
	$(TF) apply tfplan

destroy: ## Destroy (set deletion_protection = false and apply first)
	$(TF) destroy

smoke: ## Both regions healthy + replication lag
	./scripts/smoke-test.sh

gameday: ## Regional outage game day (measures RTO/RPO, fails back)
	./scripts/gameday.sh --mode throttle

gameday-fault: ## Health-check-only fault game day
	./scripts/gameday.sh --mode fault

restore-drill: ## Restore the newest DR-vault backup to a scratch table
	./scripts/restore-drill.sh
