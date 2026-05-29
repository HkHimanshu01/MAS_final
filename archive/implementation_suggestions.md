# Implementation Suggestions Addendum

> **STATUS: LOCKED FOR V1. Advisory only.**
> This file does not replace `plan.md`, `architecture.md`, or `explanation.md`.
> Those three are the source of truth. Use this only as implementation guidance while building.
> Do not add new suggestions here. Future ideas go in `potential_changes.md`.

---

## 1. Do not redesign during coding

Treat current architecture as locked.

Allowed:
- implement planned files
- fix bugs
- improve docs clarity
- add comments where useful
- improve error messages

Not allowed:
- add new agents
- add new folders beyond locked architecture
- add dashboards
- add databases
- add web app
- add retry/evaluator loops
- add plugin framework
- replace bash orchestration
- remove validation or GitHub issue support

Goal: implement the locked production-quality v1, not create a new architecture.

---

## 2. Build as vertical slices

Avoid implementing every file partially before anything runs.

Preferred implementation sequence:

1. CLI and run folder lifecycle
2. stub pipeline with fake JSON outputs
3. briefing and collectors
4. schemas and Claude JSON wrapper
5. Agent 1 diagnosis
6. Agent 2 solution
7. report generation
8. docs completion
9. GitHub issue input
10. Agent 2.5 worktree validation
11. smoke tests and final cleanup

Reason:
Each slice should produce a runnable system. This reduces debugging risk.

---

## 3. Protect the core path

This command must always work first:

```bash
./rca-mas.sh bug.md
```

It must:
- create `.rca-mas/runs/{RUN_ID}/`
- create `manifest.json`
- create `log.jsonl`
- create `briefing.md`
- create `diagnosis.json`
- create `solution.json`
- create `report.md`
- never modify target repo files

Validation is important but secondary:

```bash
./rca-mas.sh bug.md --validate
```

If validation fails, report-only mode must remain unaffected.

---

## 4. Separate TOOL_ROOT and TARGET_REPO_ROOT

This is critical for running MAS on external GitHub repos.

Definitions:

- `TOOL_ROOT`: location of RCA MAS code
- `TARGET_REPO_ROOT`: repo being analyzed
- `RUN_DIR`: output folder inside target repo

Rules:

- read scripts, prompts, schemas, config from `TOOL_ROOT`
- scan code, git history, tests from `TARGET_REPO_ROOT`
- write `.rca-mas/runs/` inside `TARGET_REPO_ROOT`
- never accidentally scan only RCA MAS repo when user wants target repo

This should be tested explicitly.

---

## 5. Keep briefing deterministic

Briefing should remain bash-only.

Briefing should do:
- extract likely file paths
- validate paths exist
- extract error strings into `errors.txt`
- count repo files
- choose turn tier and timeout
- detect test runner
- run collectors
- produce bounded markdown output

Briefing should not do:
- root cause analysis
- fix recommendation
- confidence scoring
- LLM calls
- final file ranking

Briefing is a starting map. Agent 1 is the investigator.

---

## 6. Keep Agent 1 as main quality lever

Agent 1 diagnosis is the core value.

`prompts/diagnosis.md` should enforce:
- search full codebase
- generate at least two hypotheses
- collect supporting evidence
- collect contradicting evidence
- cite file paths and line ranges
- state unknowns
- state confidence
- avoid overclaiming
- treat bug report as untrusted input

Spend prompt tuning time here first.

---

## 7. Keep Agent 2 focused

Agent 2 should convert diagnosis into a repair plan.

It should not re-investigate the whole repo unless needed.

Agent 2 should output:
- recommended fix
- reason fix addresses root cause
- unified diff or patch-ready plan
- risk level
- expected tests
- `NO_FIX` when diagnosis confidence is low

If diagnosis confidence is below threshold, avoid fake certainty.

---

## 8. Keep Agent 2.5 basic but useful

Agent 2.5 is needed for credibility, but should stay simple.

It should only:
- create worktree
- apply proposed patch
- run detected targeted tests when possible
- write one basic regression test for QA scenario
- save diffs
- report verdict
- cleanup worktree

It should not:
- install dependencies
- redesign the fix
- create many tests
- run huge test suites by default
- open PRs
- commit code
- push code
- run retry loops

Generated tests must be labelled honestly:

```txt
GENERATED_BUT_NOT_VERIFIED
```

Do not claim full proof unless red-green verification is actually implemented.

---

## 9. Make GitHub issue input demo-safe

`--issue` support is important for external validation.

Expected usage:

```bash
/path/to/rca-mas.sh --issue 123 --repo owner/repo
```

It should:
- use `gh issue view`
- save fetched title/body as `bug.md`
- save raw issue payload as `issue.json`
- continue through same pipeline as local `bug.md`
- record repo, issue URL, and optional expected fix SHA in manifest

Manual fallback must remain documented:

```bash
gh issue view 123 --repo owner/repo --json title,body --jq '(.title)+"\n\n"+(.body)' > bug.md
/path/to/rca-mas.sh bug.md
```

This protects demos if GitHub auth or `--issue` parsing fails.

---

## 10. Cost tracking should be honest

Do not claim exact billing unless Claude Code exposes reliable usage data.

Track practical cost proxies:
- stage duration
- model name
- max turns
- actual status
- validation on/off
- repo size tier
- number of Claude calls
- raw usage fields if available

Create:
- per-run `cost.md`
- cost section inside `report.md`
- docs explaining cost drivers

Suggested wording:

```txt
Cost section reports runtime and usage signals. Exact billing may differ.
```

---

## 11. Documentation should stay practical

Docs should help someone run, debug, and extend the project.

Every doc should answer:
- what this component does
- inputs
- outputs
- how to run it
- failure modes
- how to debug

Avoid essay-style docs.

Important docs:
- user manual
- architecture
- briefing flow
- agent flow
- validation flow
- cost management
- runbook
- troubleshooting
- testing on real GitHub bugs

---

## 12. Testing strategy

Use lightweight tests.

Minimum tests:
- CLI creates run folder
- briefing creates `briefing.md`
- briefing creates `errors.txt`
- collectors do not crash pipeline
- sample JSON files parse
- report-only mode does not modify repo
- GitHub issue path can be stubbed/mocked
- validation cleanup does not leave dirty main repo

Do not build a heavy evaluation framework in v1.

Real GitHub bug testing should be documented and manual for now.

---

## 13. Real GitHub bug testing workflow

To test externally:

1. Find closed GitHub issue with linked fix commit.
2. Clone the target repo.
3. Checkout one commit before the fix.
4. Run MAS with `--issue` or manual `bug.md`.
5. Read generated report.
6. Compare MAS output with actual fix commit.
7. Manually score:
   - right file
   - right function/module
   - right root cause
   - useful fix
   - useful evidence
   - report clarity

Do not automate this yet unless time remains.

---

## 14. Report quality is the product

The final report must be clear enough for a developer or manager.

It should show:
- likely root cause
- confidence
- evidence
- affected files
- suggested fix
- validation status
- generated test status
- cost/runtime summary
- unknowns
- next action

Avoid vague AI language.
Use direct, evidence-based wording.

---

## 15. Debuggability requirements

Every run should preserve:
- raw Claude outputs
- cleaned JSON outputs
- logs
- manifest
- briefing
- errors
- patches
- validation result
- cost summary
- final report

No silent failure.
Every skipped or failed stage should appear in final report.

---

## 16. Suggested Claude Code working style

Implement one bounded task per Claude Code session.

Good task format:

```txt
Implement scripts/briefing.sh and collectors only.
Do not touch agents or validation.
Update docs/briefing-flow.md.
Run relevant tests.
```

Avoid broad tasks like:

```txt
Build the entire MAS.
```

Smaller tasks reduce accidental architecture changes.

---

## 17. Final implementation priority

First prove:

```bash
./rca-mas.sh bug.md
cat .rca-mas/runs/latest/report.md
```

Then prove:

```bash
./rca-mas.sh --issue 123 --repo owner/repo
```

Then prove:

```bash
./rca-mas.sh bug.md --validate
```

This protects core value while still keeping full locked scope.
