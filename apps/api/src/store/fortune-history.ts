/**
 * Fortune History Store
 *
 * インメモリで占い履歴を管理するシングルトンストア。
 * - モジュールレベルの配列に格納（Node.js モジュールキャッシュで同一インスタンス共有）
 * - createdAt 降順で返す
 * - clearHistory() はテスト用のリセット関数
 */

import { randomUUID } from 'crypto';

// ─── 型定義 ───────────────────────────────────────────────────────────────────

/**
 * 各カテゴリの概要情報（dimensions を省いたサマリー）
 */
export interface CategorySummary {
  name?: string;
  totalScore: number;
  templateText: string;
}

/**
 * 履歴エントリ
 */
export interface HistoryEntry {
  /** UUID */
  id: string;
  /** ISO 8601 タイムスタンプ */
  createdAt: string;
  /** カテゴリ概要の配列 */
  categories: CategorySummary[];
}

// ─── In-memory store ──────────────────────────────────────────────────────────

const _store: HistoryEntry[] = [];

// ─── Store 操作 ───────────────────────────────────────────────────────────────

/**
 * 占い結果を履歴に追加する
 *
 * @param categories カテゴリ概要の配列
 * @returns 追加されたエントリ
 */
export function addHistoryEntry(categories: CategorySummary[]): HistoryEntry {
  const entry: HistoryEntry = {
    id: randomUUID(),
    createdAt: new Date().toISOString(),
    categories,
  };
  _store.push(entry);
  return entry;
}

/**
 * 全履歴を createdAt 降順（最新順）で返す
 *
 * @returns createdAt 降順ソート済みの履歴エントリ配列
 */
export function getHistory(): HistoryEntry[] {
  return [..._store].sort(
    (a, b) =>
      new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
  );
}

/**
 * ストアをクリアする（テスト用）
 */
export function clearHistory(): void {
  _store.length = 0;
}
