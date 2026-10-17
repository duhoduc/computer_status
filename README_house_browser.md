# house_browser

A remote Chrome browser server (Playwright **1.63.0**) on this Windows PC. Another computer, such as the Ubuntu scraper machine, can drive it over **Tailscale**.

- Endpoint: `ws://100.80.61.99:3000/` (Tailscale IP of this PC, `qat-805`)
- The server listens only on the Tailscale interface, never on the office LAN.
- The Windows Task Scheduler task **`PlaywrightServer`** starts it automatically when you log in.

---

## Folder contents

| File / folder | Purpose |
|---|---|
| `server.js` | **The server. Edit `HEADLESS` and `PORT` here.** |
| `start-server.ps1` | Launcher run by the scheduled task. Restarts `server.js` if it stops. |
| `restart-server.ps1` | Restarts the server. Run it after you edit `server.js`. |
| `register-task.ps1` | Creates or repairs the scheduled task (runs at logon, no admin needed). |
| `install-startup-task-admin.ps1` | Optional, needs admin. Starts the server at boot, before anyone logs in. |
| `server.log` | Server log. |
| `node\` | Portable Node.js 24 (not installed system-wide). |
| `node_modules\` | Playwright 1.63.0. |
| `browsers\` | Chrome, Firefox and WebKit binaries used by Playwright. |

---

## Change headless mode (show or hide the Chrome window)

1. Open `C:\computer_status\server.js` and change the setting at the top:

   ```js
   const HEADLESS = true;    // true = no window, false = Chrome window visible on this PC's desktop
   ```

2. Save the file, then restart the scheduled task from PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\computer_status\restart-server.ps1
   ```

   The script stops the task and any running server or Chrome processes, starts the task again, and waits for the server. When it's up, you'll see a line like this:

   ```
   2026-10-16 23:10:45  Chrome ready (headless=false) at ws://100.80.61.99:3000/
   ```

The setting is saved in `server.js`, so it stays the same after a reboot or a new login.

> With `HEADLESS = false` the Chrome window appears on your desktop. **Don't close it by hand.** That stops the server; the launcher starts it again about 5 seconds later.

You can also restart the task without the script:

```powershell
Stop-ScheduledTask PlaywrightServer
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*C:\computer_status*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-ScheduledTask PlaywrightServer
```

To restart from the GUI, open **Task Scheduler**, find `PlaywrightServer` in the library, then click **End** and **Run**. Ending the task may leave `node.exe` running, so the script is the more reliable option.

---

## Setup from scratch (for example, on a new PC)

Requirements: Tailscale installed and logged in, and this folder at `C:\computer_status`.

If `node\`, `node_modules\` or `browsers\` are missing, reinstall them:

```powershell
cd C:\computer_status
# 1. Portable Node.js: download https://nodejs.org/dist/v24.22.0/node-v24.22.0-win-x64.zip
#    and extract it so that C:\computer_status\node\node.exe exists.
$env:Path = "C:\computer_status\node;$env:Path"
$env:PLAYWRIGHT_BROWSERS_PATH = "C:\computer_status\browsers"
# 2. Playwright and browsers
npm install playwright@1.63.0
npx playwright install chromium firefox webkit
```

Then create the scheduled task and start the server:

```powershell
powershell -ExecutionPolicy Bypass -File C:\computer_status\register-task.ps1
```

This registers `PlaywrightServer` with these settings:
- **Triggers:** at logon of the current user, with no delay. A watchdog also checks every 5 minutes and starts the task again if it has stopped. It does nothing while the server is running.
- **Restart:** the launcher restarts `server.js` within 5 s if it stops. Task Scheduler restarts the task every minute if it fails.
- **Power:** runs on battery and has no time limit.

### Optional: start at boot without logging in (needs admin)

From an **Administrator** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File C:\computer_status\install-startup-task-admin.ps1
```

Also turn on **Run unattended** in Tailscale (tray icon â†’ Preferences) so Tailscale connects before anyone logs in.

> In this mode Chrome runs as SYSTEM in a hidden session, so `HEADLESS = false` **doesn't show a window**. To switch back to the logon task, run `register-task.ps1`.

---

## Firewall

No change was needed. Tailscale's own Windows Firewall rule (`Tailscale-In`) allows inbound traffic on the Tailscale interface.

---

## Using it from the Ubuntu machine

The client's Playwright version **must be 1.63.x** to match the server. You don't need to install browsers on Ubuntu.

**Python**

```bash
pip install playwright==1.63.0
```

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.connect("ws://100.80.61.99:3000/")
    context = browser.new_context()      # one isolated context per job
    page = context.new_page()
    page.goto("https://example.com")
    print(page.title())
    context.close()
    browser.close()                      # disconnects only; the server keeps running
```

**Node.js**

```bash
npm install playwright@1.63.0
```

```js
const { chromium } = require('playwright');
const browser = await chromium.connect('ws://100.80.61.99:3000/');
```

Notes:
- All clients share one Chrome process, and each `new_context()` is isolated (separate cookies and storage).
- The server decides `headless`. A `headless` option set by the client has no effect.

---

## Troubleshooting

| Check | Command |
|---|---|
| Is the task running? | `Get-ScheduledTask PlaywrightServer` (State should be `Running`) |
| Is the server listening? | `Get-NetTCPConnection -LocalPort 3000 -State Listen` |
| What happened? | `Get-Content C:\computer_status\server.log -Tail 30` |
| Tailscale IP of this PC | `& 'C:\Program Files\Tailscale\tailscale.exe' ip -4` |
| Test from Ubuntu | `nc -zv 100.80.61.99 3000` |

- **Ubuntu can't connect:** check that both machines show as online in `tailscale status`, and that this PC isn't asleep. Set sleep to "Never" in Windows power settings, at least when plugged in.
- **Version mismatch error:** install Playwright `1.63.0` on the client.
- **Remove everything:** `Unregister-ScheduledTask PlaywrightServer -Confirm:$false`, then delete `C:\computer_status`.
