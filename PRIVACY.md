# Privacy

Codex Token Observer is local-first.

- It reads token usage events from `~/.codex/sessions/**/*.jsonl`.
- It stores counters in `~/Library/Application Support/Codex Token Observer/token_counter.sqlite3`.
- On Windows, counters and preferences live under `%LOCALAPPDATA%\Codex Token Observer`. It reads the current user's `.codex/sessions`, or an existing `CODEX_HOME` override. It does not automatically inspect WSL or remote machines. The bundled Python and .NET runtimes do not require administrator privileges.
- To match sidebar project names, it reads only project names and root paths from Codex's local `state_5.sqlite` project tables, falling back to project label fields in `.codex-global-state.json` when unavailable. It never modifies those files. These labels are used for display, not to rewrite token history.
- It does not upload local session contents or local token counters.
- It does not require an OpenAI API key.
- For the weekly quota indicator, the bundled Codex CLI contacts OpenAI using its existing signed-in account. The observer calls only `account/read` and `account/rateLimits/read`, after initialization. It does not start AI tasks, sign in or out, or redeem reset credits.
- It stores observed quota percentages and reset history in the local database, keyed by a hash of the account identity. It does not persist account email addresses or authentication credentials.
- It displays the service-reported weekly quota percentage and an estimated accumulated percentage across observed resets. It does not convert tokens to a billing amount or assume a fixed token allowance.

For local token counting, the application parses `token_count` events and reads the working directory in `session_meta` to group projects. It stores project names and paths locally. It does not display or persist prompt or response text.

Uninstalling the `.app` does not automatically remove the local SQLite database. Delete the Application Support folder separately if you want to remove the counter history.
