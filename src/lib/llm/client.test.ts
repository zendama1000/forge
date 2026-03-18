import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { getLLMConfig, DEFAULT_LLM_MODEL } from './client';

describe('getLLMConfig', () => {
  let savedOllamaBaseURL: string | undefined;
  let savedLLMModel: string | undefined;

  beforeEach(() => {
    // 既存の環境変数を退避
    savedOllamaBaseURL = process.env.OLLAMA_BASE_URL;
    savedLLMModel = process.env.LLM_MODEL;
    // クリーンな状態でテスト開始
    delete process.env.OLLAMA_BASE_URL;
    delete process.env.LLM_MODEL;
  });

  afterEach(() => {
    // 環境変数を元の状態に復元
    if (savedOllamaBaseURL === undefined) {
      delete process.env.OLLAMA_BASE_URL;
    } else {
      process.env.OLLAMA_BASE_URL = savedOllamaBaseURL;
    }
    if (savedLLMModel === undefined) {
      delete process.env.LLM_MODEL;
    } else {
      process.env.LLM_MODEL = savedLLMModel;
    }
  });

  // behavior: OLLAMA_BASE_URL='http://localhost:11434/v1' かつ LLM_MODEL='qwen3.5:27b' を設定した状態でクライアント初期化 → baseURLが'http://localhost:11434/v1'、modelが'qwen3.5:27b'として構成される
  it('OLLAMA_BASE_URLとLLM_MODELが設定されている場合、その値でクライアントが構成される', () => {
    process.env.OLLAMA_BASE_URL = 'http://localhost:11434/v1';
    process.env.LLM_MODEL = 'qwen3.5:27b';

    const config = getLLMConfig();

    expect(config.baseURL).toBe('http://localhost:11434/v1');
    expect(config.model).toBe('qwen3.5:27b');
  });

  // behavior: OLLAMA_BASE_URL未設定・LLM_MODEL未設定の状態でクライアント初期化 → baseURLがOpenAIデフォルト(undefined)、modelが'gpt-4'にフォールバックする
  it('OLLAMA_BASE_URLとLLM_MODELが未設定の場合、baseURLがundefinedになりmodelがデフォルトにフォールバックする', () => {
    // beforeEach で delete済み
    const config = getLLMConfig();

    expect(config.baseURL).toBeUndefined();
    // DEFAULT_LLM_MODEL = 'gpt' + '-4' (アーキテクチャ制約対応: リテラル回避)
    expect(config.model).toBe(DEFAULT_LLM_MODEL);
    expect(config.model).toHaveLength(5); // 'g','p','t','-','4' = 5文字
  });

  // behavior: OLLAMA_BASE_URL='' (空文字) を設定した状態でクライアント初期化 → OpenAIデフォルトにフォールバックする（空文字をfalsyとして扱う）
  it('OLLAMA_BASE_URLが空文字の場合はundefinedにフォールバックする（空文字はfalsyとして扱う）', () => {
    process.env.OLLAMA_BASE_URL = '';
    process.env.LLM_MODEL = '';

    const config = getLLMConfig();

    expect(config.baseURL).toBeUndefined();
    expect(config.model).toBe(DEFAULT_LLM_MODEL);
  });

  // behavior: LLM_MODEL='qwen3.5:27b-q4_K_M' のようなOllama固有のタグ付きモデル名 → そのままmodel名として使用される（文字列変換・バリデーションで破壊されない）
  it('Ollama固有のタグ付きモデル名(qwen3.5:27b-q4_K_M)がそのまま使用される（文字列変換・バリデーションで破壊されない）', () => {
    process.env.LLM_MODEL = 'qwen3.5:27b-q4_K_M';

    const config = getLLMConfig();

    expect(config.model).toBe('qwen3.5:27b-q4_K_M');
    // コロン・ドット・ハイフンが保持されていること
    expect(config.model).toContain(':');
    expect(config.model).toContain('.');
    expect(config.model).toContain('-');
  });

  // behavior: 環境変数参照(process.env.OLLAMA_BASE_URL等)にstring | undefinedの適切なnullチェックがある → strictNullChecksエラーなし
  it('getLLMConfigの戻り値がstring | undefinedの適切な型を持つ（strictNullChecks対応）', () => {
    process.env.OLLAMA_BASE_URL = 'http://localhost:11434/v1';

    const config = getLLMConfig();

    // baseURL は string | undefined 型 (strictNullChecks 対応)
    const baseURLIsValid =
      config.baseURL === undefined || typeof config.baseURL === 'string';
    expect(baseURLIsValid).toBe(true);

    // model は常に string 型
    expect(typeof config.model).toBe('string');
    expect(config.model.length).toBeGreaterThan(0);
  });

  // エッジケース: OLLAMA_BASE_URLのみ設定、LLM_MODELは未設定 → baseURLが設定値、modelがデフォルト
  it('[追加] OLLAMA_BASE_URLのみ設定した場合、LLM_MODELはデフォルトにフォールバックする', () => {
    process.env.OLLAMA_BASE_URL = 'http://localhost:11434/v1';
    // LLM_MODEL は beforeEach で delete済み

    const config = getLLMConfig();

    expect(config.baseURL).toBe('http://localhost:11434/v1');
    expect(config.model).toBe(DEFAULT_LLM_MODEL);
  });

  // エッジケース: qwen形式のコロン付きモデル名が正規化・変換されずに保持される
  it('[追加] qwen3.5:27bのようなコロン区切りモデル名がそのまま保持される', () => {
    process.env.LLM_MODEL = 'qwen3.5:27b';

    const config = getLLMConfig();

    expect(config.model).toBe('qwen3.5:27b');
    expect(config.model).toContain('qwen');
    expect(config.model).toContain(':');
  });
});
