# Zonexplo - developer entry points.
#
# Quick start on a fresh clone:
#
#     cp Config.example.xcconfig Config.xcconfig   # paste Supabase keys + Team ID
#     cp supabase/.env.example supabase/.env       # paste service role key
#     make seed                                    # push schema + load camera data
#     make project && open ios/Zonexplo.xcodeproj
#
# `make help` lists every target.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IOS_DIR      := ios
CORE_DIR     := $(IOS_DIR)/Packages/ZonexploCore
PROJECT      := $(IOS_DIR)/Zonexplo.xcodeproj
SCHEME       := Zonexplo
DESTINATION  ?= platform=iOS Simulator,name=iPhone 17 Pro

# xcbeautify makes an xcodebuild log readable, and is optional on purpose:
# `make bootstrap` does not install it, so requiring it meant `make build` died
# with "xcbeautify: command not found" before xcodebuild produced a single line.
# Fall back to cat, which is ugly and works.
FORMAT := $(shell command -v xcbeautify >/dev/null 2>&1 && echo xcbeautify || echo cat)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## Install the toolchain (XcodeGen, SwiftLint, Supabase CLI, Deno) via Homebrew
	@# Installed one at a time and skipped when already present. Installing them
	@# as a batch fails the whole command if any single one is already there from
	@# a different tap, which is exactly what happens with the Supabase CLI: it
	@# used to live in supabase/tap and now ships in homebrew/core, and Homebrew
	@# refuses to have both.
	@for tool in xcodegen swiftlint xcbeautify supabase deno; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "$$tool: already installed ($$(command -v $$tool))"; \
		else \
			echo "$$tool: installing"; \
			brew install $$tool || exit 1; \
		fi; \
	done
	@echo ""
	@echo "Toolchain ready. Next:"
	@echo "  cp Config.example.xcconfig Config.xcconfig   # Supabase keys + Team ID"
	@echo "  cp supabase/.env.example supabase/.env       # service role key"
	@echo "  make link PROJECT_REF=<your-project-ref>"
	@echo "  make seed"

.PHONY: link
link: ## Link this checkout to your Supabase project (asks if PROJECT_REF is unset)
	@# Prompts rather than printing a usage line with a <placeholder> in it.
	@# Angle brackets are shell redirection, so a copied placeholder is a parse
	@# error before make ever runs. The tr strips them anyway, in case someone
	@# quotes one.
	@ref=$$(printf '%s' "$(PROJECT_REF)" | tr -d '<>'); \
	if [ -z "$$ref" ]; then \
		echo "Your project ref is the last part of the Supabase dashboard URL:"; \
		echo "  https://supabase.com/dashboard/project/THIS-BIT"; \
		echo "It is also on Settings > General, as \"Reference ID\"."; \
		echo ""; \
		printf "Project ref: "; \
		read ref; \
	fi; \
	if [ -z "$$ref" ]; then \
		echo "No project ref given, nothing linked."; \
		exit 1; \
	fi; \
	supabase link --project-ref "$$ref"

Config.xcconfig:
	@echo "Config.xcconfig is missing. Creating it from the example."
	@cp Config.example.xcconfig Config.xcconfig
	@echo "Now open Config.xcconfig and fill in SUPABASE_URL, SUPABASE_ANON_KEY and DEVELOPMENT_TEAM."
	@exit 1

.PHONY: project
project: Config.xcconfig ## Generate the Xcode project from ios/project.yml
	cd $(IOS_DIR) && xcodegen generate

.PHONY: doctor
doctor: ## Check the machine for the things that break a build before your code does
	@# Everything here is something that has actually cost someone an evening,
	@# and none of it shows up as itself. A Rosetta shell reports fifteen
	@# "unable to resolve module dependency" errors; git's Unicode setting
	@# reports a failure to unlink a file called "a"; an evicted iCloud file
	@# reports a missing package product. The build error never names the cause,
	@# so check the causes directly.
	@echo "== toolchain =="
	@for tool in xcodegen swiftlint xcbeautify; do \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "  ok       $$tool"; \
		elif [ "$$tool" = "xcbeautify" ]; then \
			echo "  optional $$tool missing (logs will be raw)"; \
		else \
			echo "  MISSING  $$tool - run: make bootstrap"; \
		fi; \
	done
	@if command -v xcodebuild >/dev/null 2>&1; then \
		echo "  ok       $$(xcodebuild -version | head -1)"; \
	else \
		echo "  MISSING  xcodebuild - install Xcode from the App Store"; \
	fi
	@echo ""
	@echo "== architecture =="
	@# A Terminal opened under Rosetta makes xcodebuild build the app for
	@# x86_64 while SwiftPM builds the packages for arm64. Nothing says
	@# "Rosetta"; you get "module file is incompatible with this Swift
	@# compiler" and every import failing.
	@hw=$$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0); \
	arch=$$(uname -m); \
	if [ "$$hw" = "1" ] && [ "$$arch" != "arm64" ]; then \
		echo "  PROBLEM  Apple Silicon Mac but this shell reports $$arch"; \
		echo "           This shell is under Rosetta. Either prefix commands with"; \
		echo "           'arch -arm64', or uncheck Open using Rosetta in Terminal's"; \
		echo "           Get Info panel and reopen it."; \
	else \
		echo "  ok       $$arch"; \
	fi
	@echo ""
	@echo "== git =="
	@# macOS stores filenames decomposed; git expects them precomposed. Without
	@# this, cloning a repository containing an accented filename - GRDB has
	@# them - dies with "failed to unlink" on a name that looks perfectly fine.
	@if [ "$$(git config --get core.precomposeunicode)" = "true" ]; then \
		echo "  ok       core.precomposeunicode"; \
	else \
		echo "  PROBLEM  core.precomposeunicode is not true"; \
		echo "           Package clones will fail on accented filenames. Fix:"; \
		echo "           git config --global core.precomposeunicode true"; \
	fi
	@echo ""
	@echo "== working copy =="
	@if [ -f Config.xcconfig ]; then \
		if grep -q 'YOUR-PROJECT-REF\|YOUR-ANON-KEY\|YOUR-TEAM-ID' Config.xcconfig; then \
			echo "  PROBLEM  Config.xcconfig still has placeholder values in it"; \
			echo "           It will build and then throw on launch. Fill it in."; \
		else \
			echo "  ok       Config.xcconfig"; \
		fi; \
	else \
		echo "  MISSING  Config.xcconfig - cp Config.example.xcconfig Config.xcconfig"; \
	fi
	@# An evicted iCloud file is a zero-byte placeholder. SwiftPM cannot read a
	@# placeholder Package.swift and reports it as a missing package product.
	@evicted=$$(find . -name '*.icloud' -not -path './.git/*' 2>/dev/null | head -5); \
	if [ -n "$$evicted" ]; then \
		echo "  PROBLEM  iCloud has evicted files from this checkout:"; \
		echo "$$evicted" | sed 's/^/             /'; \
		echo "           Fix: brctl download \"$$(pwd)\", then right-click the"; \
		echo "           folder in Finder and choose Keep Downloaded."; \
	else \
		echo "  ok       no evicted iCloud placeholders"; \
	fi
	@case "$$(pwd)" in \
		*com~apple~CloudDocs*) \
			echo "  note     this checkout is inside iCloud Drive; builds work but"; \
			echo "           eviction and sync churn are on you to watch" ;; \
	esac

# ---------------------------------------------------------------------------
# Build and test
# ---------------------------------------------------------------------------

.PHONY: test
test: ## Run the core engine unit tests (no simulator needed)
	cd $(CORE_DIR) && swift test

.PHONY: build
build: project ## Build the iOS app for the simulator
	@# pipefail, and no `|| true`.
	@#
	@# This used to end in `| xcbeautify || true`, which had two ways of lying.
	@# Piping puts xcodebuild's exit status out of reach, so make saw only
	@# xcbeautify's, and `|| true` then discarded even that: a failed build
	@# exited 0 and `make build && make archive` would happily archive code that
	@# had not compiled. It also hid xcodebuild's stdout when xcbeautify was
	@# missing, leaving only stderr - which is why a broken build showed a pile
	@# of errors and no sign of what it had been doing.
	set -o pipefail; xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO \
		| $(FORMAT)

.PHONY: test-app
test-app: project ## Run the full test suite through xcodebuild on a simulator
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO

.PHONY: test-sync
test-sync: ## Run the Deno tests for the Overpass translation layer
	deno test supabase/functions/_shared

.PHONY: lint
lint: ## Run SwiftLint
	swiftlint lint --strict

.PHONY: format
format: ## Autocorrect what SwiftLint can fix
	swiftlint --fix

# ---------------------------------------------------------------------------
# Release
# ---------------------------------------------------------------------------
#
# The supported path is the TestFlight workflow in .github/workflows. These are
# the same thing by hand, for when you want to watch it happen. Either way the
# one-time setup is in docs/TESTFLIGHT.md.

ARCHIVE ?= ios/build/Zonexplo.xcarchive

.PHONY: icon
icon: ## Regenerate the placeholder app icon
	python3 scripts/generate-app-icon.py

.PHONY: archive
archive: project ## Build a signed release archive for the App Store
	xcodebuild archive \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE) \
		-allowProvisioningUpdates

.PHONY: testflight
testflight: ## Upload the archive from `make archive` to TestFlight
	@if [ ! -d "$(ARCHIVE)" ]; then \
		echo "No archive at $(ARCHIVE). Run: make archive"; \
		exit 1; \
	fi
	@for var in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do \
		if [ -z "$${!var}" ]; then \
			echo "$$var is not set. See docs/TESTFLIGHT.md."; \
			exit 1; \
		fi; \
	done
	@# destination=upload hands the build straight to App Store Connect, which
	@# is the supported route now that altool is deprecated.
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>method</key><string>app-store-connect</string>' \
		'<key>destination</key><string>upload</string>' \
		'<key>uploadSymbols</key><true/>' \
		'<key>manageAppVersionAndBuildNumber</key><false/>' \
		'</dict></plist>' > ios/build/ExportOptions.plist
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE) \
		-exportOptionsPlist ios/build/ExportOptions.plist \
		-exportPath ios/build/export \
		-allowProvisioningUpdates \
		-authenticationKeyPath "$$ASC_KEY_PATH" \
		-authenticationKeyID "$$ASC_KEY_ID" \
		-authenticationKeyIssuerID "$$ASC_ISSUER_ID"

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
seed: ## Apply migrations and load every enabled country (the one setup command)
	@if [ ! -f supabase/.env ]; then \
		echo "supabase/.env is missing. Run: cp supabase/.env.example supabase/.env"; \
		exit 1; \
	fi
	@# `db push` needs the checkout linked to a project. Rather than guessing at
	@# the CLI's internal state file, let it fail and explain the fix.
	@supabase db push || { \
		echo ""; \
		echo "If that failed because no project is linked, run this once:"; \
		echo "  make link PROJECT_REF=<your-project-ref>"; \
		exit 1; \
	}
	@# Each country may fail without taking the others with it. A country whose
	@# data is missing upstream is a fact about OpenStreetMap rather than a broken
	@# setup, and it must not stop the ones that did load from being usable - or
	@# stop `make seed && make project` from reaching `make project`.
	@failed=""; \
	for country in israel moldova lithuania; do \
		echo ""; \
		(cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts $$country) \
			|| failed="$$failed $$country"; \
	done; \
	if [ -n "$$failed" ]; then \
		echo ""; \
		echo "  Loaded nothing for:$$failed"; \
		echo "  The countries that did load are fine and the app will work with them."; \
		echo "  To find out why, run:  make inspect CODE=<XX>"; \
	fi
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

.PHONY: seed-lithuania
seed-lithuania: ## Pull Lithuania cameras and average-speed sections from Overpass
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts lithuania

.PHONY: seed-country
seed-country: ## Load any country by ISO code, e.g. make seed-country CODE=PL
	@code=$$(printf '%s' "$(CODE)" | tr -d '<>'); \
	if [ -z "$$code" ]; then \
		echo "Usage: make seed-country CODE=<ISO 3166-1 alpha-2>"; \
		echo "  e.g. make seed-country CODE=PL"; \
		exit 1; \
	fi; \
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts "$$code"

.PHONY: inspect
inspect: ## Explain why a country loaded nothing, e.g. make inspect CODE=LT
	@code=$$(printf '%s' "$(CODE)" | tr -d '<>'); \
	if [ -z "$$code" ]; then \
		echo "Usage: make inspect CODE=<ISO 3166-1 alpha-2>"; \
		echo "  e.g. make inspect CODE=LT"; \
		exit 1; \
	fi; \
	cd supabase/seed && deno run --allow-net --allow-read inspect.ts "$$code"

.PHONY: seed-limits
seed-limits: ## Harvest posted road speed limits, e.g. make seed-limits CODE=LT (slow, resumable)
	@code=$$(printf '%s' "$(CODE)" | tr -d '<>'); \
	if [ -z "$$code" ]; then \
		echo "Usage: make seed-limits CODE=<ISO 3166-1 alpha-2>"; \
		echo "  e.g. make seed-limits CODE=LT"; \
		echo ""; \
		echo "A few hundred Overpass queries covering a whole country. It runs for"; \
		echo "tens of minutes. Ctrl-C is safe: every finished tile is checkpointed"; \
		echo "and re-running resumes from there."; \
		exit 1; \
	fi; \
	cd supabase/seed && deno run --allow-net --allow-env --allow-read --allow-write seed_limits.ts "$$code"

.PHONY: seed-dry-run
seed-dry-run: ## Show what seeding would change without writing to the database
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts israel --dry-run
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts moldova --dry-run
	cd supabase/seed && deno run --allow-net --allow-env --allow-read seed.ts lithuania --dry-run

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf $(CORE_DIR)/.build
	rm -rf $(PROJECT)
	rm -rf DerivedData
	rm -rf ios/build
