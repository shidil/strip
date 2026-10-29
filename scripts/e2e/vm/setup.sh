#!/usr/bin/env bash
# ONE-TIME setup for the isolated Tart-VM e2e path (`make e2e-vm`). Interactive: macOS privacy grants
# can't be scripted without disabling SIP (considered and rejected — TESTING.md §7), so this opens each
# System Settings pane in the VM and waits while you flip the toggle. Everything else is automated.
# Safe to re-run: automated steps skip what's already done; for a grant that's already on, just
# press Enter.
#
# The grants are tied to Strip's code signature. The guest gets its own fixed self-signed identity
# (step 3) and run.sh re-signs every pushed build with it, so the grants survive every rebuild — no
# re-granting, however the host build was signed.
set -uo pipefail

VM_NAME="${STRIP_E2E_VM:-strip-e2e}"
BASE_IMAGE="${STRIP_E2E_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
GOLDEN="$VM_NAME-golden"
GUEST_SIGN_ID="Strip Dev"
GUEST_KEYCHAIN_PASS="admin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GUEST_APP="/Applications/Strip.app"

g() { tart exec "$VM_NAME" "$@"; }
gi() { tart exec -i "$VM_NAME" "$@"; } # stdin piped into the guest command
pause() { echo; read -r -p ">>> $1 Press Enter once done. " _; }
step() { echo; echo "=== $1 ==="; }
# Opens a Privacy & Security pane in the guest. The legacy URL scheme still routes on macOS 15/26.
open_pane() { g open "x-apple.systempreferences:com.apple.preference.security?$1" >/dev/null 2>&1 || true; }

step "1. VM"
if ! command -v tart >/dev/null 2>&1; then
  echo "Installing Tart via Homebrew…"
  brew install cirruslabs/cli/tart || { echo "✗ brew install failed" >&2; exit 1; }
fi
if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM_NAME"; then
  echo "✓ VM '$VM_NAME' exists."
elif tart list 2>/dev/null | awk '{print $2}' | grep -qx "$GOLDEN"; then
  echo "Restoring '$VM_NAME' from the golden snapshot '$GOLDEN' (grants included)…"
  tart clone "$GOLDEN" "$VM_NAME" || { echo "✗ clone failed" >&2; exit 1; }
  echo "✓ Restored. Start it with 'tart run $VM_NAME', then 'make e2e-vm'. (If the snapshot predates"
  echo "  Google Chrome, re-run this script once the VM is up: it only installs what's missing.)"
  exit 0
else
  if tart list 2>/dev/null | grep -qF "$BASE_IMAGE"; then
    echo "Base image $BASE_IMAGE is cached locally — cloning (copy-on-write, fast)."
  else
    echo "Pulling $BASE_IMAGE: ~25GB download, ~50GB on disk. Free at least ~60GB first."
    df -H / | tail -1
    pause "Confirm you have enough free disk space."
  fi
  tart clone "$BASE_IMAGE" "$VM_NAME" || { echo "✗ pull/clone failed" >&2; exit 1; }
  echo "✓ Created '$VM_NAME'."
fi

step "2. Boot it (in your own terminal)"
if ! tart list 2>/dev/null | awk -v n="$VM_NAME" '$1 == "local" && $2 == n' | grep -q running; then
  echo "Tart's VM window only renders when started from a real interactive terminal. Run:"
  echo
  echo "    tart run $VM_NAME"
  echo
  pause "Wait for the VM desktop (auto-login as 'admin')."
fi
for _ in $(seq 1 60); do g true >/dev/null 2>&1 && break; sleep 1; done
g true >/dev/null 2>&1 || { echo "✗ Can't reach the guest agent — is the VM running (tart list)?" >&2; exit 1; }
echo "✓ Guest agent reachable."
g sudo pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1
g defaults -currentHost write com.apple.screensaver idleTime 0
g defaults write com.apple.screensaver askForPassword -int 0
echo "✓ Sleep and screensaver off (a locked screen breaks AX and UI scripting mid-run)."

step "3. Stable signing identity in the guest"
if g sh -c "security find-identity -p codesigning | grep -q '$GUEST_SIGN_ID'"; then
  echo "✓ '$GUEST_SIGN_ID' already in the guest keychain."
else
  g security unlock-keychain -p "$GUEST_KEYCHAIN_PASS" login.keychain-db >/dev/null 2>&1
  gi tee /tmp/setup-signing.sh <"$REPO_ROOT/scripts/setup-signing.sh" >/dev/null
  g bash /tmp/setup-signing.sh || { echo "✗ creating the guest signing identity failed" >&2; exit 1; }
  # Let codesign use the key without a GUI prompt.
  g security set-key-partition-list -S apple-tool:,apple: -s -k "$GUEST_KEYCHAIN_PASS" login.keychain-db >/dev/null 2>&1
  g sh -c "security find-identity -p codesigning | grep -q '$GUEST_SIGN_ID'" \
    || { echo "✗ '$GUEST_SIGN_ID' still missing in the guest" >&2; exit 1; }
  echo "✓ Created '$GUEST_SIGN_ID' in the guest (guest-only; never leaves the VM)."
fi

step "4. Install Strip in the guest, signed with that identity"
[ -d "$REPO_ROOT/.build/Strip.app" ] || { echo "✗ .build/Strip.app missing — run 'make bundle' first." >&2; exit 1; }
g sh -c "pkill -x Strip; rm -rf /tmp/wm-e2e-setup $GUEST_APP; mkdir -p /tmp/wm-e2e-setup"
tar -czf - -C "$REPO_ROOT/.build" Strip.app | gi sh -c "tar -xzf - -C /tmp/wm-e2e-setup"
g cp -R /tmp/wm-e2e-setup/Strip.app "$GUEST_APP"
g sh -c "security unlock-keychain -p '$GUEST_KEYCHAIN_PASS' login.keychain-db >/dev/null 2>&1; \
  codesign --force --sign '$GUEST_SIGN_ID' --identifier io.github.shidil.strip $GUEST_APP" \
  || { echo "✗ guest codesign failed" >&2; exit 1; }
g open "$GUEST_APP"
echo "✓ Strip launched in the guest."

step "4b. Google Chrome (for the Chromium tab scenario)"
if g test -d "/Applications/Google Chrome.app"; then
  echo "✓ Google Chrome already installed."
else
  echo "Downloading Google Chrome (~270MB) into the guest…"
  g sh -c 'cd /tmp && curl -sSfL -o chrome.dmg https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg \
    && hdiutil attach -nobrowse -quiet -mountpoint /tmp/chrome-mnt chrome.dmg \
    && cp -R "/tmp/chrome-mnt/Google Chrome.app" /Applications/ \
    && hdiutil detach -quiet /tmp/chrome-mnt && rm -f chrome.dmg' \
    && echo "✓ Installed Google Chrome." \
    || echo "✗ Chrome install failed — scenario_search_chromium_tabs will fail until it's installed." >&2
fi

step "5. Grant: Strip → Accessibility"
open_pane Privacy_Accessibility
pause "In the VM: toggle Strip ON in Accessibility (password: admin). If Strip isn't listed, click + and pick $GUEST_APP."

step "6. Grant: Strip → Screen Recording"
echo "The Overview captures window thumbnails. Without this grant, opening it shows a system prompt"
echo "in the middle of a run."
open_pane Privacy_ScreenCapture
pause "In the VM: toggle Strip ON in Screen & System Audio Recording. Choose 'Quit & Reopen' (or 'Later') if asked."
g sh -c "pkill -x Strip" >/dev/null 2>&1

step "7. Grant: Terminal → Accessibility, Developer Tools and Screen Recording"
echo "The suite runs inside a guest Terminal session; UI scripting from it needs both (TESTING.md §7)."
open_pane Privacy_Accessibility
pause "In the VM: add Terminal to Accessibility (+, Cmd-Shift-G, /System/Applications/Utilities/Terminal.app) and toggle it ON."
open_pane Privacy_DevTools
pause "In the VM: add Terminal to Developer Tools and toggle it ON."
echo "Screenshots (scripts/screenshots/) call screencapture from the same Terminal session; without"
echo "this grant it captures nothing."
open_pane Privacy_ScreenCapture
pause "In the VM: toggle Terminal ON in Screen & System Audio Recording (+ if it isn't listed)."

step "8. Automation prompts (one per app the suite drives)"
cat >/tmp/strip-e2e-automation.sh <<'EOF'
#!/bin/bash
for app in "System Events" Console "Activity Monitor" Preview TextEdit Finder; do
  osascript -e "tell application \"$app\" to get name" >/dev/null 2>&1
done
osascript -e 'tell application "System Events" to count processes' > /tmp/strip-e2e-automation.out 2>&1
for app in Console "Activity Monitor" Preview TextEdit; do
  osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1
done
EOF
gi tee /tmp/strip-e2e-automation.sh </tmp/strip-e2e-automation.sh >/dev/null
rm -f /tmp/strip-e2e-automation.sh
g chmod +x /tmp/strip-e2e-automation.sh
g osascript -e 'tell application "Terminal" to do script "/tmp/strip-e2e-automation.sh"' >/dev/null
pause "In the VM: click Allow on each 'Terminal wants to control …' prompt (up to 6)."

step "9. Verify"
if (cd "$REPO_ROOT" && bash scripts/e2e/vm/run.sh --check); then
  echo
  echo "✓ Setup complete. Run 'make e2e-vm' with the VM left running."
  echo
  echo "Recommended — snapshot it so a lost VM is a 1-minute restore, not a re-setup:"
  echo "    tart stop $VM_NAME && tart clone $VM_NAME $GOLDEN && tart run $VM_NAME"
  echo "Restore later with: scripts/e2e/vm/setup.sh (clones '$GOLDEN' when '$VM_NAME' is missing)."
else
  echo "✗ Preflight failed — fix the grant it names, then re-run this script (completed steps are skipped)." >&2
  exit 1
fi
