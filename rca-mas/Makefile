SHELL := /usr/bin/env bash
BUG   ?= examples/bug.md

.PHONY: lint test test-real-briefing run run-validate report clean

lint:
	@bash -n rca-mas.sh scripts/*.sh collectors/*.sh lib/*.sh
	@echo "Lint: OK"

test:
	@bash tests/test_briefing.sh
	@bash tests/test_collectors.sh
	@bash tests/test_json_schemas.sh
	@bash tests/test_smoke_report_only.sh
	@echo "All tests passed."

test-real-briefing:
	@bash tests/test_real_repo_briefing.sh

run:
	./rca-mas.sh $(BUG)

run-validate:
	./rca-mas.sh $(BUG) --validate

report:
	@cat .rca-mas/runs/latest/report.md

clean:
	rm -rf .rca-mas/runs .rca-mas-worktrees
