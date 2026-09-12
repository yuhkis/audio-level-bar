.PHONY: build test diagnose app verify-app install install-login-agent run ci lint-metadata check-localization verify-vendor vendor-smoke setup-dev audit-history

APP_PATH := $(CURDIR)/dist/Audio Level Bar.app

build:
	swift build

test:
	swift test

diagnose:
	swift run AudioLevelBar --diagnose

app:
	./scripts/build-app.sh

verify-app:
	./scripts/verify-app.sh "$(APP_PATH)"

install:
	./scripts/install-app.sh "$(APP_PATH)"

install-login-agent:
	./scripts/install-login-agent.sh

setup-dev:
	./scripts/setup-dev.sh

audit-history:
	./scripts/audit-history.sh

lint-metadata:
	/bin/sh -n scripts/*.sh
	/bin/sh -n scripts/git-hooks/*
	plutil -lint Resources/*.plist
	plutil -lint Resources/*.entitlements

check-localization:
	./scripts/check-localization.sh

verify-vendor:
	./scripts/verify-vendor.sh

vendor-smoke:
	./scripts/test-vendor.sh

ci: lint-metadata check-localization verify-vendor vendor-smoke test app verify-app

run: app
	open "$(APP_PATH)"
