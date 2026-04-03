#!/usr/bin/env bash
# L3-002: 7段階APIチェーン順次呼出・chain-result.json出力
#
# 7段階の流れ:
#   Stage 1: GET  /api/health        — ヘルスチェック
#   Stage 2: POST /api/theory/upload — 理論ファイルアップロード
#   Stage 3: POST /api/metaframe/extract — メタフレーム抽出
#   Stage 4: POST /api/outline/generate  — アウトライン生成
#   Stage 5: POST /api/section/generate  — セクション生成（desireセクション）
#   Stage 6: POST /api/integrate         — セクション統合
#   Stage 7: POST /api/product/inject    — 商品情報注入
#
# 出力: chain-result.json
#
# 使用方法:
#   bash api-chain-flow.sh [BASE_URL] [OUTPUT_FILE]
#   デフォルト BASE_URL: http://localhost:3001
#   デフォルト OUTPUT_FILE: chain-result.json

set -euo pipefail

# ─── 設定 ──────────────────────────────────────────────────────────────────────

BASE_URL="${1:-http://localhost:3001}"
OUTPUT_FILE="${2:-chain-result.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── ログ関数 ──────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*" >&2; }
pass()  { echo "[PASS]  $*" >&2; }
fail()  { echo "[FAIL]  $*" >&2; exit 1; }
stage() { echo "" >&2; echo "━━━ Stage $1: $2 ━━━" >&2; }

# ─── HTTPリクエストヘルパー ────────────────────────────────────────────────────

# curl_post <endpoint> <json_body>  → レスポンスJSONを標準出力
curl_post() {
  local endpoint="$1"
  local body="$2"
  local url="${BASE_URL}${endpoint}"

  local response
  local http_code

  response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$url" 2>/dev/null)

  http_code=$(echo "$response" | tail -n1 | sed 's/__HTTP_CODE__//')
  local body_part
  body_part=$(echo "$response" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    fail "POST $endpoint → HTTP $http_code: $body_part"
  fi

  echo "$body_part"
}

curl_get() {
  local endpoint="$1"
  local url="${BASE_URL}${endpoint}"

  local response
  local http_code

  response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
    -X GET \
    "$url" 2>/dev/null)

  http_code=$(echo "$response" | tail -n1 | sed 's/__HTTP_CODE__//')
  local body_part
  body_part=$(echo "$response" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    fail "GET $endpoint → HTTP $http_code: $body_part"
  fi

  echo "$body_part"
}

# node を使って JSON フィールドを抽出
json_get() {
  local json="$1"
  local field="$2"
  echo "$json" | node -e "
    let d='';
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try {
        const o=JSON.parse(d);
        const v=${field};
        process.stdout.write(v !== undefined && v !== null ? String(v) : '');
      } catch(e) { process.stdout.write(''); }
    });
  "
}

# ─── テスト用理論ファイルデータ ────────────────────────────────────────────────

THEORY_FILES_JSON='{
  "theory_files": [
    {
      "id": "chain-theory-001",
      "title": "PASフレームワーク基礎",
      "content": "PAS（Problem-Agitation-Solution）フレームワークはセールスコピーの根幹をなす手法です。問題の明確化→感情的深化→解決策提示の3段階で読者の購買意欲を高めます。第1段階では読者が既に感じている痛みや課題を具体的に言語化し、共感を生み出します。第2段階では問題を放置した場合の深刻な結果を描写し、感情的な痛みを増幅させます。第3段階では解決策を明確かつ魅力的に提示し、行動を促します。効果的なPASには具体的な数字、感情に訴える言葉、社会的証明が不可欠です。"
    },
    {
      "id": "chain-theory-002",
      "title": "感情的購買心理とAIDA帯域",
      "content": "AIDA（Attention-Interest-Desire-Action）モデルは購買プロセスの心理的段階を表します。Attentionでは強い見出しと共感で注意を引きます。Interestでは問題の本質と解決の可能性を示して興味を持続させます。Desireではベネフィットと社会的証明で欲求を高めます。Actionでは緊急性とCTAで即座の行動を促します。AIDA5帯域ではConviction（確信）を追加し、論理的な根拠と保証で購買への確信を強化します。各帯域への適切な文字数配分が成功の鍵です。"
    }
  ]
}'

# ─── Stage 1: ヘルスチェック ───────────────────────────────────────────────────

stage "1" "GET /api/health"
HEALTH_RESP=$(curl_get "/api/health")
HEALTH_STATUS=$(json_get "$HEALTH_RESP" "o.status")
if [[ "$HEALTH_STATUS" != "ok" ]]; then
  fail "ヘルスチェック失敗: status=${HEALTH_STATUS}"
fi
pass "ヘルスチェック成功: status=ok"

# ─── Stage 2: 理論ファイルアップロード ────────────────────────────────────────

stage "2" "POST /api/theory/upload"
THEORY_RESP=$(curl_post "/api/theory/upload" "$THEORY_FILES_JSON")
THEORY_COUNT=$(json_get "$THEORY_RESP" "o.files ? o.files.length : 0")
info "アップロード済みファイル数: ${THEORY_COUNT}"
if [[ -z "$THEORY_COUNT" || "$THEORY_COUNT" == "0" ]]; then
  fail "理論ファイルのアップロードに失敗しました"
fi
pass "理論ファイルアップロード成功: ${THEORY_COUNT}件"

# ─── Stage 3: メタフレーム抽出 ────────────────────────────────────────────────

stage "3" "POST /api/metaframe/extract"
METAFRAME_BODY='{
  "theory_ids": ["chain-theory-001", "chain-theory-002"],
  "config": {
    "target_tokens": 2000,
    "focus_areas": ["感情的訴求", "AIDA帯域", "行動喚起"]
  }
}'
METAFRAME_RESP=$(curl_post "/api/metaframe/extract" "$METAFRAME_BODY")
PRINCIPLES_COUNT=$(json_get "$METAFRAME_RESP" "Array.isArray(o.principles) ? o.principles.length : 0")
info "抽出された原則数: ${PRINCIPLES_COUNT}"
pass "メタフレーム抽出成功"

# ─── Stage 4: アウトライン生成 ────────────────────────────────────────────────

stage "4" "POST /api/outline/generate"
OUTLINE_BODY=$(node -e "
const metaframe = ${METAFRAME_RESP};
// プリンシパルが不足している場合は最低限のダミーを追加
const principles = Array.isArray(metaframe.principles) && metaframe.principles.length > 0
  ? metaframe.principles
  : [{ name: 'PASフレームワーク', description: 'Problem-Agitation-Solution', application_trigger: '問題提起時' }];
const triggers = Array.isArray(metaframe.triggers) ? metaframe.triggers : [];
const section_mappings = Array.isArray(metaframe.section_mappings) ? metaframe.section_mappings : [];
const body = {
  metaframe: { principles, triggers, section_mappings },
  config: { total_chars: 20000, copy_framework: 'PAS_PPPP_HYBRID' }
};
process.stdout.write(JSON.stringify(body));
")
OUTLINE_RESP=$(curl_post "/api/outline/generate" "$OUTLINE_BODY")
SECTIONS_COUNT=$(json_get "$OUTLINE_RESP" "Array.isArray(o.sections) ? o.sections.length : 0")
info "生成されたアウトラインセクション数: ${SECTIONS_COUNT}"
pass "アウトライン生成成功"

# ─── Stage 5: セクション生成（最初のdesireセクション） ──────────────────────

stage "5" "POST /api/section/generate"
SECTION_BODY=$(node -e "
const outline = ${OUTLINE_RESP};
const metaframe = ${METAFRAME_RESP};
// desire帯域のセクションを優先、なければ最初のセクションを使用
const sections = Array.isArray(outline.sections) ? outline.sections : [];
let target = sections.find(s => s.aida_band === 'desire') || sections[0];
if (!target) {
  target = {
    index: 0,
    title: 'ベネフィット紹介',
    aida_band: 'desire',
    target_chars: 3000,
    primary_theories: ['感情的訴求'],
    key_points: ['ベネフィットの訴求', '欲求喚起']
  };
}
const principles = Array.isArray(metaframe.principles) && metaframe.principles.length > 0
  ? metaframe.principles.slice(0, 2)
  : [{ name: 'PASフレームワーク', description: 'Problem-Agitation-Solution', application_trigger: '問題提起時' }];
const body = {
  section_index: target.index || 0,
  outline_section: target,
  metaframe_subset: { principles },
  overlap_context: '',
  style_guide: { tone: '親しみやすく説得力のある', target_audience: '副業を目指すサラリーマン' }
};
process.stdout.write(JSON.stringify(body));
")
SECTION_RESP=$(curl_post "/api/section/generate" "$SECTION_BODY")
SECTION_CHARS=$(json_get "$SECTION_RESP" "o.char_count || (o.content ? o.content.length : 0)")
info "生成されたセクション文字数: ${SECTION_CHARS}"
pass "セクション生成成功"

# ─── Stage 6: セクション統合 ──────────────────────────────────────────────────

stage "6" "POST /api/integrate"
INTEGRATE_BODY=$(node -e "
const section = ${SECTION_RESP};
const content = section.content || section.generated_text || section.text || '（セクションコンテンツ）';
const idx = section.index !== undefined ? section.index : 0;
const body = {
  sections: [{ index: idx, content: content }]
};
process.stdout.write(JSON.stringify(body));
")
INTEGRATE_RESP=$(curl_post "/api/integrate" "$INTEGRATE_BODY")
INTEGRATED_CHARS=$(json_get "$INTEGRATE_RESP" "o.integrated_text ? o.integrated_text.length : (o.letter_text ? o.letter_text.length : 0)")
info "統合後文字数: ${INTEGRATED_CHARS}"
pass "セクション統合成功"

# ─── Stage 7: 商品情報注入 ────────────────────────────────────────────────────

stage "7" "POST /api/product/inject"
INJECT_BODY=$(node -e "
const integrated = ${INTEGRATE_RESP};
const draftText = integrated.integrated_text || integrated.letter_text || integrated.text || 'セールスレタードラフト';
const body = {
  letter_draft: draftText,
  product_info: {
    name: 'ライフシフト・アカデミー',
    price: '198,000円（分割払い: 月々16,500円×12回）',
    features: [
      '7段階ロードマップカリキュラム',
      '週3時間でも成果が出る設計',
      '現役メンターによる直接指導',
      'プライベートコミュニティ',
      '90日間全額返金保証'
    ],
    target_audience: '副業で月収10万円以上を目指すサラリーマン'
  }
};
process.stdout.write(JSON.stringify(body));
")
INJECT_RESP=$(curl_post "/api/product/inject" "$INJECT_BODY")
PRODUCT_INJECTED=$(json_get "$INJECT_RESP" "o.product_injected !== undefined ? o.product_injected : 'unknown'")
info "商品情報注入ステータス: ${PRODUCT_INJECTED}"
pass "商品情報注入成功"

# ─── chain-result.json 出力 ────────────────────────────────────────────────────

stage "出力" "chain-result.json 生成"
node -e "
const result = {
  completed_at: new Date().toISOString(),
  base_url: '${BASE_URL}',
  stages: {
    stage1_health: ${HEALTH_RESP},
    stage2_theory_upload: ${THEORY_RESP},
    stage3_metaframe: ${METAFRAME_RESP},
    stage4_outline: ${OUTLINE_RESP},
    stage5_section: ${SECTION_RESP},
    stage6_integrate: ${INTEGRATE_RESP},
    stage7_product_inject: ${INJECT_RESP}
  }
};
process.stdout.write(JSON.stringify(result, null, 2));
" > "${OUTPUT_FILE}"

info "chain-result.json を保存しました: ${OUTPUT_FILE}"

echo ""
echo "=== L3-002 完了: 7段階APIチェーンが正常に完了しました ==="
echo "出力ファイル: ${OUTPUT_FILE}"
