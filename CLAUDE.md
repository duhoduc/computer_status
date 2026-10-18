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
- Always rebuild/restart every job whose code was modified so it runs the up-to-date code: Docker app (`docker compose up -d --build`), `server.js` (`restart-server.ps1`), Windows collector/push agents (re-run their register/restart scripts).
- Do this before the commit/push step and confirm each job is running.

## Project
- Server: `app/app.py` (port 8765, Docker). Windows agent: `agent/`. Ubuntu client: `ubuntu_client/`.
- Ubuntu must reach the server via the Windows LAN IP, not `localhost`.
