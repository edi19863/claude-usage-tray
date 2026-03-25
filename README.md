# Claude Code Usage Tray

A Windows system tray monitor that shows your **Claude Code token usage** in real time — 5-hour window, 7-day total, time to reset, and extra-usage status.

[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg)](https://paypal.me/edi19863)

![Tray icon showing usage percentage](.github/preview.png)

---

## What it does

- Sits in the Windows system tray with a live usage indicator (0–100%)
- Shows **5h usage**, **7-day usage**, **time to next reset**, and **extra usage** status on hover
- Reads usage from local Claude Code JSONL logs (`~/.claude/projects/`) — no extra API calls needed for basic stats
- Optionally refreshes OAuth token to fetch rate-limit data directly from Anthropic's API
- Sends a desktop notification when you reach 85% and 90% of your quota
- Saves a 30-day usage history to `~/.claude/claude-usage-history.json`
- Auto-starts with Windows

### Tray tooltip example

```
Claude Code Usage
5h:  42%  (847K / 2.0M tokens)
7d:  18%  (3.6M / 20M tokens)
Reset in: 2h 14m
```

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1+ (built into Windows)
- Node.js (only for `read-ratelimit.js` — optional)
- Claude Code installed (`~/.claude/` folder must exist)

---

## Installation

1. Clone or download this repo
2. Run the setup script:

```bat
installa-avvio-automatico.bat
```

This registers `start.vbs` as a Windows startup task so the tray icon appears automatically on login (no PowerShell window visible).

To start manually right now:

```powershell
powershell -File claude-tray.ps1
```

---

## How it works

1. Reads `~/.claude/projects/**/*.jsonl` — the same conversation logs Claude Code writes locally
2. Aggregates token counts by session, hour, and day
3. Displays the rolling 5-hour and 7-day totals as a percentage of your plan limits
4. Optionally calls `https://api.anthropic.com/api/oauth/usage` (using your existing Claude Code OAuth token from `~/.claude/.credentials.json`) for authoritative rate-limit data

No API key is required — it reuses the token Claude Code already stores locally.

---

## Files

| File | Description |
|---|---|
| `claude-tray.ps1` | Main script — all tray logic, dashboard, history |
| `read-ratelimit.js` | Node.js helper to read rate-limit headers |
| `installa-avvio-automatico.bat` | Registers autostart on Windows login |
| `start.vbs` | Silent launcher (hides the PowerShell window) |

---

## Support the project

If this saves you from hitting the limit mid-session, consider buying me a coffee ☕

[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg)](https://paypal.me/edi19863)

---

## License

MIT
