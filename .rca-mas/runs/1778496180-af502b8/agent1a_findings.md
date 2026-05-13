## FINAL FINDINGS

### Root cause
In click 8.3.0, `Parameter.handle_parse_result` (test-repos/click/src/click/core.py:2536-2551) commits a value to `ctx.params[self.name]` for the **first** parameter that targets a given name, regardless of whether that parameter actually contributed a value. The guard `self.name not in ctx.params` causes the first-processed option to "claim" the shared destination, and the very next line `ctx.params[self.name] = value if value is not UNSET else None` writes `None` when the option had no CLI value, no env value, no default_map value, and `self.default is UNSET`. For feature flags declared with `flag_value=` (e.g. `--red`, `--blue`), `self.default` stays UNSET unless the user passed `default=True`. Only the `--green` option has `default=True`, which `Option.__init__` aligns to `flag_value` ("green") at core.py:2771-2772; its siblings keep `default=UNSET`. Therefore, with the declaration order `--red, --green, --blue`, click processes `--red` first, writes `None` into `ctx.params["color"]`, and the guard then blocks `--green` from contributing its `"green"` default. Moving `--green` above `--red` lets `--green` claim the slot first with `"green"`, which is precisely why reordering "fixes" the output. The bug is that an option with nothing to contribute (UNSET) is allowed to pre-empt a sibling option that does have a real default, making `default=True` on feature flags order-sensitive.

### Affected files
- test-repos/click/src/click/core.py:2536-2551 / `Parameter.handle_parse_result` — guarded write that claims the shared name and converts UNSET to None in-place.
- test-repos/click/src/click/core.py:2295-2322 / `Parameter.consume_value` — returns UNSET when nothing is provided and `self.default is UNSET`.
- test-repos/click/src/click/core.py:2761-2772 / `Option.__init__` — only options with explicit `default=True` get their `default` aligned to their `flag_value`; siblings remain UNSET.

### Key evidence
- test-repos/click/src/click/core.py:2541 — `and self.name not in ctx.params` enforces "first-touch wins" semantics for parameters sharing a destination.
- test-repos/click/src/click/core.py:2551 — `ctx.params[self.name] = value if value is not UNSET else None` writes `None` for a non-contributing option that won the first-touch race.
- test-repos/click/src/click/core.py:2771-2772 — `if self.default is True and self.flag_value is not UNSET: self.default = self.flag_value` — explains why only `--green` carries a usable default through `consume_value`; `--red`/`--blue` enter with `default=UNSET`.
- test-repos/click/src/click/core.py:2295-2322 / `consume_value` — for `--red` with no CLI input, env, default_map, and `default=UNSET`, the returned value is UNSET with `source=ParameterSource.DEFAULT`.
- Manual trace with the reporter's snippet reproduces both reported outputs: order `red, green, blue` → `ctx.params["color"]` is set to `None` by `--red`, locking out `--green` → result `None`; order `green, red, blue` → `--green` claims first with `"green"` → result `"green"`.

### Alternative considered
That `consume_value` itself regressed and fails to return `"green"` for the `--green` option in isolation (e.g. an eager UNSET normalization during option construction overwriting `self.default`). The code at core.py:2771-2772 explicitly sets `self.default = self.flag_value` when `default is True`, and `consume_value` (core.py:2316-2320) falls through to `self.default` when no other source provides a value. So `--green` in isolation does return `("green", DEFAULT)`. The order-sensitivity only manifests when a *sibling* option processed earlier has already written to `ctx.params[name]`, which pinpoints the regression to the shared-name write guard in `handle_parse_result`, not to per-option default resolution.

### Recommended fix
Stop letting an option claim a shared destination when it has nothing to contribute. In `Parameter.handle_parse_result` (test-repos/click/src/click/core.py:2536-2551), tighten the guard so the write only happens when the option actually produced a value:

```python
if (
    self.expose_value
    and self.name not in ctx.params
    and value is not UNSET
):
    assert self.name is not None, (
        f"{self!r} parameter's name should not be None when exposing value."
    )
    ctx.params[self.name] = value
```

Then, after all parameters in the command have been processed, perform a single normalization pass that fills in any still-missing names with `None` (for example, `ctx.params.setdefault(param.name, None)` for each declared, exposed param). This restores the 8.2.x behavior: an option without a real value can never pre-empt a sibling option that has a real `default`, so the resolution of `--red / --green / --blue` becomes independent of declaration order and yields `"green"` in both orderings.

### Confidence
0.88
