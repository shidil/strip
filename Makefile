CONFIG ?= debug
APP_NAME := Strip
APP    := .build/$(APP_NAME).app
BIN    := $(APP)/Contents/MacOS/$(APP_NAME)
BUNDLE_ID := io.github.shidil.strip
SIGN_ID   ?= Strip Dev
REQUIRE_SIGNING ?= 0
CODESIGN_OPTIONS ?=
DIST_DIR := .build/dist

.PHONY: build bundle verify-bundle archive notarized-release ci run open profile test e2e e2e-vm e2e-vm-check screenshots clean setup-signing

## Compile the Swift package.
build:
	swift build -c $(CONFIG)

## One-time: create the stable "Strip Dev" self-signed code-signing identity.
setup-signing:
	@bash scripts/setup-signing.sh

## Assemble + sign Strip.app. Prefers the stable "Strip Dev" identity (grant survives rebuilds);
## falls back to ad-hoc if it isn't set up yet.
bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/$(APP_NAME) $(BIN)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if [ -n "$(SIGN_ID)" ] && security find-identity -p codesigning | grep -Fq "$(SIGN_ID)"; then \
		echo "Signing with '$(SIGN_ID)'"; \
		codesign --force $(CODESIGN_OPTIONS) --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) $(APP); \
	elif [ "$(REQUIRE_SIGNING)" = "1" ]; then \
		echo "Required signing identity '$(SIGN_ID)' was not found" >&2; \
		exit 1; \
	else \
		echo "No development identity — ad-hoc signing (not for public distribution)"; \
		codesign --force --sign - --identifier $(BUNDLE_ID) $(APP); \
	fi
	@echo "Built $(APP)"

## Validate source metadata and assembled application bundle.
verify-bundle:
	plutil -lint Resources/Info.plist
	@test -d $(APP) || (echo "Missing $(APP); run 'make bundle' first" >&2; exit 1)
	@actual=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $(APP)/Contents/Info.plist); \
		test "$$actual" = "$(BUNDLE_ID)" || (echo "Bundle id $$actual != $(BUNDLE_ID)" >&2; exit 1)
	codesign --verify --deep --strict --verbose=2 $(APP)

## Create an ad-hoc local test archive and checksum. Never publish this artifact.
archive:
	@$(MAKE) bundle CONFIG=release SIGN_ID=
	@$(MAKE) verify-bundle
	@mkdir -p $(DIST_DIR)
	@version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist); \
		artifact="$(DIST_DIR)/Strip-$$version-macos-local.zip"; \
		rm -f "$$artifact" "$$artifact.sha256"; \
		ditto -c -k --keepParent $(APP) "$$artifact"; \
		artifact_name=$$(basename "$$artifact"); \
		(cd "$(DIST_DIR)" && shasum -a 256 "$$artifact_name" > "$$artifact_name.sha256"); \
		echo "Created local-only $$artifact"

notarized-release:
	@bash scripts/release.sh

## Public pull-request validation that does not require TCC permissions.
ci:
	$(MAKE) test
	$(MAKE) bundle CONFIG=release SIGN_ID=
	$(MAKE) verify-bundle

## Run the bundled binary directly so logs stream to this terminal (bundle identity still applies).
run: bundle
	@echo "Launching $(APP_NAME) (Ctrl-C to stop)…"
	@$(BIN)

## Launch detached via the app bundle (no streamed logs; use Console.app).
## Kills any running instance first so the fresh build takes over.
open: bundle
	@pkill -x $(APP_NAME) 2>/dev/null && echo "Killed running $(APP_NAME)" || true
	open $(APP)

## Profile the running app under Instruments. Launches via `open` (the only Accessibility-trusted
## path) then ATTACHES xctrace — never launches the binary itself, so the TCC grant is preserved.
## Records until you press Ctrl-C, then opens the .trace.
##
## Default template "Logging" carries the os_signpost instrument: it shows the Phase 0 intervals
## (apply / placements / refresh / allWindows / animate / frame) and events (setFrame.enqueue/.done,
## inFlightDrop, reconcile) — filter subsystem io.github.shidil.strip, category hotpath. It also avoids the
## task_for_pid entitlement that sampling templates need on attach.
## Complementary passes (may prompt for authorization on attach):
##   make profile TEMPLATE="Time Profiler"   # main-thread stalls (R1/R4)
##   make profile TEMPLATE=Allocations        # per-command churn
TEMPLATE ?= Logging
TRACE    ?= .build/$(APP_NAME)-$(shell date +%Y%m%d-%H%M%S).trace
profile: open
	@echo "Waiting for $(APP_NAME) to come up…"
	@for i in $$(seq 1 50); do pgrep -x $(APP_NAME) >/dev/null && break; sleep 0.1; done; \
	pid=$$(pgrep -x $(APP_NAME)); \
	if [ -z "$$pid" ]; then echo "✗ $(APP_NAME) not running — check /tmp/strip.log"; exit 1; fi; \
	echo "Recording '$(TEMPLATE)' attached to pid $$pid → $(TRACE)"; \
	echo "  Exercise Strip now (hotkeys, multi-window slides, Cmd-Tab storm), then Ctrl-C to stop."; \
	xcrun xctrace record --template "$(TEMPLATE)" --attach $$pid --output "$(TRACE)"; \
	echo "Opening $(TRACE)…"; open "$(TRACE)"

## Unit tests for the pure layout engine.
test:
	swift test

## AppKit/AX/menu integration smoke suite — drives a real bundled+launched Strip via hotkeys and
## status-menu clicks, asserting against /tmp/strip-e2e.log. NOT part of `test`/the PostToolUse
## hook: needs a granted Accessibility permission, a real display, and no other automation touching
## the mouse/keyboard while it runs. Kills any running Strip and needs a clean desktop (only its own
## fixture windows) — see TESTING.md.
e2e: bundle
	@E2E_ONLY="$(E2E_ONLY)" bash scripts/e2e/run.sh

## Same suite as `e2e`, but run inside an isolated Tart macOS VM instead of the real desktop — no
## clean-desktop precondition to maintain by hand. Needs one-time setup (scripts/e2e/vm/setup.sh,
## mostly manual) and the VM already running (`tart run strip-e2e` in its own terminal) — see
## TESTING.md's "Isolated runs via a Tart VM" section.
e2e-vm: bundle
	@E2E_ONLY="$(E2E_ONLY)" bash scripts/e2e/vm/run.sh

## Preflight the VM path without running the suite: VM up, guest signing identity, Strip's
## Accessibility grant, Terminal's UI-scripting grants.
e2e-vm-check: bundle
	@bash scripts/e2e/vm/run.sh --check

## Recapture the website/README screenshots from a release build in the strip-e2e VM, then publish
## them to site/assets/img/screenshots/. SHOTS="search help" for a subset. See scripts/screenshots/.
screenshots:
	@bash scripts/screenshots/capture.sh $(SHOTS)

clean:
	swift package clean
	rm -rf $(APP)
