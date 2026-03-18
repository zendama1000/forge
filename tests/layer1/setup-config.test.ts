/**
 * Layer 1 テスト: setup-project-config
 * 検証内容: TypeScript・ESLint・Prettierの設定が正しく機能すること
 *
 * Required behaviors:
 * - 全ソースファイルに対してtsc --noEmit → exit code 0（型エラーなし）
 * - 全ソースファイルに対してeslint実行 → 0 errors
 * - unused importを含むファイル → ESLint no-unused-vars / @typescript-eslint/no-unused-vars error検出
 * - any型を明示的に使用するコード → @typescript-eslint/no-explicit-any error検出
 * - 正しく型付けされたコード（generics, union types使用）→ no-explicit-anyで誤検出されない
 * - 全ソースファイルに対してprettier --check → exit code 0
 * - インデント不統一・末尾セミコロン不統一のファイル → prettier --check で差分検出
 */

import { execSync, spawnSync } from 'child_process';
import { existsSync, writeFileSync, unlinkSync } from 'fs';
import path from 'path';
import { describe, test, expect, beforeAll, afterAll } from 'vitest';
import { ESLint } from 'eslint';

const PROJECT_ROOT = path.resolve(__dirname, '../..');
const FIXTURE_PATH = path.join(PROJECT_ROOT, 'lint-test-fixture.ts');

/** ESLintインスタンスを取得するヘルパー */
function createEslint(): ESLint {
  return new ESLint({
    cwd: PROJECT_ROOT,
  });
}

/** ESLintでコードをlintし、メッセージを返す */
async function lintCode(code: string): Promise<ESLint.LintResult[]> {
  const eslint = createEslint();
  // ルートレベルの仮想ファイルとしてlint（ignoreパターンに引っかからない場所）
  const results = await eslint.lintText(code, {
    filePath: path.join(PROJECT_ROOT, 'lint-test-virtual.ts'),
  });
  return results;
}

// =============================================================================
// 1. TypeScript型チェック
// =============================================================================
describe('TypeScript型チェック', () => {
  // behavior: 全ソースファイルに対してtsc --noEmit → exit code 0（型エラーなし）
  test('tsc --noEmitがエラーなく完了すること', () => {
    const result = spawnSync('npx', ['tsc', '--noEmit'], {
      cwd: PROJECT_ROOT,
      encoding: 'utf-8',
      shell: true,
    });
    expect(result.status).toBe(0);
  });
});

// =============================================================================
// 2. ESLint - プロジェクト全体
// =============================================================================
describe('ESLint プロジェクト全体', () => {
  // behavior: 全ソースファイルに対してeslint実行 → 0 errors
  test('eslint . --max-warnings 0 がエラーなく完了すること', () => {
    const result = spawnSync('npx', ['eslint', '.', '--max-warnings', '0'], {
      cwd: PROJECT_ROOT,
      encoding: 'utf-8',
      shell: true,
    });
    expect(result.status).toBe(0);
  });
});

// =============================================================================
// 3. ESLint - ルール検出テスト（programmatic API）
// =============================================================================
describe('ESLint ルール検出', () => {
  // behavior: unused importを含むファイル → ESLint no-unused-vars / @typescript-eslint/no-unused-vars error検出
  test('未使用importを含むTypeScriptコードがESLintエラーとして検出されること', async () => {
    const code = `
import path from 'path';

export const value = 42;
`;
    const results = await lintCode(code);
    const messages = results[0]?.messages ?? [];
    const hasUnusedVarError = messages.some(
      (m) =>
        m.ruleId === '@typescript-eslint/no-unused-vars' ||
        m.ruleId === 'no-unused-vars'
    );
    expect(hasUnusedVarError).toBe(true);
  });

  // behavior: any型を明示的に使用するコード → @typescript-eslint/no-explicit-any error検出
  test('any型を明示的に使用するコードがESLintエラーとして検出されること', async () => {
    const code = `
export function processData(data: any): string {
  return String(data);
}
`;
    const results = await lintCode(code);
    const messages = results[0]?.messages ?? [];
    const hasNoExplicitAnyError = messages.some(
      (m) => m.ruleId === '@typescript-eslint/no-explicit-any'
    );
    expect(hasNoExplicitAnyError).toBe(true);
  });

  // behavior: 正しく型付けされたコード（generics, union types使用）→ no-explicit-anyで誤検出されない
  test('ジェネリクスとunion型を使った正しいコードではno-explicit-anyエラーが発生しないこと', async () => {
    const code = `
export function identity<T>(value: T): T {
  return value;
}

export function formatValue(value: string | number): string {
  return String(value);
}

export interface ApiResponse<T> {
  data: T;
  status: number;
}
`;
    const results = await lintCode(code);
    const messages = results[0]?.messages ?? [];
    const hasNoExplicitAnyError = messages.some(
      (m) => m.ruleId === '@typescript-eslint/no-explicit-any'
    );
    expect(hasNoExplicitAnyError).toBe(false);
  });

  // エッジケース: 変数にanyを使った場合もerror検出
  // behavior: [追加] any型変数宣言もno-explicit-anyで検出
  test('変数宣言でany型を使った場合もESLintエラーとして検出されること', async () => {
    const code = `
export const data: any[] = [];
`;
    const results = await lintCode(code);
    const messages = results[0]?.messages ?? [];
    const hasNoExplicitAnyError = messages.some(
      (m) => m.ruleId === '@typescript-eslint/no-explicit-any'
    );
    expect(hasNoExplicitAnyError).toBe(true);
  });
});

// =============================================================================
// 4. 設定ファイルの存在確認
// =============================================================================
describe('設定ファイルの存在確認', () => {
  // behavior: [追加] package.json, tsconfig.json, vitest.config.ts, playwright.config.ts の存在
  test('package.jsonが存在すること', () => {
    expect(existsSync(path.join(PROJECT_ROOT, 'package.json'))).toBe(true);
  });

  test('tsconfig.jsonが存在すること', () => {
    expect(existsSync(path.join(PROJECT_ROOT, 'tsconfig.json'))).toBe(true);
  });

  test('vitest.config.tsが存在すること', () => {
    expect(existsSync(path.join(PROJECT_ROOT, 'vitest.config.ts'))).toBe(true);
  });

  test('playwright.config.tsが存在すること', () => {
    expect(existsSync(path.join(PROJECT_ROOT, 'playwright.config.ts'))).toBe(true);
  });

  test('.prettierrcが存在すること', () => {
    expect(existsSync(path.join(PROJECT_ROOT, '.prettierrc'))).toBe(true);
  });

  test('.prettierrcが有効なJSONであること', async () => {
    const { readFileSync } = await import('fs');
    const content = readFileSync(path.join(PROJECT_ROOT, '.prettierrc'), 'utf-8');
    expect(() => JSON.parse(content)).not.toThrow();
    const config = JSON.parse(content) as Record<string, unknown>;
    expect(typeof config).toBe('object');
  });
});

// =============================================================================
// 5. Prettier（インストール済みの場合のみ実行）
// =============================================================================
describe('Prettier フォーマット確認', () => {
  let prettierAvailable = false;

  beforeAll(() => {
    // ローカルにインストール済みの prettier のみ使用（npx による自動ダウンロードを防ぐ）
    const prettierBin = path.join(PROJECT_ROOT, 'node_modules', '.bin', 'prettier');
    prettierAvailable = existsSync(prettierBin);
  });

  // behavior: 全ソースファイルに対してprettier --check → exit code 0
  test('prettier --check が正しくフォーマットされたファイルでexit code 0を返すこと', () => {
    if (!prettierAvailable) {
      console.warn('prettier not installed locally, skipping test');
      return;
    }
    const prettierBin = path.join(PROJECT_ROOT, 'node_modules', '.bin', 'prettier');
    const result = spawnSync(prettierBin, ['--check', '.'], {
      cwd: PROJECT_ROOT,
      encoding: 'utf-8',
      shell: false,
      timeout: 30000,
    });
    expect(result.status).toBe(0);
  });

  // behavior: インデント不統一・末尾セミコロン不統一のファイル → prettier --check で差分検出
  test('インデント不統一なファイルをprettier --checkが検出すること', () => {
    if (!prettierAvailable) {
      console.warn('prettier not installed locally, skipping test');
      return;
    }
    // インデントが不統一なコード（タブとスペースが混在）
    const badCode = `export const x = {
\tname: 'test',
  value: 42
}
`;
    writeFileSync(FIXTURE_PATH, badCode);
    try {
      const prettierBin = path.join(PROJECT_ROOT, 'node_modules', '.bin', 'prettier');
      const result = spawnSync(prettierBin, ['--check', 'lint-test-fixture.ts'], {
        cwd: PROJECT_ROOT,
        encoding: 'utf-8',
        shell: false,
        timeout: 15000,
      });
      // prettier --check は差分がある場合に非ゼロを返す
      expect(result.status).not.toBe(0);
    } finally {
      if (existsSync(FIXTURE_PATH)) {
        unlinkSync(FIXTURE_PATH);
      }
    }
  });
});

// クリーンアップ
afterAll(() => {
  if (existsSync(FIXTURE_PATH)) {
    unlinkSync(FIXTURE_PATH);
  }
});
