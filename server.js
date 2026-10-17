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
