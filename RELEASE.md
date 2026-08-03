# Release checklist

1. Run the Python unit tests.
2. Build the macOS app.
3. Confirm no SQLite database or Codex session log is bundled.
4. Launch the app and verify TODAY/TOTAL with a clean user profile.
5. Create the zip and SHA-256 checksum:

```bash
desktop-observer/package-release.sh 0.1.0
```

The current package is ad-hoc signed, not Apple-notarized. A broadly distributed build should be signed with a Developer ID certificate and notarized before publishing as a GitHub Release.
