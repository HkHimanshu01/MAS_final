# `ctx.invoke` passes `Sentinel` to command

In a GitHub action that worked in the past I get an error

```
│ /opt/hostedtoolcache/Python/3.13.7/x64/lib/python3.13/site-packages/hatch/cl │
│ i/__init__.py:221 in main                                                    │
│                                                                              │
│   218                                                                        │
│   219 def main():  # no cov                                                  │
│   220 │   try:                                                               │
│ ❱ 221 │   │   hatch(prog_name='hatch', windows_expand_args=False)            │
│   222 │   except Exception:  # noqa: BLE001                                  │
│   223 │   │   import sys                                                     │
│   224      

│ /opt/hostedtoolcache/Python/3.13.7/x64/lib/python3.13/site-packages/hatch/cl │
│ i/run/__init__.py:147 in run                                                 │
│                                                                              │
│   144 │   elif not env_name:                                                 │
│   145 │   │   env_name = 'system'                                            │
│   146 │                                                                      │
│ ❱ 147 │   ctx.invoke(                                                        │
│   148 │   │   run_command,                                                   │
│   149 │   │   args=[command, *final_args],                                   │
│   150 │   │   env_names=[env_name],                                          │
│                                                                              │

│ /opt/hostedtoolcache/Python/3.13.7/x64/lib/python3.13/json/__init__.py:339   │
│ in loads                                                                     │
│                                                                              │
│   336 │   │   │   │   │   │   │   │     s, 0)                                │
│   337 │   else:                                                              │
│   338 │   │   if not isinstance(s, (bytes, bytearray)):                      │
│ ❱ 339 │   │   │   raise TypeError(f'the JSON object must be str, bytes or by │
│   340 │   │   │   │   │   │   │   f'not {s.__class__.__name__}')             │
│   341 │   │   s = s.decode(detect_encoding(s), 'surrogatepass')              │
│   342                                                                        │
╰──────────────────────────────────────────────────────────────────────────────╯
TypeError: the JSON object must be str, bytes or bytearray, not Sentinel
Error: Process completed with exit code 1.
```

Click is used as part of Hatch as build tool.

I guess it is linked to https://github.com/pallets/click/issues/3065
