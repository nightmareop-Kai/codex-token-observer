# Privacy

Codex Token Observer is local-first.

- It reads token usage events from `~/.codex/sessions/**/*.jsonl`.
- It stores counters in `~/Library/Application Support/Codex Token Observer/token_counter.sqlite3`.
- It does not upload session contents, token counters, or identifiers.
- It does not require an OpenAI API key.
- It does not calculate billing or account quota.

The application only parses records whose payload type is `token_count`. It does not display or persist prompt or response text.

Uninstalling the `.app` does not automatically remove the local SQLite database. Delete the Application Support folder separately if you want to remove the counter history.
