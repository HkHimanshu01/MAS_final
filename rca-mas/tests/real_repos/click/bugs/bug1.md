# Error hint shows env var when one doesn't exist

#2696 added the environment variable to the error hint when `show_envvar` is set. However, it does not check to see if an `envvar` exists.

click-test.py
```python
import click

@click.command()
@click.option("--foo", envvar="FOO", show_envvar=True, type=click.types.BOOL)
@click.option("--bar", show_envvar=True, type=click.types.INT)
def main(foo: bool, bar: int) -> None:
    print(f"{foo=} {bar=}")

if __name__ == '__main__':
    main()
```

Examples of running this file where each argument is invalid. And one example of the help output.
```
$ python ./click-test.py --bar aaa
Usage: click-test.py [OPTIONS]
Try 'click-test.py --help' for help.

Error: Invalid value for '--bar' (env var: 'None'): 'aaa' is not a valid integer.
$ python ./click-test.py --foo aaa
Usage: click-test.py [OPTIONS]
Try 'click-test.py --help' for help.

Error: Invalid value for '--foo' (env var: 'FOO'): 'aaa' is not a valid boolean.
$ python ./click-test.py --help
Usage: click-test.py [OPTIONS]

Options:
  --foo BOOLEAN  [env var: FOO]
  --bar INTEGER
  --help         Show this message and exit.
```

I would expect the error hint for `--bar` to act like the help output by not displaying any information about an environment variable.

Environment:

- Python version: 3.10.12
- Click version: 8.2.1
