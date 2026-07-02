#!/usr/bin/env bash
# Runs the *existing, unmodified* scripts/e2e/{run.sh,scenarios.sh,lib/*} suite inside an isolated
# Tart macOS VM instead of the real desktop — no "clean desktop" precondition to maintain by hand.
# See TESTING.md's "Isolated runs via a Tart VM" section for the one-time setup this depends on and
# the (non-obvious) reasons for the shape of this script.
set -uo pipefail

VM_NAME="strip-e2e"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GUEST_DIR="/tmp/wm-e2e"
GUEST_RUNNER="/tmp/wm-e2e-runner.sh"
GUEST_LOG="/tmp/wm-e2e-output.log"
GUEST_EXITCODE="/tmp/wm-e2e-exitcode"
POLL_TIMEOUT_S=300

if ! command -v tart >/dev/null 2>&1; then
  echo "✗ tart not installed — 'brew install cirruslabs/cli/tart' (see TESTING.md)." >&2
  exit 1
fi

if ! tart list 2>/dev/null | awk '{print $2}' | grep -qx "$VM_NAME"; then
  echo "✗ VM '$VM_NAME' doesn't exist — run scripts/e2e/vm/setup.sh first (one-time, mostly manual)." >&2
  exit 1
fi

if ! tart list 2>/dev/null | grep "^local  $VM_NAME " | grep -q running; then
  echo "✗ VM '$VM_NAME' isn't running. Start it yourself in a terminal first:" >&2
  echo "    tart run $VM_NAME" >&2
  echo "  (must be launched from a real interactive terminal, and NOT with --no-graphics — both are" >&2
  echo "  required for the guest's own UI-scripting to work; see TESTING.md.)" >&2
  exit 1
fi

echo "=== Strip e2e suite (Tart VM: $VM_NAME) ==="

echo "Pushing $(basename "$ROOT")/.build/Strip.app + scripts/e2e into the guest…"
tart exec "$VM_NAME" sh -c "rm -rf $GUEST_DIR && mkdir -p $GUEST_DIR" || exit 1
if ! tar -czf - -C "$ROOT" .build/Strip.app scripts/e2e | tart exec -i "$VM_NAME" sh -c "tar -xzf - -C $GUEST_DIR"; then
  echo "✗ Failed to push files into the guest — is '$VM_NAME' still running (tart list)?" >&2
  exit 1
fi

# Written fresh each run — /tmp doesn't survive a VM stop/restart, and the suite always needs the
# freshest host-built Strip.app anyway.
RUNNER_LOCAL="$(mktemp)"
trap 'rm -f "$RUNNER_LOCAL"' EXIT
cat > "$RUNNER_LOCAL" << EOF
#!/bin/bash
cd $GUEST_DIR || exit 1
bash scripts/e2e/run.sh > $GUEST_LOG 2>&1
echo \$? > $GUEST_EXITCODE
EOF
tart exec -i "$VM_NAME" tee "$GUEST_RUNNER" < "$RUNNER_LOCAL" >/dev/null
tart exec "$VM_NAME" chmod +x "$GUEST_RUNNER"
tart exec "$VM_NAME" rm -f "$GUEST_EXITCODE" "$GUEST_LOG"

# MUST run as a child of a real Terminal.app session inside the guest, not as a direct `tart exec`
# target — confirmed empirically (not assumed) that osascript's System-Events UI-scripting (which
# the suite depends on throughout) fails with "osascript is not allowed assistive access" when
# tart-guest-agent execs it directly, but succeeds when it runs inside a Terminal `do script`. Every
# grant needed is one-time, done in scripts/e2e/vm/setup.sh / TESTING.md — this script doesn't grant
# anything itself.
echo "Launching the suite inside the guest (via a Terminal session — see TESTING.md if this ever"
echo "regresses to an 'assistive access' error)…"
if ! tart exec "$VM_NAME" osascript -e "tell application \"Terminal\" to do script \"$GUEST_RUNNER\"" >/dev/null; then
  echo "✗ Failed to launch the suite inside the guest." >&2
  exit 1
fi

echo "Waiting for the guest run to finish (up to ${POLL_TIMEOUT_S}s)…"
elapsed=0
code=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_S" ]; do
  code=$(tart exec "$VM_NAME" cat "$GUEST_EXITCODE" 2>/dev/null)
  [ -n "$code" ] && break
  sleep 3
  elapsed=$((elapsed + 3))
done

if [ -z "$code" ]; then
  echo "✗ TIMEOUT waiting for the guest run after ${POLL_TIMEOUT_S}s. Partial output:" >&2
  tart exec "$VM_NAME" cat "$GUEST_LOG" 2>&1 | sed 's/^/    /' >&2
  exit 1
fi

tart exec "$VM_NAME" cat "$GUEST_LOG" 2>&1
exit "$code"
