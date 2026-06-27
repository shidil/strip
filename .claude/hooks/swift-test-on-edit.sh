#!/usr/bin/env bash
# PostToolUse hook — run Strip's pure engine tests when StripKit or test sources change.
#
# CLAUDE.md makes "keep `make test` green" a hard rule, and StripKitTests is pure / fast /
# permission-free, so this gives a tight edit -> test feedback loop. Test or build failures are
# fed straight back to Claude via exit code 2; clean edits exit 0 silently-ish.
#
# Only fires for edits under Sources/StripKit or Tests/StripKitTests — edits elsewhere (docs,
# the AppKit entry point, hook scripts) are skipped so the loop stays fast and relevant.
set -uo pipefail

input=$(cat)
file=$(printf '%s' "$input" | /usr/bin/jq -r '.tool_input.file_path // ""')

case "$file" in
  *Sources/StripKit/*.swift | *Tests/StripKitTests/*.swift) ;;
  *) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

if ! out=$(swift test 2>&1); then
  {
    echo "❌ swift test FAILED after editing ${file##*/} — fix before continuing:"
    printf '%s\n' "$out" | tail -30
  } >&2
  exit 2
fi

echo "✅ swift test green after editing ${file##*/}"
exit 0
