# RCA MAS Report

## Status
COMPLETE — root cause identified with HIGH confidence.

## Root Cause
`apply_discount()` in `src/cart/pricing.py` dereferences `discount.discount_value` without
checking whether the discount lookup returned `None`. When an unrecognised code is passed,
`lookup_discount()` returns `None`, causing a `TypeError` on the attribute access.
Introduced in commit `abc1234` ("refactor discount stack logic") which changed the return
type of `lookup_discount()` from raising `DiscountNotFound` to returning `None`.

## Confidence
**HIGH (0.82)**

## Evidence

| File | Lines | Note |
|---|---|---|
| `src/cart/pricing.py` | 42–48 | `discount.discount_value` accessed with no None guard |
| `src/cart/discount.py` | 31 | `lookup_discount()` returns `None` on miss since abc1234 |
| `tests/test_pricing.py` | 10–20 | Existing tests only cover valid codes — no test for unknown code |

Introducing commit: `abc1234` — "refactor discount stack logic" (3 days ago)

## Affected Files
- `src/cart/pricing.py`

## Proposed Fix
Add a `None` guard before accessing `discount.discount_value`.

```diff
--- a/src/cart/pricing.py
+++ b/src/cart/pricing.py
@@ -42,7 +42,8 @@ def apply_discount(cart, code):
     discount = lookup_discount(code)
-    total = cart.subtotal - discount.discount_value
+    if discount is None:
+        return cart.subtotal
+    total = cart.subtotal - discount.discount_value
     return total
```

Risk: **low** — change is isolated to `apply_discount()`, no shared call paths affected.

## Patch Files
- `patches/fix.diff` — apply with `git apply patches/fix.diff`

## Validation
SKIPPED — run with `--validate` to apply fix in an isolated worktree and run tests.

## Cost / Runtime
Model: claude-sonnet-4-6 | Repo tier: S (340 files) | Total: 176s
Agent 1: 18/25 turns, 142s | Agent 2: 1/1 turns, 34s | Validation: skipped
Cost level: LOW (non-authoritative)

## Unknowns / Risks
- Other callers of `apply_discount()` may also lack None guards — grep recommended.
- `lookup_discount()` return-type change not covered by type annotations.

## Next Action
1. Review and apply `patches/fix.diff`
2. Add a test for unknown discount codes in `tests/test_pricing.py`
3. Search for other callers of `apply_discount()` to check for the same pattern
