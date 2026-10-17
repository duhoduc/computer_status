#!/usr/bin/env python3
"""Pull samples from the Windows computer_status API into a local SQLite DB on Ubuntu.

Incremental and idempotent: remembers the newest timestamp it has, asks only for newer rows,
so it catches up automatically after the Windows PC or this machine was off.
Standard library only (Python 3.8+).

  python3 sync_from_windows.py http://<WINDOWS_IP>:8765 [--db ~/dustinho_status.db]
"""
import argparse, json, os, sqlite3, sys, time, urllib.request

p = argparse.ArgumentParser()
p.add_argument("url", help="e.g. http://192.168.1.50:8765")
p.add_argument("--db", default=os.path.expanduser("~/dustinho_status.db"))
a = p.parse_args()

db = sqlite3.connect(a.db)
last = None
try:
    last = db.execute("SELECT MAX(ts) FROM samples").fetchone()[0]
except sqlite3.OperationalError:
    pass

url = f"{a.url.rstrip('/')}/api/samples?since={last or 0}"
for attempt in range(4):  # retry with backoff: tolerate brief network / restart gaps
    try:
        rows = json.load(urllib.request.urlopen(url, timeout=15))
        break
    except Exception as e:
        if attempt == 3:
            sys.exit(f"sync failed: {e}")
        time.sleep(2 ** attempt)

if rows:
    cols = list(rows[0].keys())
    db.execute(f"CREATE TABLE IF NOT EXISTS samples (ts REAL PRIMARY KEY, {', '.join(c + ' REAL' if c != 'hostname' else c + ' TEXT' for c in cols if c != 'ts')})")
    with db:
        db.executemany(f"INSERT OR REPLACE INTO samples ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
                       [[r[c] for c in cols] for r in rows])
print(f"{len(rows)} new rows -> {a.db}")
