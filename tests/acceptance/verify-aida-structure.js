#!/usr/bin/env node
/**
 * L3-005: AIDA帯域比率検証・キーワード検出
 * - AIDA5帯域マッピング（Attention 0-10% / Interest 10-35% / Desire 35-70% / Conviction 70-90% / Action 90-100%）
 * - 各帯域のキーワード検出（帯域特有の表現が含まれているか）
 * - 帯域比率の妥当性検証
 *
 * 使用方法:
 *   node verify-aida-structure.js [pipeline-output.json]
 *   デフォルト: output/pipeline-result.json
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ─── AIDA5帯域定義 ─────────────────────────────────────────────────────────────

const AIDA5_BAND_DEFINITIONS = [
  {
    name: 'attention',
    label: 'Attention（注意）',
    start_percent: 0,
    end_percent: 10,
    keywords: ['問題', '課題', '悩み', 'あなたへ', 'あなたは', 'このまま', '毎朝', '毎日', '現状'],
    min_ratio: 0.05,
    max_ratio: 0.20,
  },
  {
    name: 'interest',
    label: 'Interest（興味）',
    start_percent: 10,
    end_percent: 35,
    keywords: ['なぜ', '理由', '仕組み', '方法', '原因', 'なるほど', '実は', 'しかし', '一方'],
    min_ratio: 0.15,
    max_ratio: 0.40,
  },
  {
    name: 'desire',
    label: 'Desire（欲求）',
    start_percent: 35,
    end_percent: 70,
    keywords: ['ベネフィット', '効果', '成果', '変化', '成功', '実現', '達成', '自由', '豊か'],
    min_ratio: 0.20,
    max_ratio: 0.50,
  },
  {
    name: 'conviction',
    label: 'Conviction（確信）',
    start_percent: 70,
    end_percent: 90,
    keywords: ['証拠', '実績', '証言', '保証', '返金', '安心', '信頼', '事例', '受講生'],
    min_ratio: 0.10,
    max_ratio: 0.35,
  },
  {
    name: 'action',
    label: 'Action（行動）',
    start_percent: 90,
    end_percent: 100,
    keywords: ['今すぐ', '今だけ', '限定', '申込', '申し込み', '行動', 'CTA', '購入', '登録'],
    min_ratio: 0.05,
    max_ratio: 0.25,
  },
];

// ─── ユーティリティ ────────────────────────────────────────────────────────────

function fail(message) {
  console.error('[FAIL] ' + message);
  process.exit(1);
}

function pass(message) {
  console.log('[PASS] ' + message);
}

function warn(message) {
  console.warn('[WARN] ' + message);
}

function info(message) {
  console.log('[INFO] ' + message);
}

// ─── 帯域比率検証 ─────────────────────────────────────────────────────────────

function verifyBandRatios(sections, totalChars) {
  info('── 帯域比率検証 ──');

  const bandCharCounts = {};
  for (const band of AIDA5_BAND_DEFINITIONS) {
    bandCharCounts[band.name] = 0;
  }

  for (const section of sections) {
    const bandName = (section.aida_band || '').toLowerCase().trim();
    if (bandCharCounts[bandName] !== undefined) {
      bandCharCounts[bandName] += section.char_count || section.content.length;
    }
  }

  let allRatiosValid = true;

  for (const band of AIDA5_BAND_DEFINITIONS) {
    const bandChars = bandCharCounts[band.name];
    const ratio = totalChars > 0 ? bandChars / totalChars : 0;
    const ratioPercent = (ratio * 100).toFixed(1);

    const expectedStart = band.start_percent;
    const expectedEnd = band.end_percent;
    const expectedRangeLabel =
      '期待範囲: ' + band.min_ratio * 100 + '%-' + band.max_ratio * 100 + '%';

    if (ratio < band.min_ratio) {
      warn(
        band.label +
          ' 比率が低い: ' +
          ratioPercent +
          '% (' +
          expectedRangeLabel +
          ', 定義: ' +
          expectedStart +
          '-' +
          expectedEnd +
          '%)',
      );
      allRatiosValid = false;
    } else if (ratio > band.max_ratio) {
      warn(
        band.label +
          ' 比率が高い: ' +
          ratioPercent +
          '% (' +
          expectedRangeLabel +
          ', 定義: ' +
          expectedStart +
          '-' +
          expectedEnd +
          '%)',
      );
      allRatiosValid = false;
    } else {
      pass(
        band.label +
          ' 比率: ' +
          ratioPercent +
          '% (' +
          expectedRangeLabel +
          ') ✓',
      );
    }
  }

  if (!allRatiosValid) {
    warn('一部の帯域比率が推奨範囲外です（コンテンツの構成を確認してください）');
  }

  return allRatiosValid;
}

// ─── キーワード検出 ────────────────────────────────────────────────────────────

function detectBandKeywords(sections) {
  info('── キーワード検出 ──');

  let totalKeywordsFound = 0;
  const keywordResults = {};

  for (const band of AIDA5_BAND_DEFINITIONS) {
    const bandSections = sections.filter(
      (s) => (s.aida_band || '').toLowerCase().trim() === band.name,
    );

    const combinedContent = bandSections.map((s) => s.content || '').join('\n');
    const foundKeywords = band.keywords.filter((kw) => combinedContent.includes(kw));
    const keywordCoverage = band.keywords.length > 0
      ? foundKeywords.length / band.keywords.length
      : 0;

    keywordResults[band.name] = {
      found: foundKeywords,
      total: band.keywords.length,
      coverage: keywordCoverage,
    };

    totalKeywordsFound += foundKeywords.length;

    const coveragePercent = (keywordCoverage * 100).toFixed(0);
    if (keywordCoverage >= 0.3) {
      pass(
        band.label +
          ' キーワード検出: ' +
          foundKeywords.length +
          '/' +
          band.keywords.length +
          ' (' +
          coveragePercent +
          '%) - [' +
          foundKeywords.slice(0, 3).join(', ') +
          (foundKeywords.length > 3 ? '...' : '') +
          ']',
      );
    } else {
      warn(
        band.label +
          ' キーワード検出率が低い: ' +
          foundKeywords.length +
          '/' +
          band.keywords.length +
          ' (' +
          coveragePercent +
          '%)',
      );
    }
  }

  info('合計キーワード検出数: ' + totalKeywordsFound);
  return keywordResults;
}

// ─── AIDA5帯域存在チェック ────────────────────────────────────────────────────

function verifyAida5Presence(sections) {
  info('── AIDA5帯域存在チェック ──');

  const presentBands = new Set(
    sections.map((s) => (s.aida_band || '').toLowerCase().trim()),
  );

  const requiredBands = AIDA5_BAND_DEFINITIONS.map((b) => b.name);
  const missingBands = requiredBands.filter((b) => !presentBands.has(b));

  if (missingBands.length > 0) {
    fail(
      'AIDA5帯域が不足しています: [' +
        missingBands.join(', ') +
        '] が存在しません',
    );
  }
  pass('AIDA5帯域: すべての帯域が存在します (' + Array.from(presentBands).join(', ') + ')');

  return true;
}

// ─── メイン検証ロジック ────────────────────────────────────────────────────────

function verifyAidaStructure(filePath) {
  info('検証対象ファイル: ' + filePath);

  if (!fs.existsSync(filePath)) {
    fail('ファイルが存在しません: ' + filePath);
  }

  let data;
  try {
    const raw = fs.readFileSync(filePath, 'utf-8');
    data = JSON.parse(raw);
  } catch (e) {
    fail('JSONパースエラー: ' + e.message);
  }

  // PipelineState 形式 or 直接 PipelineResult 形式に対応
  const result = data.result || data;

  if (!Array.isArray(result.sections) || result.sections.length === 0) {
    fail('result.sections が空または配列ではありません');
  }

  const totalChars = result.total_chars || result.final_text?.length || 0;
  info('総文字数: ' + totalChars);
  info('セクション数: ' + result.sections.length);

  // AIDA5帯域存在チェック
  verifyAida5Presence(result.sections);

  console.log('');

  // 帯域比率検証
  const ratiosValid = verifyBandRatios(result.sections, totalChars);

  console.log('');

  // キーワード検出
  detectBandKeywords(result.sections);

  console.log('');

  if (ratiosValid) {
    console.log('=== L3-005 検証完了: AIDA帯域構造が有効です ===');
  } else {
    console.log('=== L3-005 検証完了: AIDA帯域は存在しますが一部の比率が推奨外です ===');
  }
}

// ─── エントリポイント ──────────────────────────────────────────────────────────

const inputFile = process.argv[2] || path.join('output', 'pipeline-result.json');
verifyAidaStructure(inputFile);
