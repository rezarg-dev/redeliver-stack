COMPOSE    := docker compose
ALL        := $(COMPOSE) --profile demo --profile tools
PROMETHEUS := prom/prometheus:v3.5.2
PROMTOOL   := docker run --rm --volume "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" \
              --entrypoint promtool $(PROMETHEUS)

.DEFAULT_GOAL := help
.PHONY: help init up demo down clean ps logs token backup restore smoke lint

help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-9s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

init: ## Create .env and generate the secrets (safe to repeat)
	@./scripts/init.sh

up: init ## Build and start the stack, wait until everything is healthy
	$(COMPOSE) up --build --detach --wait

demo: init ## Like "up", plus a fake destination and generated traffic
	$(COMPOSE) --profile demo up --build --detach --wait

down: ## Stop and remove the containers, keep the data
	$(ALL) down --remove-orphans

clean: ## Stop everything and delete all data volumes
	$(ALL) down --remove-orphans --volumes

ps: ## Show the state of the services
	$(ALL) ps

logs: ## Follow the logs of all services
	$(ALL) logs --follow --tail 50

token: ## Print the admin API token
	@cat secrets/admin_token && echo

backup: ## Write a database snapshot to ./backups
	$(COMPOSE) run --rm backup

restore: ## Restore a snapshot: make restore FILE=backups/<name>.db.gz
	@./scripts/restore.sh "$(FILE)"

smoke: ## Check a running stack from the outside
	@./scripts/smoke-test.sh

lint: ## Validate the compose file, Dockerfiles, scripts and Prometheus config
	$(ALL) config --quiet
	docker run --rm -i hadolint/hadolint < app/Dockerfile
	docker run --rm -i hadolint/hadolint < backup/Dockerfile
	$(PROMTOOL) check config /etc/prometheus/prometheus.yml
	$(PROMTOOL) test rules /etc/prometheus/tests/alerts_test.yml
	shellcheck scripts/*.sh app/docker-entrypoint.sh backup/backup.sh
