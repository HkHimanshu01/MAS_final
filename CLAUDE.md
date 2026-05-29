# CLAUDE.md — MAS_final Workspace

## What this workspace is

This is the development workspace for the RCA Compression MAS project. The actual tool lives in `rca-mas/`. This root directory is a container for the tool, its test dependencies, and run outputs.

## Directory layout

```text
MAS_final/
├── rca-mas/          ← the tool — this is the folder you share or deploy
├── test-repos/       ← local clones of repos used for real-repo testing
│   └── click/        ← pallets/click clone (required for test-real-repo suite)
├── reports/          ← any manually saved reports for review
├── archive/          ← superseded docs, old exports, presentation files
└── CLAUDE.md         ← this file
```

## The tool is in rca-mas/

All development, running, and testing happens inside `rca-mas/`. Start there:

```bash
cd rca-mas
cat CLAUDE.md        # project instructions
cat architecture.md  # architecture reference
bash run.sh --help   # available commands
```

## test-repos/ setup

Real-repo tests require a local clone of pallets/click:

```bash
git clone https://github.com/pallets/click test-repos/click
```

Override the location at test time:
```bash
RCA_REAL_REPO_ROOT=/custom/path bash run.sh test-real-repo
```

The `test-repos/` directory is gitignored — clones are not committed.

## Rules

- Never modify anything inside `rca-mas/` from a root-level context unless you have read `rca-mas/CLAUDE.md` first
- Never commit files from `test-repos/` — they are local test dependencies only
- `archive/` is read-only — files there are superseded and kept only for reference
- Never auto-commit, auto-push, or open PRs from this workspace
