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
  export AGENT1_PROMPT="${RUN_DIR}/agent1_prompt.md"
  export AGENT2_PROMPT="${RUN_DIR}/agent2_prompt.md"
  export AGENT25_PROMPT="${RUN_DIR}/agent25_prompt.md"
  export DIAGNOSIS_RAW="${RUN_DIR}/diagnosis.raw.json"
  export DIAGNOSIS="${RUN_DIR}/diagnosis.json"
  export SOLUTION_RAW="${RUN_DIR}/solution.raw.json"
  export SOLUTION="${RUN_DIR}/solution.json"
  export VALIDATION_RAW="${RUN_DIR}/validation.raw.json"
  export VALIDATION="${RUN_DIR}/validation.json"
  export FIX_DIFF="${RUN_DIR}/patches/fix.diff"
  export REPORT="${RUN_DIR}/report.md"
  export COST_SUMMARY="${RUN_DIR}/cost_summary.json"
  export AGENT1_LOG="${RUN_DIR}/agent1.log"
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
