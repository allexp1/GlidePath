# GlidePath - developer entry points.
#
# Quick start on a fresh clone:
#
#     cp Config.example.xcconfig Config.xcconfig   # paste Supabase keys + Team ID
#     cp supabase/.env.example supabase/.env       # paste service role key
#     make seed                                    # push schema + load camera data
#     make project && open ios/GlidePath.xcodeproj
#
# `make help` lists every target.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IOS_DIR      := ios
CORE_DIR     := $(IOS_DIR)/Packages/GlidePathCore
PROJECT      := $(IOS_DIR)/GlidePath.xcodeproj
SCHEME       := GlidePath
DESTINATION  ?= platform=iOS Simulator,name=iPhone 17 Pro

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## Install the toolchain (XcodeGen, SwiftLint, Supabase CLI) via Homebrew
	brew install xcodegen swiftlint supabase/tap/supabase

Config.xcconfig:
	@echo "Config.xcconfig is missing. Creating it from the example."
	@cp Config.example.xcconfig Config.xcconfig
	@echo "Now open Config.xcconfig and fill in SUPABASE_URL, SUPABASE_ANON_KEY and DEVELOPMENT_TEAM."
	@exit 1

.PHONY: project
project: Config.xcconfig ## Generate the Xcode project from ios/project.yml
	cd $(IOS_DIR) && xcodegen generate

# ---------------------------------------------------------------------------
# Build and test
# ---------------------------------------------------------------------------

.PHONY: test
test: ## Run the core engine unit tests (no simulator needed)
	cd $(CORE_DIR) && swift test

.PHONY: build
build: project ## Build the iOS app for the simulator
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO \
		| xcbeautify || true

.PHONY: test-app
test-app: project ## Run the full test suite through xcodebuild on a simulator
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO

.PHONY: lint
lint: ## Run SwiftLint
	swiftlint lint --strict

.PHONY: format
format: ## Autocorrect what SwiftLint can fix
	swiftlint --fix

# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------

.PHONY: db-start
db-start: ## Start the local Supabase stack (Docker)
	supabase start

.PHONY: db-stop
db-stop: ## Stop the local Supabase stack
	supabase stop

.PHONY: db-reset
db-reset: ## Drop and re-apply every migration against the local stack
	supabase db reset

.PHONY: db-push
db-push: ## Apply migrations to the linked remote project
	supabase db push

.PHONY: deploy-functions
deploy-functions: ## Deploy the nightly sync Edge Function
	supabase functions deploy sync-cameras

# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------

.PHONY: seed
seed: ## Apply migrations and load Israel + Moldova camera data (the one setup command)
	@if [ ! -f supabase/.env ]; then \
		echo "supabase/.env is missing. Run: cp supabase/.env.example supabase/.env"; \
		exit 1; \
	fi
	supabase db push
	$(MAKE) seed-israel
	$(MAKE) seed-moldova
	@echo ""
	@echo "Done. One thing the migrations cannot do for you:"
	@echo ""
	@echo "  The nightly sync reads its credentials from Supabase Vault, and a"
	@echo "  service role key must never be committed to a migration. Run this"
	@echo "  once in the SQL editor:"
	@echo ""
	@echo "    select vault.create_secret('<your project url>', 'project_url');"
	@echo "    select vault.create_secret('<your service role key>', 'service_role_key');"
	@echo ""
	@echo "  Until then the schedule fires and fails harmlessly. Seeding by hand"
	@echo "  (this command) keeps working either way."

.PHONY: seed-israel
seed-israel: ## Pull Israel cameras from Overpass and merge the manual zone file
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts israel

.PHONY: seed-moldova
seed-moldova: ## Pull Moldova cameras from Overpass
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts moldova

.PHONY: seed-dry-run
seed-dry-run: ## Show what seeding would change without writing to the database
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts israel --dry-run
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts moldova --dry-run

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf $(CORE_DIR)/.build
	rm -rf $(PROJECT)
	rm -rf DerivedData
