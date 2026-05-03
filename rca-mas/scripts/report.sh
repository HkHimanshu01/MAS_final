#!/usr/bin/env bash
# scripts/report.sh — JSON -> report.md. Pure bash + jq. No LLM.
# Inputs: DIAGNOSIS, SOLUTION, VALIDATION, COST_SUMMARY, REPORT paths.
# Outputs: REPORT (report.md) with all 11 required sections.
# Failure: always writes report even if some inputs are degraded.
set -Eeuo pipefail
IFS=$'\n\t'

# Stub — full implementation in Step 8
cat > "$REPORT" <<'EOF'
# RCA MAS Report

## Status
STUB — report not yet implemented (Step 8).

## Root Cause
N/A

## Confidence
N/A

## Evidence
N/A

## Affected Files
N/A

## Proposed Fix
N/A

## Patch Files
N/A

## Validation
SKIPPED

## Cost / Runtime
N/A

## Unknowns / Risks
N/A

## Next Action
N/A
EOF
