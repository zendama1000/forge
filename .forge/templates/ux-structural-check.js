#!/usr/bin/env node
/**
 * ux-structural-check.js — 非LLM UX 構造検査（ux-judgment P1-b）
 *
 * 検査項目:
 *   1. viewport_overflow  — 横スクロール発生（レイアウト崩れ）
 *   2. tap_target         — タップ領域サイズ不足（モバイル viewport のみ、既定 24px =
 *                           WCAG 2.5.8 AA。インラインテキストリンクは同基準の例外に従い対象外。
 *                           2.5.8 のスペーシング例外[間隔で補償]は未実装 — 過検出side）
 *   3. contrast           — テキストのコントラスト比不足（WCAG 相対輝度。
 *                           background-image 上のテキストは判定不能として対象外）
 *   4. focus_order        — 正の tabindex（フォーカス順の破壊）+ フォーカス可能要素の有無
 *
 * 使い方:
 *   node ux-structural-check.js --url <URL> --out <result.json> \
 *     [--viewports '<json>'] [--min-tap 44] [--min-contrast 4.5]
 *
 * playwright は実行 cwd（対象プロジェクト）の node_modules から解決する。
 * 解決できない場合は exit 2（環境不足 — 呼出側が skip 扱いにする）。
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ===== 引数パース =====
const args = {};
for (let i = 2; i < process.argv.length; i += 2) {
  args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
}

const URL_ARG = args.url;
const OUT = args.out;
if (!URL_ARG || !OUT) {
  console.error('usage: node ux-structural-check.js --url <URL> --out <file> [--viewports <json>] [--min-tap N] [--min-contrast N]');
  process.exit(1);
}
const VIEWPORTS = args.viewports
  ? JSON.parse(args.viewports)
  : [
      { name: 'mobile', width: 390, height: 844 },
      { name: 'desktop', width: 1440, height: 900 },
    ];
const MIN_TAP = Number(args['min-tap'] || 24);
const MIN_CONTRAST = Number(args['min-contrast'] || 4.5);
const MAX_VIOLATIONS_PER_CHECK = 20;

// ===== playwright 解決（対象プロジェクトの node_modules → playwright-core） =====
let chromium;
try {
  ({ chromium } = require(require.resolve('playwright', { paths: [process.cwd()] })));
} catch (e1) {
  try {
    ({ chromium } = require(require.resolve('playwright-core', { paths: [process.cwd()] })));
  } catch (e2) {
    console.error('ENV_MISSING: playwright / playwright-core が解決できない');
    process.exit(2);
  }
}

// ===== ページ内検査関数（browser context で実行） =====
function pageChecks(opts) {
  const { minTap, minContrast, isMobile } = opts;
  const out = { overflow: [], tap: [], contrast: [], focus: [] };

  // --- 1. viewport overflow ---
  const de = document.documentElement;
  if (de.scrollWidth > window.innerWidth + 1) {
    out.overflow.push({
      detail: `横スクロール発生: scrollWidth=${de.scrollWidth} > innerWidth=${window.innerWidth}`,
    });
  }

  const describe = (el) => {
    const id = el.id ? `#${el.id}` : '';
    const cls = el.className && typeof el.className === 'string'
      ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : '';
    const text = (el.textContent || '').trim().slice(0, 30);
    return `${el.tagName.toLowerCase()}${id}${cls}${text ? ` "${text}"` : ''}`;
  };

  const isVisible = (el) => {
    const st = getComputedStyle(el);
    if (st.display === 'none' || st.visibility === 'hidden' || Number(st.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };

  // --- 2. tap targets（モバイルのみ） ---
  if (isMobile) {
    const interactive = document.querySelectorAll(
      'a[href], button, input:not([type=hidden]), select, textarea, [role=button], [onclick]'
    );
    for (const el of interactive) {
      if (!isVisible(el)) continue;
      // WCAG 2.5.8 例外: 文中のインラインリンクはサイズ要件の対象外
      // （inline-block/inline-flex のボタン風リンクは検査対象のまま）
      if (el.tagName === 'A' && getComputedStyle(el).display === 'inline') continue;
      const r = el.getBoundingClientRect();
      if (r.width < minTap || r.height < minTap) {
        out.tap.push({
          element: describe(el),
          detail: `タップ領域 ${Math.round(r.width)}x${Math.round(r.height)}px < ${minTap}px`,
        });
      }
    }
  }

  // --- 3. contrast ---
  const lum = (rgb) => {
    const c = rgb.map((v) => {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const parseColor = (s) => {
    const m = s.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)/);
    if (!m) return null;
    return { rgb: [Number(m[1]), Number(m[2]), Number(m[3])], a: m[4] === undefined ? 1 : Number(m[4]) };
  };
  const bgOf = (el) => {
    let cur = el;
    while (cur && cur !== document.documentElement) {
      const st = getComputedStyle(cur);
      // background-image 上のテキストは実効背景色を静的に決定できない —
      // 偽陽性を出さないため判定不能（null）として検査を skip する（監査 C-8）
      if (st.backgroundImage && st.backgroundImage !== 'none') return null;
      const c = parseColor(st.backgroundColor || '');
      if (c && c.a > 0.9) return c.rgb;
      cur = cur.parentElement;
    }
    const rootC = parseColor(getComputedStyle(document.documentElement).backgroundColor || '');
    return rootC && rootC.a > 0.9 ? rootC.rgb : [255, 255, 255];
  };
  const textEls = document.querySelectorAll('body *');
  let checked = 0;
  for (const el of textEls) {
    if (checked > 800) break; // 巨大ページの計算量キャップ
    const hasDirectText = Array.from(el.childNodes).some(
      (n) => n.nodeType === 3 && n.textContent.trim().length > 0
    );
    if (!hasDirectText || !isVisible(el)) continue;
    checked++;
    const st = getComputedStyle(el);
    const fg = parseColor(st.color || '');
    if (!fg) continue;
    const bg = bgOf(el);
    if (!bg) continue; // 画像背景等で実効背景が決定不能 → 判定しない
    const l1 = lum(fg.rgb);
    const l2 = lum(bg);
    const ratio = (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
    // 大きい文字（18.66px bold / 24px）は WCAG AA 基準 3.0 に緩和
    const fontSize = parseFloat(st.fontSize);
    const bold = Number(st.fontWeight) >= 700;
    const threshold = fontSize >= 24 || (fontSize >= 18.66 && bold) ? 3.0 : minContrast;
    if (ratio < threshold) {
      out.contrast.push({
        element: describe(el),
        detail: `コントラスト比 ${ratio.toFixed(2)} < ${threshold}（fg=${st.color} / bg=rgb(${bg.join(',')})）`,
      });
    }
  }

  // --- 4. focus order ---
  const positiveTabindex = document.querySelectorAll(
    '[tabindex]:not([tabindex="0"]):not([tabindex="-1"])'
  );
  for (const el of positiveTabindex) {
    const ti = Number(el.getAttribute('tabindex'));
    if (ti > 0) {
      out.focus.push({
        element: describe(el),
        detail: `正の tabindex=${ti}（DOM 順ベースのフォーカス順を破壊する）`,
      });
    }
  }
  const focusable = document.querySelectorAll(
    'a[href], button:not([disabled]), input:not([type=hidden]):not([disabled]), select, textarea, [tabindex="0"]'
  );
  const anyInteractive = document.querySelectorAll('a[href], button, [role=button], [onclick]').length;
  if (anyInteractive > 0 && focusable.length === 0) {
    out.focus.push({
      detail: 'キーボードフォーカス可能な要素が0件（インタラクティブ要素は存在する）',
    });
  }

  // 各チェックの件数キャップは呼出側で適用する
  return out;
}

// ===== メイン =====
(async () => {
  const browser = await chromium.launch({ headless: true });
  const checks = [];
  let violationsTotal = 0;

  try {
    for (const vp of VIEWPORTS) {
      const page = await browser.newPage({ viewport: { width: vp.width, height: vp.height } });
      try {
        await page.goto(URL_ARG, { waitUntil: 'load', timeout: 30000 });
        await page.waitForTimeout(1500); // 描画安定待ち（SPA の初期レンダリング）
        const result = await page.evaluate(pageChecks, {
          minTap: MIN_TAP,
          minContrast: MIN_CONTRAST,
          isMobile: vp.width < 500,
        });
        const mapping = {
          viewport_overflow: result.overflow,
          tap_target: result.tap,
          contrast: result.contrast,
          focus_order: result.focus,
        };
        for (const [check, violations] of Object.entries(mapping)) {
          if (check === 'tap_target' && vp.width >= 500) continue; // desktop はタップ検査対象外
          const capped = violations.slice(0, MAX_VIOLATIONS_PER_CHECK);
          checks.push({
            check,
            viewport: vp.name,
            pass: violations.length === 0,
            violation_count: violations.length,
            violations: capped,
          });
          violationsTotal += violations.length;
        }
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
  }

  const report = {
    url: URL_ARG,
    generated_at: new Date().toISOString(),
    config: { min_tap_target_px: MIN_TAP, min_contrast_ratio: MIN_CONTRAST },
    checks,
    summary: { violations_total: violationsTotal },
    verdict: violationsTotal === 0 ? 'pass' : 'fail',
  };

  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(report, null, 2));
  console.log(`structural check: ${report.verdict} (violations=${violationsTotal}) -> ${OUT}`);
  process.exit(0);
})().catch((e) => {
  console.error(`STRUCTURAL_CHECK_ERROR: ${e.message}`);
  process.exit(3);
});
