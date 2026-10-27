#!/usr/bin/env bash
# Summarize the Overview search prototype's feedback log lines (counts/ranks only — no query text).
# Usage: scripts/search-feedback.sh [/tmp/strip.log]
set -euo pipefail
log="${1:-${STRIP_LOG:-/tmp/strip.log}}"
grep -E ' search: ' "$log" | awk '
  / search: begin /         { begins++; split($0, a, "via="); via[a[2]]++ }
  / search: pick /          { picks++; for (i = 1; i <= NF; i++) { if ($i ~ /^kind=/) kind[substr($i, 6)]++; if ($i ~ /^rank=/) rank[substr($i, 6)]++; if ($i ~ /^via=/) pvia[substr($i, 5)]++; if ($i ~ /^qlen=/) q += substr($i, 6) } }
  / search: end /           { for (i = 1; i <= NF; i++) { if ($i ~ /^reason=/) reason[substr($i, 8)]++; if ($i ~ /^peeks=/) peeks += substr($i, 7) } }
  / search: peek id=/       { pk++; v = $NF; sub(/ms$/, "", v); pms += v; if (v > pmax) pmax = v }
  / search: peek capture failed/ { pfail++ }
  / search: tab scan done / { scans++; for (i = 1; i <= NF; i++) { if ($i ~ /^tabs=/) tabs += substr($i, 6); if ($i ~ /^ambiguous=/) amb += substr($i, 11); if ($i ~ /ms$/) { v = $i; sub(/ms$/, "", v); ms += v; if (v > maxms) maxms = v } } }
  END {
    printf "sessions: %d   picks: %d (%.0f%%)\n", begins, picks, begins ? 100 * picks / begins : 0
    printf "opened via:"; for (k in via) printf " %s=%d", k, via[k]; print ""
    printf "ended:     "; for (k in reason) printf " %s=%d", k, reason[k]; print ""
    printf "pick kind: "; for (k in kind) printf " %s=%d", k, kind[k]; print ""
    printf "pick rank: "; for (k in rank) printf " #%d=%d", k, rank[k]; print ""
    printf "picked by: "; for (k in pvia) printf " %s=%d", k, pvia[k]; print ""
    if (picks) printf "avg query length at pick: %.1f\n", q / picks
    if (peeks || pk) printf "tab peeks: %d   first capture after press avg/max: %.0f/%.0f ms   failed captures: %d\n", peeks, pk ? pms / pk : 0, pmax, pfail
    if (scans) printf "tab scans: %d   avg tabs: %.1f   ambiguous windows: %d   scan ms avg/max: %.1f/%.1f\n", scans, tabs / scans, amb, ms / scans, maxms
  }'
