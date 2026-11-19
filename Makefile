# =============================================================================
# Convenience commands. Everything runs inside Docker - no PHP, Composer or
# Node.js is needed on the host. Run `make help` for the list.
# =============================================================================
SHELL        := /bin/bash
.SHELLFLAGS  := -e -o pipefail -c
.DEFAULT_GOAL := help

COMPOSE ?= docker compose
APP     := $(COMPOSE) exec app

# Read a value from .env (empty when missing).
env_val      = $(shell grep -E '^$(1)=' .env 2>/dev/null | tail -n1 | cut -d= -f2-)
PROJECT_NAME := $(call env_val,PROJECT_NAME)
VITE_PORT    := $(or $(call env_val,VITE_PORT),5173)

.PHONY: help setup up down restart build logs bash artisan composer npm npm-dev npm-build \
        test mysql status xdebug-on xdebug-off db-backup db-restore clean destroy \
        check-env ensure-up

help: ## Show this help
	@echo "Usage: make <target> [cmd=\"...\"]"; echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-env:
	@test -f .env || { echo "No .env found. Run ./setup.sh first."; exit 1; }

# Start the stack automatically if the app container is not running.
ensure-up: check-env
	@$(COMPOSE) ps --status running --services | grep -x app >/dev/null \
		|| { echo "Starting containers..."; $(COMPOSE) up -d; }

setup: ## Run ./setup.sh (first-time install, safe to re-run)
	@./setup.sh

up: check-env ## Start all containers in the background
	$(COMPOSE) up -d

down: check-env ## Stop and remove containers (database volume is kept)
	$(COMPOSE) down

restart: check-env ## Restart all containers
	$(COMPOSE) restart

build: check-env ## Build/rebuild images, then recreate changed containers
	$(COMPOSE) build
	$(COMPOSE) up -d

logs: check-env ## Follow logs (optionally: make logs svc=nginx)
	$(COMPOSE) logs -f --tail=100 $(svc)

bash: ensure-up ## Open a shell in the app container
	$(APP) bash

artisan: ensure-up ## Run Artisan:  make artisan cmd="migrate"
	@test -n "$(cmd)" || { echo 'Usage: make artisan cmd="migrate"'; exit 1; }
	$(APP) php artisan $(cmd)

composer: ensure-up ## Run Composer:  make composer cmd="install"
	@test -n "$(cmd)" || { echo 'Usage: make composer cmd="install"'; exit 1; }
	$(APP) composer $(cmd)

npm: ensure-up ## Run npm:  make npm cmd="install"
	@test -n "$(cmd)" || { echo 'Usage: make npm cmd="install"'; exit 1; }
	$(APP) npm $(cmd)

npm-dev: ensure-up ## Start the Vite dev server (HMR) on VITE_PORT
	$(APP) npm run dev -- --host 0.0.0.0 --port $(VITE_PORT)

npm-build: ensure-up ## Build production assets
	$(APP) npm run build

test: ensure-up ## Run the test suite (optional: make test cmd="--filter=Foo")
	$(APP) php artisan test $(cmd)

mysql: ensure-up ## Open a MySQL shell as the application user
	$(COMPOSE) exec mysql sh -c 'exec mysql -u"$$MYSQL_USER" -p"$$MYSQL_PASSWORD" "$$MYSQL_DATABASE"'

status: check-env ## Show container status and URLs
	@$(COMPOSE) ps
	@echo
	@echo "App:     http://localhost:$(call env_val,APP_PORT)"
	@echo "Mailpit: http://localhost:$(call env_val,MAILPIT_WEB_PORT)"
	@echo "MySQL:   $(call env_val,BIND_ADDRESS):$(call env_val,MYSQL_PORT)"
	@echo "Xdebug:  XDEBUG_MODE=$(call env_val,XDEBUG_MODE)"

xdebug-on: check-env ## Enable Xdebug step debugging
	@sed -i 's/^XDEBUG_MODE=.*/XDEBUG_MODE=debug/' .env
	$(COMPOSE) up -d app
	@echo "Xdebug enabled (XDEBUG_MODE=debug). Start 'Listen for PHP Debug Connections' in PhpStorm."

xdebug-off: check-env ## Disable Xdebug (no overhead)
	@sed -i 's/^XDEBUG_MODE=.*/XDEBUG_MODE=off/' .env
	$(COMPOSE) up -d app
	@echo "Xdebug disabled (XDEBUG_MODE=off)."

db-backup: ensure-up ## Dump the database to backups/<project>-<timestamp>.sql.gz
	@mkdir -p backups
	@f="backups/$(PROJECT_NAME)-$$(date +%Y%m%d-%H%M%S).sql.gz"; \
	$(COMPOSE) exec -T mysql sh -c 'exec mysqldump -uroot -p"$$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers "$$MYSQL_DATABASE"' | gzip > "$$f" \
		&& echo "Backup written to $$f"

db-restore: ensure-up ## Restore a dump:  make db-restore file=backups/x.sql.gz
	@test -n "$(file)" && test -f "$(file)" || { echo 'Usage: make db-restore file=backups/<dump>.sql[.gz]'; exit 1; }
	@echo "Restoring $(file) into the current database (existing tables with the same names are replaced by the dump)..."
	@if [[ "$(file)" == *.gz ]]; then gunzip -c "$(file)"; else cat "$(file)"; fi \
		| $(COMPOSE) exec -T mysql sh -c 'exec mysql -uroot -p"$$MYSQL_ROOT_PASSWORD" "$$MYSQL_DATABASE"'
	@echo "Restore finished."

clean: check-env ## Remove containers and network. Database & caches are KEPT
	$(COMPOSE) down --remove-orphans
	@echo "Containers removed. Named volumes (database, caches) were NOT deleted."

destroy: check-env ## DESTRUCTIVE: also delete all volumes (database!) - asks to confirm
	@echo "This permanently deletes the MySQL data and caches of project '$(PROJECT_NAME)'."
	@read -r -p "Type the project name to confirm: " answer; \
	[ "$$answer" = "$(PROJECT_NAME)" ] || { echo "Aborted."; exit 1; }; \
	$(COMPOSE) down -v --remove-orphans
