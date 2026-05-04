# `default=True` on feature flags is order-sensitive

The following code:

```python
import click


@click.command()
@click.option("--red", "color", flag_value="red")
@click.option("--green", "color", flag_value="green", default=True)
@click.option("--blue", "color", flag_value="blue")
def main(color: str) -> None:
    print(repr(color))


if __name__ == "__main__":
    main()
```

when run with no arguments using click 8.2.1 outputs `'green'`, which is what I expect.  If click 8.3.0 is used instead, then it outputs `None` — but if the `--green` option is moved above the `--red` option in the script, click 8.3.0 will output `'green'`.

I believe that the script should output `'green'` regardless of the declaration order of the options.

Environment:

- Python version: 3.13.7
- Click version: 8.2.1 and 8.3.0
