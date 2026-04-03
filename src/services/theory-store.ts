/**
 * インメモリ理論ファイルストア
 * Map<id, TheoryFile> による管理
 */

import { TheoryFile } from '../types';
import { countChars, estimateTokens } from '../utils';

/** 500KB 上限（バイト数） */
export const MAX_TOTAL_SIZE_BYTES = 500 * 1024;

export interface StoredFileMeta {
  id: string;
  title: string;
  char_count: number;
  estimated_tokens: number;
}

export class TheoryStore {
  private store: Map<string, TheoryFile> = new Map();

  /** 理論ファイルを保存する */
  set(file: TheoryFile): void {
    this.store.set(file.id, file);
  }

  /** ID で理論ファイルを取得する */
  get(id: string): TheoryFile | undefined {
    return this.store.get(id);
  }

  /** 全理論ファイルを取得する */
  getAll(): TheoryFile[] {
    return Array.from(this.store.values());
  }

  /** 理論ファイルを削除する */
  delete(id: string): boolean {
    return this.store.delete(id);
  }

  /** ストアをクリアする */
  clear(): void {
    this.store.clear();
  }

  /** ストア内のファイル数を返す */
  size(): number {
    return this.store.size;
  }

  /** TheoryFile → メタデータ変換 */
  toMeta(file: TheoryFile): StoredFileMeta {
    return {
      id: file.id,
      title: file.title,
      char_count: countChars(file.content),
      estimated_tokens: estimateTokens(file.content),
    };
  }
}

/** シングルトンインスタンス */
export const theoryStore = new TheoryStore();
