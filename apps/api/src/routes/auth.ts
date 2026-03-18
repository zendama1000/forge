/**
 * Authentication Handlers
 *
 * POST /auth/signup - ユーザー登録（bcryptハッシュ + JWT発行）
 * POST /auth/login - ログイン（認証 + トークン発行）
 * POST /auth/refresh - リフレッシュトークン再発行
 * POST /auth/logout - トークン無効化
 */

import { Hono } from 'hono';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { eq, and } from 'drizzle-orm';
import { getDb, getSqliteClient } from '../db/index.js';
import { users, sessions, type NewUser, type NewSession } from '../db/schema.js';

const auth = new Hono();

// ===========================
// 環境変数・定数
// ===========================

const JWT_SECRET = process.env.JWT_SECRET || 'default-secret-change-in-production';
const JWT_EXPIRES_IN = process.env.JWT_EXPIRES_IN || '1h';
const REFRESH_TOKEN_EXPIRES_IN = process.env.REFRESH_TOKEN_EXPIRES_IN || '7d';
const BCRYPT_ROUNDS = 10;

// ===========================
// Types
// ===========================

interface SignupRequest {
  email: string;
  password: string;
  username?: string;
}

interface LoginRequest {
  email: string;
  password: string;
}

interface RefreshRequest {
  refreshToken: string;
}

interface LogoutRequest {
  token: string;
}

// ===========================
// Helper Functions
// ===========================

/**
 * JWTトークンを生成
 */
function generateAccessToken(userId: string): string {
  return jwt.sign(
    {
      userId,
      type: 'access',
      jti: crypto.randomUUID() // ランダムなJWT IDを追加して一意性を保証
    },
    JWT_SECRET,
    {
      expiresIn: JWT_EXPIRES_IN,
    }
  );
}

/**
 * リフレッシュトークンを生成
 */
function generateRefreshToken(userId: string): string {
  return jwt.sign(
    {
      userId,
      type: 'refresh',
      jti: crypto.randomUUID() // ランダムなJWT IDを追加して一意性を保証
    },
    JWT_SECRET,
    {
      expiresIn: REFRESH_TOKEN_EXPIRES_IN,
    }
  );
}

/**
 * トークンの有効期限を計算
 */
function calculateExpiresAt(expiresIn: string): Date {
  const match = expiresIn.match(/^(\d+)([smhd])$/);
  if (!match) {
    throw new Error(`Invalid expiresIn format: ${expiresIn}`);
  }

  const value = parseInt(match[1], 10);
  const unit = match[2];

  const now = new Date();
  switch (unit) {
    case 's':
      return new Date(now.getTime() + value * 1000);
    case 'm':
      return new Date(now.getTime() + value * 60 * 1000);
    case 'h':
      return new Date(now.getTime() + value * 60 * 60 * 1000);
    case 'd':
      return new Date(now.getTime() + value * 24 * 60 * 60 * 1000);
    default:
      throw new Error(`Unknown time unit: ${unit}`);
  }
}

/**
 * JWTトークンを検証
 */
function verifyToken(token: string): { userId: string; type: string } {
  try {
    const payload = jwt.verify(token, JWT_SECRET) as { userId: string; type: string };
    return payload;
  } catch (error) {
    throw new Error('Invalid or expired token');
  }
}

/**
 * SQLite環境かどうかを判定
 */
function isSqliteEnv(): boolean {
  return getSqliteClient() !== null;
}

// ===========================
// POST /auth/signup
// ===========================

auth.post('/signup', async (c) => {
  try {
    const body = await c.req.json<SignupRequest>();
    const { email, password, username } = body;

    // バリデーション
    if (!email || !password) {
      return c.json({ error: 'Email and password are required' }, 400);
    }

    if (password.length < 8) {
      return c.json({ error: 'Password must be at least 8 characters' }, 400);
    }

    const db = getDb();

    // 既存ユーザーチェック
    const existingUsers = await db
      .select()
      .from(users)
      .where(eq(users.email, email))
      .limit(1);

    if (existingUsers.length > 0) {
      return c.json({ error: 'Email already registered' }, 409);
    }

    // パスワードハッシュ化
    const passwordHash = await bcrypt.hash(password, BCRYPT_ROUNDS);

    let createdUser: any;

    // SQLite環境では直接SQL実行
    if (isSqliteEnv()) {
      const sqlite = getSqliteClient()!;
      const now = new Date().toISOString();
      const userId = crypto.randomUUID();

      sqlite.prepare(`
        INSERT INTO users (id, email, username, password_hash, is_active, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      `).run(userId, email, username || null, passwordHash, 1, now, now);

      createdUser = {
        id: userId,
        email,
        username: username || null,
      };
    } else {
      // PostgreSQL環境ではDrizzle ORM使用
      const newUser: NewUser = {
        email,
        username: username || null,
        passwordHash,
        isActive: true,
      };

      [createdUser] = await db.insert(users).values(newUser).returning();

      if (!createdUser) {
        return c.json({ error: 'Failed to create user' }, 500);
      }
    }

    // トークン生成
    const accessToken = generateAccessToken(createdUser.id);
    const refreshToken = generateRefreshToken(createdUser.id);

    // セッション作成
    const expiresAtDate = calculateExpiresAt(JWT_EXPIRES_IN);

    if (isSqliteEnv()) {
      const sqlite = getSqliteClient()!;
      const now = new Date().toISOString();
      const sessionId = crypto.randomUUID();

      sqlite.prepare(`
        INSERT INTO sessions (id, user_id, token, refresh_token, expires_at, ip_address, user_agent, is_revoked, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        sessionId,
        createdUser.id,
        accessToken,
        refreshToken,
        expiresAtDate.toISOString(),
        c.req.header('x-forwarded-for') || c.req.header('x-real-ip') || null,
        c.req.header('user-agent') || null,
        0,
        now
      );
    } else {
      const newSession: NewSession = {
        userId: createdUser.id,
        token: accessToken,
        refreshToken,
        expiresAt: expiresAtDate,
        ipAddress: c.req.header('x-forwarded-for') || c.req.header('x-real-ip') || null,
        userAgent: c.req.header('user-agent') || null,
        isRevoked: false,
      };

      await db.insert(sessions).values(newSession);
    }

    return c.json(
      {
        message: 'User created successfully',
        user: {
          id: createdUser.id,
          email: createdUser.email,
          username: createdUser.username,
        },
        tokens: {
          accessToken,
          refreshToken,
        },
      },
      201
    );
  } catch (error) {
    console.error('Signup error:', error);
    return c.json({ error: 'Internal server error' }, 500);
  }
});

// ===========================
// POST /auth/login
// ===========================

auth.post('/login', async (c) => {
  try {
    const body = await c.req.json<LoginRequest>();
    const { email, password } = body;

    // バリデーション
    if (!email || !password) {
      return c.json({ error: 'Email and password are required' }, 400);
    }

    const db = getDb();

    // ユーザー検索
    const foundUsers = await db
      .select()
      .from(users)
      .where(eq(users.email, email))
      .limit(1);

    if (foundUsers.length === 0) {
      return c.json({ error: 'Invalid email or password' }, 401);
    }

    const user = foundUsers[0];

    // パスワード検証
    const isPasswordValid = await bcrypt.compare(password, user.passwordHash);

    if (!isPasswordValid) {
      return c.json({ error: 'Invalid email or password' }, 401);
    }

    // アクティブユーザーチェック
    if (!user.isActive) {
      return c.json({ error: 'Account is inactive' }, 403);
    }

    // トークン生成
    const accessToken = generateAccessToken(user.id);
    const refreshToken = generateRefreshToken(user.id);

    // セッション作成
    const expiresAtDate = calculateExpiresAt(JWT_EXPIRES_IN);

    if (isSqliteEnv()) {
      const sqlite = getSqliteClient()!;
      const now = new Date().toISOString();
      const sessionId = crypto.randomUUID();

      sqlite.prepare(`
        INSERT INTO sessions (id, user_id, token, refresh_token, expires_at, ip_address, user_agent, is_revoked, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        sessionId,
        user.id,
        accessToken,
        refreshToken,
        expiresAtDate.toISOString(),
        c.req.header('x-forwarded-for') || c.req.header('x-real-ip') || null,
        c.req.header('user-agent') || null,
        0,
        now
      );

      // 最終ログイン日時を更新
      sqlite.prepare(`
        UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ?
      `).run(now, now, user.id);
    } else {
      const newSession: NewSession = {
        userId: user.id,
        token: accessToken,
        refreshToken,
        expiresAt: expiresAtDate,
        ipAddress: c.req.header('x-forwarded-for') || c.req.header('x-real-ip') || null,
        userAgent: c.req.header('user-agent') || null,
        isRevoked: false,
      };

      await db.insert(sessions).values(newSession);

      // 最終ログイン日時を更新
      await db
        .update(users)
        .set({
          lastLoginAt: new Date(),
          updatedAt: new Date(),
        })
        .where(eq(users.id, user.id));
    }

    return c.json({
      message: 'Login successful',
      user: {
        id: user.id,
        email: user.email,
        username: user.username,
      },
      tokens: {
        accessToken,
        refreshToken,
      },
    });
  } catch (error) {
    console.error('Login error:', error);
    return c.json({ error: 'Internal server error' }, 500);
  }
});

// ===========================
// POST /auth/refresh
// ===========================

auth.post('/refresh', async (c) => {
  try {
    const body = await c.req.json<RefreshRequest>();
    const { refreshToken } = body;

    // バリデーション
    if (!refreshToken) {
      return c.json({ error: 'Refresh token is required' }, 400);
    }

    // トークン検証
    let payload: { userId: string; type: string };
    try {
      payload = verifyToken(refreshToken);
    } catch (error) {
      return c.json({ error: 'Invalid or expired refresh token' }, 401);
    }

    if (payload.type !== 'refresh') {
      return c.json({ error: 'Invalid token type' }, 401);
    }

    let session: any;

    if (isSqliteEnv()) {
      const sqlite = getSqliteClient()!;
      const result = sqlite.prepare(`
        SELECT * FROM sessions WHERE refresh_token = ? AND is_revoked = 0 LIMIT 1
      `).get(refreshToken);

      if (!result) {
        return c.json({ error: 'Session not found or revoked' }, 401);
      }

      session = result;
    } else {
      const db = getDb();

      // セッション検証（リフレッシュトークンがDBに存在し、無効化されていないか）
      const foundSessions = await db
        .select()
        .from(sessions)
        .where(
          and(
            eq(sessions.refreshToken, refreshToken),
            eq(sessions.isRevoked, false)
          )
        )
        .limit(1);

      if (foundSessions.length === 0) {
        return c.json({ error: 'Session not found or revoked' }, 401);
      }

      session = foundSessions[0];
    }

    // 新しいトークン生成
    const newAccessToken = generateAccessToken(payload.userId);
    const newRefreshToken = generateRefreshToken(payload.userId);

    const expiresAtDate = calculateExpiresAt(JWT_EXPIRES_IN);

    if (isSqliteEnv()) {
      const sqlite = getSqliteClient()!;
      const now = new Date().toISOString();
      const sessionId = crypto.randomUUID();

      // 古いセッションを無効化
      sqlite.prepare(`
        UPDATE sessions SET is_revoked = 1 WHERE id = ?
      `).run(session.id);

      // 新しいセッション作成
      sqlite.prepare(`
        INSERT INTO sessions (id, user_id, token, refresh_token, expires_at, ip_address, user_agent, is_revoked, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        sessionId,
        payload.userId,
        newAccessToken,
        newRefreshToken,
        expiresAtDate.toISOString(),
        c.req.header('x-forwarded-for') || c.req.header('x-real-ip') || null,
        c.req.header('user-agent') || null,
        0,
        now
      );
    } else {
      // 古いセッションを無効化
      await db
        .update(sessions)
        .set({ isRevoked: true })
        .where(eq(sessions.id, session.id));

      // 新しいセッション作成
      const newSession: NewSession = {
        userId: payload.userId,
        token: newAccessToken,
        refreshToken: newRefreshToken,
        expiresAt: expiresAtDate,
        ipAddress: c.req.header('x-forwarded-for') || c.req.header('x-real-ip') || null,
        userAgent: c.req.header('user-agent') || null,
        isRevoked: false,
      };

      await db.insert(sessions).values(newSession);
    }

    return c.json({
      message: 'Token refreshed successfully',
      tokens: {
        accessToken: newAccessToken,
        refreshToken: newRefreshToken,
      },
    });
  } catch (error) {
    console.error('Refresh error:', error);
    return c.json({ error: 'Internal server error' }, 500);
  }
});

// ===========================
// POST /auth/logout
// ===========================

auth.post('/logout', async (c) => {
  try {
    const body = await c.req.json<LogoutRequest>();
    const { token } = body;

    // バリデーション
    if (!token) {
      return c.json({ error: 'Token is required' }, 400);
    }

    if (isSqliteEnv()) {
      const sqlite = getSqliteClient()!;

      // セッション無効化（冪等性：存在しなくてもエラーにしない）
      sqlite.prepare(`
        UPDATE sessions SET is_revoked = 1 WHERE token = ?
      `).run(token);
    } else {
      const db = getDb();

      // セッション無効化
      await db
        .update(sessions)
        .set({ isRevoked: true })
        .where(eq(sessions.token, token));
    }

    return c.json({ message: 'Logout successful' });
  } catch (error) {
    console.error('Logout error:', error);
    return c.json({ error: 'Internal server error' }, 500);
  }
});

export default auth;
