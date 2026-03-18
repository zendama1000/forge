import { describe, it, expect } from 'vitest';
import { removeCodeBlock } from './preprocess';

describe('removeCodeBlock', () => {
  // behavior: '```json\n{"key":"value"}\n```' を入力 → '{"key":"value"}' が返却される
  it('```json コードブロック囲みを除去して中身のJSONを返す', () => {
    const input = '```json\n{"key":"value"}\n```';
    const result = removeCodeBlock(input);
    expect(result).toBe('{"key":"value"}');
  });

  // behavior: '```\n{"key":"value"}\n```'（言語指定なし）を入力 → '{"key":"value"}' が返却される
  it('言語指定なしのコードブロック囲みを除去して中身のJSONを返す', () => {
    const input = '```\n{"key":"value"}\n```';
    const result = removeCodeBlock(input);
    expect(result).toBe('{"key":"value"}');
  });

  // behavior: コードブロック囲みなしの純粋なJSON文字列を入力 → 入力がそのまま返却される（変換なし）
  it('コードブロック囲みなしの純粋なJSON文字列はそのまま返す', () => {
    const input = '{"key":"value"}';
    const result = removeCodeBlock(input);
    expect(result).toBe('{"key":"value"}');
  });

  // behavior: 先頭にテキスト + ```json...``` が混在する入力（例: 'Here is the result:\n```json\n{...}\n```'） → JSONブロック部分のみが抽出される
  it('先頭テキストとコードブロックが混在する場合、JSONブロック部分のみを抽出する', () => {
    const input = 'Here is the result:\n```json\n{"key":"value"}\n```';
    const result = removeCodeBlock(input);
    expect(result).toBe('{"key":"value"}');
  });

  // behavior: 空文字列を入力 → 空文字列がそのまま返却される
  it('空文字列を入力すると空文字列がそのまま返される', () => {
    const input = '';
    const result = removeCodeBlock(input);
    expect(result).toBe('');
  });

  // behavior: [追加] 複数行JSONをコードブロックで囲った場合も正しく抽出される
  it('複数行JSONのコードブロックを正しく抽出する', () => {
    const input = '```json\n{\n  "key": "value",\n  "num": 42\n}\n```';
    const result = removeCodeBlock(input);
    expect(result).toBe('{\n  "key": "value",\n  "num": 42\n}');
  });

  // behavior: [追加] 前後に余分な空白・改行があっても正しく除去される
  it('前後に余分なテキストがあっても中身が抽出される', () => {
    const input = 'Some text before\n```json\n{"a":1}\n```\nSome text after';
    const result = removeCodeBlock(input);
    expect(result).toBe('{"a":1}');
  });

  // behavior: [追加] ``` なし・プレーンテキスト入力はそのまま返す
  it('コードブロックなしのプレーンテキストはそのまま返す', () => {
    const input = 'plain text without any code block';
    const result = removeCodeBlock(input);
    expect(result).toBe('plain text without any code block');
  });
});
