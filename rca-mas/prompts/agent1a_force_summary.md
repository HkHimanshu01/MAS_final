No more tool calls are available.

Write FINAL FINDINGS using only evidence already visible in this conversation.

Required format:

## FINAL FINDINGS

### Root cause
One precise paragraph.

### Affected files
- path:line/function — relevance

### Key evidence
- path:line/function — observed fact
- path:line/function — observed fact

### Alternative considered
What else could explain the bug, and why it is less likely.

### Recommended fix
Concrete code-level change.

### Confidence
0.00-1.00

Rules:
- Do not say more investigation is needed.
- Do not mention tool limitations.
- Do not write JSON.
- Include exact file paths and line numbers when available.
- If line numbers are unavailable, include function/class names.
- Be specific enough for a checkpoint writer to produce checkpoint.json.
- Prefer source-code facts over guesses.
- State uncertainty explicitly through Confidence.
