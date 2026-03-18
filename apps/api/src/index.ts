import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { serve } from '@hono/node-server';
import auth from './routes/auth.js';
import settingsRouter from './routes/settings.js';
import fortuneRouter from './routes/fortune.js';
import historyRouter from './routes/history.js';
import { initDb, getSqliteClient } from './db/index.js';

const app = new Hono();

// CORS
app.use('/api/*', cors({
  origin: ['http://localhost:3000'],
  credentials: true,
}));

// Routes
app.route('/api/auth', auth);
app.route('/api/settings', settingsRouter);
app.route('/api/fortune', fortuneRouter);
app.route('/api/fortune/history', historyRouter);

app.get('/', (c) => {
  return c.json({ message: 'API Server Running', version: '1.0.0' });
});

app.get('/health', (c) => {
  return c.json({ status: 'ok', timestamp: new Date().toISOString() });
});

const port = Number(process.env.PORT) || 3001;

// DB 初期化（テストモード時は SQLite テーブル作成）
initDb();
const sqlite = getSqliteClient();
if (sqlite) {
  sqlite.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      username TEXT,
      password_hash TEXT NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      last_login_at TEXT,
      metadata TEXT
    );
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      token TEXT NOT NULL UNIQUE,
      refresh_token TEXT,
      expires_at TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      ip_address TEXT,
      user_agent TEXT,
      is_revoked INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS worlds (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      dimensions TEXT NOT NULL,
      content TEXT,
      tags TEXT,
      is_public INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      view_count INTEGER NOT NULL DEFAULT 0,
      like_count INTEGER NOT NULL DEFAULT 0,
      metadata TEXT
    );
  `);
  console.log('SQLite tables initialized (test mode)');
}

export default app;

// Dev server start
serve({
  fetch: app.fetch,
  port,
}, (info) => {
  console.log(`Server running on http://localhost:${info.port}`);
});
