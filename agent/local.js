// Local-machine jobs in one process: runs/supervises the live metrics collector (live_collector.ps1) and the
// chromium cleaner. Separate from server.js (the remote browser), so restarting one never touches the other.
//
// Cleaner: lists the Playwright chromium processes, marks orphans (not descended from the live browser server)
// as dead, counts DEAD_GRACE_S down to 0 and kills them. Reports to the dashboard. Does nothing destructive while
// the browser server is down/restarting (its pid is unknown then, so nothing is judged dead).
const path = require('path');
const { execFile, spawn } = require('child_process');

const APP = 'http://localhost:8765';
const BROWSERS = path.join(__dirname, '..', 'browsers').toLowerCase();
const DEAD_GRACE_S = 60;
const EVERY_SEC = 5;
const PS = "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,WorkingSetSize | ConvertTo-Json -Compress";

const log = m => console.log(`${new Date().toISOString().replace('T', ' ').slice(0, 19)}  ${m}`);
const failed = new Map();      // pid -> failed kill attempts
const deadSince = new Map();   // pid -> first time seen dead
let busy = false;

async function rootPid() {
  try {
    const b = await (await fetch(`${APP}/api/browser`, { signal: AbortSignal.timeout(3000) })).json();
    return b.up ? b.pid : null;
  } catch { return null; }
}

function scan() {
  if (busy) return; busy = true;
  execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', PS], { maxBuffer: 64e6, windowsHide: true }, async (err, out) => {
    try {
      if (err) return;
      let all; try { all = JSON.parse(out); } catch { return; }
      const root = await rootPid();
      const parent = new Map(all.map(p => [p.ProcessId, p.ParentProcessId]));
      const isAlive = pid => { for (let i = 0, x = pid; x && i < 50; i++, x = parent.get(x)) if (x === root) return true; return false; };
      const now = Date.now(), seen = new Set();
      const chrome = all.filter(p => (p.ExecutablePath || '').toLowerCase().startsWith(BROWSERS)).map(p => {
        seen.add(p.ProcessId);
        let status = 'running', left = null;
        if (!root) { status = 'unknown'; deadSince.delete(p.ProcessId); }   // browser server down: don't judge
        else if (isAlive(p.ProcessId)) deadSince.delete(p.ProcessId);
        else {
          status = 'dead';
          if (!deadSince.has(p.ProcessId)) deadSince.set(p.ProcessId, now);
          left = Math.max(0, DEAD_GRACE_S - Math.round((now - deadSince.get(p.ProcessId)) / 1000));
          if (left === 0) {
            if ((failed.get(p.ProcessId) || 0) >= 3) status = 'stuck';   // already gone but a handle keeps the ghost alive: stop retrying
            else {
              log(`killing dead chromium pid ${p.ProcessId}`);
              execFile('taskkill', ['/F', '/PID', String(p.ProcessId)], { windowsHide: true }, e => { if (e) failed.set(p.ProcessId, (failed.get(p.ProcessId) || 0) + 1); });
            }
          }
        }
        return { pid: p.ProcessId, name: p.Name, status, mem_mb: Math.round(p.WorkingSetSize / 1048576), counter: left };
      });
      for (const k of deadSince.keys()) if (!seen.has(k)) { deadSince.delete(k); failed.delete(k); }
      await fetch(`${APP}/api/cleaner/heartbeat`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chrome }), signal: AbortSignal.timeout(3000),
      }).catch(() => {});
    } finally { busy = false; }
  });
}
// ---- collector supervisor: restart live_collector.ps1 whenever it exits ----
function startCollector() {
  const c = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', path.join(__dirname, 'live_collector.ps1')],
    { windowsHide: true, stdio: 'ignore' });
  log(`collector started pid ${c.pid}`);
  c.on('exit', code => { log(`collector exited (${code}); restarting in 5s`); setTimeout(startCollector, 5000); });
}

log('local jobs started');
startCollector();
scan(); setInterval(scan, EVERY_SEC * 1000);

// ---- Claude Code usage sampler: one sample every `claude_sample_minutes` (config), sent to the dashboard ----
const claude = require('./claude_usage');
const fs = require('fs');
const CONFIG = path.join(__dirname, '..', 'config', 'general_computer_settings.json');
let lastClaude = 0;
async function claudeTick() {
  let mins = 5; try { mins = Number(JSON.parse(fs.readFileSync(CONFIG, 'utf8')).claude_sample_minutes) || 5; } catch {}
  if (Date.now() - lastClaude < mins * 60000) return;
  lastClaude = Date.now();
  const t = claude.totals(); if (!t) return;
  await fetch(`${APP}/api/claude`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(t), signal: AbortSignal.timeout(5000) }).catch(() => {});
}
claudeTick(); setInterval(claudeTick, 15000);
