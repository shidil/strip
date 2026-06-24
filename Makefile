CONFIG ?= debug
APP_NAME := Strip
APP    := .build/$(APP_NAME).app
BIN    := $(APP)/Contents/MacOS/$(APP_NAME)
BUNDLE_ID := com.spike.strip
SIGN_ID   ?= Strip Dev

.PHONY: build bundle run open test clean setup-signing

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
	@if security find-identity -p codesigning | grep -q "$(SIGN_ID)"; then \
		echo "Signing with '$(SIGN_ID)'"; \
		codesign --force --sign "$(SIGN_ID)" --identifier $(BUNDLE_ID) $(APP); \
	else \
		echo "No '$(SIGN_ID)' identity — ad-hoc signing (run 'make setup-signing' for a stable grant)"; \
		codesign --force --sign - --identifier $(BUNDLE_ID) $(APP); \
	fi
	@echo "Built $(APP)"

## Run the bundled binary directly so logs stream to this terminal (bundle identity still applies).
run: bundle
	@echo "Launching $(APP_NAME) (Ctrl-C to stop)…"
	@$(BIN)

## Launch detached via the app bundle (no streamed logs; use Console.app).
## Kills any running instance first so the fresh build takes over.
open: bundle
	@pkill -x $(APP_NAME) 2>/dev/null && echo "Killed running $(APP_NAME)" || true
	open $(APP)

## Unit tests for the pure layout engine.
test:
	swift test

clean:
	swift package clean
	rm -rf $(APP)
