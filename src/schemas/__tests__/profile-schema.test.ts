import { describe, it, expect } from 'vitest';
import { validateProfile, countChars } from '../profile-validator';

/** LINE公式 特商法7項目 */
const TOKUSHO_ITEMS = [
  '事業者名',
  '所在地',
  '電話番号',
  '代表者名',
  '販売価格',
  '支払方法',
  '返金・キャンセルポリシー',
];

/** 有効なInstagramプロフィールのベースライン */
const validInstagram: Record<string, unknown> = {
  platform_type: 'instagram',
  display_name: 'スターライト占術',
  bio: 'タロットと星占いで、あなたの道を照らします。毎日の宇宙エネルギーをシェア。',
  aesthetic_priority: 'visual',
  $schema_version: '1.0.0',
};

/** 有効なTikTokプロフィールのベースライン */
const validTiktok: Record<string, unknown> = {
  platform_type: 'tiktok',
  display_name: 'スターライト占術',
  bio: 'タロットと星占いで毎日を輝かせる✨',
  aesthetic_priority: 'approachable',
  $schema_version: '1.0.0',
};

/** 有効なLINE公式プロフィールのベースライン */
const validLineOfficial: Record<string, unknown> = {
  platform_type: 'line_official',
  display_name: 'スターライト占術 LINE公式',
  bio: 'タロット・星占い鑑定のLINE公式アカウント。',
  compliance_level: 'legal_required',
  compliance_checklist: [...TOKUSHO_ITEMS],
  $schema_version: '1.0.0',
};

describe('profile-schema validateProfile', () => {
  // behavior: platform_type='instagram'のプロフィール（bio 150文字以内、aesthetic_priority='visual'）→ バリデーション通過
  it('Instagramプロフィール（bio 150文字以内、aesthetic_priority=visual）はバリデーション通過', () => {
    const result = validateProfile(validInstagram);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: platform_type='tiktok'のプロフィール（bio 80文字以内、aesthetic_priority='approachable'）→ バリデーション通過
  it('TikTokプロフィール（bio 80文字以内、aesthetic_priority=approachable）はバリデーション通過', () => {
    const result = validateProfile(validTiktok);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: platform_type='line_official'のプロフィール（compliance_level='legal_required'、特商法7項目含む）→ バリデーション通過
  it('LINE公式プロフィール（compliance_level=legal_required、特商法7項目含む）はバリデーション通過', () => {
    const result = validateProfile(validLineOfficial);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: Instagramプロフィールのbioが151文字 → バリデーションエラー（文字数上限超過メッセージ）
  it('Instagramプロフィールのbioが151文字の場合はバリデーションエラー（文字数上限超過メッセージ）', () => {
    // マルチバイト151文字（'あ'が151個 = Unicode code point 151個）
    const bio151 = 'あ'.repeat(151);
    expect(countChars(bio151)).toBe(151); // 事前確認
    const data: Record<string, unknown> = { ...validInstagram, bio: bio151 };
    const result = validateProfile(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasBioLimitError = result.errors!.some(
      (e) =>
        e.includes('bio') &&
        (e.includes('150') ||
          e.toLowerCase().includes('character') ||
          e.includes('limit') ||
          e.includes('exceed') ||
          e.includes('超過'))
    );
    expect(hasBioLimitError).toBe(true);
  });

  // behavior: LINE公式プロフィールに特商法チェックリストが欠落 → バリデーションエラー（compliance_checklist必須メッセージ）
  it('LINE公式プロフィールにcompliance_checklistが欠落の場合はバリデーションエラー（compliance_checklist必須メッセージ）', () => {
    const data: Record<string, unknown> = {
      platform_type: 'line_official',
      display_name: 'スターライト占術 LINE公式',
      bio: 'タロット・星占い鑑定のLINE公式アカウント。',
      compliance_level: 'legal_required',
      $schema_version: '1.0.0',
      // compliance_checklist は意図的に欠落
    };
    const result = validateProfile(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasChecklistError = result.errors!.some((e) => e.includes('compliance_checklist'));
    expect(hasChecklistError).toBe(true);
  });

  // behavior: platform_typeが未定義値（例: 'facebook'）→ バリデーションエラー（対応プラットフォーム一覧を含むメッセージ）
  it('platform_typeが未定義値（facebook）の場合はバリデーションエラー（対応プラットフォーム一覧を含むメッセージ）', () => {
    const data: Record<string, unknown> = {
      platform_type: 'facebook',
      bio: 'テストプロフィール',
      $schema_version: '1.0.0',
    };
    const result = validateProfile(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    // 対応プラットフォーム一覧（instagram, tiktok, line_official 等）を含むメッセージ検証
    const hasPlatformListError = result.errors!.some(
      (e) =>
        e.includes('platform_type') &&
        (e.includes('instagram') ||
          e.includes('tiktok') ||
          e.includes('line_official') ||
          e.includes('supported'))
    );
    expect(hasPlatformListError).toBe(true);
  });

  // behavior: platform_typeフィールド自体が欠落 → バリデーションエラー（'platform_type' 必須メッセージ）
  it('platform_typeフィールドが欠落した場合はバリデーションエラー（platform_type 必須メッセージ）', () => {
    const data: Record<string, unknown> = {
      bio: 'テストプロフィール',
      $schema_version: '1.0.0',
    };
    const result = validateProfile(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasPlatformRequiredError = result.errors!.some((e) => e.includes('platform_type'));
    expect(hasPlatformRequiredError).toBe(true);
  });

  // behavior: [追加] countChars関数がマルチバイト文字を1文字としてカウントする
  it('countChars関数がマルチバイト文字（日本語・絵文字）を正確にカウントする', () => {
    // 日本語3文字
    expect(countChars('あいう')).toBe(3);
    // ASCII 3文字
    expect(countChars('abc')).toBe(3);
    // 混在
    expect(countChars('あbc')).toBe(3);
    // 絵文字は code point 1個
    expect(countChars('😀😀')).toBe(2);
    // ちょうど150文字（Instagram上限）
    expect(countChars('あ'.repeat(150))).toBe(150);
    // 151文字（Instagram上限超過）
    expect(countChars('あ'.repeat(151))).toBe(151);
  });

  // behavior: [追加] TikTokのbioがちょうど80文字の場合はバリデーション通過（境界値）
  it('TikTokプロフィールのbioがちょうど80文字の場合はバリデーション通過（境界値）', () => {
    const bio80 = 'あ'.repeat(80);
    expect(countChars(bio80)).toBe(80);
    const data: Record<string, unknown> = { ...validTiktok, bio: bio80 };
    const result = validateProfile(data);
    expect(result.valid).toBe(true);
    expect(result.errors).toBeUndefined();
  });

  // behavior: [追加] TikTokのbioが81文字の場合はバリデーションエラー（境界値）
  it('TikTokプロフィールのbioが81文字の場合はバリデーションエラー（80文字上限超過）', () => {
    const bio81 = 'あ'.repeat(81);
    const data: Record<string, unknown> = { ...validTiktok, bio: bio81 };
    const result = validateProfile(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasBioError = result.errors!.some((e) => e.includes('bio') && e.includes('80'));
    expect(hasBioError).toBe(true);
  });

  // behavior: [追加] LINE公式の特商法チェックリストが7項目未満の場合はバリデーションエラー
  it('LINE公式プロフィールのcompliance_checklistが7項目未満の場合はバリデーションエラー', () => {
    const incompleteChecklist = TOKUSHO_ITEMS.slice(0, 5); // 5項目のみ
    const data: Record<string, unknown> = {
      ...validLineOfficial,
      compliance_checklist: incompleteChecklist,
    };
    const result = validateProfile(data);
    expect(result.valid).toBe(false);
    expect(result.errors).toBeDefined();
    const hasChecklistError = result.errors!.some((e) => e.includes('compliance_checklist'));
    expect(hasChecklistError).toBe(true);
  });
});
