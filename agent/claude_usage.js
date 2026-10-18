// Claude Code usage for THIS folder: sums token usage over the project's transcripts
// (~/.claude/projects/<folder-slug>/*.jsonl). Each API message is logged several times while streaming,
// so entries are de-duplicated by message id (keeping the largest usage seen).
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DIR = path.join(os.homedir(), '.claude', 'projects', ROOT.replace(/[^a-zA-Z0-9]/g, '-'));

function totals() {
  let files = [];
  try { files = fs.readdirSync(DIR).filter(f => f.endsWith('.jsonl')); } catch { return null; }
  const msgs = new Map();        // message id -> {model, session, ts, usage}
  for (const f of files) {
    let text; try { text = fs.readFileSync(path.join(DIR, f), 'utf8'); } catch { continue; }
    for (const line of text.split('\n')) {
      if (!line.includes('"usage"')) continue;
      let o; try { o = JSON.parse(line); } catch { continue; }
      const m = o.message;
      if (o.type !== 'assistant' || !m || !m.usage) continue;
      const key = m.id || o.uuid, u = m.usage;
      const size = (u.output_tokens || 0) + (u.input_tokens || 0);
      const old = msgs.get(key);
      if (!old || size >= old.size) msgs.set(key, { size, model: m.model || o.requestedModel || '?', session: o.sessionId || f, ts: o.timestamp, u });
    }
  }
  const t = { input: 0, output: 0, cache_read: 0, cache_create: 0, messages: msgs.size, last_ts: null };
  const models = {}, sessions = new Set();
  for (const e of msgs.values()) {
    const m = models[e.model] || (models[e.model] = { input: 0, output: 0, cache_read: 0, cache_create: 0, messages: 0 });
    for (const [k, v] of [['input', e.u.input_tokens], ['output', e.u.output_tokens], ['cache_read', e.u.cache_read_input_tokens], ['cache_create', e.u.cache_creation_input_tokens]]) {
      t[k] += v || 0; m[k] += v || 0;
    }
    m.messages++; sessions.add(e.session);
    if (e.ts && (!t.last_ts || e.ts > t.last_ts)) t.last_ts = e.ts;
  }
  return { ...t, sessions: sessions.size, models };
}

// Local SQLite copy on the host (data/claude_usage.db, gitignored), written even while the dashboard is down.
let ldb = null;
function saveLocal(t) {
  try {
    if (!ldb) {
      fs.mkdirSync(path.join(ROOT, 'data'), { recursive: true });
      const { DatabaseSync } = require('node:sqlite');
      ldb = new DatabaseSync(path.join(ROOT, 'data', 'claude_usage.db'));
      ldb.exec('CREATE TABLE IF NOT EXISTS claude_usage (ts REAL PRIMARY KEY, input REAL, output REAL, cache_read REAL, cache_create REAL, messages INTEGER, sessions INTEGER, models TEXT)');
    }
    ldb.prepare('INSERT OR REPLACE INTO claude_usage VALUES (?,?,?,?,?,?,?,?)')
      .run(Date.now() / 1000, t.input, t.output, t.cache_read, t.cache_create, t.messages, t.sessions, JSON.stringify(t.models));
  } catch (e) { console.log(`local sqlite save failed: ${e.message}`); ldb = null; }
}

module.exports = { totals, saveLocal, DIR };
