# CLAUDE.md

## Save tokens (top priority)
- Prefer writing a small script/code to do a task over doing it by hand or step by step in chat.
- Never read large files whole. Use Grep to locate, then Read only the needed section (`offset`/`limit`).
- Don't re-read files just edited, or re-derive facts already established.
- Keep replies short: result and next step only. No recaps of code or diffs.
- Use Glob/Grep before spawning agents; spawn agents only for broad, parallel work.
- Pipe noisy command output through filters (head, tail, Select-String) instead of dumping it.

## Git workflow
- After finishing each task (one task per user input), commit and push immediately.
- One commit per user input, with a short message describing what changed.
- Remote: `git@github.com:duhoduc/computer_status.git`, branch `main`, using deploy key `~/.ssh/computer_status_deploy`.
- Never commit secrets (keys, tokens, `.env`, `*.db`).

## Rebuild after changes
- Always rebuild/restart every job whose code was modified so it runs the up-to-date code: Docker app (`docker compose up -d --build`), `browser/server.js` (`browser/restart-server.ps1`), Windows collector/push agents (re-run their `scripts/register-local.ps1` for the local jobs).
- Do this before the commit/push step and confirm each job is running.

## Machines
- Only `DUSTINHO` (the dev machine) may change code/files in this folder. Every other machine is read-only: `git pull`, then update/restart all services (rebuild Docker app, `browser/restart-server.ps1`, `scripts/register-local.ps1`) — never edit or commit code there.

## Project
- Layout: `app/` dashboard server (port 8765, Docker) · `agent/` local jobs (`local.js` cleaner+collector supervisor, `live_collector.ps1`, `push_status.ps1`) · `browser/` remote Playwright server (`server.js`, start/restart scripts) · `config/` settings JSON · `scripts/` scheduled-task installers · `docs/` · `logs/` (gitignored) · `ubuntu_client/`.
- Ubuntu must reach the server via the Windows LAN IP, not `localhost`.

## Per-machine scope
- Fixes and changes are machine-specific, keyed by computer name (`hostname`). Apply a change only for the machine it was requested for (this one, unless told otherwise) and don't modify behavior, config, or scripts for other machines.
- Put machine-specific logic/config behind a hostname check or a per-machine entry in `config/`; leave other machines' entries untouched.
