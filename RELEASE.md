# Release checklist

Current worktree: Zuno 0.3.0 is an unreleased network-enabled development version (macOS build 8). The published v0.2.1 release remains named Codex Token Observer; do not rewrite its tag, notes, asset names, or download links. Public installation packages must wait for the leaderboard service to be explicitly opened publicly and tested through its actual HTTPS URL.

Windows branding, permanent profile onboarding and network leaderboard source have also been updated to Zuno 0.3.0. Native Mac checks do not imply Windows validation; the Windows runner gates below remain required before publishing.

1. Before a public release, match versions in macOS Info.plist, pyproject.toml and the Windows csproj. Local development metadata may be ahead of the last released version; that is not release approval.
2. Run Python unit tests, macOS packaging tests, appearance/foreground-policy smoke tests, and the Foundation quota/leaderboard plus native page-navigation smoke tests.
3. Build the Mac ZIP on Apple Silicon and the Windows ZIP on a Windows runner.
4. Extract the Windows ZIP and run `CodexTokenObserver.exe --smoke-test <isolated-output-directory>`.
5. Inspect compact, expanded, unavailable, exhausted, full, post-reset, stale and transparent fixture screenshots, including onboarding and network leaderboard states. Verify weekly remaining uses only current usage, never reset carry, and that balance, fill, color and warnings agree. Check real double-click, right-click navigation, Back, pagination, own row, dragging and counter preservation. Fixtures stay synthetic; runtime must not substitute sample participants for an empty or unavailable board.
6. Check both archives for private databases, logs, credentials, project bytecode and personal build paths. Verify architecture, versions, licenses and SHA256 files.
7. Publish both reviewed assets on one GitHub Release. Compilation alone is not Windows runtime validation.
8. Confirm permanent-name/idempotent creation, uniqueness, same-device restart, explicit Create & Join before any usage upload, since-join-only aggregation and simulation exclusion, bounded/authorized HTTPS writes, duplicate absolute totals, fixed UTC+08 days, pause/resume, failed-upload visibility, and two independent synthetic installations on the deployed service. Never choose the user's permanent nickname for them. Exclude all .zuno-profile.json, lock and credential temp files from artifacts.

Mac packaging:

```bash
desktop-observer/package-release.sh 0.3.0
```

The Mac script creates `Zuno-0.3.0-macos-arm64.zip` (no spaces) and its `.sha256`, containing `Zuno.app`. Packaging does not publish to GitHub. Building the renamed bundle leaves any old `dist/Codex Token Observer.app` untouched. Do not run both copies together.

Rebrand compatibility checks: keep the Mac bundle identifier `design.codex.token-observer`, internal executable `CodexTokenObserver`, and existing Application Support directory `Codex Token Observer`. Verify both fresh startup and upgrade using isolated data, and confirm the packaged `AppIcon.icns` is the approved cat icon. Never reset, migrate, or include a real user ledger to test a rename.

Windows packaging: `./windows-observer/build-release.ps1` (PowerShell on Windows, .NET 10 SDK).
The source now targets `Zuno-0.3.0-windows-x64.zip` with a `Zuno` folder; the executable remains `CodexTokenObserver.exe` and the data directory remains `%LOCALAPPDATA%\Codex Token Observer`. These are intended package names, not evidence of a validated Windows build in this iteration.

Mac is ad-hoc signed and not Apple-notarized; Windows is unsigned. Both may show OS trust warnings. Do not recommend disabling platform protections. Mac currently requires a working `/usr/bin/python3`; Windows includes hash-pinned official Python and self-contained .NET with licenses.

Versioned ZIPs are never overwritten by the packaging scripts. Use a new version for replacement public packages. Smoke artifacts contain only synthetic data and must not be added to release ZIPs.
