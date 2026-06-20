# MTPLX Router — build / install
APP_NAME := MTPLX Router
BUNDLE   := $(APP_NAME).app
CONFIG   ?= release
BIN      := .build/$(CONFIG)/MTPLXRouter
DIST     := dist/$(BUNDLE)
APPS     := /Applications/$(BUNDLE)
PROC     := MTPLXRouter

.DEFAULT_GOAL := help

.PHONY: help build bundle install update reinstall uninstall run stop doctor write-opencode open logs clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*## "}{printf "  %-16s %s\n", $$1, $$2}'

build: ## Compile (CONFIG=debug|release, default release)
	swift build -c $(CONFIG)

bundle: ## Build the .app into ./dist
	./scripts/build_app.sh $(CONFIG)

install: bundle stop ## ONE-SHOT: build, replace app in /Applications, relaunch
	rm -rf "$(APPS)"
	ditto "$(DIST)" "$(APPS)"
	@echo "✓ installed → $(APPS)"
	open "$(APPS)"

update: install ## Alias for install
reinstall: install ## Alias for install

uninstall: stop ## Quit and remove from /Applications (keeps config + logs)
	rm -rf "$(APPS)"
	@echo "✓ removed $(APPS) — config/logs kept in ~/Library/Application Support/MTPLX Router"

run: build ## Run the dev binary in the foreground
	"$(BIN)"

stop: ## Quit any running instance (cleanly frees the backend daemon)
	-@osascript -e 'quit app "$(APP_NAME)"' >/dev/null 2>&1 || true
	-@pkill -TERM -x $(PROC) >/dev/null 2>&1 || true
	@sleep 1

doctor: build ## Print diagnostics (mtplx, models, ports)
	-"$(BIN)" --doctor

write-opencode: build ## Write the OpenCode provider config (backs up first)
	"$(BIN)" --write-opencode

open: ## Open the installed app
	open "$(APPS)"

logs: ## Tail the router log
	tail -f "$$HOME/Library/Application Support/MTPLX Router/logs/router.log"

clean: ## Remove build artifacts (.build, dist)
	swift package clean 2>/dev/null || true
	rm -rf .build dist
	@echo "✓ cleaned"
