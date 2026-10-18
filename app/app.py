"""Computer status store: SQLite + tiny HTTP API + dashboard. Standard library only."""
import collections, json, logging, logging.handlers, os, sqlite3, threading, time, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DB_PATH = os.environ.get("DB_PATH", "status.db")
PORT = int(os.environ.get("PORT", "8765"))
CONFIG_PATH = os.environ.get("CONFIG_PATH", "general_computer_settings.json")
BROWSER = {"ts": 0, "endpoint": None, "headless": None, "pid": None}
CLEANER = {"ts": 0, "chrome": []}  # last heartbeat from the host-side agent/local.js
DEFAULTS = {"sample_interval_s": 30, "retention_days": 30, "claude_sample_minutes": 5, "browser_headless": False,
            "power_model": {"cpu_idle_w": 25, "cpu_max_w": 120, "other_w": 40}}
LIMITS = {"sample_interval_s": (1, 3600), "retention_days": (1, 3650), "claude_sample_minutes": (1, 1440)}
lock = threading.Lock()

# Access log: which computer (IP + reported hostname) talked to the API. Lives in the data volume, never in git.
ACCESS_LOG = logging.getLogger("access")
ACCESS_LOG.setLevel(logging.INFO)
try:
    _h = logging.handlers.RotatingFileHandler(os.environ.get("ACCESS_LOG_PATH", "access.log"), maxBytes=1_000_000, backupCount=5)
    _h.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    ACCESS_LOG.addHandler(_h)
except OSError as e:
    print("access log disabled:", e)

SAMPLE_COLS = [  # flat columns of the `samples` table: (name, extractor over the collector payload)
    ("cpu_percent", lambda s: s["cpu"]["util_percent"]),
    ("cpu_speed_ghz", lambda s: s["cpu"]["speed_ghz"]),
    ("cpu_temp_c", lambda s: s["cpu"]["temp_c"]),
    ("ram_percent", lambda s: s["memory"]["percent"]),
    ("ram_used_mb", lambda s: s["memory"]["used_mb"]),
    ("ram_total_mb", lambda s: s["memory"]["total_mb"]),
    ("gpu_percent", lambda s: s["gpu"]["util_percent"]),
    ("gpu_temp_c", lambda s: s["gpu"]["temp_c"]),
    ("gpu_power_w", lambda s: s["gpu"]["power_w"]),
    ("vram_used_mb", lambda s: s["gpu"]["vram_used_mb"]),
    ("disk_active_percent", lambda s: s["disk"]["active_percent"]),
    ("disk_read_mbps", lambda s: s["disk"]["read_mbps"]),
    ("disk_write_mbps", lambda s: s["disk"]["write_mbps"]),
    ("net_recv_mbps", lambda s: s["network"]["recv_mbps"]),
    ("net_sent_mbps", lambda s: s["network"]["sent_mbps"]),
    ("power_total_w_est", lambda s: s["power"]["total_w_est"]),
]


def load_config():
    cfg = json.loads(json.dumps(DEFAULTS))
    try:
        with open(CONFIG_PATH) as f:
            user = json.load(f)
        for k, v in user.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    except FileNotFoundError:
        write_config(cfg)
    except Exception as e:
        print("bad config, using defaults:", e)
    return cfg


def write_config(cfg):
    with open(CONFIG_PATH, "w") as f:  # in place: keeps the bind-mounted file's inode
        json.dump(cfg, f, indent=2)
        f.write("\n")


def update_config(new):
    cfg = load_config()
    for k, (lo, hi) in LIMITS.items():
        if k in new:
            v = float(new[k])
            if not lo <= v <= hi:
                raise ValueError(f"{k} must be between {lo} and {hi}")
            cfg[k] = int(v)
    if "browser_headless" in new:
        cfg["browser_headless"] = bool(new["browser_headless"])
    for k, v in (new.get("power_model") or {}).items():
        if k in cfg["power_model"]:
            if float(v) < 0:
                raise ValueError(f"{k} must be >= 0")
            cfg["power_model"][k] = float(v)
    write_config(cfg)
    return cfg


def db():
    c = sqlite3.connect(DB_PATH, timeout=10)
    c.execute("CREATE TABLE IF NOT EXISTS status (id INTEGER PRIMARY KEY, ts REAL, source TEXT, data TEXT)")
    c.execute("CREATE INDEX IF NOT EXISTS idx_src_ts ON status (source, ts)")
    cols = ", ".join(f"{n} REAL" for n, _ in SAMPLE_COLS)
    c.execute(f"CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, hostname TEXT, {cols})")
    c.execute("CREATE TABLE IF NOT EXISTS claude_usage (ts REAL PRIMARY KEY, input REAL, output REAL, cache_read REAL, cache_create REAL, messages INTEGER, sessions INTEGER, models TEXT)")
    return c


def save_claude(t):
    with lock:
        c = db()
        with c:
            c.execute("INSERT OR REPLACE INTO claude_usage VALUES (?,?,?,?,?,?,?,?)", (time.time(), t.get("input", 0), t.get("output", 0), t.get("cache_read", 0),
                      t.get("cache_create", 0), t.get("messages", 0), t.get("sessions", 0), json.dumps(t.get("models", {}))))
            c.execute("DELETE FROM claude_usage WHERE ts < ?", (time.time() - load_config()["retention_days"] * 86400,))
        c.close()


def claude_rows(hours):
    c = db()
    c.row_factory = sqlite3.Row
    start = time.time() - hours * 3600 if hours > 0 else 0
    rows = [dict(r) for r in c.execute("SELECT * FROM claude_usage WHERE ts>? ORDER BY ts", (start,))]
    c.close()
    for r in rows:
        r["models"] = json.loads(r["models"] or "{}")
    return rows


def save(source, data):
    with lock:
        c = db()
        with c:
            c.execute("INSERT INTO status (ts, source, data) VALUES (?,?,?)", (time.time(), source, json.dumps(data)))
            c.execute("DELETE FROM status WHERE ts < ?", (time.time() - load_config()["retention_days"] * 86400,))
        c.close()


def save_sample(s):
    def get(fn):
        try:
            return fn(s)
        except (KeyError, TypeError):
            return None
    row = [s["ts"], s.get("hostname")] + [get(fn) for _, fn in SAMPLE_COLS]
    with lock:
        c = db()
        with c:
            c.execute(f"INSERT OR REPLACE INTO samples VALUES ({','.join('?' * len(row))})", row)
            c.execute("DELETE FROM samples WHERE ts < ?", (time.time() - load_config()["retention_days"] * 86400,))
        c.close()


def samples(hours, since=None, limit=50000, points=0):
    """Rows newer than `since` (epoch seconds) if given, else from the last `hours`. Oldest first."""
    c = db()
    c.row_factory = sqlite3.Row
    start = since if since is not None else (time.time() - hours * 3600 if hours > 0 else 0)  # hours<=0: whole history
    rows = [dict(r) for r in c.execute("SELECT * FROM samples WHERE ts>? ORDER BY ts LIMIT ?", (start, limit))]
    c.close()
    if points and len(rows) > points:  # thin out evenly, keep the newest row
        step = len(rows) / points
        rows = [rows[min(len(rows) - 1, int(i * step))] for i in range(points - 1)] + [rows[-1]]
    return rows


def db_stats():
    c = db()
    n, first, last = c.execute("SELECT COUNT(*), MIN(ts), MAX(ts) FROM samples").fetchone()
    c.close()
    try:
        size = os.path.getsize(DB_PATH)
    except OSError:
        size = 0
    return {"rows": n, "first_ts": first, "last_ts": last, "db_size_kb": round(size / 1024, 1), "db_path": DB_PATH}


def read_cpu():
    with open("/proc/stat") as f:
        v = list(map(int, f.readline().split()[1:]))
    return sum(v), v[3] + v[4]


def collect_wsl():
    t1, i1 = read_cpu()
    time.sleep(1)
    t2, i2 = read_cpu()
    with open("/proc/meminfo") as f:
        mem = {l.split(":")[0]: int(l.split()[1]) for l in f}
    disk = shutil.disk_usage("/")
    with open("/proc/uptime") as f:
        uptime = int(float(f.read().split()[0]))
    return {
        "cpu_percent": round(100 * (1 - (i2 - i1) / max(t2 - t1, 1)), 1),
        "mem_total_mb": mem["MemTotal"] // 1024,
        "mem_used_mb": (mem["MemTotal"] - mem["MemAvailable"]) // 1024,
        "disk_total_gb": round(disk.total / 1e9, 1),
        "disk_used_gb": round(disk.used / 1e9, 1),
        "uptime_s": uptime,
        "load": os.getloadavg(),
    }


def collector():
    while True:
        try:
            save("wsl", collect_wsl())
        except Exception as e:
            print("collect error", e)
        time.sleep(load_config()["sample_interval_s"])


def latest():
    out = {}
    c = db()
    for (src,) in c.execute("SELECT DISTINCT source FROM status WHERE source != 'windows_live'").fetchall():  # legacy source
        ts, data = c.execute("SELECT ts, data FROM status WHERE source=? ORDER BY ts DESC LIMIT 1", (src,)).fetchone()
        out[src] = {"ts": ts, "age_s": int(time.time() - ts), "data": json.loads(data)}
    c.close()
    return out


def history(source, hours):
    c = db()
    rows = c.execute("SELECT ts, data FROM status WHERE source=? AND ts>? ORDER BY ts",
                     (source, time.time() - hours * 3600)).fetchall()
    c.close()
    return [{"ts": ts, **json.loads(d)} for ts, d in rows]


LIVE = collections.deque(maxlen=900)  # ~15 min of 1s samples, in memory
_last_persist = [0.0]


def live_add(sample):
    sample["ts"] = time.time()
    LIVE.append(sample)
    if sample["ts"] - _last_persist[0] >= load_config()["sample_interval_s"]:  # persist one sample per interval
        _last_persist[0] = sample["ts"]
        save_sample(sample)


PAGE = """<!doctype html><meta charset=utf-8><title>Computer status</title>
<style>body{font:15px system-ui;margin:2rem;background:#111;color:#eee}h2{margin-top:1.5rem}
table{border-collapse:collapse}td,th{padding:4px 12px;border-bottom:1px solid #333;text-align:left;vertical-align:top}.old{color:#f66}</style>
<h1>Computer status</h1><div id=o>loading...</div>
<script>
function render(v){
  if(Array.isArray(v)) return v.map(x=>typeof x==='object'&&x?render(x):x).join(' ');
  if(v&&typeof v==='object') return '<table>'+Object.entries(v).map(([a,b])=>'<tr><th>'+a+'<td>'+render(b)).join('')+'</table>';
  return v;
}
async function go(){
  const d=await (await fetch('/api/status')).json();
  document.getElementById('o').innerHTML=Object.entries(d).map(([s,x])=>
    '<h2>'+s+' <small class="'+(x.age_s>180?'old':'')+'">('+x.age_s+'s ago)</small></h2>'+render(x.data)).join('')||'no data yet';
}
go();
fetch('/api/settings').then(r=>r.json()).then(d=>setInterval(go,d.settings.sample_interval_s*1000));  // refresh at the sampling interval
</script>"""


class H(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        if not isinstance(body, (bytes, str)):
            body = json.dumps(body)
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/health":
            return self.send(200, {"ok": True})
        if u.path == "/api/status":
            return self.send(200, latest())
        if u.path == "/api/history":
            return self.send(200, history(q.get("source", ["windows"])[0], float(q.get("hours", ["24"])[0])))
        if u.path == "/api/live":
            n = int(q.get("n", ["300"])[0])
            return self.send(200, {"latest": LIVE[-1] if LIVE else None, "history": list(LIVE)[-n:]})
        if u.path == "/api/browser":
            age = time.time() - BROWSER["ts"]
            return self.send(200, {"up": age < 20, "age_s": int(age) if BROWSER["ts"] else None, "endpoint": BROWSER["endpoint"],
                                   "running_headless": BROWSER["headless"], "wanted_headless": load_config()["browser_headless"],
                                   "pid": BROWSER["pid"] if age < 20 else None,
                                   "cleaner_up": time.time() - CLEANER["ts"] < 30, "chrome": CLEANER["chrome"] if time.time() - CLEANER["ts"] < 30 else []})
        if u.path == "/api/claude":
            return self.send(200, claude_rows(float(q.get("hours", ["0"])[0])))
        if u.path == "/api/settings":
            return self.send(200, {"settings": load_config(), "db": db_stats(), "file": "general_computer_settings.json"})
        if u.path == "/api/samples":
            since = float(q["since"][0]) if "since" in q else None
            return self.send(200, samples(float(q.get("hours", ["24"])[0]), since, points=int(q.get("points", ["0"])[0])))
        if u.path in ("/", "/live"):
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "live.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if u.path == "/status":
            return self.send(200, PAGE, "text/html; charset=utf-8")
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/settings":
            try:
                n = int(self.headers.get("Content-Length", 0))
                return self.send(200, {"settings": update_config(json.loads(self.rfile.read(n)))})
            except Exception as e:
                return self.send(400, {"error": str(e)})
        if self.path == "/api/claude":
            try:
                save_claude(json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)))))
                return self.send(200, {"ok": True})
            except Exception as e:
                return self.send(400, {"error": str(e)})
        if self.path == "/api/cleaner/heartbeat":
            try:
                b = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                CLEANER.update(ts=time.time(), chrome=b.get("chrome") or [])
                return self.send(200, {"ok": True})
            except Exception as e:
                return self.send(400, {"error": str(e)})
        if self.path == "/api/browser/heartbeat":
            try:
                b = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                BROWSER.update(ts=time.time(), endpoint=b.get("endpoint"), headless=b.get("headless"), pid=b.get("pid"))
                return self.send(200, {"ok": True})
            except Exception as e:
                return self.send(400, {"error": str(e)})
        if self.path not in ("/api/status", "/api/live"):
            return self.send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            self.who = str(body.get("hostname") or body.get("source") or "")[:64]
            if self.path == "/api/live":
                live_add(body)
                return self.send(200, {"ok": True})
            save(str(body.pop("source", "windows")), body)
            self.send(200, {"ok": True})
        except Exception as e:
            self.send(400, {"error": str(e)})

    who = ""  # hostname/source reported in a POST body, for the access log

    def log_message(self, fmt, *a):
        if self.path in ("/health", "/api/browser/heartbeat", "/api/cleaner/heartbeat", "/api/browser"):  # skip polling noise
            return
        try:
            ACCESS_LOG.info("%s %s %s %s %s", self.client_address[0], self.command, self.path, a[1] if len(a) > 1 else "-", self.who)
        except Exception:
            pass


if __name__ == "__main__":
    db().close()
    threading.Thread(target=collector, daemon=True).start()
    print("listening on", PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
