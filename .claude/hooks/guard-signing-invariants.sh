#!/usr/bin/env bash
# PreToolUse hook — ask for confirmation before edits that can silently break the dev loop.
#
# Two expensive, hard-to-diagnose footguns from CLAUDE.md:
#   1. Changing the code-signing identity (SIGN_ID / the "Strip Dev" cert / setup-signing.sh)
#      resets the Accessibility TCC grant. Recovery is manual: `tccutil reset Accessibility
#      com.spike.strip`, `make open`, then re-toggle Strip in System Settings -> Privacy &
#      Security -> Accessibility. Easy to trip without noticing why the app suddenly can't move
#      windows.
#   2. Changing `swiftLanguageMode` off v5 reintroduces Swift 6 Sendable friction with the
#      CoreFoundation / Accessibility types the codebase leans on.
#
# Emits permissionDecision="ask" ONLY when the edit payload actually touches those invariants,
# so ordinary edits to the Makefile / Package.swift pass through untouched.
set -uo pipefail

input=$(cat)
file=$(printf '%s' "$input" | /usr/bin/jq -r '.tool_input.file_path // ""')
# Collect the text being introduced/removed (Edit -> new/old_string, Write -> content).
payload=$(printf '%s' "$input" | /usr/bin/jq -r \
  '[.tool_input.new_string, .tool_input.content, .tool_input.old_string] | map(select(. != null)) | join("\n")')

reason=""
case "$file" in
  *Package.swift)
    if printf '%s' "$payload" | grep -q 'swiftLanguageMode'; then
      reason="This edit changes swiftLanguageMode in Package.swift. CLAUDE.md requires staying on Swift language mode v5 to avoid Swift 6 Sendable friction with CoreFoundation/AX types. Confirm this is intentional."
    fi
    ;;
  *Makefile | *scripts/setup-signing.sh)
    if printf '%s' "$payload" | grep -Eq 'SIGN_ID|Strip Dev|--sign|codesign'; then
      reason="This edit touches the code-signing identity. Changing it RESETS the Accessibility (TCC) grant — you'll then need: tccutil reset Accessibility com.spike.strip, make open, and a manual re-toggle in System Settings. Confirm this is intentional."
    fi
    ;;
esac

if [ -n "$reason" ]; then
  /usr/bin/jq -n --arg r "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
fi
exit 0
