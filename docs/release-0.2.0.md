# Codex Token Observer 0.2.0 — Mac + Windows preview

Download the ZIP for your computer, extract it completely, and open the app.

- **Mac (Apple Silicon, macOS 14+)**: `macos-arm64.zip`. Requires a working `/usr/bin/python3`.
- **Windows 11 x64**: `windows-x64.zip`. Includes Python and .NET; no runtime installation needed.
- These are desktop builds, not iPhone/iPad apps.

## What's new

- Compact English UI with TODAY, TOTAL and WEEKLY USAGE; original Codex project names preserved.
- Today-based top three. Expand for all projects: Today + Total for the top three, Total for the rest.
- Weekly quota colors and estimated accumulation across observed manual resets.
- Short fast-to-slow rolling counters; about five-minute sampling, no continuous idle animation.
- Native Codex/ChatGPT foreground following, hide while counting, tray/menu-bar recovery and edge snapping.
- Fix a partial-log-line race that could otherwise skip an event while it was being written.

## Before sharing

Mac is ad-hoc signed and not notarized; Windows is unsigned. Verify SHA256 and follow your organization's installation policy. Do not disable system security protections.

Counts are local Codex activity, not API billing or a guaranteed account-wide Token total. Usage before first installation is not imported. Weekly quota requires an existing signed-in official Codex CLI; unavailable quota does not stop counting. Windows does not automatically read WSL or remote sessions.

Packages contain no developer account, private token database or session logs. New users start their own counter; upgrades preserve the database outside the app folder.

Windows is a first public preview sharing the tested Python counter with a native WPF shell. Automated package/UI tests use isolated fixtures, not a signed-in colleague's live Codex account. Please report platform-specific issues in this repository.
