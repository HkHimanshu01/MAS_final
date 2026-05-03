# RCA Compression MAS

**Root Cause Analysis — Multi-Agent System**

A developer productivity tool that reads a QA bug report, searches the codebase, and produces a structured root-cause report in 3–8 minutes — compressing what would otherwise take a developer 30–60 minutes of manual investigation.

---

## The Problem This Solves

In any software delivery team, bugs follow a predictable cycle:

1. Developer writes code, automated tests pass, code is merged
2. QA manually tests the application and finds a bug automated tests missed
3. QA raises a ticket on GitHub or JIRA
4. **Developer opens the ticket, opens the codebase, and spends 30–60 minutes** reading the report, searching files, tracing call chains, checking git history, forming a theory, and verifying it — all under sprint pressure

That 30–60 minute investigation window is the bottleneck this tool addresses. The agent does the search and triage; the developer gets a ready-to-act report.

---

## What It Produces

Given a bug report, the system outputs a `report.md` that contains:

- **Root cause** — the specific file, function, and line where the bug originates
- **Confidence score** — how certain the agent is (0–1)
- **Evidence** — file paths, line numbers, git blame, call chains backing the diagnosis
- **Competing hypotheses** — alternate explanations that were considered and rejected, with reasons
- **Proposed fix** — a unified diff ready for developer review
- **Risk assessment** — low / medium / high impact of applying the fix
- **New regression test** — a test written specifically for this bug scenario (validation mode)
- **Unknowns** — things the agent could not verify and that a human should check
- **Next action** — explicit instructions for what the developer should do next

---

## What the Agent Does NOT Do

This section is the most important one for anyone evaluating or deploying this system.

### The agent never makes decisions for humans

| Action | Who does it |
|---|---|
| Read the report and decide whether the diagnosis is credible | **Human (developer)** |
| Apply the proposed fix to the codebase | **Human (developer)** |
| Decide whether the fix is safe to deploy | **Human (developer + tech lead)** |
| Raise, assign, or close tickets | **Human (QA / project manager)** |
| Communicate the fix to stakeholders | **Human (developer / delivery manager)** |
| Decide whether to run the validation mode | **Human (developer)** |
| Judge whether the generated regression test is adequate | **Human (developer)** |

The system is a **reading and reasoning tool**, not an autonomous repair agent. It never touches application source code in default mode. Even in validation mode, changes are made only inside an isolated git workspace that is discarded after the run.

### What the agent cannot guarantee

- **It may be wrong.** Every report includes a confidence score. Scores below 0.7 should be treated as a starting point for investigation, not a conclusion. The developer must verify.
- **It cannot read environment state.** The agent reads source code and git history. It cannot observe running servers, database contents, live session state, infrastructure config, or anything outside the repository.
- **It cannot test end-to-end behaviour.** Validation runs unit or integration tests that exist in the repo. It does not simulate QA's manual testing steps.
- **It cannot assess business impact.** Whether a bug affects one user or ten thousand, whether it is a P1 or a P4 — that judgement belongs to the delivery team.
- **It cannot replace QA.** The system exists because manual QA finds bugs that automated tests miss. It does not eliminate that need.
- **It may miss bugs in external dependencies, infrastructure, or configuration.** It searches the repository it is pointed at.
- **Generated tests are labelled `GENERATED_BUT_NOT_VERIFIED`.** The developer must review and integrate them into the test suite.

---

## How to Use It

### Prerequisites

- [Claude Code CLI](https://claude.ai/code) installed and logged in
- `git`, `jq`, `bash` available on the machine
- `gh` (GitHub CLI) — only needed for `--issue` input mode

### Quickstart

```bash
# From a bug report file
./rca-mas.sh bug.md

# Read the report
cat .rca-mas/runs/latest/report.md

# Optional: validate the proposed fix in an isolated workspace
./rca-mas.sh bug.md --validate

# From a GitHub Issue directly
./rca-mas.sh --issue 42
./rca-mas.sh --issue 42 --repo owner/repo
```

### Two modes

| Mode | What happens | Touches source code? |
|---|---|---|
| `report-only` (default) | Diagnoses root cause, proposes fix as a diff | Never |
| `--validate` | Additionally applies fix in isolated git workspace, runs existing tests, writes a new regression test | Only inside a temporary isolated workspace, discarded after |

---

## How It Works — For Non-Technical Readers

Think of the system as three specialists working in sequence, each handing off to the next:

**Stage 1 — Triage (instant, no AI)**
Before any AI runs, a fast automated scan reads the bug report, maps the codebase structure, traces imports, and finds where relevant error messages appear in the code. This takes 2 seconds and costs nothing. It gives the AI agents a head start rather than having them fumble through the codebase from scratch.

**Stage 2 — Diagnosis (Agent 1)**
An AI agent with the profile of a senior QA engineer searches the full codebase. It reads files, traces call chains, checks git history, and builds at least two competing explanations for the bug. It documents the evidence for and against each hypothesis, critiques its own reasoning, and produces a structured diagnosis with a confidence score.

**Stage 3 — Solution (Agent 2)**
A separate AI agent — starting fresh with only the diagnosis, not the 30K tokens of exploration from Stage 2 — proposes a focused fix. It produces a unified diff, assesses the risk, and identifies which existing tests should be checked. If confidence is too low, it returns "NO FIX" rather than guessing.

**Stage 4 — Validation (Agent 2.5, optional)**
A third agent applies the proposed fix inside an isolated copy of the repository, runs the relevant existing tests to check for regressions, and writes a new test that specifically reproduces the QA-reported scenario. The isolated copy is deleted after the run. Nothing in the main codebase is changed.

**Stage 5 — Report**
All structured outputs are compiled into a single markdown report for the developer.

---

## Human Handoff Points

These are the moments where a human must engage. The system cannot proceed past these points on its own.

```
QA finds bug → raises ticket
      │
      ▼
  [HUMAN]  Developer decides to run the tool
      │
      ▼
  Agent pipeline runs (3–8 minutes)
      │
      ▼
  [HUMAN]  Developer reads report.md
           ├── Is the diagnosis credible? (confidence score + evidence)
           ├── Does the proposed fix make sense?
           └── Is the risk level acceptable?
      │
      ▼  (if yes)
  [HUMAN]  Developer applies the fix manually
      │
      ▼
  [HUMAN]  Developer reviews and integrates the generated regression test
      │
      ▼
  [HUMAN]  Code review by peers
      │
      ▼
  [HUMAN]  QA retests the fix
      │
      ▼
  [HUMAN]  Deployment decision by delivery manager / tech lead
```

The system accelerates the investigation step. Every decision step remains human.

---

## System Boundaries

```
┌─────────────────────────────────────────────────────┐
│                  INSIDE THE SYSTEM                  │
│                                                     │
│  Reading bug reports                                │
│  Searching source files (read-only)                 │
│  Checking git history                               │
│  Tracing import and call chains                     │
│  Generating diagnosis and hypotheses                │
│  Proposing a fix as a diff                          │
│  Running tests inside isolated workspace            │
│  Writing a regression test draft                    │
│  Producing report.md                                │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│                 OUTSIDE THE SYSTEM                  │
│              (human responsibility)                 │
│                                                     │
│  Deciding whether the diagnosis is correct          │
│  Applying any fix to the codebase                   │
│  Code review and approval                           │
│  Deployment                                         │
│  Ticket management (JIRA / GitHub)                  │
│  Stakeholder communication                          │
│  Business impact assessment                         │
│  Reading environment, infrastructure, or DB state   │
│  End-to-end / regression / load testing             │
│  Security review of the proposed change             │
│  Dependency installation                            │
│  Any network operations                             │
└─────────────────────────────────────────────────────┘
```

---

## Output Files

Every run writes to `.rca-mas/runs/{RUN_ID}/`. The most recent run is always accessible at `.rca-mas/runs/latest/`.

| File | What it contains |
|---|---|
| `report.md` | **Start here.** Developer-facing report with root cause, fix, and next steps |
| `diagnosis.json` | Structured diagnosis: hypotheses, evidence, confidence, affected files |
| `solution.json` | Proposed fix, risk level, expected tests |
| `validation.json` | Test results and regression test status (validation mode only) |
| `patches/fix.diff` | Proposed fix as a unified diff — ready to review and apply |
| `patches/generated_test.diff` | New regression test as a diff — review before adding to test suite |
| `manifest.json` | Run metadata: timestamp, mode, git state, tool versions |
| `log.jsonl` | Structured event log for debugging |

---

## Confidence Scores — What They Mean

Every diagnosis carries a confidence score between 0 and 1.

| Range | Interpretation | Recommended action |
|---|---|---|
| 0.8 – 1.0 | Agent found strong, consistent evidence | Review evidence, apply fix if it looks right |
| 0.6 – 0.79 | Reasonable hypothesis with some gaps | Use as starting point; verify the unknowns section |
| 0.5 – 0.59 | Weak signal; multiple plausible causes | Investigate manually; treat report as a lead, not a conclusion |
| Below 0.5 | Agent could not confidently diagnose | System returns NO_FIX; report shows what was found and what remains unknown |

The report always shows the unknowns the agent could not verify. These are the things a developer should check manually before applying any fix.

---

## Technical Stack

No cloud services beyond Claude Code. No databases. No dashboards. No background workers.

| Component | Technology |
|---|---|
| Orchestration | Bash |
| AI agents | Claude Code CLI (Sonnet 4.6 default; configurable) |
| Structured output | JSON schemas via `--json-schema` flag |
| Code search | `rg` (ripgrep) with `grep` fallback |
| Isolated validation | `git worktree` |
| Data format | JSON on disk, JSONL for logs |
| Report format | Markdown |

---

## Limitations and Known Gaps (v1)

These are deliberate scope decisions, not bugs. They are documented so stakeholders can plan around them.

| Gap | Why it exists | Workaround |
|---|---|---|
| No JIRA / GitHub ticket update | Prevents accidental writes to shared systems | Developer copies findings manually |
| No Slack / Teams notification | Same reason | Developer shares `report.md` manually |
| No web dashboard | Out of scope for v1; adds infrastructure complexity | Read `report.md` directly |
| Generated tests not red-green verified | Would require running the test suite twice (before and after fix), doubling cost | Developer runs tests manually; tests are labelled `GENERATED_BUT_NOT_VERIFIED` |
| No multi-repo tracing | Agent searches one repository per run | Run separately on each repo if bug spans services |
| No environment / infra visibility | Agent reads only source code and git history | Developer checks infra config manually |
| No evaluator-optimizer retry | Agent 1 runs once; no automatic retry on low-confidence output | Re-run manually with adjusted parameters |

---

## For Delivery Managers and Consultants

**What this changes in the delivery workflow:**

- The investigation phase of a bug cycle shrinks from 30–60 minutes to 3–8 minutes
- Developer time is spent on decision-making and fixing, not searching
- Every bug investigation produces a structured artifact (the report) that can be reviewed, archived, and referenced
- Generated regression tests, when reviewed and integrated, reduce the chance the same bug recurs

**What this does not change:**

- QA remains essential — the system depends on QA finding and reporting bugs
- Code review, approval, and deployment processes are unchanged
- Developers remain accountable for every fix they apply
- The tool does not produce SLA metrics, ticket velocity, or any reporting — those remain in your existing project management tools

**Risk posture:**

- Default mode is read-only with no writes to source code
- No credentials, tokens, or secrets are read or logged
- The system cannot push code, open PRs, or deploy
- All proposed changes are presented as diffs for human review before anything is applied

---

## Further Reading

| Document | Audience |
|---|---|
| [architecture.md](architecture.md) | Engineers building or tuning the system — agent parameters, data flows, schemas |
| `docs/agent-contracts.md` | Engineers — exact tool permissions and output contracts per agent |
| `docs/security-model.md` | Security reviewers — trust boundaries, denied operations, prompt injection defence |
| `docs/decisions.md` | Anyone wondering why something was built a certain way |
| `docs/troubleshooting.md` | Engineers debugging a failed run |
