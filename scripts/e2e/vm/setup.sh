#!/usr/bin/env bash
# ONE-TIME setup for the isolated Tart-VM e2e path (`make e2e-vm`). Mostly manual and interactive —
# some of what's needed (permission click-throughs) genuinely can't be scripted headlessly. Safe to
# re-run: skips the image pull if the VM already exists, and each grant step tells you how to check
# whether it's already done.
#
# Every step here reflects what was ACTUALLY needed, confirmed empirically while building this path
# — not a guess at what "should" be needed. See TESTING.md's "Isolated runs via a Tart VM" section
# for the full narrative and the dead ends that didn't work (SIP-disable/TCC.db scripting was
# considered and explicitly rejected in favor of this).
set -uo pipefail

VM_NAME="strip-e2e"
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-base:latest"

pause() {
  echo
  read -r -p ">>> $1 Press Enter once done. " _
}

if ! command -v tart >/dev/null 2>&1; then
  echo "Installing Tart via Homebrew…"
  brew install cirruslabs/cli/tart || { echo "✗ brew install failed" >&2; exit 1; }
fi

if tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM_NAME"; then
  echo "✓ VM '$VM_NAME' already exists — skipping image pull. (Delete it with 'tart delete $VM_NAME'"
  echo "  first if you want to redo this from scratch.)"
else
  echo "This pulls $BASE_IMAGE: ~25GB download, ~50GB actual disk usage once unpacked (checked"
  echo "against the live registry manifest — not a guess). Free at least ~60GB before continuing."
  df -H / | tail -1
  pause "Confirm you have enough free disk space."
  tart clone "$BASE_IMAGE" "$VM_NAME" || { echo "✗ pull/clone failed" >&2; exit 1; }
fi

echo
echo "=== Boot the VM yourself ==="
echo "Tart's VM window needs a real interactive terminal to render — a backgrounded/tool-driven"
echo "'tart run' will start the process but never show a window. In your OWN terminal, run:"
echo
echo "    tart run $VM_NAME"
echo
pause "Once its window shows a normal logged-in desktop (auto-login as 'admin' is already configured in the base image), confirm the VM desktop is visible and logged in."

echo "Waiting for the guest agent to come up…"
for i in $(seq 1 30); do
  tart exec "$VM_NAME" true >/dev/null 2>&1 && break
  sleep 1
done
if ! tart exec "$VM_NAME" true >/dev/null 2>&1; then
  echo "✗ Can't reach the guest agent yet — is the VM really running (tart list)?" >&2
  exit 1
fi
echo "✓ Guest agent reachable."

echo
echo "=== Non-interactive prep (no manual steps) ==="
tart exec "$VM_NAME" sudo pmset -a sleep 0 displaysleep 0 disksleep 0
tart exec "$VM_NAME" defaults -currentHost write com.apple.screensaver idleTime 0
tart exec "$VM_NAME" defaults write com.apple.screensaver askForPassword -int 0
echo "✓ Sleep/screensaver disabled (a locked screen would break AX/UI-scripting mid-run)."

echo
echo "=== Push Strip.app and launch it (triggers its own Accessibility prompt) ==="
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [ ! -d "$REPO_ROOT/.build/Strip.app" ]; then
  echo "✗ $REPO_ROOT/.build/Strip.app not found — run 'make bundle' first." >&2
  exit 1
fi
tart exec "$VM_NAME" mkdir -p /tmp/wm-e2e-setup
tar -czf - -C "$REPO_ROOT/.build" Strip.app | tart exec -i "$VM_NAME" sh -c "tar -xzf - -C /tmp/wm-e2e-setup"
tart exec "$VM_NAME" cp -R /tmp/wm-e2e-setup/Strip.app /Applications/Strip.app
tart exec "$VM_NAME" open /Applications/Strip.app

pause "A permission prompt should appear in the VM window. Click 'Open System Settings', then in
Privacy & Security > Accessibility, toggle Strip ON (password: admin)."

echo
echo "=== Manual grant #2: Terminal — Accessibility ==="
echo "In the VM: System Settings > Privacy & Security > Accessibility > + > (Cmd-Shift-G) >"
echo "  /System/Applications/Utilities/Terminal.app"
echo "Toggle it ON. (This is usually offered as a natural prompt the first time a script drives"
echo "Terminal — if you see that prompt instead, just click through it.)"
pause "Confirm Terminal has Accessibility."

echo
echo "=== Manual grant #3: Terminal — Developer Tools ==="
echo "This is the one that's easy to miss and the one that actually gates UI-scripting from a"
echo "Terminal-launched script (found the hard way — see TESTING.md). In the VM:"
echo "  System Settings > Privacy & Security > Developer Tools > add Terminal if not listed > toggle ON."
pause "Confirm Terminal has Developer Tools."

echo
echo "=== Manual grant #4 & #5: tart-guest-agent and osascript — Accessibility ==="
echo "Also granted during verification; include them for reliability even though the final design"
echo "routes UI-scripting through a Terminal session. In the VM, System Settings > Privacy & Security"
echo "> Accessibility > + > Cmd-Shift-G, add each of:"
echo "    /opt/homebrew/bin/tart-guest-agent"
echo "    /usr/bin/osascript"
pause "Confirm both are added and toggled ON."

echo
echo "=== Verifying the full recipe works ==="
cat > /tmp/wm-e2e-setup-verify-local.sh << 'EOF'
#!/bin/bash
osascript -e 'tell application "System Events" to tell process "Strip" to click menu bar item 1 of menu bar 1' > /tmp/wm-e2e-setup-verify.txt 2>&1
osascript -e 'tell application "System Events" to key code 53' >> /tmp/wm-e2e-setup-verify.txt 2>&1
echo "OK" >> /tmp/wm-e2e-setup-verify.txt
EOF
tart exec -i "$VM_NAME" tee /tmp/wm-e2e-setup-verify.sh < /tmp/wm-e2e-setup-verify-local.sh >/dev/null
tart exec "$VM_NAME" chmod +x /tmp/wm-e2e-setup-verify.sh
tart exec "$VM_NAME" rm -f /tmp/wm-e2e-setup-verify.txt
tart exec "$VM_NAME" osascript -e 'tell application "Terminal" to do script "/tmp/wm-e2e-setup-verify.sh"' >/dev/null
sleep 3
result="$(tart exec "$VM_NAME" cat /tmp/wm-e2e-setup-verify.txt 2>/dev/null)"
if [[ "$result" == *"OK"* ]] && [[ "$result" != *"not allowed"* ]]; then
  echo "✓ UI-scripting works end to end. Setup complete — 'make e2e-vm' should work now (with the"
  echo "  VM left running via 'tart run $VM_NAME')."
else
  echo "✗ Still not working. Output was:" >&2
  echo "$result" | sed 's/^/    /' >&2
  echo "  Re-check the grants above, or see TESTING.md for the full debugging narrative." >&2
  exit 1
fi
