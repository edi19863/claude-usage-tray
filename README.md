# Claude Code Usage Tray

A lightweight **Windows system tray monitor** for [Claude Code](https://claude.ai/code) — shows your 5h session quota and 7-day quota at a glance, with a full usage dashboard, all without leaving your desktop.

[![Ko-fi](https://img.shields.io/badge/Buy%20me%20a%20beer-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/edi1986)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078d4?logo=windows)
![PowerShell](https://img.shields.io/badge/requires-PowerShell%205.1-5391FE?logo=powershell)
![License](https://img.shields.io/badge/license-MIT-22c55e)

---

## Features

- **Color-coded tray icon** that changes based on quota level (green → orange → red → dark red → grey at 100%)
- **Right-click menu** with instant summary: current %, reset time, extra-usage status
- **Full HTML dashboard** with 4 tabs — Today / This Week / This Month / All Time
- **Reads your local `~/.claude/projects/*.jsonl` files** directly — no Node.js, no ccusage, no external tools
- **Calls the Anthropic OAuth API** every 5 minutes for official quota %; falls back to cached values on rate limit
- **Desktop notification** at 85% and 90% usage

## Icon colors

| Color | Usage |
|-------|-------|
| Green | 0 – 50% |
| Orange | 50 – 80% |
| Red | 80 – 95% |
| Dark red | 95 – 99% |
| Dark grey | 100% |

---

## Dashboard

Click **"Usage history..."** from the right-click menu to open the dashboard in your browser.

### Today
Tokens processed today vs yesterday, sessions active today, and an **hourly bar chart** showing activity across the day.

### This Week / This Month
Total tokens, active days, peak day, daily average, per-day bar chart, day table.

### All Time
Quota trend chart (line, with 80%/95% thresholds), range selector (24h / 7d / all), top sessions by token usage, full statistics summary.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (built into Windows — no install needed)
- Claude Code installed and logged in (`~/.claude/.credentials.json` must exist)

---

## Installation

### Option A — Quick start

1. [Download the ZIP](https://github.com/edi19863/claude-code-usage-tray/archive/refs/heads/main.zip) and extract it anywhere
2. Double-click **`start.vbs`** — the tray icon appears immediately, no console window

### Option B — Auto-start at every login

1. Extract the folder
2. Double-click **`setup-autostart.bat`** — creates a shortcut in your Windows Startup folder (no admin rights needed)

### Option C — Git clone

```
git clone https://github.com/edi19863/claude-code-usage-tray.git
```

Then run `start.vbs`.

---

## Files

| File | Description |
|------|-------------|
| `claude-tray.ps1` | Main script — tray icon, menu, dashboard, API polling, JSONL parsing |
| `start.vbs` | Silent launcher — starts PowerShell without showing a console window |
| `setup-autostart.bat` | Creates a Windows Startup shortcut for auto-launch at login |
| `add-bom-restart.ps1` | Dev utility — adds UTF-8 BOM to the script and restarts the tray |

---

## Notes

- **Cost columns are intentionally hidden** — Claude Pro/Max users always have `$0` in their JSONL files.
- Token counts come from local files only. No data leaves your machine except the API quota call.
- If the quota API returns a rate limit (429), the last cached values are used silently.
- The script uses PowerShell 5.1 and requires UTF-8 BOM encoding. If you edit the `.ps1` file manually, run `add-bom-restart.ps1` afterward.

---

## Support

If this tool saves you from hitting the limit mid-session, feel free to buy me a beer.

[![Buy me a beer](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/edi1986)

---

## License

MIT — do whatever you want with it.
