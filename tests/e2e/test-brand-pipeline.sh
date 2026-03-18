#!/usr/bin/env bash
# =============================================================================
# E2E: ブランド構築パイプラインテスト (L2-001)
# サーバーが http://localhost:3001 で起動済みであることを前提とする
# 冪等: 実行ごとに brand/context/ を再作成する
# =============================================================================
set -euo pipefail

SERVER_URL="${SERVER_URL:-http://localhost:3001}"
BRAND_DIR="brand/context"
PASS=0
FAIL=0

echo "=== E2E: Brand Pipeline Test (L2-001) ==="
echo "Server: $SERVER_URL"
echo ""

# ─── セットアップ（冪等: 前回の出力を削除して再作成） ─────────────────────────
rm -rf "$BRAND_DIR"
mkdir -p "$BRAND_DIR"

# ─── Step 1: ブランドコンセプトの作成 ─────────────────────────────────────────
echo "[1/3] Creating brand concept..."

TMP1=$(mktemp)
HTTP1=$(curl -s -o "$TMP1" -w "%{http_code}" \
  -X POST "${SERVER_URL}/api/brand/concept" \
  -H "Content-Type: application/json" \
  -d '{
    "brand_name": "テストブランド",
    "divination_type": "tarot",
    "target_audience": "20代女性",
    "core_values": ["誠実さ", "洞察力"],
    "differentiators": ["独自のカード解釈"],
    "$schema_version": "1.0.0"
  }')
BODY1=$(cat "$TMP1")
rm -f "$TMP1"

if [ "$HTTP1" != "201" ]; then
  echo "  FAIL: POST /api/brand/concept expected 201, got $HTTP1"
  echo "  Body: $BODY1"
  exit 1
fi
echo "  PASS: POST /api/brand/concept → 201"
PASS=$((PASS + 1))

# concept_id を抽出
CONCEPT_ID=$(node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try { console.log(JSON.parse(d).concept_id); }
    catch (e) { console.error('JSON parse failed:', e.message); process.exit(1); }
  });
" <<< "$BODY1")

if [ -z "$CONCEPT_ID" ]; then
  echo "  FAIL: concept_id not found in response"
  echo "  Body: $BODY1"
  exit 1
fi
echo "  concept_id: $CONCEPT_ID"

# ─── Step 2: コンセプト取得 → brand/context/core.json に保存 ─────────────────
echo "[2/3] Retrieving brand concept and saving core.json..."

TMP2=$(mktemp)
HTTP2=$(curl -s -o "$TMP2" -w "%{http_code}" \
  "${SERVER_URL}/api/brand/concept/${CONCEPT_ID}")
BODY2=$(cat "$TMP2")
rm -f "$TMP2"

if [ "$HTTP2" != "200" ]; then
  echo "  FAIL: GET /api/brand/concept/:id expected 200, got $HTTP2"
  echo "  Body: $BODY2"
  exit 1
fi
echo "  PASS: GET /api/brand/concept/:id → 200"
PASS=$((PASS + 1))

echo "$BODY2" > "${BRAND_DIR}/core.json"
echo "  Saved: ${BRAND_DIR}/core.json"

# ─── Step 3: 倫理バリデーション → brand/context/ethics.json に保存 ────────────
echo "[3/3] Running ethics validation and saving ethics.json..."

TMP3=$(mktemp)
HTTP3=$(curl -s -o "$TMP3" -w "%{http_code}" \
  -X POST "${SERVER_URL}/api/brand/ethics/validate" \
  -H "Content-Type: application/json" \
  -d '{"text": "占いで自分の可能性を探求しましょう"}')
BODY3=$(cat "$TMP3")
rm -f "$TMP3"

if [ "$HTTP3" != "200" ]; then
  echo "  FAIL: POST /api/brand/ethics/validate expected 200, got $HTTP3"
  echo "  Body: $BODY3"
  exit 1
fi
echo "  PASS: POST /api/brand/ethics/validate → 200"
PASS=$((PASS + 1))

echo "$BODY3" > "${BRAND_DIR}/ethics.json"
echo "  Saved: ${BRAND_DIR}/ethics.json"

# ─── ファイル存在確認 ──────────────────────────────────────────────────────────
echo ""
echo "Verifying output files..."
for FILE in "${BRAND_DIR}/core.json" "${BRAND_DIR}/ethics.json"; do
  if [ -f "$FILE" ]; then
    echo "  PASS: $FILE exists"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $FILE not found"
    FAIL=$((FAIL + 1))
  fi
done

# ─── 結果サマリー ──────────────────────────────────────────────────────────────
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  echo "=== E2E Brand Pipeline: FAILED ==="
  exit 1
fi

echo "=== E2E Brand Pipeline: PASSED ==="
