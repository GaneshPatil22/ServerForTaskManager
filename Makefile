# Brain server. `make ci` runs exactly what CI runs (ADR-0006).
.DEFAULT_GOAL := help
.PHONY: help build test lint run ci clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Build the server
	swift build

test: ## Unit and HTTP tests (in-process, no network)
	swift test

lint: ## Format check
	swift format lint --strict --recursive Sources Tests Package.swift

run: ## Run locally on 127.0.0.1:8080
	swift run brain-server

ci: lint test ## Exactly what CI runs. If this passes, CI passes.

clean:
	rm -rf .build
