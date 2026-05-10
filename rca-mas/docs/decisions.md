# Decisions

Architecture decisions made during v1 design, including what was kept, what was cut, and why.

---

## Core Architecture Decisions

### Bash orchestrator, not Python

**Decision:** The orchestrator (`rca-mas.sh`) and all collector scripts are bash.

**Why:** The tool runs inside Claude Code's environment, which guarantees bash availability. Python adds a dependency and startup overhead. Bash scripts are also easier to audit for security — no imports, no pip packages, no supply chain surface.

**Trade-off:** Complex string manipulation is harder in bash than Python. Mitigated by keeping complex logic in awk/grep/sed idioms and documenting patterns in `code_practices.md`.

---

### Sequential pipeline, not parallel agents

**Decision:** Agent 1 → Agent 2 → Agent 2.5 runs in sequence. No parallelism.

**Why:** Each agent's input depends on the previous agent's output. Agent 2 cannot write a fix without reading the diagnosis. Running them in parallel would require speculative execution and merging contradictory results.

**Trade-off:** Total wall-clock time is the sum of all stages. A parallel "hypothesis farm" (multiple Agent 1s with different seeds) was considered but cut from v1 — it triples cost for marginal gain on well-defined bugs.

---

### Briefing is pure bash with zero LLM calls

**Decision:** `briefing.sh` does all repo scanning without invoking Claude.

**Why:** LLM calls are expensive and slow. The briefing information (git history, imports, error locations) is entirely deterministic — there is no ambiguity that requires language understanding. Bash can compute it in 3–30 seconds vs. an LLM turn costing 5–15 seconds and real dollars.

**Impact:** Saves Agent 1 approximately 8–12 orientation turns on every run. On a 25-turn budget, that is the difference between solving the bug and running out of turns before forming a hypothesis.

---

### Agent 2 works only from diagnosis.json, not the raw repo

**Decision:** Agent 2 has no access to the target repo. It reads only `briefing.md` and `diagnosis.json`.

**Why:** Context funnel. Agent 2's job is to write a patch, not to re-investigate. Giving it repo access would cause it to re-run Agent 1's investigation, wasting turns and tokens. Agent 1 has already identified the exact lines that need changing.

**Trade-off:** If Agent 1's diagnosis is wrong or incomplete, Agent 2 cannot recover independently. This is a feature: it forces the diagnosis quality signal to be explicit (the `confidence` score) rather than hidden inside Agent 2's reasoning.

---

### Validation uses a git worktree, not a Docker container

**Decision:** Agent 2.5 validates in a `git worktree` sibling to the target repo.

**Why:** Zero setup — anyone with git has worktrees. Docker would require the user to have Docker installed, configured, and with the right image. Worktrees are also lightweight (they share the git object store) and are automatically cleaned up by git.

**Trade-off:** Test execution environment is not fully isolated. If the target repo's tests depend on system packages or services, worktree validation may fail for environment reasons unrelated to the patch. This is surfaced as `status: ERROR` in `validation.json`.

---

### Confidence scores drive pipeline decisions

**Decision:** Two explicit confidence thresholds control flow: `RCA_CONFIDENCE_STOP` (0.7, Agent 1a early stop) and `RCA_CONFIDENCE_NOFX` (0.5, Agent 2 refuses to patch).

**Why:** Without explicit thresholds, agents would always produce output. A hallucinated root cause followed by a hallucinated patch is worse than a `NO_FIX` response — it sends developers chasing phantom bugs.

**Trade-off:** Thresholds require calibration. At 0.5, some salvageable diagnoses will produce `NO_FIX`. Thresholds are tunable via env vars.

---

### Agent 1 is split into two phases (1a investigation + 1b conclusion)

**Decision:** Agent 1 runs as two sequential Claude Code invocations: Agent 1a (free-text, no schema, writes checkpoint.json) and Agent 1b (schema-enforced, reads checkpoint, emits diagnosis.json).

**Why:** `--json-schema` enforcement forces the model to reserve its final turn for valid JSON output. On medium/hard bugs with 30–60 turns of investigation needed, the model runs out of turns mid-investigation and produces no output at all. Separating the phases gives Agent 1a all its turns for investigation, and Agent 1b a dedicated small budget (5 turns) for synthesis.

**Evidence:** Bug 4 (click ctx.invoke/Sentinel, difficulty: Medium/Hard) failed in 3 consecutive single-phase runs — Agent 1 hit `error_max_turns` every time and produced zero diagnosis output. After the two-phase split, Agent 1a writes checkpoint.json regardless of when it is interrupted, guaranteeing Agent 1b always has something to synthesise from.

**Trade-off:** Two Claude Code invocations instead of one adds ~20–60 seconds of overhead per run. This is acceptable given the alternative is zero output on any bug requiring more than ~15 turns of investigation.

**Key constraint:** Agent 1b must not receive the full briefing — only the checkpoint and bug report. Passing it the full briefing would fill its context and push it back toward re-investigation behaviour.

---

## What Was Cut from v1

### Haiku preprocessing step

**What it was:** A cheap Haiku pass to categorise the bug and route it to a specialised Agent 1 prompt.

**Why cut:** Adds latency and cost before the main investigation. Agent 1 is capable of handling bug classification as part of its investigation. Re-add if Agent 1 routing becomes the bottleneck.

### 5-signal quality scorer

**What it was:** A separate scoring agent that graded Agent 1's diagnosis on 5 axes and decided whether to re-run.

**Why cut:** Doubles Agent 1 cost on every run. The confidence score + turn budget achieves 80% of the same effect without a second LLM call. Re-add if confidence score calibration proves unreliable.

### Agent 3 (patch review)

**What it was:** A review agent that critiqued Agent 2's patch before delivering it to the developer.

**Why cut:** Single-turn Agent 2 at a high confidence threshold produces better patches than a multi-turn review loop in testing. The review step added latency without measurable quality improvement. Re-add if patch quality becomes the top complaint.

### Auto-PR creation

**What it was:** After validation passes, open a GitHub PR automatically.

**Why cut:** Too much trust for v1. Developers need to review the patch before it goes to a PR. The report's `## Next Action` section tells developers how to apply and push the patch manually.

### Jira / Slack integrations

**What they were:** Webhook notifications and issue comment updates.

**Why cut:** Out of scope for v1. The tool's output is `report.md` — integrations are a wrapper concern, not a core concern. Build them as thin shells around `rca-mas.sh` if needed.

### Database / dashboard

**What it was:** A persistent store of all runs for trend analysis and ticket linking.

**Why cut:** Premature. Each run directory already contains all the data needed for retrospective analysis. A dashboard can be built later by scanning `.rca-mas/runs/*/manifest.json` and `cost_summary.json` files.

---

## What Was Kept (and Why It's Non-Obvious)

### Competing hypotheses field in diagnosis.json

The `hypotheses` field requires Agent 1 to list alternatives it considered and rejected. This prevents Agent 1 from fixating on the first plausible explanation. Evidence: on multi-cause bugs (where a workaround masked the real issue), hypothesis tracking caused Agent 1 to find the root cause instead of the symptom in 3 of 5 real-repo test cases.

### NO_FIX as an explicit status (not an empty patch)

When confidence is too low, returning nothing is dishonest. `NO_FIX` is an explicit statement: "I looked and couldn't find a reliable fix." This is more useful to a developer than an empty diff or a generic "could not determine root cause" message.

### Validation is optional (`--validate` flag)

Validation adds 1–3 minutes and requires the test suite to be runnable. Many QA-reported bugs come from codebases where the test suite takes 10+ minutes or requires external services. Making validation optional means the tool is useful even in those contexts. Developers can always run the patch manually.

### `errors.txt` as an intermediate file (not just embedded in briefing)

`errors.sh` reads from `errors.txt`, not from `briefing.md`. This separation means:
1. `errors.sh` can be run independently for debugging
2. Other future consumers (e.g. a pre-Agent 1 grep report) can read the same extracted strings
3. The briefing phase is testable in parts

### File count tier system (XS/S/M/L) rather than a flat budget

A flat 30-turn budget would over-spend on tiny repos and under-spend on large ones. The tier system scales cost with repo size. The breakpoints (100/500/2000 files) were chosen empirically based on the distribution of real-world repo sizes in the test corpus.
