#!/usr/bin/env node
/**
 * L3-001: パイプライン出力構造検証
 * - total_chars >= 20000
 * - AIDA5帯域（attention/interest/desire/conviction/action）すべて存在
 * - product_injected === true
 *
 * 使用方法:
 *   node verify-structure.js [pipeline-output.json]
 *   デフォルト: output/pipeline-result.json
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ─── 定数 ─────────────────────────────────────────────────────────────────────

const REQUIRED_MIN_CHARS = 20000;
const AIDA5_BANDS = ['attention', 'interest', 'desire', 'conviction', 'action'];

// ─── ユーティリティ ────────────────────────────────────────────────────────────

function fail(message) {
  console.error('[FAIL] ' + message);
  process.exit(1);
}

function pass(message) {
  console.log('[PASS] ' + message);
}

function info(message) {
  console.log('[INFO] ' + message);
}

// ─── 検証ロジック ─────────────────────────────────────────────────────────────

function verifyPipelineOutput(filePath) {
  info('検証対象ファイル: ' + filePath);

  // ファイル存在チェック
  if (!fs.existsSync(filePath)) {
    fail('ファイルが存在しません: ' + filePath);
  }

  // JSON パース
  let data;
  try {
    const raw = fs.readFileSync(filePath, 'utf-8');
    data = JSON.parse(raw);
  } catch (e) {
    fail('JSONパースエラー: ' + e.message);
  }

  // result フィールド取得（PipelineState 形式 or 直接 PipelineResult 形式に対応）
  const result = data.result || data;

  info('レスポンス構造確認中...');

  // ── 検証1: total_chars >= 20000 ────────────────────────────────────────────
  if (typeof result.total_chars !== 'number') {
    fail('result.total_chars が数値ではありません: ' + JSON.stringify(result.total_chars));
  }

  if (result.total_chars < REQUIRED_MIN_CHARS) {
    fail(
      'total_chars が不足しています: ' +
        result.total_chars +
        ' < ' +
        REQUIRED_MIN_CHARS +
        ' (required)',
    );
  }
  pass('total_chars チェック: ' + result.total_chars + ' >= ' + REQUIRED_MIN_CHARS);

  // ── 検証2: final_text の実際の文字数チェック ──────────────────────────────
  if (typeof result.final_text !== 'string') {
    fail('result.final_text が文字列ではありません');
  }

  const actualChars = result.final_text.length;
  if (actualChars < REQUIRED_MIN_CHARS) {
    fail(
      'final_text の実際の文字数が不足しています: ' +
        actualChars +
        ' < ' +
        REQUIRED_MIN_CHARS,
    );
  }
  pass('final_text 文字数チェック: ' + actualChars + '文字');

  // ── 検証3: AIDA5帯域すべて存在 ────────────────────────────────────────────
  if (!Array.isArray(result.sections)) {
    fail('result.sections が配列ではありません');
  }

  const presentBands = new Set(
    result.sections.map((s) => (s.aida_band || '').toLowerCase().trim()),
  );

  const missingBands = AIDA5_BANDS.filter((band) => !presentBands.has(band));
  if (missingBands.length > 0) {
    fail(
      'AIDA5帯域が不足しています: [' +
        missingBands.join(', ') +
        '] が存在しません。' +
        '存在する帯域: [' +
        Array.from(presentBands).join(', ') +
        ']',
    );
  }
  pass('AIDA5帯域チェック: すべての帯域が存在します (' + AIDA5_BANDS.join(', ') + ')');

  // ── 検証4: product_injected === true ──────────────────────────────────────
  if (result.product_injected !== true) {
    fail(
      'product_injected が true ではありません: ' + JSON.stringify(result.product_injected),
    );
  }
  pass('product_injected チェック: true');

  // ── 検証5: quality_score が数値 ───────────────────────────────────────────
  if (typeof result.quality_score === 'number') {
    info('quality_score: ' + result.quality_score);
  }

  // ── 検証6: sections の内容チェック ────────────────────────────────────────
  info('sections 数: ' + result.sections.length);
  for (let i = 0; i < result.sections.length; i++) {
    const section = result.sections[i];
    if (typeof section.content !== 'string' || section.content.length === 0) {
      fail('sections[' + i + '].content が空または文字列ではありません');
    }
    if (typeof section.char_count !== 'number') {
      fail('sections[' + i + '].char_count が数値ではありません');
    }
  }
  pass('sections 内容チェック: すべてのセクションが有効なコンテンツを持っています');

  console.log('');
  console.log('=== L3-001 検証完了: すべてのチェックが通過しました ===');
}

// ─── エントリポイント ──────────────────────────────────────────────────────────

const inputFile = process.argv[2] || path.join('output', 'pipeline-result.json');
verifyPipelineOutput(inputFile);
