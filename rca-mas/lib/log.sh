#!/usr/bin/env bash
# lib/log.sh — Structured JSONL logging + terminal helpers.
# Inputs: LOG_FILE must be set by orchestrator before sourcing.
# Outputs: Appends JSON lines to LOG_FILE; prints to stderr.

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf '[rca-mas] WARNING: %s\n' "$*" >&2; }
info() { printf '[rca-mas] %s\n' "$*" >&2; }

log_event() {
  local level="$1" stage="$2" msg="$3"
  shift 3
  local ts extra="{}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Build extra key=value pairs into JSON
  local kv_json=""
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    kv_json="${kv_json},\"${k}\":\"${v}\""
  done
  printf '{"ts":"%s","level":"%s","stage":"%s","msg":"%s"%s}\n' \
    "$ts" "$level" "$stage" "$msg" "$kv_json" >> "${LOG_FILE:-/dev/stderr}"
}
