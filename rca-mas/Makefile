SHELL := /usr/bin/env bash
BUG   ?= examples/bug.md

# ---------------------------------------------------------------------------
# When to use which target:
#
#   While coding (fast feedback):
#     make test-fast          lint + schemas + smoke (~2 min)
#
#   After changing a collector or briefing.sh:
#     make test-briefing      briefing + collectors tests
#
#   Quick real-repo signal (bugs 1 and 4 only):
#     make test-real-repo-quick
#
#   Full synthetic suite (step gate — required before each step):
#     make lint && make test
#
#   Full suite + real-repo (pre-lock gate — required before locking a step):
#     make test-full
# ---------------------------------------------------------------------------

.PHONY: lint test test-fast test-schemas test-briefing \
        test-real-repo test-real-repo-quick test-real-briefing \
        test-full run run-validate report clean

# Syntax check all scripts
lint:
	@bash -n rca-mas.sh scripts/*.sh collectors/*.sh lib/*.sh
	@echo "Lint: OK"

# All synthetic unit tests — no Claude, no network (~6 min on Windows)
# Covers: briefing logic, collectors, JSON schemas, end-to-end pipeline stub
# Step gate: make lint && make test
test:
	@bash tests/test_briefing.sh
	@bash tests/test_collectors.sh
	@bash tests/test_json_schemas.sh
	@bash tests/test_smoke_report_only.sh
	@echo "All unit tests passed."

# Fast subset: lint + schemas + smoke — skip slow briefing/collectors (~2 min)
# Use while actively coding on any file that is not briefing.sh or a collector
test-fast:
	@bash -n rca-mas.sh scripts/*.sh collectors/*.sh lib/*.sh
	@echo "Lint: OK"
	@bash tests/test_json_schemas.sh
	@bash tests/test_smoke_report_only.sh
	@echo "test-fast passed."

# Schema and fixture tests only (~5s)
# Use when iterating on schemas, fixtures, or lib/json.sh
test-schemas:
	@bash tests/test_json_schemas.sh

# Briefing + collectors tests only
# Use when changing briefing.sh or any collector
test-briefing:
	@bash tests/test_briefing.sh
	@bash tests/test_collectors.sh
	@echo "test-briefing passed."

# Real GitHub bug test — all 5 Click bugs (~3 min)
# Requires: git clone https://github.com/pallets/click C:/MAS_final/test-repos/click
# Override clone: RCA_REAL_REPO_ROOT=/path/to/click make test-real-repo
# Run specific bugs: RCA_REAL_REPO_BUGS=1,3 make test-real-repo
test-real-repo:
	@bash tests/test_real_repo_briefing.sh

# Quick real-repo signal — bugs 1 (Easy) and 4 (Medium/Hard) only (~40s)
# Use during active development for fast real-repo feedback
test-real-repo-quick:
	@RCA_REAL_REPO_BUGS=1,4 bash tests/test_real_repo_briefing.sh

# Pre-lock gate: full synthetic suite + all 5 real-repo bugs
# Run before declaring any step complete
test-full:
	@bash tests/test_briefing.sh
	@bash tests/test_collectors.sh
	@bash tests/test_json_schemas.sh
	@bash tests/test_smoke_report_only.sh
	@bash tests/test_real_repo_briefing.sh
	@echo "test-full passed."

# Alias kept for backward compatibility
test-real-briefing: test-real-repo

# Run pipeline against a bug file (default: examples/bug.md)
# Override: make run BUG=path/to/my-bug.md
run:
	./rca-mas.sh $(BUG)

# Run pipeline with worktree validation
run-validate:
	./rca-mas.sh $(BUG) --validate

# Print the latest report
report:
	@cat .rca-mas/runs/latest/report.md

# Remove all run output and worktrees
clean:
	rm -rf .rca-mas/runs .rca-mas-worktrees
