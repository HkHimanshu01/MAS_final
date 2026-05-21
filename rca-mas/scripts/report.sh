#!/usr/bin/env bash
# scripts/report.sh — JSON → report.md. Pure bash + jq. No LLM.
# Inputs: DIAGNOSIS, SOLUTION, VALIDATION, COST_SUMMARY, REPORT, MANIFEST paths.
# Outputs: REPORT (report.md) with 11 mandatory sections.
# Failure: always writes report even if some inputs are degraded.
set -Eeuo pipefail
IFS=$'\n\t'

# --- Helpers ---
_jq() {
  # Read a jq path from a file with a fallback string when missing/null/error.
  local file="$1" query="$2" fallback="${3:-N/A}"
  local val
  val="$(jq -r "$query // empty" "$file" 2>/dev/null || true)"
  [ -z "$val" ] && val="$fallback"
  printf '%s' "$val"
}

_jq_array() {
  # Read a jq array path, return bulleted lines or "(none)".
  local file="$1" query="$2"
  local out
  out="$(jq -r "$query // [] | if length == 0 then \"(none)\" else map(\"- \(. )\") | join(\"\n\") end" "$file" 2>/dev/null || echo "(none)")"
  printf '%s' "$out"
}

# --- Read diagnosis fields ---
_root_cause="$(_jq "$DIAGNOSIS" '.root_cause' 'N/A')"
_confidence="$(_jq "$DIAGNOSIS" '.confidence' '0')"
_selected_id="$(_jq "$DIAGNOSIS" '.selected_hypothesis_id' '')"
_affected_files="$(_jq_array "$DIAGNOSIS" '.affected_files')"
_files_examined="$(_jq_array "$DIAGNOSIS" '.files_examined')"
_unknowns="$(_jq_array "$DIAGNOSIS" '.unknowns')"
_next_action="$(_jq "$DIAGNOSIS" '.next_best_action' 'N/A')"
_introducing_commit="$(_jq "$DIAGNOSIS" '.introducing_commit' '(not identified)')"

# Build evidence section from selected hypothesis
_evidence="$(jq -r --arg id "$_selected_id" '
  (.hypotheses[]? | select(.id == $id) | .supporting_evidence // []) as $e |
  if ($e | length) == 0 then "(none)"
  else $e | map("- `\(.path):\(.lines)` — \(.note)") | join("\n")
  end
' "$DIAGNOSIS" 2>/dev/null || echo "(none)")"

# --- Read solution fields ---
_solution_status="$(_jq "$SOLUTION" '.recommendation' 'UNKNOWN')"
_solution_conf="$(_jq "$SOLUTION" '.confidence' '0')"
_weak_evidence="$(_jq "$SOLUTION" '.weak_evidence' 'false')"
_weak_reason="$(_jq "$SOLUTION" '.weak_evidence_reason' '')"
_no_fix_reason="$(_jq "$SOLUTION" '.no_fix_reason' '')"
_rec_fix_id="$(_jq "$SOLUTION" '.recommended_fix_id' '')"

# Build proposed fix section
if [ "$_solution_status" = "FIX" ] && [ -n "$_rec_fix_id" ]; then
  _fix_desc="$(jq -r --arg id "$_rec_fix_id" '
    .fixes[]? | select(.id == $id) | .description
  ' "$SOLUTION" 2>/dev/null || echo "(no description)")"
  _fix_why="$(jq -r --arg id "$_rec_fix_id" '
    .fixes[]? | select(.id == $id) | .why_this_fixes_root_cause
  ' "$SOLUTION" 2>/dev/null || echo "")"
  _fix_risk="$(jq -r --arg id "$_rec_fix_id" '
    .fixes[]? | select(.id == $id) | .risk
  ' "$SOLUTION" 2>/dev/null || echo "unknown")"
  _fix_review="$(jq -r --arg id "$_rec_fix_id" '
    .fixes[]? | select(.id == $id) | .manual_review_notes // []
    | if length == 0 then "(none)"
      else map("- \(. )") | join("\n")
      end
  ' "$SOLUTION" 2>/dev/null || echo "(none)")"
  _fix_tests="$(jq -r --arg id "$_rec_fix_id" '
    .fixes[]? | select(.id == $id) | .expected_tests // []
    | if length == 0 then "(none)"
      else map("- `\(. )`") | join("\n")
      end
  ' "$SOLUTION" 2>/dev/null || echo "(none)")"
else
  _fix_desc=""
  _fix_why=""
  _fix_risk=""
  _fix_review=""
  _fix_tests=""
fi

# --- Read validation ---
_val_status="$(_jq "$VALIDATION" '.status' 'SKIPPED')"

# --- Read cost summary ---
_cost_level="$(_jq "$COST_SUMMARY" '.cost_level' 'unknown')"
_total_dur="$(_jq "$COST_SUMMARY" '.total_duration_seconds' '0')"
_model="$(_jq "$COST_SUMMARY" '.model' 'unknown')"
_repo_tier="$(_jq "$COST_SUMMARY" '.repo_tier' 'unknown')"

# --- Status banner ---
case "$_solution_status" in
  FIX)
    if [ "$_weak_evidence" = "true" ]; then
      _status_banner="⚠️ FIX proposed (based on weak evidence — review carefully)"
    else
      _status_banner="✅ FIX proposed"
    fi
    ;;
  NO_FIX)
    _status_banner="🚫 NO_FIX — see reason below"
    ;;
  *)
    _status_banner="⚠️ Solution status unknown: $_solution_status"
    ;;
esac

# --- Patch section ---
if [ "$_solution_status" = "FIX" ] && [ -f "$FIX_DIFF" ]; then
  _patch_path="${FIX_DIFF#${RUN_DIR}/}"
  _patch_bytes="$(wc -c < "$FIX_DIFF" 2>/dev/null || echo 0)"
  _patch_section="- \`${_patch_path}\` (${_patch_bytes} bytes)

To apply:
\`\`\`bash
git apply ${_patch_path}
# Or preview first:
git apply --check ${_patch_path}
\`\`\`"
else
  _patch_section="(none — NO_FIX recommendation)"
fi

# --- Weak evidence banner ---
if [ "$_weak_evidence" = "true" ]; then
  _weak_banner="

> **⚠️ Weak Evidence**: ${_weak_reason}
"
else
  _weak_banner=""
fi

# --- Assemble report ---
cat > "$REPORT" <<EOF
# RCA MAS Report
${_weak_banner}
## Status

${_status_banner}

- Diagnosis confidence: ${_confidence}
- Solution confidence: ${_solution_conf}
- Validation: ${_val_status}

## Root Cause

${_root_cause}

## Confidence

- **Diagnosis (Agent 1b):** ${_confidence}
- **Solution (Agent 2):** ${_solution_conf}
- **Weak evidence flag:** ${_weak_evidence}

## Evidence

${_evidence}

## Affected Files

${_affected_files}

## Proposed Fix

EOF

if [ "$_solution_status" = "FIX" ]; then
  cat >> "$REPORT" <<EOF
**Description:** ${_fix_desc}

**Why this fixes the root cause:** ${_fix_why}

**Risk:** ${_fix_risk}

**Manual review notes:**
${_fix_review}

**Suggested tests:**
${_fix_tests}
EOF
else
  cat >> "$REPORT" <<EOF
**NO_FIX**

${_no_fix_reason}
EOF
fi

cat >> "$REPORT" <<EOF

## Patch Files

${_patch_section}

## Validation

${_val_status}

## Cost / Runtime

- Model: ${_model}
- Repo tier: ${_repo_tier}
- Cost level: ${_cost_level}
- Total wall time: ${_total_dur}s

## Unknowns / Risks

${_unknowns}

## Next Action

${_next_action}

---
*Generated by rca-mas. Files examined: see \`agent1a_evidence.txt\` and \`diagnosis.json\` for full evidence.*
EOF

log_event "info" "report" "report written" "status=${_solution_status}" "weak_evidence=${_weak_evidence}"
