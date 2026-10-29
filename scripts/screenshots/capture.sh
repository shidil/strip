#!/usr/bin/env bash
# Captures the screenshots used by the website and README, from a RELEASE build of Strip running in
# the strip-e2e Tart VM (never on the host, where Strip is your live window manager).
#
#   scripts/screenshots/capture.sh                  # build release, capture every shot, publish
#   scripts/screenshots/capture.sh search help      # only some shots
#   scripts/screenshots/capture.sh --no-build …     # reuse the existing .build/Strip.app
#   scripts/screenshots/capture.sh --raw-only …     # stop after pulling the PNGs (no publish)
#   SHOT_HEIGHT=0.90 scripts/screenshots/capture.sh # window height (0.05 steps; default 0.85)
#
# Pipeline: make bundle CONFIG=release → push the app, scripts/e2e/lib and scene.sh into the guest →
# re-sign with the guest's stable identity (keeps its privacy grants valid) → run scene.sh inside a
# guest Terminal session → pull PNGs to .build/screenshots/raw/ → publish.sh writes the web JPEGs.
#
# Needs: the VM running (`tart run strip-e2e`) and its one-time grants (scripts/e2e/vm/setup.sh),
# including Screen Recording for the guest's Terminal (step 7).
set -uo pipefail

VM_NAME="${STRIP_E2E_VM:-strip-e2e}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUEST_DIR="/tmp/strip-shots"
GUEST_LOG="$GUEST_DIR/scene-output.log"
GUEST_SIGN_ID="Strip Dev"
GUEST_KEYCHAIN_PASS="admin" # the cirruslabs base image's admin password
RAW_DIR="$ROOT/.build/screenshots/raw"
POLL_TIMEOUT_S=300

BUILD=1 PUBLISH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --raw-only) PUBLISH=0; shift ;;
    *) break ;;
  esac
done
SHOTS="$*"

g() { tart exec "$VM_NAME" "$@"; }
gi() { tart exec -i "$VM_NAME" "$@"; }

command -v tart >/dev/null 2>&1 || { echo "✗ tart not installed (see TESTING.md §7)." >&2; exit 1; }
if ! tart list 2>/dev/null | awk -v n="$VM_NAME" '$1 == "local" && $2 == n' | grep -q running; then
  echo "✗ VM '$VM_NAME' isn't running. Start it in your own terminal and leave it open:" >&2
  echo "    tart run $VM_NAME" >&2
  exit 1
fi
g true >/dev/null 2>&1 || { echo "✗ Can't reach the guest agent in '$VM_NAME' — still booting?" >&2; exit 1; }

if [ "$BUILD" == 1 ]; then
  echo "Building a release bundle…"
  (cd "$ROOT" && make bundle CONFIG=release) || { echo "✗ release build failed" >&2; exit 1; }
fi
[ -d "$ROOT/.build/Strip.app" ] || { echo "✗ .build/Strip.app missing (drop --no-build)." >&2; exit 1; }

echo "Pushing Strip.app + scene into the guest…"
g sh -c "rm -rf $GUEST_DIR && mkdir -p $GUEST_DIR" || exit 1
cp "$ROOT/site/assets/img/og-image.png" "$ROOT/.build/og-image.png"
tar -czf - -C "$ROOT" .build/Strip.app .build/og-image.png scripts/e2e/lib scripts/screenshots \
  | gi sh -c "tar -xzf - -C $GUEST_DIR && mv $GUEST_DIR/.build/og-image.png $GUEST_DIR/" \
  || { echo "✗ push failed" >&2; exit 1; }

echo "Re-signing in the guest with '$GUEST_SIGN_ID'…"
g sh -c "security unlock-keychain -p '$GUEST_KEYCHAIN_PASS' login.keychain-db >/dev/null 2>&1; \
  codesign --force --sign '$GUEST_SIGN_ID' --identifier io.github.shidil.strip $GUEST_DIR/.build/Strip.app" \
  || { echo "✗ guest codesign failed (run scripts/e2e/vm/setup.sh)" >&2; exit 1; }

# Close idle Terminal windows from earlier runs, or Strip would manage them as part of the scene.
g osascript -e 'tell application "Terminal"
  repeat with w in (get every window)
    if not (busy of selected tab of w) then close w
  end repeat
end tell' >/dev/null 2>&1

# Run scene.sh as a child of a real guest Terminal session: UI scripting and screencapture need that
# Terminal's grants, which a plain `tart exec` doesn't have (TESTING.md §7).
g osascript -e "tell application \"Terminal\" to do script \"SHOT_HEIGHT=${SHOT_HEIGHT:-0.85} bash $GUEST_DIR/scripts/screenshots/scene.sh $GUEST_DIR $SHOTS > $GUEST_LOG 2>&1\"" >/dev/null \
  || { echo "✗ couldn't start the scene in a guest Terminal" >&2; exit 1; }

elapsed=0 shown=0 code=""
while [ "$elapsed" -lt "$POLL_TIMEOUT_S" ]; do
  sleep 3; elapsed=$((elapsed + 3))
  out=$(g cat "$GUEST_LOG" 2>/dev/null) || out=""
  total=$(printf '%s' "$out" | grep -c '') || total=0
  if [ "$total" -gt "$shown" ]; then printf '%s\n' "$out" | tail -n "+$((shown + 1))"; shown=$total; fi
  code=$(g cat "$GUEST_DIR/out/exitcode" 2>/dev/null) && [ -n "$code" ] && break
done
out=$(g cat "$GUEST_LOG" 2>/dev/null) || out=""
printf '%s\n' "$out" | tail -n "+$((shown + 1))"

mkdir -p "$RAW_DIR"
g cat "$GUEST_DIR/strip.log" >"$ROOT/.build/screenshots/strip.log" 2>/dev/null
[ -n "$code" ] || { echo "✗ TIMEOUT after ${POLL_TIMEOUT_S}s" >&2; exit 1; }
[ "$code" == 0 ] || { echo "✗ scene failed (Strip's log: .build/screenshots/strip.log)" >&2; exit 1; }

g sh -c "cd $GUEST_DIR/out && tar -cf - *.png" | tar -xf - -C "$RAW_DIR" || { echo "✗ pull failed" >&2; exit 1; }
echo "Raw captures: ${RAW_DIR#"$ROOT"/}/"
ls "$RAW_DIR"

[ "$PUBLISH" == 1 ] && bash "$ROOT/scripts/screenshots/publish.sh" $SHOTS
exit 0
