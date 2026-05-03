# CLAUDE.md — RCA Compression MAS

## What this project is

A CLI tool that reads a QA bug report, investigates a codebase with Claude Code agents, and produces a developer-ready root-cause report in 3-8 minutes.

## Authoritative files

- `code_practices.md` — implementation authority (bash patterns, CLI contract, security rules)
- `config/defaults.env` — all tunable parameters

## Rules when working in this repo

- Never auto-commit, auto-push, auto-tag, or open PRs
- Never modify `.rca-mas/runs/` or `.rca-mas-worktrees/` source files
- Never read `.env`, `.pem`, `.key`, `id_rsa`, or credential files
- Never run `curl`, `wget`, `ssh`, `scp` unless explicitly instructed
- Architecture is LOCKED FOR V1 — no new agents, folders, or integrations without approval
- Future ideas go in `potential_changes.md` only

## Build order

Follow `plan.md` steps 1–12 in sequence. Do not skip steps.

## Test gates

Every step must pass: `make lint` then `make test` before proceeding.
