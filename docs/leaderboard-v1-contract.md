# Zuno network leaderboard v1 (implementation contract)

The desktop name is Zuno. First launch offers a permanent nickname. Clicking **Create & Join** confirms: the nickname cannot be changed and the nickname, random installation ID, ranking day and daily token total will be public. There is no second join prompt. No upload or registration occurs before that action. Local counting is independent and continues if the service is unreachable.

## Identity and privacy

Generate a UUID v4 and a 256-bit random bearer credential per installation; never use computer name, username, serial, MAC address, Codex account ID or credentials. Persist locally with restrictive permissions. Registration is idempotent and the server stores only a SHA-256 credential hash. The nickname is immutable at the server for that installation. Nicknames: Unicode NFKC, trim, 2–24 Unicode code points, letters/numbers/spaces/underscore/hyphen only, no control/bidi/markup. The unique name key is the normalized name lowercased with JavaScript `toLowerCase()`, not Unicode case folding (for example, ß and ss remain different names). The public ID disambiguates devices; reinstall with retained data preserves it, deleting identity creates another device, not a verified human account. Client-reported activity is not verified by OpenAI and is not cheating-proof.

## Service API (HTTPS, JSON, version 1)

- `POST /api/v1/installations` with bearer credential and `{id,nickname,consent_version:1}`. Client generates/persists credential before requesting. Same id+credential retries return the original `{id,nickname,joined_at}` and cannot rename it; another credential cannot take it over. Conflict/error `{error:"nickname_taken|invalid_nickname|identity_conflict|rate_limited|..."}`.
- `GET /api/v1/me` with bearer credential plus `X-Zuno-ID`. Returns `{id,nickname,joined_at}`; never returns credentials.
- `POST /api/v1/usage` with bearer credential + `X-Zuno-ID` and `{days:[{date:"YYYY-MM-DD",total_tokens:123}]}`. Up to 8 days, from today−7 through today in Asia/Shanghai. Nonnegative safe integers only (max 9,007,199,254,740,991); at most 16 KiB body. Idempotent per installation/day absolute totals, monotonically max-merge, never add duplicate submissions. Service validates day and computes ranks.
- `GET /api/v1/leaderboard?offset=0&limit=50` with optional `X-Zuno-ID` for a public own-row lookup. Returns yesterday in Asia/Shanghai, no credentials required: `{date,time_zone:"Asia/Shanghai",entries:[{id,rank,nickname,total_tokens}],total_participants,own_entry:null|entry,updated_at}`. Sort by tokens DESC then id ASC. Pagination exposes all reported participants; a device without yesterday's activity shows an explicit not-ranked state, not fictional data. Late reports can update yesterday's ranking.
- `DELETE /api/v1/me` with bearer + X-Zuno-ID removes the public profile/daily rows and retires that identity. No rename endpoint. Do not invoke without explicit user request/confirmation. Client can locally pause sync separately, preserving immutable identity.

For beta, retain daily usage for 30 days; identity persists until deletion, to keep the permanent nickname. No raw session, project, account or quota data is accepted. Use per-identity write limits and bounded registration limits; avoid raw IP logs where possible. No shared secret in the distributed desktop package.

## Shared Python desktop boundary

Add `--leaderboard` to `stream`. Network base URL is the built-in service URL; test/developer override `ZUNO_LEADERBOARD_URL` (HTTPS, loopback HTTP only for tests). Never use redirects for credential-bearing calls. Before registration no usage upload. On first registration send only actual activity since the explicit join timestamp; thereafter catch up at most 7 prior days. Exclude `simulation:*`, `session_path=simulation` and all visual/demo baselines. Aggregate from `occurred_at` in fixed UTC+08 rather than the existing local_date. Today/Total remain unchanged. Network timeout must not block emission of local counters; run bounded network work independently of the counting loop.

`profile-register --nickname NAME` on the same `--db` requests creation; JSON stdout contains sanitized profile and error only, never credential. `profile-status` reads sanitized local profile only. `profile-pause` stops uploads, `profile-resume` resumes the same identity. No implicit delete or rename.

Stream adds optional:

```json
{"profile":{"status":"needs_name","id":null,"nickname":null,"error":null},"leaderboard":{"status":"loading","date":"2026-09-07","time_zone":"Asia/Shanghai","entries":[],"total_participants":0,"own_entry":null,"updated_at":null,"stale":false}}
```

Profile statuses: `needs_name`, `pending`, `active`, `paused`, `error`. Board statuses: `loading`, `ok`, `offline`, `not_configured`. Preserve last successful board with stale=true on failures; do not turn unavailable into zeros or replace it with demo participants. Provide `leaderboard-read --offset N --limit N` for native pagination (read-only network, same JSON board shape). Counter clients show top page with next/previous and own rank when outside it.

Global board freshness is independent of own upload success: optional `error: "sync_failed"` and `own_entry_stale: true` indicate an upload pending even when the public GET succeeds. Paused sharing also marks the own row stale. The active profile keeps its locked identity and a sanitized error until a successful upload clears it.

Native onboarding uses the shared CLI and explains permanent nickname/public daily tokens; creation controls disabled during request, errors retry without changing identity. App menus may show **Your Zuno profile** and **Pause leaderboard sync**. Mock samples are debug previews/tests only, never a runtime fallback.

## Acceptance

Two independent synthetic installations, immutable/idempotent nickname and uniqueness, unauthenticated/mismatched writes rejected, duplicate usage not doubled, ordering/page+own-rank, midnight/UTC+08 boundaries, pre-join/simulation exclusion, offline/no-upload-before-create, restart identity preservation, pause/resume, no secrets in UI/logs/packages, native Mac and Windows build/smoke before a joint GitHub release. All live smoke records must be synthetic; do not choose the user's permanent nickname for them.
