'use client';

import { useState } from 'react';

// ─── 7次元パラメータ定義 ───────────────────────────────────────────────────────

const DIMENSIONS = [
  { name: '運気', icon: '⭐' },
  { name: '活力', icon: '⚡' },
  { name: '知性', icon: '💡' },
  { name: '感情', icon: '💖' },
  { name: '財運', icon: '💰' },
  { name: '健康', icon: '🌿' },
  { name: '社交', icon: '👥' },
] as const;

// ─── 型定義 ───────────────────────────────────────────────────────────────────

interface CategoryResult {
  id?: string;
  name?: string;
  totalScore: number;
  templateText: string;
  dimensions: Array<{ name?: string; rawScore: number }>;
}

interface FortuneResponse {
  categories: CategoryResult[];
}

// ─── カテゴリID導出 ──────────────────────────────────────────────────────────

const CATEGORY_NAME_TO_ID: Record<string, string> = {
  '恋愛運': 'love',
  '仕事運': 'work',
  '金運': 'money',
  '健康運': 'health',
};

function getCategoryId(cat: CategoryResult, index: number): string {
  return cat.id ?? CATEGORY_NAME_TO_ID[cat.name ?? ''] ?? `cat-${index}`;
}

// ─── FortunePage コンポーネント ────────────────────────────────────────────────

export default function FortunePage() {
  const [values, setValues] = useState<number[]>(Array(7).fill(50));
  const [isLoading, setIsLoading] = useState(false);
  const [result, setResult] = useState<FortuneResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState<string | null>(null);
  const [expandedCards, setExpandedCards] = useState<Set<string>>(new Set());

  const handleChange = (index: number, value: number) => {
    setValues((prev) => prev.map((v, i) => (i === index ? value : v)));
  };

  const handleSubmit = async () => {
    setIsLoading(true);
    setError(null);
    setResult(null);
    setExpandedCards(new Set());

    try {
      const response = await fetch('/api/fortune', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ dimensions: values }),
      });

      if (!response.ok) {
        const errorData = (await response.json()) as { error?: string };
        setError(errorData.error ?? 'エラーが発生しました');
        return;
      }

      const data = (await response.json()) as FortuneResponse;
      setResult(data);
      if (data.categories.length > 0) {
        setActiveTab(getCategoryId(data.categories[0], 0));
      }
    } catch {
      setError('ネットワークエラーが発生しました');
    } finally {
      setIsLoading(false);
    }
  };

  const toggleCard = (categoryId: string) => {
    setExpandedCards((prev) => {
      const next = new Set(prev);
      if (next.has(categoryId)) {
        next.delete(categoryId);
      } else {
        next.add(categoryId);
      }
      return next;
    });
  };

  return (
    <main className="min-h-screen p-8 max-w-2xl mx-auto">
      <h1 className="text-3xl font-bold mb-2">7次元占い</h1>
      <p className="text-gray-500 mb-8 text-sm">
        7つのパラメータを設定して、あなたの運勢を占いましょう。
      </p>

      {/* 7次元パラメータ入力 */}
      <section className="mb-8 space-y-4">
        <h2 className="text-xl font-semibold mb-4">パラメータ設定</h2>
        {DIMENSIONS.map((dim, index) => (
          <div key={dim.name} className="space-y-1">
            <label className="flex items-center gap-2">
              <span aria-hidden="true">{dim.icon}</span>
              <span className="font-medium">{dim.name}</span>
              <span className="ml-auto font-mono text-purple-600 w-8 text-right">
                {values[index]}
              </span>
            </label>
            <input
              type="range"
              min="0"
              max="100"
              step="1"
              value={values[index]}
              onChange={(e) =>
                handleChange(index, parseInt(e.target.value, 10))
              }
              className="w-full accent-purple-600"
              aria-label={`${dim.name}の値: ${values[index]}`}
            />
          </div>
        ))}
      </section>

      {/* 占い実行ボタン */}
      <button
        data-testid="fortune-submit"
        onClick={handleSubmit}
        disabled={isLoading}
        className="w-full py-3 px-6 bg-purple-600 text-white rounded-lg font-semibold hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
      >
        {isLoading ? '占い中...' : '占いを実行する'}
      </button>

      {/* ローディング状態 */}
      {isLoading && (
        <div
          data-testid="fortune-loading"
          className="mt-8 text-center py-8"
          role="status"
          aria-live="polite"
        >
          <div className="inline-block w-8 h-8 border-4 border-purple-600 border-t-transparent rounded-full animate-spin mb-4" />
          <p className="text-gray-600">星の配置を読み取っています...</p>
        </div>
      )}

      {/* エラー表示 */}
      {error && (
        <div
          data-testid="fortune-error"
          className="mt-4 p-4 bg-red-100 text-red-700 rounded-lg border border-red-200"
          role="alert"
        >
          <p className="font-medium">エラーが発生しました</p>
          <p className="text-sm mt-1">{error}</p>
        </div>
      )}

      {/* 占い結果 */}
      {result && (
        <section className="mt-8">
          <h2 className="text-xl font-semibold mb-4">占い結果</h2>

          {/* タブナビゲーション */}
          <div role="tablist" className="flex gap-1 mb-4 border-b border-gray-200">
            {result.categories.map((cat, index) => {
              const catId = getCategoryId(cat, index);
              const isActive = activeTab === catId;
              return (
                <button
                  key={catId}
                  data-testid={`tab-${catId}`}
                  role="tab"
                  aria-selected={isActive}
                  onClick={() => setActiveTab(catId)}
                  className={`px-4 py-2 text-sm font-medium rounded-t-lg transition-colors ${
                    isActive
                      ? 'bg-purple-600 text-white border-purple-600'
                      : 'text-gray-600 hover:text-purple-600 hover:bg-purple-50'
                  }`}
                >
                  {cat.name}
                </button>
              );
            })}
          </div>

          {/* カテゴリカード一覧 */}
          <div className="space-y-4">
            {result.categories.map((cat, index) => {
              const catId = getCategoryId(cat, index);
              const isExpanded = expandedCards.has(catId);

              return (
                <div
                  key={catId}
                  data-testid="fortune-card"
                  data-category={catId}
                  onClick={() => toggleCard(catId)}
                  className="p-4 border border-gray-200 rounded-xl shadow-sm bg-white cursor-pointer select-none"
                >
                  {/* サマリー部分 */}
                  <div aria-expanded={isExpanded}>
                    {/* カードヘッダー: カテゴリ名 + スコア */}
                    <div className="flex items-center justify-between mb-3">
                      <h3
                        data-testid="fortune-card-name"
                        className="text-lg font-semibold text-gray-800"
                      >
                        {cat.name}
                      </h3>
                      <span
                        data-testid="fortune-card-score"
                        className="text-2xl font-bold text-purple-600"
                      >
                        {cat.totalScore}
                      </span>
                    </div>

                    {/* プログレスバー */}
                    <div className="w-full bg-gray-100 rounded-full h-3 mb-3 overflow-hidden">
                      <div
                        data-testid="fortune-card-progress"
                        className="bg-purple-500 h-3 rounded-full transition-all duration-500"
                        style={{ width: `${cat.totalScore}%` }}
                        role="progressbar"
                        aria-valuenow={cat.totalScore}
                        aria-valuemin={0}
                        aria-valuemax={100}
                      />
                    </div>

                    {/* テンプレートテキスト */}
                    <p className="text-gray-600 text-sm leading-relaxed">
                      {cat.templateText}
                    </p>
                  </div>

                  {/* 詳細セクション（展開時のみ表示） */}
                  {isExpanded && (
                    <div
                      data-testid={`fortune-detail-${catId}`}
                      className="mt-4 pt-4 border-t border-gray-100"
                    >
                      {cat.dimensions.length > 0 ? (
                        <div className="grid grid-cols-2 gap-2">
                          {cat.dimensions.map((dim, i) => (
                            <div
                              key={i}
                              className="flex items-center justify-between text-sm py-1"
                            >
                              <span className="text-gray-600">
                                {dim.name ?? `次元${i + 1}`}
                              </span>
                              <span className="font-mono text-purple-600">
                                {dim.rawScore}
                              </span>
                            </div>
                          ))}
                        </div>
                      ) : (
                        <p className="text-gray-400 text-sm text-center">
                          データなし
                        </p>
                      )}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </section>
      )}
    </main>
  );
}
