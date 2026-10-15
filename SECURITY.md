# Security Policy

## Supported Versions

The latest version on the default branch is the supported version.

## Reporting A Vulnerability

Please report security issues privately instead of opening a public issue when the report includes account data, local file paths, thread titles, local Codex database contents, or other sensitive information.

Include:

- macOS version.
- codexU version.
- Whether the issue affects app launch, local file reads, quota reads, packaging, or update distribution.
- Minimal reproduction steps without private Codex data.

## Local Data Scope

codexU reads:

- `~/.codex/state_5.sqlite`
- `~/.codex/automations/**/automation.toml`
- local responses from `codex app-server`
- `~/.codex/sessions/**/rollout-*.jsonl` and `~/.codex/archived_sessions/*.jsonl` token metadata
- `~/.claude/projects/**/*.jsonl` assistant `message.usage` and `tool_use.name` metadata
- `~/.claude/tasks/**/*.json` task status/title metadata
- `~/.kimi-code/credentials/kimi-code.json` authentication credentials when no manual Kimi key is configured
- `~/.kimi-code/sessions/**/agents/*/wire.jsonl` structured usage, model, tool/Skill and inference timing metadata, completed turn boundaries, plus session `state.json` working directories and agent rosters
- `~/.kimi-code/sessions/<workspace>/session_<id>/state.json` session title, workspace and activity-time metadata for the Kimi task board; no conversation bodies or raw tool arguments are used
- local Kimi usage caches under `~/Library/Caches/codexU/kimi/`
- optional `~/Library/Caches/codexU/claude-code/statusline-snapshot.json`
- optional `~/Library/Caches/codexU/update-check.json` for cached GitHub Release update metadata

It should not upload local usage, transcript, task, thread, account, or path data to a third-party service. Claude Code transcript parsing must not store prompt text, assistant response text, tool arguments, or tool output.

Manual Kimi keys are stored in the macOS Keychain. A legacy plaintext preference is deleted only after successful migration. Keychain failures are surfaced without silently switching to another account. Kimi log caches contain derived metadata, not conversation text or raw tool arguments. The Kimi CLI owns its credential file; codexU reads it but never refreshes OAuth credentials or writes to it.

## Network Scope

codexU is local-first. The update checker may request public GitHub Release metadata from `https://api.github.com/repos/shanggqm/codexU/releases` during automatic checks when enabled or when the user manually checks for updates.

Kimi quota reads authenticate to `https://api.kimi.com/coding/v1/usages` using either a user-supplied API key or a still-valid Kimi Code access token. codexU does not call the OAuth token endpoint. If the local access token has expired, codexU asks the user to update or reauthenticate through Kimi Code. Quota requests send authentication credentials only; local session usage, transcripts, paths and task data are never included.

Update requests must not include local usage, transcript, task, thread, account, path, prompt, response, tool argument, or tool output data. The update checker may send standard HTTPS headers such as `User-Agent` and `If-None-Match` for ETag caching.

codexU must not silently download, install, replace, or relaunch the app as part of the GitHub Release check. It may open the user's default browser to a matching DMG asset or the Release page.

## Derived startup data

The home display cache retains at most two 256 KiB snapshots with usage summaries and bounded task titles/identifiers. It excludes account quota, raw transcripts, prompts, responses and tool arguments; restored tasks do not assert live running state. Files use mode 0600 inside a 0700 directory, with atomic replacement and fsync. The production history pipeline uses a separate SQLite index containing typed statistical facts and parser state under a single-writer lock. It opens original Codex databases read-only. Parser helpers have bounded frames and deadlines. Large Codex message/tool-output bodies are validated as a stream while only allowlisted statistical scalars survive in checkpoints; raw output and message text are discarded. Unknown or unsupported oversized statistical records are marked incomplete rather than silently counted. No usage, path, transcript, or account information is uploaded.
