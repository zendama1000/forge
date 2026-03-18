/**
 * ブランドコンセプト インメモリストア
 * concept_id → ConceptEntry のマップで管理
 */

import { randomUUID } from 'node:crypto';

/** ストアに格納するコンセプトエントリ */
export interface ConceptEntry {
  /** 一意のコンセプトID（UUID v4） */
  concept_id: string;
  /** コンセプトデータ本体 */
  data: Record<string, unknown>;
  /** 作成日時（ISO 8601） */
  created_at: string;
}

/** インメモリストア（モジュールキャッシュで共有） */
const conceptStore = new Map<string, ConceptEntry>();

/**
 * 新しいブランドコンセプトをストアに追加する
 * @param data バリデーション済みのコンセプトデータ
 * @returns 作成されたエントリ（concept_id・created_at 付き）
 */
export function createConcept(data: Record<string, unknown>): ConceptEntry {
  const concept_id = randomUUID();
  const entry: ConceptEntry = {
    concept_id,
    data,
    created_at: new Date().toISOString(),
  };
  conceptStore.set(concept_id, entry);
  return entry;
}

/**
 * concept_id でコンセプトを取得する
 * @param id コンセプトID
 * @returns 存在すれば ConceptEntry、なければ undefined
 */
export function getConcept(id: string): ConceptEntry | undefined {
  return conceptStore.get(id);
}

/**
 * ストアを全消去する（テスト用）
 */
export function clearStore(): void {
  conceptStore.clear();
}
