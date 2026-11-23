# Brain server. `make ci` runs exactly what CI runs (ADR-0006).
.DEFAULT_GOAL := help
.PHONY: help build test lint run ci clean db-up db-down db-reset

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Build the server
	swift build

test: ## All tests. Storage tests need Postgres: run `make db-up` first
	swift test

db-up: ## Start local Postgres (Docker) and wait until it is ready
	docker compose up -d --wait db

db-down: ## Stop local Postgres, keeping its data
	docker compose down

db-reset: ## Stop local Postgres and delete its data
	docker compose down -v

lint: ## Format check
	swift format lint --strict --recursive Sources Tests Package.swift

run: ## Run locally on 127.0.0.1:8080
	swift run brain-server

# CI gets Postgres from a service container instead of `db-up`; the commands
# that run against it are identical.
ci: db-up lint test ## Exactly what CI runs. If this passes, CI passes.

clean:
	rm -rf .build
