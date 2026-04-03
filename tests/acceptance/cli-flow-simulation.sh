#!/usr/bin/env bash
# L3-008: 4段階CLIフロー模擬・output/ディレクトリ出力
#
# 4段階の流れ:
#   Stage 1: POST /api/theory/upload       — 理論ファイルアップロード
#   Stage 2: POST /api/metaframe/extract   — メタフレーム抽出
#   Stage 3: POST /api/letter/generate     — フルパイプライン実行（Phase A→B→C→D）
#   Stage 4: POST /api/evaluate            — 品質評価（4次元ルーブリック）
#
# 出力:
#   output/theory-upload.json    — Stage 1 結果
#   output/metaframe.json        — Stage 2 結果
#   output/pipeline-result.json  — Stage 3 パイプライン出力
#   output/evaluation.json       — Stage 4 評価結果
#   output/summary.json          — 最終サマリー
#
# 使用方法:
#   bash cli-flow-simulation.sh [BASE_URL] [OUTPUT_DIR]
#   デフォルト BASE_URL: http://localhost:3001
#   デフォルト OUTPUT_DIR: output

set -euo pipefail

# ─── 設定 ──────────────────────────────────────────────────────────────────────

BASE_URL="${1:-http://localhost:3001}"
OUTPUT_DIR="${2:-output}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 出力ディレクトリ作成 ──────────────────────────────────────────────────────

mkdir -p "${OUTPUT_DIR}"
info() { echo "[INFO]  $*" >&2; }
pass() { echo "[PASS]  $*" >&2; }
fail() { echo "[FAIL]  $*" >&2; exit 1; }
stage_log() { echo "" >&2; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2; echo "  Stage $1: $2" >&2; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2; }

# ─── HTTPリクエストヘルパー ────────────────────────────────────────────────────

curl_post() {
  local endpoint="$1"
  local body="$2"
  local url="${BASE_URL}${endpoint}"

  local response http_code body_part

  response=$(curl -s -w "\n__HTTP_CODE__%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$url" 2>/dev/null)

  http_code=$(echo "$response" | tail -n1 | sed 's/__HTTP_CODE__//')
  body_part=$(echo "$response" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    fail "POST $endpoint → HTTP $http_code: $body_part"
  fi

  echo "$body_part"
}

json_get() {
  local json="$1"
  local field="$2"
  echo "$json" | node -e "
    let d='';
    process.stdin.on('data',c=>d+=c);
    process.stdin.on('end',()=>{
      try { const o=JSON.parse(d); process.stdout.write(String(${field})); }
      catch(e) { process.stdout.write(''); }
    });
  "
}

# ─── Stage 1: 理論ファイルアップロード ────────────────────────────────────────

stage_log "1/4" "理論ファイルアップロード (POST /api/theory/upload)"

THEORY_BODY='{
  "theory_files": [
    {
      "id": "cli-theory-pas-001",
      "title": "PASフレームワーク実践ガイド",
      "content": "PAS（Problem-Agitation-Solution）フレームワークは、セールスコピーライティングの根幹をなす手法です。\n\n【Problem: 問題の明確化】読者がすでに感じている痛みや課題を具体的に言語化します。「副業で月5万円を目指しているのに、3ヶ月経っても結果が出ない」「情報が多すぎて何から始めればいいかわからない」といった具体的な問題を提示することで、読者は「これは自分のことだ」と感じます。\n\n【Agitation: 問題の深化】問題を放置した場合の深刻な結果を描写し、感情的な痛みを増幅させます。「このまま何も変わらなければ、5年後も今と同じ状況が続く」という感情的な恐怖を喚起します。\n\n【Solution: 解決策の提示】深化した問題に対する明確な解決策を提示します。解決策は具体的で実行可能であることが重要です。正しいシステムがあれば、普通の人でも確実に成果を出すことができます。"
    },
    {
      "id": "cli-theory-aida-002",
      "title": "AIDA5帯域マッピングと感情的購買心理",
      "content": "AIDA5帯域は購買プロセスの心理的段階を表す高度なフレームワークです。\n\n【Attention帯域 (0-10%)】強烈な見出しと共感で読者の注意を引きます。「あなたは今、こんな悩みを抱えていませんか？」という問いかけが有効です。\n\n【Interest帯域 (10-35%)】問題の本質と解決の可能性を示して興味を持続させます。「なぜ多くの人が失敗するのか？」という疑問提起が効果的です。\n\n【Desire帯域 (35-70%)】ベネフィットと社会的証明で欲求を高めます。具体的な成功事例や数字を使って「これなら自分もできる」という確信を育てます。\n\n【Conviction帯域 (70-90%)】論理的な根拠と保証で購買への確信を強化します。返金保証や実績データが信頼を生みます。\n\n【Action帯域 (90-100%)】緊急性とCTAで即座の行動を促します。「今月中に申し込んだ方には特別特典」という限定性が行動を加速します。"
    },
    {
      "id": "cli-theory-pppp-003",
      "title": "PPPPフレームワークと感情的訴求",
      "content": "PPPP（Picture-Promise-Prove-Push）フレームワークはビジョン提示による感情的購買を促進します。\n\n【Picture: 理想のビジョン提示】読者が望む未来の姿を鮮明に描写します。「月収30万円を副業で稼ぎ、毎日好きな時間に好きな場所で働く——そんな生活がスタートから6ヶ月で実現できます」\n\n【Promise: 約束と保証】具体的な成果を約束します。根拠のある数字と明確なタイムラインが信頼を生みます。\n\n【Prove: 証拠の提示】実績データ、顧客証言、メディア掲載などで約束を裏付けます。3,000名以上の受講生実績が社会的証明となります。\n\n【Push: 行動への背中押し】最後に決断を後押しする要素を配置します。限定特典、期間限定割引、返金保証が行動の心理的ハードルを下げます。"
    }
  ]
}'

THEORY_RESP=$(curl_post "/api/theory/upload" "$THEORY_BODY")
echo "$THEORY_RESP" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{JSON.parse(d);}catch(e){process.exit(1);}});" || fail "Stage 1 レスポンスのJSONパースに失敗"

THEORY_COUNT=$(json_get "$THEORY_RESP" "Array.isArray(o.files) ? o.files.length : 0")
info "アップロード完了: ${THEORY_COUNT}件の理論ファイル"
pass "Stage 1 完了: 理論ファイルアップロード成功"

# Stage 1 結果を保存
echo "$THEORY_RESP" > "${OUTPUT_DIR}/theory-upload.json"
info "保存: ${OUTPUT_DIR}/theory-upload.json"

# ─── Stage 2: メタフレーム抽出 ────────────────────────────────────────────────

stage_log "2/4" "メタフレーム抽出 (POST /api/metaframe/extract)"

METAFRAME_BODY='{
  "theory_ids": ["cli-theory-pas-001", "cli-theory-aida-002", "cli-theory-pppp-003"],
  "config": {
    "target_tokens": 3000,
    "focus_areas": [
      "感情的訴求テクニック",
      "AIDA5帯域の原則",
      "行動喚起メカニズム",
      "社会的証明の活用"
    ]
  }
}'

METAFRAME_RESP=$(curl_post "/api/metaframe/extract" "$METAFRAME_BODY")
echo "$METAFRAME_RESP" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{JSON.parse(d);}catch(e){process.exit(1);}});" || fail "Stage 2 レスポンスのJSONパースに失敗"

PRINCIPLES_COUNT=$(json_get "$METAFRAME_RESP" "Array.isArray(o.principles) ? o.principles.length : 0")
TOKEN_COUNT=$(json_get "$METAFRAME_RESP" "o.token_count || 0")
info "抽出された原則数: ${PRINCIPLES_COUNT}"
info "推定トークン数: ${TOKEN_COUNT}"
pass "Stage 2 完了: メタフレーム抽出成功"

# Stage 2 結果を保存
echo "$METAFRAME_RESP" > "${OUTPUT_DIR}/metaframe.json"
info "保存: ${OUTPUT_DIR}/metaframe.json"

# ─── Stage 3: フルパイプライン実行 ────────────────────────────────────────────

stage_log "3/4" "フルパイプライン実行 (POST /api/letter/generate)"
info "※このステージはLLM呼出を含むため時間がかかる場合があります"

PIPELINE_BODY='{
  "theory_files": [
    {
      "id": "cli-theory-pas-001",
      "title": "PASフレームワーク実践ガイド",
      "content": "PAS（Problem-Agitation-Solution）フレームワークは、セールスコピーライティングの根幹をなす手法です。問題の明確化→感情的深化→解決策提示の3段階で読者の購買意欲を高めます。第1段階では読者が既に感じている痛みや課題を具体的に言語化し、共感を生み出します。第2段階では問題を放置した場合の深刻な結果を描写し、感情的な痛みを増幅させます。第3段階では解決策を明確かつ魅力的に提示し、行動を促します。効果的なPASには具体的な数字、感情に訴える言葉、社会的証明が不可欠です。正しいシステムがあれば、普通の人でも時間がない人でも確実に成果を出すことができます。"
    },
    {
      "id": "cli-theory-aida-002",
      "title": "AIDA5帯域マッピングと感情的購買心理",
      "content": "AIDA5帯域は購買プロセスの心理的段階を表します。Attention帯域では強烈な見出しと共感で注意を引きます。Interest帯域では問題の本質と解決の可能性を示して興味を持続させます。Desire帯域ではベネフィットと社会的証明で欲求を高めます。Conviction帯域では論理的な根拠と保証で確信を強化します。Action帯域では緊急性とCTAで即座の行動を促します。各帯域の適切な文字数配分がセールスレターの成否を決定します。"
    }
  ],
  "config": {
    "total_chars": 20000,
    "copy_framework": "PAS_PPPP_HYBRID",
    "style_guide": {
      "tone": "親しみやすく説得力がある。読者に寄り添いながらも行動を強く促す",
      "target_audience": "副業で月収10万円以上を目指す30-45歳のサラリーマン・主婦",
      "writing_style": "体験談を交えた共感型ライティング。具体的な数字と事例を多用する"
    },
    "model": "claude-sonnet-4-6",
    "metaframe_target_tokens": 3000,
    "quality_threshold": 70,
    "max_rewrite_attempts": 2
  },
  "product_info": {
    "name": "ライフシフト・アカデミー",
    "price": "198,000円（期間限定100,000円OFF）",
    "features": [
      "7段階ロードマップカリキュラム（実績ベース）",
      "週3時間でも成果が出る効率設計",
      "現役で稼ぐメンターによる直接指導",
      "3,000名以上の受講生コミュニティ",
      "90日間完全返金保証"
    ],
    "target_audience": "副業を始めたいが方法がわからないサラリーマン・主婦",
    "benefits": [
      "平均6.2ヶ月で月収10万円以上を副業で達成",
      "時間的・経済的自由の実現",
      "副業収入により本業への依存度を下げる",
      "自分のスキルと価値を市場で証明する"
    ],
    "offer_details": "今月中にお申し込みの方には合計99,600円分の特典（ワークブック＋個別セッション＋動画講座）をプレゼント",
    "cta_text": "今すぐ無料説明会に参加する → https://example.com/lifeshiftacademy"
  }
}'

PIPELINE_RESP=$(curl_post "/api/letter/generate" "$PIPELINE_BODY")
echo "$PIPELINE_RESP" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{JSON.parse(d);}catch(e){process.exit(1);}});" || fail "Stage 3 レスポンスのJSONパースに失敗"

PIPELINE_STATUS=$(json_get "$PIPELINE_RESP" "o.status || 'unknown'")
TOTAL_CHARS=$(json_get "$PIPELINE_RESP" "(o.result && o.result.total_chars) || o.total_chars || 0")
QUALITY_SCORE=$(json_get "$PIPELINE_RESP" "(o.result && o.result.quality_score) || o.quality_score || 0")
info "パイプラインステータス: ${PIPELINE_STATUS}"
info "総文字数: ${TOTAL_CHARS}"
info "品質スコア: ${QUALITY_SCORE}"

if [[ "$PIPELINE_STATUS" != "completed" ]]; then
  fail "パイプラインが完了しませんでした: status=${PIPELINE_STATUS}"
fi
pass "Stage 3 完了: フルパイプライン実行成功 (${TOTAL_CHARS}文字, スコア: ${QUALITY_SCORE})"

# Stage 3 結果を保存
echo "$PIPELINE_RESP" > "${OUTPUT_DIR}/pipeline-result.json"
info "保存: ${OUTPUT_DIR}/pipeline-result.json"

# ─── Stage 4: 品質評価 ────────────────────────────────────────────────────────

stage_log "4/4" "品質評価 (POST /api/evaluate)"

# pipeline-result.json から final_text を取得して評価
EVAL_BODY=$(node -e "
const pipeline = ${PIPELINE_RESP};
const letterText = (pipeline.result && pipeline.result.final_text)
  || pipeline.final_text
  || 'セールスレター本文の取得に失敗しました';
const body = {
  letter_text: letterText,
  rubric: {
    structural_completeness: { weight: 30, description: 'AIDA5帯域の完全性と論理構成' },
    theory_reflection: { weight: 25, description: 'PAS+PPPPフレームワークの反映度' },
    readability: { weight: 20, description: '読了促進力と日本語表現の自然さ' },
    action_appeal: { weight: 25, description: '行動喚起力とCTAの明確さ' }
  },
  model: 'claude-sonnet-4-6'
};
process.stdout.write(JSON.stringify(body));
")

EVAL_RESP=$(curl_post "/api/evaluate" "$EVAL_BODY")
echo "$EVAL_RESP" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{JSON.parse(d);}catch(e){process.exit(1);}});" || fail "Stage 4 レスポンスのJSONパースに失敗"

EVAL_SCORE=$(json_get "$EVAL_RESP" "o.total_score || o.score || 0")
info "評価スコア: ${EVAL_SCORE}/100"
pass "Stage 4 完了: 品質評価成功 (スコア: ${EVAL_SCORE}/100)"

# Stage 4 結果を保存
echo "$EVAL_RESP" > "${OUTPUT_DIR}/evaluation.json"
info "保存: ${OUTPUT_DIR}/evaluation.json"

# ─── サマリー出力 ──────────────────────────────────────────────────────────────

node -e "
const summary = {
  completed_at: new Date().toISOString(),
  base_url: '${BASE_URL}',
  output_dir: '${OUTPUT_DIR}',
  stages_completed: 4,
  results: {
    theory_files_uploaded: parseInt('${THEORY_COUNT}') || 0,
    metaframe_principles: parseInt('${PRINCIPLES_COUNT}') || 0,
    pipeline_status: '${PIPELINE_STATUS}',
    total_chars: parseInt('${TOTAL_CHARS}') || 0,
    quality_score: parseFloat('${QUALITY_SCORE}') || 0,
    evaluation_score: parseFloat('${EVAL_SCORE}') || 0
  },
  output_files: [
    '${OUTPUT_DIR}/theory-upload.json',
    '${OUTPUT_DIR}/metaframe.json',
    '${OUTPUT_DIR}/pipeline-result.json',
    '${OUTPUT_DIR}/evaluation.json',
    '${OUTPUT_DIR}/summary.json'
  ]
};
process.stdout.write(JSON.stringify(summary, null, 2));
" > "${OUTPUT_DIR}/summary.json"

info "保存: ${OUTPUT_DIR}/summary.json"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  L3-008 CLIフローシミュレーション完了                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  理論ファイル数  : %-36s ║\n" "${THEORY_COUNT}件"
printf "║  メタフレーム    : %-36s ║\n" "${PRINCIPLES_COUNT}原則"
printf "║  総文字数        : %-36s ║\n" "${TOTAL_CHARS}文字"
printf "║  品質スコア      : %-36s ║\n" "${QUALITY_SCORE}/100"
printf "║  評価スコア      : %-36s ║\n" "${EVAL_SCORE}/100"
printf "║  出力ディレクトリ: %-36s ║\n" "${OUTPUT_DIR}/"
echo "╚══════════════════════════════════════════════════════════╝"
