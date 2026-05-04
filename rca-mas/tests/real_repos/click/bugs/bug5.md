# click.prompt and click.confirm argument prompt_suffix no longer works when suffix is empty

After #1836 and #2093 were merged the behavior of the `prompt_suffix` argument in the `click.prompt` and `click.confirm` functions changed.

# Before these changes in click version 7.1.2

Prior to the #1836 and #2093 PRs when an empty `prompt_suffix` was passed, no suffix was applied to the prompt.

Here's how `prompt` used to behave

```python
>>> import click
>>> click.prompt("test", prompt_suffix="")
testfoo
'foo'
>>> click.prompt("test", prompt_suffix=" ")
test foo
'foo'
```

Notice that when a `prompt_suffix of `""` is passed, there is no suffix after the prompt text of `test`. This is illustrated by how the text typed by the user (in this case `foo`) displays immediately after the prompt without a space character.

# Current behavior in click 8.0.0 and newer

```python
>>> import click
>>> click.prompt("test", prompt_suffix="")
test foo
'foo'
>>> click.prompt("test", prompt_suffix=" ")
test foo
'foo'
```

Notice now that if you tell `prompt` to use no suffix, it still applies a space character suffix.

This is because the fixes in #1836 and #2093 presumes that the last character of the prompt is a space character. It then [`rstrip`s the space character and adds the space character back in](https://github.com/pallets/click/pull/1836/files#diff-1f88635ce1d1f86bb7f9de29ef053bf8fc628a13530d1d2c6a69d0ad637e32cdR130-R133). This doesn't work if the last character of the prompt is not a space character though.

This matters because it makes it impossible to do prompts like the following example

# Example

```python
import click
click.prompt("What IP address would you like? : 192.168.1.", prompt_suffix="")
```

This would have the user enter the last octet of an IP and make it clear that they can only set something within the displayed subnet. The problem is that the resulting display looks like this

```
What IP address would you like? : 192.168.1. 123
```

# Note

The fixes in these two PRs can't just be reverted because the `readline` behavior that inspired them still exists.

Environment:

- Python version: 3.13
- Click version: 8.0.3
