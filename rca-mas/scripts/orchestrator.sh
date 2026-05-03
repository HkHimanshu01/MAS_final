#!/usr/bin/env bash
# scripts/orchestrator.sh — Pipeline controller. Owns run lifecycle start to finish.
# Inputs: BUG_FILE, ISSUE_NUM, REPO_SLUG, VALIDATE, TARGET_REPO_ROOT, TOOL_ROOT (exported by rca-mas.sh).
# Outputs: RUN_DIR with all artifacts; prints report path on completion.
# Failure: always attempts to write report even if stages degrade.
set -Eeuo pipefail
IFS=$'\n\t'

# --- Source libs ---
# shellcheck source=../lib/log.sh
source "${TOOL_ROOT}/lib/log.sh"
# shellcheck source=../lib/json.sh
source "${TOOL_ROOT}/lib/json.sh"
# shellcheck source=../lib/paths.sh
source "${TOOL_ROOT}/lib/paths.sh"
# shellcheck source=../lib/cleanup.sh
source "${TOOL_ROOT}/lib/cleanup.sh"

# --- Source config (already sourced by rca-mas.sh but re-source for safety) ---
source "${TOOL_ROOT}/config/defaults.env"

# --- Determine mode ---
MODE="report-only"
[ "${VALIDATE:-0}" = "1" ] && MODE="validate"

# --- Generate run ID and init run dir ---
RUN_ID="$(make_run_id)"
init_run_dir "$RUN_ID"
update_latest_symlink

# --- Register cleanup trap ---
trap 'run_cleanup' EXIT

# --- Start logging ---
log_event "info" "orchestrator" "run started" "run_id=${RUN_ID}" "mode=${MODE}"
info "Run ${RUN_ID} starting (${MODE})"

# --- Collect tool versions ---
CLAUDE_VER="$(claude --version 2>/dev/null || echo 'unknown')"
GIT_VER="$(git --version 2>/dev/null | awk '{print $3}' || echo 'unknown')"
JQ_VER="$(jq --version 2>/dev/null || echo 'unknown')"
GH_VER="$(gh --version 2>/dev/null | head -1 | awk '{print $3}' || echo 'not-installed')"

# --- Write manifest.json ---
cat > "$MANIFEST" <<EOF
{
  "run_id": "${RUN_ID}",
  "mode": "${MODE}",
  "tool_root": "${TOOL_ROOT}",
  "target_repo_root": "${TARGET_REPO_ROOT}",
  "repo_remote_url": "$(git -C "${TARGET_REPO_ROOT}" remote get-url origin 2>/dev/null || echo 'unknown')",
  "git_head_sha": "$(git -C "${TARGET_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "git_branch": "$(git -C "${TARGET_REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')",
  "bug_source": "${ISSUE_NUM:+github_issue}${BUG_FILE:+file}",
  "bug_source_file": "${BUG_FILE:-}",
  "issue_url": null,
  "expected_fix_commit": "${EXPECTED_FIX_SHA:-}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ended_at": null,
  "stage_statuses": {
    "briefing": "pending",
    "agent1": "pending",
    "agent2": "pending",
    "validation": "pending",
    "report": "pending"
  },
  "stage_durations_seconds": {
    "briefing": null,
    "agent1": null,
    "agent2": null,
    "validation": null,
    "report": null
  },
  "cost_summary": "${COST_SUMMARY}",
  "tool_versions": {
    "claude": "${CLAUDE_VER}",
    "git": "${GIT_VER}",
    "jq": "${JQ_VER}",
    "gh": "${GH_VER}"
  }
}
EOF
log_event "info" "orchestrator" "manifest written" "run_id=${RUN_ID}"

# --- Resolve bug input ---
if [ -n "${ISSUE_NUM:-}" ]; then
  info "Fetching GitHub issue #${ISSUE_NUM}..."
  SLUG="${REPO_SLUG:-}"
  REPO_FLAG=""
  [ -n "$SLUG" ] && REPO_FLAG="--repo ${SLUG}"
  # shellcheck disable=SC2086
  gh issue view "$ISSUE_NUM" $REPO_FLAG \
    --json number,title,body,url,state,labels,author,createdAt,updatedAt \
    > "${RUN_DIR}/issue.json"
  jq -r '"# " + .title + "\n\n" + .body' "${RUN_DIR}/issue.json" > "${RUN_DIR}/bug.md"
  ISSUE_URL="$(jq -r '.url' "${RUN_DIR}/issue.json")"
  # Update manifest with issue URL
  tmp="$(mktemp)"
  jq --arg url "$ISSUE_URL" '.issue_url = $url | .bug_source = "github_issue"' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
  export BUG_FILE="${RUN_DIR}/bug.md"
  export BUG_INPUT_FILE="${RUN_DIR}/bug.md"
else
  # Save original path before overwriting BUG_FILE with the run copy
  export BUG_INPUT_FILE="$BUG_FILE"
  cp "$BUG_FILE" "${RUN_DIR}/bug.md"
  export BUG_FILE="${RUN_DIR}/bug.md"
fi

# --- Stage helper: record duration and update stage_statuses in manifest ---
_stage_start=0
stage_begin() {
  _stage_start="$(date +%s)"
}
stage_end() {
  local name="$1" status="$2"
  local dur=$(( $(date +%s) - _stage_start ))
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$status" --argjson d "$dur" \
    '.stage_statuses[$n] = $s | .stage_durations_seconds[$n] = $d' \
    "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
  log_event "info" "$name" "stage complete" "status=${status}" "duration_seconds=${dur}"
}

# ============================================================
# STAGE: Briefing
# ============================================================
info "Briefing..."
stage_begin
source "${TOOL_ROOT}/scripts/briefing.sh"
stage_end "briefing" "ok"

# ============================================================
# STAGE: Agent 1 — Diagnosis (stub)
# ============================================================
info "Agent 1: diagnosis (stub)..."
stage_begin
source "${TOOL_ROOT}/scripts/claude_json.sh"
# Write stub diagnosis JSON
cat > "$DIAGNOSIS" <<'STUB'
{
  "run_id": "stub",
  "root_cause": "STUB — Agent 1 not yet implemented (Step 6)",
  "selected_hypothesis_id": "h1",
  "hypotheses": [
    {
      "id": "h1",
      "summary": "Stub hypothesis",
      "supporting_evidence": [],
      "contradicting_evidence": [],
      "confidence": 0.0
    }
  ],
  "rejected_hypotheses": [],
  "affected_files": [],
  "call_chain": [],
  "files_examined": [],
  "unknowns": ["Agent 1 not yet implemented"],
  "confidence": 0.0,
  "introducing_commit": null,
  "next_best_action": "Implement Agent 1 (Step 6)"
}
STUB
cp "$DIAGNOSIS" "$DIAGNOSIS_RAW"
stage_end "agent1" "stub"

# ============================================================
# STAGE: Agent 2 — Solution (stub)
# ============================================================
info "Agent 2: solution (stub)..."
stage_begin
cat > "$SOLUTION" <<'STUB'
{
  "run_id": "stub",
  "recommendation": "NO_FIX",
  "no_fix_reason": "STUB — Agent 2 not yet implemented (Step 7)",
  "recommended_fix_id": null,
  "fixes": []
}
STUB
cp "$SOLUTION" "$SOLUTION_RAW"
stage_end "agent2" "stub"

# ============================================================
# STAGE: Validation (always skipped in stub)
# ============================================================
cat > "$VALIDATION" <<'STUB'
{
  "run_id": "stub",
  "status": "SKIPPED",
  "worktree_path": null,
  "applied_patch": false,
  "generated_test": false,
  "test_command": null,
  "commands_run": [],
  "failures": [],
  "regression_risk": "unknown",
  "notes": ["Run with --validate to apply patch in a worktree and run tests."]
}
STUB
stage_end "validation" "skipped"

# ============================================================
# STAGE: Cost summary
# ============================================================
cat > "$COST_SUMMARY" <<STUB
{
  "run_id": "${RUN_ID}",
  "mode": "${MODE}",
  "model": "${RCA_MODEL:-claude-sonnet-4-6}",
  "repo_tier": "XS",
  "agent1_max_turns": ${RCA_TURNS_XS},
  "agent1_turns_used": 0,
  "agent2_max_turns": ${RCA_AGENT2_TURNS},
  "stage_durations_seconds": {
    "briefing": 0,
    "agent1": 0,
    "agent2": 0,
    "validation": 0,
    "report": 0
  },
  "total_duration_seconds": 0,
  "validation_run": false,
  "token_counts": {
    "agent1_input": null,
    "agent1_output": null,
    "agent2_input": null,
    "agent2_output": null,
    "note": "populated if Claude raw output exposes usage fields; null otherwise"
  },
  "cost_level": "LOW",
  "authoritative": false,
  "note": "Stub cost summary — real values populated from Step 6 onwards."
}
STUB

# ============================================================
# STAGE: Report
# ============================================================
info "Report..."
stage_begin
source "${TOOL_ROOT}/scripts/report.sh"
stage_end "report" "ok"

# --- Write ended_at to manifest ---
tmp="$(mktemp)"
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.ended_at = $t' "$MANIFEST" > "$tmp"
mv "$tmp" "$MANIFEST"

# --- Sync latest/ directory on Windows (no-op on symlink systems) ---
sync_latest

log_event "info" "orchestrator" "run complete" "run_id=${RUN_ID}" "report=${REPORT}"
info "Report: ${REPORT}"
printf '\n══════════════════════════════════════════\n'
printf ' RCA Report: %s\n' "$REPORT"
printf ' Run ID:     %s\n' "$RUN_ID"
printf '══════════════════════════════════════════\n'
