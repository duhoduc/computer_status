# computer_status

Docker app that stores a computer's status (CPU, RAM, GPU, disk, network, estimated power) in SQLite with 30-day retention, and shows it on a live dashboard.

## How it works

```
Windows agent (agent/*.ps1) --POST /api/live, /api/status--> Docker app (app/app.py, port 8765, SQLite)
                                                                  ^                ^
                                          browser dashboard  -----+                +----- Ubuntu client (ubuntu_client/sync_from_windows.py)
```

1. **Agents collect.** `agent/live_collector.ps1` posts a sample about every second to `/api/live`. `agent/push_status.ps1` posts a snapshot to `/api/status`.
2. **The app stores.** It keeps the last ~15 minutes of live samples in memory. It writes one sample per `sample_interval_s` to SQLite, and deletes rows older than `retention_days`. It also samples its own WSL VM.
3. **Clients read.** The dashboard (`/`) and the Ubuntu client read `/api/live`, `/api/samples`, `/api/history` and `/api/status`.
4. **Settings** live in `config/general_computer_settings.json`. Change them via `POST /api/settings` or edit the file.

## Run

- Start: `docker compose up -d --build`
- Dashboard: http://localhost:8765 (other computers use `http://<WINDOWS_IP>:8765`, and Windows Firewall must allow TCP 8765)
- Ubuntu: `python3 ubuntu_client/sync_from_windows.py http://<WINDOWS_IP>:8765`

## Remote access over Tailscale

- Open `http://<tailscale-ip>:8765` (this PC: `http://100.96.25.96:8765`, or its MagicDNS name) from any machine on your tailnet. The Rebuild button works there too: it talks to the agent on port 8766 of the same host.
- One-time, as administrator: `scripts/allow-tailscale-admin.ps1` opens TCP 8765 and 8766 to `100.64.0.0/10` only (not the wider LAN or internet).
- Ports are plain HTTP with no login: anyone on your tailnet can view the dashboard and press Rebuild. Use Tailscale ACLs if that is too open.

## Always on?

Partly. These layers keep it running:

- `restart: always` restarts the container after a crash, a Docker restart, or a reboot, as long as the Docker engine itself is running.
- The Docker engine runs only if Docker Desktop starts at login. Turn on *Settings > General > Start Docker Desktop when you sign in*. If nobody signs in after a reboot, nothing runs.
- The healthcheck (`/health`) only marks the container `unhealthy`. Docker does not restart it for that. Check with `docker ps`.
- The Windows agents must also start on their own, for example with Task Scheduler. Without that, there is no new data after a reboot.

## Access log (which computer talked to the app)

Every API request is logged to `/data/access.log` inside the container. That path is the repo's `data/` folder (bind-mounted, gitignored), so it is never committed. `data/` also holds `status.db` (computer + Claude samples) and `claude_usage.db` (a host-side copy of the Claude samples written by `agent/local.js`). It rotates at 1 MB with 5 backups.

Each line is `time client-ip METHOD path status hostname-or-source`. The hostname comes from the POST body.

Read it with: `docker exec computer-status tail -n 50 /data/access.log`

## Privacy and git

`.gitignore` excludes logs, databases, keys and tokens. Never commit them. Client IPs and hostnames are sensitive.
