'use client';

import { useState, useEffect } from 'react';

// ─── 型定義 ───────────────────────────────────────────────────────────────────

interface CategorySummary {
  name?: string;
  totalScore: number;
  templateText: string;
}

interface HistoryEntry {
  id: string;
  createdAt: string;
  categories: CategorySummary[];
}

// ─── カテゴリアイコンマッピング ──────────────────────────────────────────────

const CATEGORY_ICONS: Record<string, string> = {
  '恋愛運': '💕',
  '仕事運': '💼',
  '金運': '💰',
  '健康運': '🌿',
};

// ─── HistoryPage コンポーネント ────────────────────────────────────────────────

export default function HistoryPage() {
  const [entries, setEntries] = useState<HistoryEntry[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    fetch('/api/fortune/history')
      .then((res) => res.json())
      .then((data: HistoryEntry[]) => {
        setEntries(data);
      })
      .catch(() => {
        setEntries([]);
      })
      .finally(() => {
        setIsLoading(false);
      });
  }, []);

  return (
    <main className="min-h-screen p-8 max-w-2xl mx-auto">
      <h1 className="text-3xl font-bold mb-8">占い履歴</h1>

      {/* ローディング状態 */}
      {isLoading && (
        <div
          data-testid="history-loading"
          role="status"
          aria-live="polite"
          className="text-center py-8"
        >
          <div className="inline-block w-8 h-8 border-4 border-purple-600 border-t-transparent rounded-full animate-spin mb-4" />
          <p className="text-gray-600">履歴を読み込んでいます...</p>
        </div>
      )}

      {/* 空状態 */}
      {!isLoading && entries.length === 0 && (
        <div
          data-testid="history-empty"
          className="text-center py-12 text-gray-500"
        >
          <p className="text-lg">まだ占い結果がありません。</p>
          <p className="text-sm mt-2">占いを実行すると、ここに履歴が表示されます。</p>
        </div>
      )}

      {/* 履歴エントリ一覧 */}
      {!isLoading && entries.length > 0 && (
        <div className="space-y-4">
          {entries.map((entry) => (
            <div
              key={entry.id}
              data-testid="history-entry"
              className="p-4 border border-gray-200 rounded-xl shadow-sm bg-white"
            >
              <div className="flex items-center justify-between mb-3">
                <span
                  data-testid="history-entry-id"
                  className="text-xs text-gray-400 font-mono truncate max-w-[200px]"
                >
                  {entry.id}
                </span>
                <span
                  data-testid="history-entry-date"
                  className="text-sm text-gray-500"
                >
                  {new Date(entry.createdAt).toLocaleString('ja-JP')}
                </span>
              </div>
              <div className="flex gap-3">
                {entry.categories.map((cat, i) => (
                  <span
                    key={i}
                    data-testid="history-category-icon"
                    className="text-xl"
                    title={`${cat.name ?? 'カテゴリ'}: ${cat.totalScore}点`}
                  >
                    {CATEGORY_ICONS[cat.name ?? ''] ?? '⭐'}
                  </span>
                ))}
              </div>
            </div>
          ))}
        </div>
      )}
    </main>
  );
}
