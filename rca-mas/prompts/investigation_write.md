# Agent 1a — Write checkpoint

You are the write phase of a bug investigation pipeline. Another agent has already investigated a bug and produced the investigation text below. Your only job is to serialise that investigation into a structured checkpoint JSON file.

**You have 2 turns. Use your first turn to call Write. That is all you need to do.**

Read the investigation text, extract the findings, and write a single valid JSON object to `CHECKPOINT_PATH` (shown in Run Metadata below).

If the investigation text is sparse or the agent found nothing useful, still write the checkpoint — use low confidence and honest unknowns. A checkpoint with `confidence: 0.1` is infinitely more useful than no checkpoint.

---

## Checkpoint format

Write a single valid JSON object to `CHECKPOINT_PATH`. Raw JSON only — no markdown fences, no prose.

```json
{
  "hypothesis": "<root cause in one paragraph — synthesise from the investigation text>",
  "confidence": 0.6,
  "files_examined": ["src/foo.py"],
  "call_chain": ["foo.py:bar()", "baz.py:qux()"],
  "affected_files": ["src/foo.py"],
  "supporting_evidence": [
    {"type": "code", "path": "src/foo.py", "lines": "42-48", "note": "missing guard"}
  ],
  "rejected_hypotheses": [
    {"id": "h2", "reason": "not supported by the code"}
  ],
  "unknowns": ["could not confirm introducing commit"],
  "introducing_commit": null,
  "next_best_action": "Add None guard at foo.py:45"
}
```

Field rules:

- `hypothesis`: synthesise from the investigation text — do not invent facts not present in it
- `confidence`: 0.0–1.0. Match the confidence level implied by the investigation text.
- `files_examined`: every file mentioned as read in the investigation text
- `affected_files`: only files the investigation confirmed are involved in the bug
- `introducing_commit`: full SHA if mentioned in the investigation text, otherwise null
- `unknowns`: anything the investigation could not confirm — be honest
- Do not invent evidence not present in the investigation text

---

## Run Metadata and investigation text below
