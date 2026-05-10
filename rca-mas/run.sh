#!/usr/bin/env bash
# run.sh — Direct bash equivalent for all Makefile targets.
# Use this when `make` is not installed (e.g. Windows/MSYS2 without make).
#
# Usage:
#   bash run.sh lint
#   bash run.sh test-fast
#   bash run.sh test
#   bash run.sh test-briefing
#   bash run.sh test-schemas
#   bash run.sh test-real-repo
#   bash run.sh test-real-repo-quick
#   bash run.sh test-full
#   bash run.sh run [path/to/bug.md]
#   bash run.sh run-validate [path/to/bug.md]
#   bash run.sh report
#   bash run.sh clean
set -Eeuo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUG="${2:-examples/bug.md}"

cmd="${1:-}"

case "$cmd" in
  lint)
    bash -n rca-mas.sh scripts/*.sh collectors/*.sh lib/*.sh
    echo "Lint: OK"
    ;;
  test)
    bash tests/test_briefing.sh
    bash tests/test_collectors.sh
    bash tests/test_json_schemas.sh
    bash tests/test_smoke_report_only.sh
    echo "All unit tests passed."
    ;;
  test-fast)
    bash -n rca-mas.sh scripts/*.sh collectors/*.sh lib/*.sh
    echo "Lint: OK"
    bash tests/test_json_schemas.sh
    bash tests/test_smoke_report_only.sh
    echo "test-fast passed."
    ;;
  test-schemas)
    bash tests/test_json_schemas.sh
    ;;
  test-briefing)
    bash tests/test_briefing.sh
    bash tests/test_collectors.sh
    echo "test-briefing passed."
    ;;
  test-real-repo)
    bash tests/test_real_repo_briefing.sh
    ;;
  test-real-repo-quick)
    RCA_REAL_REPO_BUGS=1,4 bash tests/test_real_repo_briefing.sh
    ;;
  test-real-briefing)
    bash tests/test_real_repo_briefing.sh
    ;;
  test-full)
    bash tests/test_briefing.sh
    bash tests/test_collectors.sh
    bash tests/test_json_schemas.sh
    bash tests/test_smoke_report_only.sh
    bash tests/test_real_repo_briefing.sh
    echo "test-full passed."
    ;;
  run)
    ./rca-mas.sh "$BUG"
    ;;
  run-validate)
    ./rca-mas.sh "$BUG" --validate
    ;;
  report)
    cat .rca-mas/runs/latest/report.md
    ;;
  clean)
    rm -rf .rca-mas/runs .rca-mas-worktrees
    ;;
  *)
    cat >&2 <<EOF
Usage: bash run.sh <target> [bug.md]

Targets:
  lint                  Syntax check all scripts
  test-fast             lint + schemas + smoke (~2 min)
  test-briefing         briefing + collectors tests
  test-schemas          schema and fixture tests only (~5s)
  test                  all 4 synthetic suites (~6 min)
  test-real-repo-quick  bugs 1+4 only, fast real-repo signal (~40s)
  test-real-repo        all 5 real-repo bugs (~3 min)
  test-full             full synthetic + real-repo (pre-lock gate)
  run [bug.md]          run pipeline (default: examples/bug.md)
  run-validate [bug.md] run pipeline with worktree validation
  report                print latest report
  clean                 remove all run outputs and worktrees
EOF
    exit 1
    ;;
esac
