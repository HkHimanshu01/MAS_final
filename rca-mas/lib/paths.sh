#!/usr/bin/env bash
# lib/paths.sh — Run directory creation and canonical path variables.
# Inputs: TARGET_REPO_ROOT and RCA_OUTPUT_DIR must be set.
# Outputs: Exports RUN_DIR and all canonical file path variables.

make_run_id() {
  local ts sha
  ts="$(date +%s)"
  sha="$(git -C "${TARGET_REPO_ROOT:-.}" rev-parse --short HEAD 2>/dev/null || printf 'nongit')"
  printf '%s-%s' "$ts" "$sha"
}

init_run_dir() {
  local run_id="$1"
  export RUN_DIR="${TARGET_REPO_ROOT}/${RCA_OUTPUT_DIR}/runs/${run_id}"
  mkdir -p "${RUN_DIR}/patches"

  # Canonical path variables consumed by all scripts
  export MANIFEST="${RUN_DIR}/manifest.json"
  export LOG_FILE="${RUN_DIR}/log.jsonl"
  export BRIEFING="${RUN_DIR}/briefing.md"
  export ERRORS_TXT="${RUN_DIR}/errors.txt"

  # Agent 1a — investigation phase (toolful, no schema, no file writes)
  export AGENT1A_PROMPT="${RUN_DIR}/agent1a_prompt.md"
  export AGENT1A_OUTPUT="${RUN_DIR}/agent1a_output.txt"
  export AGENT1A_LOG="${RUN_DIR}/agent1a.log"

  # Agent 1a stream artifacts (set -e safe extraction)
  export AGENT1A_STREAM="${RUN_DIR}/agent1a_output.txt.stream"
  export AGENT1A_STDERR="${RUN_DIR}/agent1a_stderr.txt"
  export AGENT1A_EVIDENCE="${RUN_DIR}/agent1a_evidence.txt"
  export AGENT1A_META_ENV="${RUN_DIR}/agent1a_meta.env"
  export AGENT1A_QUALITY_ENV="${RUN_DIR}/agent1a_quality.env"
  export AGENT1A_FINDINGS="${RUN_DIR}/agent1a_findings.md"

  export CHECKPOINT="${RUN_DIR}/checkpoint.json"

  # Agent 1b — conclusion phase (schema-enforced, reads checkpoint)
  export AGENT1B_PROMPT="${RUN_DIR}/agent1b_prompt.md"
  export AGENT1B_LOG="${RUN_DIR}/agent1b.log"
  export AGENT1B_RAW="${RUN_DIR}/agent1b_raw.json"
  export AGENT1B_STDERR="${RUN_DIR}/agent1b_stderr.txt"
  export AGENT1B_META_ENV="${RUN_DIR}/agent1b_meta.env"
  export AGENT1B_QUALITY_ENV="${RUN_DIR}/agent1b_quality.env"
  export AGENT1B_REPAIR_RAW="${RUN_DIR}/agent1b_repair_raw.json"
  export AGENT1B_REPAIR_STDERR="${RUN_DIR}/agent1b_repair_stderr.txt"

  # Legacy name kept for downstream compatibility (diagnosis.json is still the output)
  export AGENT1_PROMPT="${RUN_DIR}/agent1a_prompt.md"
  export AGENT1_LOG="${RUN_DIR}/agent1a.log"

  export AGENT2_PROMPT="${RUN_DIR}/agent2_prompt.md"
  export AGENT25_PROMPT="${RUN_DIR}/agent25_prompt.md"
  export DIAGNOSIS_RAW="${RUN_DIR}/diagnosis.raw.json"
  export DIAGNOSIS="${RUN_DIR}/diagnosis.json"

  # Agent 2 — solution phase (schema-enforced, reads briefing + diagnosis only)
  export AGENT2_RAW="${RUN_DIR}/agent2_raw.json"
  export AGENT2_STDERR="${RUN_DIR}/agent2_stderr.txt"
  export AGENT2_META_ENV="${RUN_DIR}/agent2_meta.env"
  export AGENT2_QUALITY_ENV="${RUN_DIR}/agent2_quality.env"
  export AGENT2_REPAIR_PROMPT="${RUN_DIR}/agent2_repair_prompt.md"
  export AGENT2_REPAIR_RAW="${RUN_DIR}/agent2_repair_raw.json"
  export AGENT2_REPAIR_STDERR="${RUN_DIR}/agent2_repair_stderr.txt"
  export SOLUTION_RAW="${RUN_DIR}/solution.raw.json"
  export SOLUTION="${RUN_DIR}/solution.json"
  export SOLUTION_INVALID="${RUN_DIR}/solution.invalid.json"
  export SOLUTION_INVALID_TXT="${RUN_DIR}/solution.invalid.txt"

  export VALIDATION_RAW="${RUN_DIR}/validation.raw.json"
  export VALIDATION="${RUN_DIR}/validation.json"
  export FIX_DIFF="${RUN_DIR}/patches/fix.diff"
  export REPORT="${RUN_DIR}/report.md"
  export COST_SUMMARY="${RUN_DIR}/cost_summary.json"
  export AGENT2_LOG="${RUN_DIR}/agent2.log"
  export AGENT25_LOG="${RUN_DIR}/agent25.log"
}

update_latest_symlink() {
  local runs_dir="${TARGET_REPO_ROOT}/${RCA_OUTPUT_DIR}/runs"
  local latest="${runs_dir}/latest"
  # Try symlink first (Linux/Mac and Windows with Developer Mode)
  rm -rf "$latest" 2>/dev/null || true
  if ln -sfn "${RUN_DIR}" "$latest" 2>/dev/null && [ -L "$latest" ]; then
    return 0
  fi
  # Windows fallback: write a pointer file; orchestrator syncs files at end of run
  mkdir -p "$latest"
  printf '%s\n' "${RUN_DIR}" > "${latest}/LATEST_RUN"
}

# Called by orchestrator at end of run to sync latest/ with final run dir contents.
sync_latest() {
  local runs_dir="${TARGET_REPO_ROOT}/${RCA_OUTPUT_DIR}/runs"
  local latest="${runs_dir}/latest"
  # If latest is a real symlink it already reflects live RUN_DIR — nothing to do
  [ -L "$latest" ] && return 0
  # Windows directory fallback: copy all output files into latest/
  [ -f "${latest}/LATEST_RUN" ] || return 0
  cp -r "${RUN_DIR}/." "${latest}/" 2>/dev/null || true
}
