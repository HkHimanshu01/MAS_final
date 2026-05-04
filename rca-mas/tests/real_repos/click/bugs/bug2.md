# Pager Popen() should not use `shell=True` now that the command is a list

In https://github.com/pallets/click/commit/299efb82e1a3d34d870129dc0c677c6efb42d811 a `Popen()` for the pager changed the command argument (the first argument) from a string to a list.

If changing the command to a sequence, we should also change `shell=True` to `shell=False` (or remove it).

Per the `subprocess` docs at

 * https://docs.python.org/3/library/subprocess.html#popen-constructor

> On POSIX with `shell=True` … If _args_ is a sequence, the first item specifies the command string, and any additional items will be treated as additional arguments to the shell itself. That is to say, Popen does the equivalent of:
> `Popen(['/bin/sh', '-c', args[0], args[1], ...])`

Whereas if `shell=False` the effect is simply "`os.execvpe()`-like behavior" to execute `args[0]` directly with `args[1:]` as its arguments.

This bug is causing failures in the test suite for https://github.com/dbcli/mycli, and we are stuck on click < 8.1.8 as a result.

I don't have a prepared failure case using click other than the mycli test suite, but one example of strange behavior you can replicate easily is that `sh` will swallow arguments that you might think go to the command.  For example:

```bash
sh -c ls --nonsense
```

will work, because `ls` never sees `--nonsense`.

Environment:

- Python version: tested on Python versions 3.9-3.13
- Click version: 8.1.8+
