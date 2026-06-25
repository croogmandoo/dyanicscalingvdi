# Convenience wrappers around the scripts. `make help` lists targets.
# Everything reads ./.env (copy from .env.example first).

SHELL := /bin/bash

.PHONY: help preflight proxmox-setup agent-template server-template \
        install-kasm autoscale test test-observe teardown lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

preflight: ## Validate workstation, .env, SSH + Proxmox reachability
	./scripts/00-preflight.sh

proxmox-setup: ## Create Proxmox role, user, pool, API token
	./scripts/proxmox/10-proxmox-setup.sh

agent-template: ## Build the Docker-agent VM template
	./scripts/proxmox/20-build-agent-template.sh

server-template: ## Build the full-desktop Linux (Horizon-style) VM template
	./scripts/proxmox/21-build-server-template.sh

windows-template: ## Build the Windows desktop-pool template (then sysprep + --finalize)
	./scripts/proxmox/22-build-windows-template.sh

windows-finalize: ## Seal a sysprepped Windows VM into a template
	./scripts/proxmox/22-build-windows-template.sh --finalize

install-kasm: ## Install Kasm control plane (run ON the Kasm host)
	./scripts/kasm/30-install-kasm.sh

autoscale: ## Validate + print VM Provider / Autoscale config values
	./scripts/kasm/40-configure-autoscale.sh

test: ## Drive demand + watch the pool scale
	./scripts/test/50-scale-test.sh

test-observe: ## Only watch the pool (create no sessions)
	./scripts/test/50-scale-test.sh --observe

teardown: ## Remove templates/token/pool/role from Proxmox
	./scripts/90-teardown.sh

lint: ## shellcheck all scripts (needs shellcheck installed)
	@shellcheck -x --severity=warning lib/*.sh scripts/*.sh scripts/**/*.sh
