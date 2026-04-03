/**
 * 商品情報後差し注入サービス
 * draft→critique→rewrite の3段構成でセールスレターに商品情報を自然に注入する
 *
 * 3段構成:
 *   Stage 1 (Draft)    : 入力として受け取ったletter_draftを起点とする
 *   Stage 2 (Critique) : LLMがドラフトを分析し、商品情報の注入ポイントと戦略を特定する
 *   Stage 3 (Rewrite)  : Critique結果を元に、商品情報を自然に組み込んでリライトする
 */

import { callLLM, callLLMJson, LLM_MODELS } from './llm-service';

// ─── 型定義 ──────────────────────────────────────────────────────────────────

export interface ProductInfo {
  name: string;
  price: string;
  features: string[];
  target_audience: string;
}

export interface ProductInjectionResult {
  modified_letter: string;
  char_count: number;
  injection_summary: string;
}

interface CritiqueResult {
  injection_points: string[];
  suggestions: string;
}

// ─── メイン関数 ──────────────────────────────────────────────────────────────

/**
 * セールスレタードラフトに商品情報を注入する（draft→critique→rewrite 3段構成）
 *
 * @param letterDraft     ベースとなるセールスレタードラフト
 * @param productInfo     注入する商品情報（name, price, features, target_audience）
 * @param model           使用するLLMモデル（省略時はPrimaryモデル）
 */
export async function injectProductInfo(
  letterDraft: string,
  productInfo: ProductInfo,
  model?: string,
): Promise<ProductInjectionResult> {
  const usedModel = model ?? LLM_MODELS.PRIMARY;

  // ── Stage 2: Critique ────────────────────────────────────────────────────
  // ドラフトを分析し、商品情報の注入ポイントと戦略を特定する

  const critiqueSystemPrompt = `あなたは日本語セールスレターの編集専門家です。
与えられたセールスレタードラフトと商品情報を分析し、
商品情報を自然に注入すべき箇所と戦略を特定してください。
出力はJSON形式のみとし、説明文や前置きは一切含めないこと。`;

  const featuresText = productInfo.features.join('、');

  const critiquePrompt = `以下のセールスレタードラフトに商品情報を自然に組み込む計画を立ててください。

## セールスレタードラフト
${letterDraft}

## 注入する商品情報
- 商品名: ${productInfo.name}
- 価格: ${productInfo.price}
- 特徴: ${featuresText}
- ターゲット: ${productInfo.target_audience}

## 分析指示
1. 商品名を自然に言及できる箇所を3箇所以上特定する（冒頭・中盤・クロージング付近）
2. 価格提示はConviction帯域以降（後半70%〜）に配置し、早すぎる価格開示を避ける
3. 特徴を読者の痛み（副業の壁・情報過多等）の解決策として文脈化できる箇所を特定する
4. 理論フレームワーク（PAS+PPPP、AIDA5帯域）の流れを断絶しない注入計画を立てる

## 出力形式（JSON）
{
  "injection_points": [
    "注入ポイントの説明1（どこに何をどう注入するか）",
    "注入ポイントの説明2",
    "注入ポイントの説明3"
  ],
  "suggestions": "全体的な注入戦略の説明（理論フレームワーク維持の観点を含む）"
}`;

  const critiqueResult = await callLLMJson<CritiqueResult>({
    prompt: critiquePrompt,
    systemPrompt: critiqueSystemPrompt,
    model: usedModel,
    maxTokens: 1024,
  });

  // ── Stage 3: Rewrite ─────────────────────────────────────────────────────
  // Critique結果を元に商品情報を自然に組み込んでリライトする

  const rewriteSystemPrompt = `あなたは日本語セールスレターの執筆専門家です。
既存のドラフトに商品情報を自然に組み込み、リライトしてください。
以下の原則を厳守すること:
- 商品名・価格・特徴が本文中で3箇所以上、文脈に沿って自然に言及されること
- 理論フレームワーク（PAS+PPPP、AIDA5帯域）の流れを維持すること（注入により断絶させない）
- 商品特徴を読者の痛みの解決策として文脈化すること
- 価格提示はConviction帯域以降（後半部分）に配置すること（早すぎる価格開示禁止）
- 元のドラフトの構造・トーンを維持しつつ商品情報を有機的に統合すること
リライト後の本文のみを出力すること。説明文・前置き・マークダウンは一切含めないこと。`;

  const injectionPointsText = (critiqueResult.injection_points ?? [])
    .map((point, i) => `${i + 1}. ${point}`)
    .join('\n');

  const rewritePrompt = `以下のセールスレタードラフトに商品情報を注入してリライトしてください。

## 元のセールスレタードラフト
${letterDraft}

## 注入する商品情報
- 商品名: ${productInfo.name}
- 価格: ${productInfo.price}
- 特徴: ${featuresText}
- ターゲット: ${productInfo.target_audience}

## 注入計画（事前分析結果）
戦略: ${critiqueResult.suggestions ?? '商品情報を理論フレームワークの流れに沿って自然に注入する'}

注入ポイント:
${injectionPointsText || '1. 導入部に商品名を問題解決の手段として言及する\n2. 中盤で商品特徴を読者の課題解決として文脈化する\n3. 後半で価格をConviction帯域に配置する'}

## リライト指示
上記の注入計画に従い、商品情報をドラフトに自然に組み込んでください。
必ず元のドラフトに商品名・価格・特徴が含まれた充実した内容にすること。
リライト後の本文のみを出力してください（説明文・前置き不要）。`;

  const rewriteResult = await callLLM({
    prompt: rewritePrompt,
    systemPrompt: rewriteSystemPrompt,
    model: usedModel,
    maxTokens: 8192,
  });

  const modifiedLetter = rewriteResult.text;

  return {
    modified_letter: modifiedLetter,
    char_count: Array.from(modifiedLetter).length,
    injection_summary: critiqueResult.suggestions ?? '',
  };
}
