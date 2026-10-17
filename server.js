// house_browser - Playwright 1.63.0 remote Chrome server, reachable over Tailscale.
//
// Edit the settings below, then restart the scheduled task (see README.md):
//   powershell -ExecutionPolicy Bypass -File C:\computer_status\restart-server.ps1

// ======================= SETTINGS =======================
const SETTINGS = require('path').join(__dirname, 'general_computer_settings.json');  // "browser_headless" here; toggled from http://localhost:8765
const readHeadless = () => { try { return !!JSON.parse(require('fs').readFileSync(SETTINGS, 'utf8')).browser_headless; } catch { return false; } };
const HEADLESS = readHeadless();   // true = no window, false = Chrome window visible on this PC's desktop
const APP = 'http://localhost:8765';
const PORT = 3000;       // clients connect to ws://<tailscale-ip>:PORT/
const WS_PATH = '/';      // must match the client URL path exactly (query string is ignored)
const CDP_PORT = 9223;    // localhost-only debug port, used by the tab janitor below
const JANITOR_IDLE_MIN = 15;     // close tabs with no navigation/network/console activity for this long
const JANITOR_MAX_TABS = 20;     // hard cap: beyond this, the least recently active tabs are closed
const JANITOR_EVERY_SEC = 60;    // sweep interval
// ========================================================

const path = require('path');
const { execFileSync } = require('child_process');

process.env.PLAYWRIGHT_BROWSERS_PATH = path.join(__dirname, 'browsers');
const { chromium } = require('playwright');

const TAILSCALE = 'C:\\Program Files\\Tailscale\\tailscale.exe';

function log(msg) {
  const d = new Date();
  const ts = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().replace('T', ' ').slice(0, 19);
  console.log(`${ts}  ${msg}`);
}

function tailscaleIp() {
  try {
    const out = execFileSync(TAILSCALE, ['ip', '-4'], { encoding: 'utf8', windowsHide: true });
    return out.split(/\r?\n/)[0].trim() || null;
  } catch {
    return null;
  }
}

async function waitForTailscaleIp() {
  // After a reboot/login Tailscale may need a few seconds to connect.
  for (;;) {
    const ip = tailscaleIp();
    if (ip) return ip;
    await new Promise(r => setTimeout(r, 2000));
  }
}

(async () => {
  const host = await waitForTailscaleIp();
  const server = await chromium.launchServer({
    headless: HEADLESS,
    host,
    port: PORT,
    wsPath: WS_PATH,
    handleSIGINT: false,  // a stray Ctrl+C on the hidden console must not stop the server
    args: [`--remote-debugging-port=${CDP_PORT}`, '--remote-debugging-address=127.0.0.1'],
  });
  log(`Chrome ready (headless=${HEADLESS}) at ${server.wsEndpoint()}`);

  // If Chrome dies (or its window is closed when headed), exit so start-server.ps1 restarts us.
  server.process().on('exit', code => {
    log(`Chrome exited (code ${code}); stopping server`);
    process.exit(1);
  });

  // Heartbeat to the dashboard app (drives its browser LED).
  const beat = () => fetch(`${APP}/api/browser/heartbeat`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ endpoint: server.wsEndpoint(), headless: HEADLESS }),
    signal: AbortSignal.timeout(3000),
  }).catch(() => {});
  beat();
  setInterval(beat, 5000);

  // Tab janitor: closes leaked/idle tabs (and empty contexts) so Chromium memory doesn't grow forever.
  // Attaches over CDP to see every client's tabs; "activity" = navigation, request or console output.
  const lastActive = new WeakMap();
  const touch = p => lastActive.set(p, Date.now());
  const watched = new WeakSet();
  const watch = p => {
    if (watched.has(p)) return;
    watched.add(p); touch(p);
    for (const ev of ['framenavigated', 'request', 'console', 'load', 'dialog']) p.on(ev, () => touch(p));
  };
  const ctxSeen = new WeakSet();
  let cdp = null;
  const sweep = async () => {
    try {
      if (!cdp || !cdp.isConnected()) {
        cdp = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`);
        cdp.on('disconnected', () => { cdp = null; });
      }
      const now = Date.now();
      const alive = [];
      for (const ctx of cdp.contexts()) {
        if (!ctxSeen.has(ctx)) { ctxSeen.add(ctx); ctx.on('page', watch); }
        for (const p of ctx.pages()) {
          watch(p);
          if (p.isClosed()) continue;
          const idle = now - (lastActive.get(p) || now);
          if (idle > JANITOR_IDLE_MIN * 60000) {
            log(`janitor: closing idle tab (${Math.round(idle / 60000)} min) ${p.url().slice(0, 80)}`);
            await p.close({ runBeforeUnload: false }).catch(() => {});
          } else alive.push(p);
        }
      }
      if (alive.length > JANITOR_MAX_TABS) {
        alive.sort((a, b) => (lastActive.get(a) || 0) - (lastActive.get(b) || 0));
        for (const p of alive.slice(0, alive.length - JANITOR_MAX_TABS)) {
          log(`janitor: closing tab over cap (${JANITOR_MAX_TABS}) ${p.url().slice(0, 80)}`);
          await p.close({ runBeforeUnload: false }).catch(() => {});
        }
      }
    } catch (e) {
      cdp = null;
      log(`janitor: sweep failed: ${e.message.split('\n')[0]}`);
    }
  };
  setInterval(sweep, JANITOR_EVERY_SEC * 1000);

  // Dashboard toggle changed browser_headless -> exit so start-server.ps1 restarts us with the new mode.
  require('fs').watchFile(SETTINGS, { interval: 2000 }, async () => {
    if (readHeadless() !== HEADLESS) {
      log(`browser_headless changed to ${!HEADLESS}; restarting`);
      await server.close().catch(() => {});
      process.exit(1);
    }
  });

  const shutdown = async () => {
    await server.close().catch(() => {});
    process.exit(0);
  };
  process.on('SIGINT', () => log('Ignoring Ctrl+C (use restart-server.ps1 to restart)'));
  process.on('SIGTERM', shutdown);
})().catch(err => {
  log(`Failed to start: ${err.stack || err}`);
  process.exit(1);
});
