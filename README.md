# Claude Usage Viewer

A macOS menu-bar app that shows your Claude plan usage — and your Gemini
quota from Google Antigravity — at a glance, and more usefully, whether
you're on track to run out before your limits reset.

```
▬ 75% ~33m        ← session at 75%, on pace to hit the limit in ~33 minutes
```

- **Pace, not just percentage.** 48% with 4 hours left is fine if it took
  four hours to get there and not fine if it took forty minutes. The menu bar
  turns amber/red based on the *projection*, and shows time-to-limit.
- **Live while you work.** Claude Code passes your usage to its status line on
  every update; a small script saves it for the app, so numbers move in real
  time without spending Anthropic's (shared, tight) usage-check rate limit.
- **Everything the usage API knows:** session and weekly limits (plus any
  per-model weekly limits), a pace marker and sparkline per window, this
  week's usage by product, and extra-usage spend.
- **Gemini too.** While the Antigravity app is running, its per-model quota
  (e.g. Gemini 4 Argon weekly, Gemini 3.8 Flash 5-hour) shows in its own
  popover section with the same pace projection and alerts. The menu bar
  shows whichever limit, Claude or Gemini, is closest to running out — a ✦
  icon means it's a Gemini one.
- **Notifications** when you're on pace to hit a limit within the hour, at
  80%/95% (adjustable), when a limit is reached, and when it resets.
- Dims when the data is stale; right-click for Refresh / Settings / Quit.

## Requirements

- macOS 15.6 or later, Xcode 26
- [Claude Code](https://claude.ai/code) installed and signed in with a Claude
  Pro, Max, Team or Enterprise plan

## Install

```bash
git clone https://github.com/bjblakerpy/claude-code-usage-widget-macos.git
cd claude-code-usage-widget-macos
make install        # runs tests, builds Release, installs to /Applications, launches
make install-feed   # optional but recommended: live updates from Claude Code
```

Set your signing team once in Xcode (target → Signing & Capabilities → Team;
a free Apple ID works). The app turns on **Launch at login** the first time
it runs; change it in Settings.

Live updates can also be turned on or off in **Settings → Live updates from
Claude Code**. Turning them on sets `statusLine` in `~/.claude/settings.json`
(a backup is saved next to it as `settings.json.usage-viewer-backup`); if you
already had a status line it keeps working unchanged, and turning live
updates off restores it exactly.

## How it works

| Source | When | Cost |
|---|---|---|
| Status-line feed (`~/Library/Application Support/Claude Usage Viewer/statusline-feed.json`) | Whenever Claude Code updates its status line | Free |
| Antigravity's local language server (`GetUserStatus` on a loopback port) | Every 60 s while Antigravity is running; the last reading is kept when it's closed | Free, local |
| `GET api.anthropic.com/api/oauth/usage` | Every 15 min (30 while the feed is live), on wake/unlock, when you open the popover and data is >5 min old | Shares a ~3-calls-per-5-min limit with every Claude client on your login |

The API call uses the OAuth token Claude Code keeps in the keychain item
`Claude Code-credentials`, read with `/usr/bin/security` (no keychain prompt).
The app never refreshes that token itself — doing so would rotate it out from
under Claude Code — so if it has expired, the app waits for Claude Code to
renew it. On HTTP 429 it waits exactly as long as `Retry-After` says, plus a
little jitter. Nothing is sent anywhere except Anthropic's own API.

For Gemini, the app finds Antigravity's language server with `ps`/`lsof`,
reads the CSRF token it was started with, and asks it for your status over
`127.0.0.1` (its self-signed certificate is trusted for loopback only). The
server talks to Google with Antigravity's own session; this app never sees a
Google token. The Gemini web app and Gemini API billing aren't covered — no
usable usage source exists for them. Turn Gemini off in Settings → Gemini.

The app is not sandboxed: it needs to run `/usr/bin/security`, `ps` and
`lsof`, find the installed `claude` binary (for the User-Agent) and
read/write the feed.

## Development

```
Claude Usage Viewer/
  Core/       pure logic, Foundation only — also built as the UsageCore package
  Services/   keychain, CLI, API client, system events, notifications
  Store/      UsageStore (state + scheduling), Preferences
  Views/      SwiftUI popover and settings
  App/        entry point, NSStatusItem controller
Tests/UsageCoreTests/
```

`make test` runs the unit tests (projection math, parsing against a real API
response, scheduling, alerts, and the status-line installer including running
the generated script). The Xcode project picks up new files in
`Claude Usage Viewer/` automatically.
