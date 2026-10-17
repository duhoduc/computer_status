# computer_status

Docker app that stores this computer's status (SQLite, 30-day retention).

- `app/` - Python container: samples the WSL VM every 60s, accepts Windows stats via `POST /api/status`, serves a dashboard.
- `agent/` - Windows scripts: `push_status.ps1` (collector), `install_task.ps1` (runs it every minute via Task Scheduler).
- Start: `docker compose up -d --build`
- Dashboard: http://localhost:8765 - API: `/api/status`, `/api/history?source=windows&hours=24`
- Always running: `restart: always` plus Docker Desktop starting at login.
