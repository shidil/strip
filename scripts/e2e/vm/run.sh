#!/usr/bin/env bash
# Runs the scripts/e2e suite inside an isolated Tart macOS VM instead of the real desktop — no
# "clean desktop" precondition, and the host's own Strip (your live window manager) is never touched.
# See TESTING.md §7 for the one-time setup (scripts/e2e/vm/setup.sh) and the reasons for this shape.
#
#   scripts/e2e/vm/run.sh                       # whole suite
#   scripts/e2e/vm/run.sh scenario_slide …      # a subset (or E2E_ONLY="…"; constraint warm-up always runs)
#   scripts/e2e/vm/run.sh --check               # preflight only: VM, guest agent, signing identity, AX grant
set -uo pipefail

VM_NAME="${STRIP_E2E_VM:-strip-e2e}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GUEST_DIR="/tmp/wm-e2e"
GUEST_RUNNER="/tmp/wm-e2e-runner.sh"
GUEST_LOG="/tmp/wm-e2e-output.log"
GUEST_EXITCODE="/tmp/wm-e2e-exitcode"
POLL_TIMEOUT_S=600
# The guest's own stable signing identity, created once by setup.sh in the guest's login keychain.
# The host build may be ad-hoc (e.g. built where "Strip Dev" isn't visible), and an ad-hoc signature
# changes every build, which silently invalidates the guest's Accessibility grant. Re-signing in the
# guest with one fixed identity keeps the grant valid across every push.
GUEST_SIGN_ID="Strip Dev"
GUEST_KEYCHAIN_PASS="admin" # the cirruslabs base image's admin password

CHECK_ONLY=0
if [ "${1:-}" == "--check" ]; then CHECK_ONLY=1; shift; fi
ONLY="${E2E_ONLY:-$*}"

g() { tart exec "$VM_NAME" "$@"; }
gi() { tart exec -i "$VM_NAME" "$@"; } # stdin piped into the guest command

if ! command -v tart >/dev/null 2>&1; then
  echo "✗ tart not installed — 'brew install cirruslabs/cli/tart' (see TESTING.md)." >&2
  exit 1
fi
if ! tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM_NAME"; then
  echo "✗ VM '$VM_NAME' doesn't exist — run scripts/e2e/vm/setup.sh first (one-time)." >&2
  exit 1
fi
if ! tart list 2>/dev/null | awk -v n="$VM_NAME" '$1 == "local" && $2 == n' | grep -q running; then
  echo "✗ VM '$VM_NAME' isn't running. Start it in your own terminal and leave it open:" >&2
  echo "    tart run $VM_NAME" >&2
  echo "  (a real interactive terminal, NOT --no-graphics — see TESTING.md §7.)" >&2
  exit 1
fi
if ! g true >/dev/null 2>&1; then
  echo "✗ Can't reach the guest agent in '$VM_NAME' — is it still booting?" >&2
  exit 1
fi
if ! g sh -c "security find-identity -p codesigning | grep -q '$GUEST_SIGN_ID'"; then
  echo "✗ No '$GUEST_SIGN_ID' signing identity in the guest — re-run scripts/e2e/vm/setup.sh." >&2
  exit 1
fi

echo "=== Strip e2e suite (Tart VM: $VM_NAME) ==="
if [ ! -d "$ROOT/.build/Strip.app" ]; then
  echo "✗ $ROOT/.build/Strip.app not found — run 'make bundle' first ('make e2e-vm' does)." >&2
  exit 1
fi

echo "Pushing .build/Strip.app + scripts/e2e into the guest…"
g sh -c "rm -rf $GUEST_DIR && mkdir -p $GUEST_DIR" || exit 1
if ! tar -czf - -C "$ROOT" .build/Strip.app scripts/e2e | gi sh -c "tar -xzf - -C $GUEST_DIR"; then
  echo "✗ Failed to push files into the guest." >&2
  exit 1
fi

echo "Re-signing in the guest with its stable '$GUEST_SIGN_ID' identity…"
if ! g sh -c "security unlock-keychain -p '$GUEST_KEYCHAIN_PASS' login.keychain-db >/dev/null 2>&1; \
    codesign --force --sign '$GUEST_SIGN_ID' --identifier io.github.shidil.strip $GUEST_DIR/.build/Strip.app"; then
  echo "✗ Guest codesign failed." >&2
  exit 1
fi

# Written fresh each run — /tmp doesn't survive a VM restart. MUST run as a child of a real
# Terminal.app session in the guest, not a direct `tart exec`: osascript's System Events
# UI-scripting fails with "not allowed assistive access" under tart-guest-agent but works inside a
# Terminal `do script` (Terminal holds Accessibility + Developer Tools — TESTING.md §7).
RUNNER_LOCAL="$(mktemp)"
trap 'rm -f "$RUNNER_LOCAL"' EXIT
if [ "$CHECK_ONLY" == 1 ]; then
  # Launch Strip, wait for its hotkey tap, quit. Proves the Accessibility grant matches the signature.
  cat >"$RUNNER_LOCAL" <<EOF
#!/bin/bash
export STRIP_LOG=/tmp/strip-e2e-check.log
rm -f \$STRIP_LOG
pkill -x Strip 2>/dev/null; sleep 0.3
open --env STRIP_LOG=\$STRIP_LOG $GUEST_DIR/.build/Strip.app
for i in \$(seq 1 50); do grep -q "hotkeys:" \$STRIP_LOG 2>/dev/null && break; sleep 0.1; done
line=\$(grep "hotkeys:" \$STRIP_LOG 2>/dev/null)
ui=\$(osascript -e 'tell application "System Events" to count processes' 2>&1)
pkill -x Strip 2>/dev/null
{ echo "strip: \${line:-no hotkeys line}"; echo "ui-scripting: \$ui"; } > $GUEST_LOG
case "\$line" in *"tap active"*) ;; *) echo 1 > $GUEST_EXITCODE; exit ;; esac
case "\$ui" in *[!0-9]*|"") echo 1 > $GUEST_EXITCODE ;; *) echo 0 > $GUEST_EXITCODE ;; esac
EOF
else
  cat >"$RUNNER_LOCAL" <<EOF
#!/bin/bash
# Shrink this Terminal window below Strip's tiling threshold (StripController.isTileableSize: 20% of
# the display's width AND 40% of its height) so the suite's exact window counts only see the fixture.
# Size, not hiding/minimizing: a scenario's ⌘Tab can activate Terminal, which would undo those.
# Kill any Strip first — one still running from an earlier run re-tiles the window right back.
pkill -x Strip 2>/dev/null; sleep 0.3
osascript -e 'tell application "Terminal" to set bounds of front window to {40, 60, 440, 300}' >/dev/null 2>&1
cd $GUEST_DIR || exit 1
E2E_ONLY="$ONLY" bash scripts/e2e/run.sh > $GUEST_LOG 2>&1
code=\$?
pkill -x Strip 2>/dev/null # leave the guest quiet between runs
echo \$code > $GUEST_EXITCODE
EOF
fi
gi tee "$GUEST_RUNNER" <"$RUNNER_LOCAL" >/dev/null
g chmod +x "$GUEST_RUNNER"
g rm -f "$GUEST_EXITCODE" "$GUEST_LOG"

# Each run opens a new guest Terminal window; close the idle ones earlier runs (and setup.sh) left,
# or Strip manages them alongside the fixture.
g osascript -e 'tell application "Terminal"
  repeat with w in (get every window)
    if not (busy of selected tab of w) then close w
  end repeat
end tell' >/dev/null 2>&1

if ! g osascript -e "tell application \"Terminal\" to do script \"$GUEST_RUNNER\"" >/dev/null; then
  echo "✗ Failed to start the runner in a guest Terminal session." >&2
  exit 1
fi

# Stream the guest's output while it runs, instead of only at the end.
elapsed=0 shown=0 code=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_S" ]; do
  sleep 3
  elapsed=$((elapsed + 3))
  out=$(g cat "$GUEST_LOG" 2>/dev/null) || out=""
  total=$(printf '%s' "$out" | grep -c '') || total=0
  if [ "$total" -gt "$shown" ]; then
    printf '%s\n' "$out" | tail -n "+$((shown + 1))"
    shown=$total
  fi
  code=$(g cat "$GUEST_EXITCODE" 2>/dev/null)
  [ -n "$code" ] && break
done
out=$(g cat "$GUEST_LOG" 2>/dev/null) || out=""
printf '%s\n' "$out" | tail -n "+$((shown + 1))"

if [ -z "$code" ]; then
  echo "✗ TIMEOUT after ${POLL_TIMEOUT_S}s waiting for the guest run." >&2
  exit 1
fi
if [ "$CHECK_ONLY" == 1 ] && [ "$code" != 0 ]; then
  echo "✗ Preflight failed. 'strip:' must say the tap is active (Accessibility granted to the" >&2
  echo "  '$GUEST_SIGN_ID'-signed Strip) and 'ui-scripting:' must be a number (Terminal has" >&2
  echo "  Accessibility + Developer Tools). See TESTING.md §7." >&2
fi
exit "$code"
