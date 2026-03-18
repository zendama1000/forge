/**
 * 倫理チェック第1段ゲート: 禁止表現データ定義
 * 景品表示法・消費者契約法に基づく禁止表現リスト（~20項目）
 */

export interface ProhibitedExpression {
  id: string;
  pattern: RegExp;
  description: string;
  law_reference: string;
  category: string;
}

export const PROHIBITED_EXPRESSIONS: ProhibitedExpression[] = [
  // ─── 景品表示法 - 優良誤認（過度な能力・効果の表示） ───────────────────────

  {
    id: 'keihyo-001',
    pattern: /必ず当たる/,
    description: '占い等において絶対的な的中を保証する表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-002',
    pattern: /\d+%的中/,
    description: '数値で的中率を断定する表現（例: 100%的中）',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-003',
    pattern: /絶対に当たる/,
    description: '占いの絶対的な正確さを主張する表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-004',
    pattern: /確実に当たる/,
    description: '確実な的中を保証する表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-005',
    pattern: /完全に当たる/,
    description: '完全な的中を主張する表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-006',
    pattern: /必ず叶う/,
    description: '願いの成就を断言する表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-007',
    pattern: /100%保証/,
    description: '100%の保証を謳う表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-008',
    pattern: /絶対に叶え/,
    description: '願望の絶対的実現を保証する表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },
  {
    id: 'keihyo-009',
    pattern: /必ず当選/,
    description: '当選を確約する表現',
    law_reference: '景品表示法',
    category: '有利誤認',
  },
  {
    id: 'keihyo-010',
    pattern: /的中率100/,
    description: '的中率100%を謳う表現',
    law_reference: '景品表示法',
    category: '優良誤認',
  },

  // ─── 消費者契約法 - 断定的判断の提供 ────────────────────────────────────────

  {
    id: 'shosha-001',
    pattern: /運命が変わります/,
    description: '運命の変化を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-002',
    pattern: /人生が変わります/,
    description: '人生の変化を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-003',
    pattern: /幸運が訪れます/,
    description: '幸運の到来を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-004',
    pattern: /必ず成功します/,
    description: '成功を断言する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-005',
    pattern: /恋愛が成就します/,
    description: '恋愛成就を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-006',
    pattern: /金運が必ず上がります/,
    description: '金運上昇を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-007',
    pattern: /願いが必ず叶います/,
    description: '願望成就を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-008',
    pattern: /未来が確実に変わります/,
    description: '未来の確実な変化を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-009',
    pattern: /必ず出会いがあります/,
    description: '出会いの必然を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
  {
    id: 'shosha-010',
    pattern: /仕事が必ずうまくいきます/,
    description: '仕事の成功を断定する表現',
    law_reference: '消費者契約法',
    category: '断定的判断の提供',
  },
];
