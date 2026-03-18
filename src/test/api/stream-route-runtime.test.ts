/**
 * stream-route-runtime.test.ts
 *
 * ストリーミングAPIルートのランタイム設定を静的解析で検証するテスト。
 * - src/app/api/readings/[id]/stream/route.ts が Node.js Runtime を使用すること
 * - SSE実装 (ReadableStream / TextEncoder / text/event-stream) が維持されていること
 * - 非ストリームAPIルート (/api/cards, /api/readings) に Edge Runtime が追加されていないこと
 */

import { describe, it, expect } from 'vitest';
import { readFileSync, existsSync } from 'fs';
import { resolve } from 'path';

// プロジェクトルート: src/test/api/ から 3階層上
const PROJECT_ROOT = resolve(__dirname, '../../../');

const STREAM_ROUTE_PATH = resolve(
  PROJECT_ROOT,
  'src/app/api/readings/[id]/stream/route.ts'
);

const CARDS_ROUTE_PATH = resolve(
  PROJECT_ROOT,
  'src/app/api/cards/route.ts'
);

const READINGS_ROUTE_PATH = resolve(
  PROJECT_ROOT,
  'src/app/api/readings/route.ts'
);

// Edge Runtime 宣言パターン
const EDGE_RUNTIME_PATTERN = /export\s+const\s+runtime\s*=\s*['"]edge['"]/;
// Node.js Runtime 宣言パターン
const NODEJS_RUNTIME_PATTERN = /export\s+const\s+runtime\s*=\s*['"]nodejs['"]/;

describe('ストリームAPIルート ランタイム設定検証', () => {
  // behavior: src/app/api/readings/[id]/stream/route.ts から export const runtime = 'edge' が除去されている、または export const runtime = 'nodejs' に変更されている → grep検証でedgeランタイム宣言が不在
  it('streamルートにedgeランタイム宣言が存在しない', () => {
    expect(existsSync(STREAM_ROUTE_PATH)).toBe(true);

    const content = readFileSync(STREAM_ROUTE_PATH, 'utf-8');

    // 'edge' ランタイム宣言が含まれていないことを確認
    expect(content).not.toMatch(EDGE_RUNTIME_PATTERN);
  });

  // behavior: src/app/api/readings/[id]/stream/route.ts にReadableStreamベースのSSE実装が維持されている → ReadableStream・TextEncoder・'text/event-stream'ヘッダが存在
  it('streamルートにReadableStreamベースのSSE実装が維持されている', () => {
    const content = readFileSync(STREAM_ROUTE_PATH, 'utf-8');

    // ReadableStream の存在確認
    expect(content).toContain('ReadableStream');

    // TextEncoder の存在確認
    expect(content).toContain('TextEncoder');

    // text/event-stream ヘッダの存在確認
    expect(content).toContain('text/event-stream');
  });

  // behavior: 既存の非ストリームAPIルート（/api/cards, /api/readings）はランタイム宣言がないままである → Edge Runtime宣言が追加されていないことを確認
  it('非ストリームAPIルート（/api/cards）にEdge Runtime宣言が追加されていない', () => {
    // ファイルが存在しない場合はEdge Runtime宣言なしとみなし、テストをパス
    if (!existsSync(CARDS_ROUTE_PATH)) {
      return;
    }

    const content = readFileSync(CARDS_ROUTE_PATH, 'utf-8');
    expect(content).not.toMatch(EDGE_RUNTIME_PATTERN);
  });

  it('非ストリームAPIルート（/api/readings）にEdge Runtime宣言が追加されていない', () => {
    // ファイルが存在しない場合はEdge Runtime宣言なしとみなし、テストをパス
    if (!existsSync(READINGS_ROUTE_PATH)) {
      return;
    }

    const content = readFileSync(READINGS_ROUTE_PATH, 'utf-8');
    expect(content).not.toMatch(EDGE_RUNTIME_PATTERN);
  });

  // エッジケース: streamルートがNode.js runtimeを明示的に宣言している
  it('[追加] streamルートがNode.js runtimeを明示的に宣言している', () => {
    const content = readFileSync(STREAM_ROUTE_PATH, 'utf-8');

    // 'nodejs' ランタイム宣言が存在することを確認
    expect(content).toMatch(NODEJS_RUNTIME_PATTERN);
  });

  // エッジケース: streamルートがLLMクライアントモジュールをインポートしている
  it('[追加] streamルートがLLMクライアントモジュール（src/lib/llm/client）をインポートしている', () => {
    const content = readFileSync(STREAM_ROUTE_PATH, 'utf-8');

    // LLMクライアントモジュールのインポートを確認
    expect(content).toMatch(/from\s+['"].*lib\/llm\/client['"]/);
  });
});
