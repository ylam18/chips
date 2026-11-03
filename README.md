# UsageBar

A minimal macOS menu bar item for Claude and Codex plan usage. A stack of poker chips shows how
much of your total usage is left — a big stack above 75%, fewer chips every 25% down, and a dashed
outline at zero: the average of what's left across all four limits (Claude and Codex, 5-hour and
weekly). Click for 5-hour and weekly bars of usage left, with reset times.

Data comes from the [CodexBar](https://github.com/steipete/CodexBar) CLI
(`codexbar usage --provider <claude|codex> --format json`, one call per provider in parallel), so
UsageBar reuses CodexBar's logins and asks for no credentials of its own. Codex usually returns in
about a second and Claude in about ten; each appears as soon as it arrives. It refreshes every 5 minutes, and when the panel opens if the data
is over a minute old.

## Requirements

- macOS 14+
- CodexBar installed (`brew install --cask steipete/tap/codexbar`), with Claude and Codex enabled
  in its Settings → Providers
- Swift 6.1 (Command Line Tools are enough; Xcode is not needed)

## Build and run

```sh
scripts/bundle.sh          # builds build/UsageBar.app
open build/UsageBar.app
```

Copy `build/UsageBar.app` to `/Applications` to keep it. Quit from the panel's Quit button.

## Test

```sh
swift test
```
