# Release checklist

1. Match versions in macOS Info.plist, pyproject.toml and the Windows csproj.
2. Run Python unit tests, macOS packaging tests and foreground-policy smoke tests.
3. Build the Mac ZIP on Apple Silicon and the Windows ZIP on a Windows runner.
4. Extract the Windows ZIP and run `CodexTokenObserver.exe --smoke-test <isolated-output-directory>`.
5. Inspect compact, expanded, unavailable, over-limit and transparent fixture screenshots.
6. Check both archives for private databases, logs, credentials, project bytecode and personal build paths. Verify architecture, versions, licenses and SHA256 files.
7. Publish both reviewed assets on one GitHub Release. Compilation alone is not Windows runtime validation.

Mac packaging:

```bash
desktop-observer/package-release.sh 0.2.0
```

Windows packaging: `./windows-observer/build-release.ps1` (PowerShell on Windows, .NET 10 SDK).

Mac is ad-hoc signed and not Apple-notarized; Windows is unsigned. Both may show OS trust warnings. Do not recommend disabling platform protections. Mac currently requires a working `/usr/bin/python3`; Windows includes hash-pinned official Python and self-contained .NET with licenses.

Versioned ZIPs are never overwritten by the packaging scripts. Use a new version for replacement public packages. Smoke artifacts contain only synthetic data and must not be added to release ZIPs.
