# Status line

*[Español](statusline.es.md)*

`statusline.py` prints one minimal gray line at the bottom of Claude Code. It shows what you usually
want to know at a glance: which project, which model, how full the context is, and how much of your
plan limits you have used.

Like every piece of the kit, it is optional: the popup and the menu bar work without it.

## Sample line

<picture><source media="(prefers-color-scheme: dark)" srcset="img/statusline-dark.png"><img src="img/statusline-light.png" width="760" alt="Status line with the ticker off"></picture>

*With the optional ticker turned on, the line continues like this:*

```
my-project  Sonnet high │ ctx 52% │ session ~1.2% ~$0.28 45k │ 5h 12% ↻3:00pm │ wk 45% $10.38/$23 │ ABC 101.50 +0.42% 3:58pm
```

Everything is gray. A percentage turns green, yellow or red only when it passes the color threshold
(40% by default), so a quiet bar means nothing needs your attention.

## What each segment means

| Segment | Meaning |
|---|---|
| `my-project` | Name of the project folder. |
| `Sonnet high` | Model and reasoning effort. A `⚡` after the model means fast mode. |
| `ctx 52%` | How full the context window is. |
| `session ~1.2% ~$0.28 45k` | This session only. It starts again at zero after `/clear`. The first number is the session's estimated share of your weekly limit. The dollar figure is that share in plan dollars (shown only if you set `plan_monthly_usd`). The last number is tokens used (input, cache writes and output). |
| `5h 12% ↻3:00pm` | How much of the 5-hour limit you have used, and the local time it resets. |
| `wk 45% $10.38/$23` | How much of the weekly limit you have used. With `plan_monthly_usd` set, it also shows the plan dollars used and the plan dollars per week. |
| `ABC 101.50 +0.42% 3:58pm` | Optional market ticker: last price, change since the previous close, and the time of that price. |

Colors: gray up to the threshold, then green below 60%, yellow below 80%, red from 80%. The ticker
change is colored only while the market is open and the move is at least `ticker_min_move_pct`.

### Narrow terminals

The script reads `COLUMNS` and trims the line to fit. It removes things in this order: the model,
then the long form of the weekly, ticker, 5-hour and session segments, then the ticker, the session
and the context. The weekly percentage is never removed.

## The plan-dollar figures are estimates

Claude Code does not report usage per session, and a subscription has no real price per token. So:

- **Session share (`~1.2%`).** The weekly percentage is split across the week's sessions in
  proportion to their list-price cost. A session never shows more than the whole week. It is an
  approximation and it only knows about sessions that ran this status line on this Mac.
- **Plan dollars (`~$0.28`, `$10.38/$23`).** These are your percentage multiplied by
  `plan_monthly_usd × 12 ÷ 52` (the plan price per week). They show "how much of what you pay
  for each week this is", not what the API would have charged. The `~` marks an estimate.

If you leave `plan_monthly_usd` unset, no dollar figures are shown. Only percentages.

## Turn it on

Add this to `~/.claude/settings.json` (merge it with what you already have):

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/ccnotify/statusline/statusline.py",
    "refreshInterval": 60
  }
}
```

`install.sh` copies the script to that path. Restart Claude Code after changing the setting.

## Configuration

Settings go in `~/.claude/ccnotify/config.json` under `"statusline"`. Every key is optional.
(If you set the environment variable `CCNOTIFY_HOME`, the file is `$CCNOTIFY_HOME/config.json`.)

```json
{
  "language": "auto",
  "statusline": {
    "plan_monthly_usd": 100,
    "ticker": "",
    "ticker_refresh_open_s": 60,
    "ticker_refresh_closed_s": 1800,
    "ticker_min_move_pct": 0.5,
    "color_threshold_pct": 40
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `language` (top level) | `"auto"` | `"auto"`, `"en"` or `"es"`. Auto uses the first macOS preferred language (`defaults read -g AppleLanguages`), or `LANG` if that fails. It is read once and cached in `state/statusline/lang.json`. Delete that file to detect again. |
| `plan_monthly_usd` | `null` | Your monthly plan price in US dollars. Unset: dollar figures are hidden. |
| `ticker` | `""` | A Yahoo Finance symbol such as `SPY` or `QQQ`. Empty: no ticker, and the script makes **no network access at all**. |
| `ticker_refresh_open_s` | `60` | Seconds between refreshes while the market is open. |
| `ticker_refresh_closed_s` | `1800` | Seconds between refreshes while the market is closed. |
| `ticker_min_move_pct` | `0.5` | The ticker change takes a color from this size of move. |
| `color_threshold_pct` | `40` | Percentages stay gray up to this value. |

### The ticker and your network

The ticker is the only part of CCNotify that touches the network, and it is off by default. When you
set a symbol, the script reads a local copy of the quote and, if it is stale, starts a background
`curl` to `query1.finance.yahoo.com`. The bar never waits for it: the first line after a fresh start
has no ticker, and the quote appears on a later refresh. Only the symbol is sent.

## Safety

- It always prints one line and exits 0, even with broken input.
- It tolerates missing fields. Claude Code may omit `rate_limits` or `effort`, and those segments
  just disappear.
- It never waits on the network.
- Cache files are in `~/.claude/ccnotify/state/statusline/`. You can delete that folder at any time.

## Test it by hand

```bash
echo '{"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":52}}' \
  | ~/.claude/ccnotify/statusline/statusline.py
```
