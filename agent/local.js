// Local-machine jobs in one process: runs/supervises the live metrics collector (live_collector.ps1) and the
// chromium cleaner. Separate from server.js (the remote browser), so restarting one never touches the other.
//
// Cleaner: lists the Playwright chromium processes, marks orphans (not descended from the live browser server)
// as dead, counts DEAD_GRACE_S down to 0 and kills them. Reports to the dashboard. Does nothing destructive while
// the browser server is down/restarting (its pid is unknown then, so nothing is judged dead).
const path = require('path');
const MACHINE = (process.env.COMPUTERNAME || require('os').hostname()).toUpperCase();
const pick = f => { const q = path.parse(f), c = path.join(q.dir, `${q.name}_${MACHINE}${q.ext}`); return require('fs').existsSync(c) ? c : f; };  // name_<MACHINE>.ext wins
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
let collectorProc = null;
function startCollector() {
  const c = collectorProc = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', pick(path.join(__dirname, 'live_collector.ps1'))],
    { windowsHide: true, stdio: 'ignore' });
  log(`collector started pid ${c.pid}`);
  c.on('exit', code => { log(`collector exited (${code}); restarting in 5s`); setTimeout(startCollector, 5000); });
}

// ---- keep remote-browser windows at the bottom of the z-order (see keep_bottom.ps1) ----
let keepBottomProc = null;
function startKeepBottom() {
  const c = keepBottomProc = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', pick(path.join(__dirname, 'keep_bottom.ps1'))],
    { windowsHide: true, stdio: 'ignore' });
  log(`keep_bottom started pid ${c.pid}`);
  c.on('exit', code => { log(`keep_bottom exited (${code}); restarting in 5s`); setTimeout(startKeepBottom, 5000); });
}

log('local jobs started');
startCollector();
startKeepBottom();
scan(); setInterval(scan, EVERY_SEC * 1000);

// ---- Claude Code usage sampler: one sample every `claude_sample_minutes` (config), sent to the dashboard ----
const claude = require('./claude_usage');
const fs = require('fs');
const CONFIG = path.join(__dirname, '..', 'config', 'general_computer_settings.json');
let lastClaude = 0;
async function claudeTick() {
  let mins = 1; try { mins = Number(JSON.parse(fs.readFileSync(CONFIG, 'utf8')).claude_sample_minutes) || 1; } catch {}
  if (Date.now() - lastClaude < mins * 60000) return;
  lastClaude = Date.now();
  const t = claude.totals(); if (!t) return;
  claude.saveLocal(t);
  await fetch(`${APP}/api/claude`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(t), signal: AbortSignal.timeout(5000) }).catch(() => {});
}
claudeTick(); setInterval(claudeTick, 15000);

// ---- Rebuild control: the dashboard (inside Docker) can't rebuild itself, so this host-side process does it ----
// POST /rebuild starts `docker compose up -d --build` (+ restarts the collector); GET /status reports progress.
// Runs on its own port so the dashboard page can keep polling it while the app container is down.
const http = require('http');
const REBUILD_PORT = 8766;
const ROOT = path.join(__dirname, '..');
let rb = { state: 'idle', started: 0, finished: 0, tail: '' };
function rebuild() {
  if (rb.state === 'rebuilding') return;
  rb = { state: 'rebuilding', started: Date.now(), finished: 0, tail: '' };
  log('rebuild: docker compose up -d --build');
  execFile('docker', ['compose', 'up', '-d', '--build'], { cwd: ROOT, windowsHide: true, maxBuffer: 32e6, timeout: 15 * 60000 }, (err, out, errout) => {
    rb = { state: err ? 'failed' : 'done', started: rb.started, finished: Date.now(), tail: String(errout || out || (err && err.message) || '').split('\n').slice(-8).join('\n') };
    log(`rebuild ${rb.state}`);
    if (!err && collectorProc) collectorProc.kill();
    if (!err && keepBottomProc) keepBottomProc.kill();   // also restart keep_bottom so it runs the new script   // supervisor restarts it with the new live_collector.ps1
  });
}
http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  const u = req.url.split('?')[0];
  if (req.method === 'POST' && u === '/rebuild') rebuild();
  else if (!(req.method === 'GET' && u === '/status')) { res.statusCode = 404; return res.end('{}'); }
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(rb));
}).on('error', e => log(`rebuild endpoint: ${e.message}`)).listen(REBUILD_PORT, '0.0.0.0');
