#!/bin/bash
# scenarios/slideshow/render.sh — image_slideshow シナリオの MVP レンダラー
#
# 入力探索順:
#   1. scenarios/slideshow/inputs/images/*.{jpg,jpeg,png}
#   2. scenarios/slideshow/assets/*.{jpg,jpeg,png}
#   3. どちらも無ければ convert で 6 枚のカラー画像を assets/ に生成
#
# 出力:
#   scenarios/slideshow/out/output.mp4  (1920x1080 h264 yuv420p)
#
# 任意入力:
#   inputs/bgm.mp3  — BGM (存在する場合のみ AAC で mux、無ければ無音)
#
# 依存: ffmpeg / ffprobe / imagemagick (convert) / jq
#
# 設計: Ralph 原則の「1 タスク = 1 独立セッション」に沿い、全副作用は
# このディレクトリ配下（inputs/, assets/, out/, .tmp/）に閉じる。

set -euo pipefail

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCENARIO_DIR"

INPUTS_DIR="${SCENARIO_DIR}/inputs"
ASSETS_DIR="${SCENARIO_DIR}/assets"
OUT_DIR="${SCENARIO_DIR}/out"
TMP_DIR="${SCENARIO_DIR}/.tmp"
OUT_FILE="${OUT_DIR}/output.mp4"
CONCAT_FILE="${TMP_DIR}/concat.txt"

SEC_PER_IMG="${SEC_PER_IMG:-5}"        # 画像 1 枚の表示時間 (秒)
TARGET_W="${TARGET_W:-1920}"
TARGET_H="${TARGET_H:-1080}"
TARGET_FPS="${TARGET_FPS:-30}"
CRF="${CRF:-22}"

mkdir -p "$OUT_DIR" "$TMP_DIR" "$ASSETS_DIR"

log() { echo "[render] $*"; }

# ---- 依存コマンド検査 ----
for cmd in ffmpeg ffprobe; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[render] ERROR: $cmd が PATH に存在しません" >&2
    exit 2
  fi
done

# ---- 画像ソースの決定 ----
list_images() {
  # $1: ディレクトリ
  local d="$1"
  [ -d "$d" ] || return 1
  ls -1 "$d"/*.jpg "$d"/*.jpeg "$d"/*.png 2>/dev/null | sort
}

IMG_LIST="$(list_images "${INPUTS_DIR}/images" 2>/dev/null || true)"
SRC_DIR=""
if [ -n "${IMG_LIST:-}" ]; then
  SRC_DIR="${INPUTS_DIR}/images"
  log "inputs/images から画像を使用 ($(echo "$IMG_LIST" | wc -l | tr -d ' ') 枚)"
else
  IMG_LIST="$(list_images "$ASSETS_DIR" 2>/dev/null || true)"
  if [ -n "${IMG_LIST:-}" ]; then
    SRC_DIR="$ASSETS_DIR"
    log "assets/ から画像を使用 ($(echo "$IMG_LIST" | wc -l | tr -d ' ') 枚)"
  fi
fi

if [ -z "${IMG_LIST:-}" ]; then
  # 自動生成 (convert 必須)
  if ! command -v convert >/dev/null 2>&1; then
    echo "[render] ERROR: 画像が無く、convert (imagemagick) も無いため自動生成不可" >&2
    exit 2
  fi
  log "サンプル画像を自動生成: ${ASSETS_DIR}/sample-01..06.jpg"
  colors=(red orange yellow green blue purple)
  i=1
  for c in "${colors[@]}"; do
    convert -size "${TARGET_W}x${TARGET_H}" "xc:${c}" \
      -gravity center -pointsize 144 -fill white \
      -annotate +0+0 "Slide $(printf "%02d" "$i")" \
      "${ASSETS_DIR}/sample-$(printf "%02d" "$i").jpg"
    i=$((i + 1))
  done
  IMG_LIST="$(list_images "$ASSETS_DIR")"
  SRC_DIR="$ASSETS_DIR"
fi

# ---- concat ファイル生成 ----
: > "$CONCAT_FILE"
LAST_IMG=""
while IFS= read -r img; do
  [ -z "$img" ] && continue
  [ -f "$img" ] || continue
  printf "file '%s'\nduration %s\n" "$img" "$SEC_PER_IMG" >> "$CONCAT_FILE"
  LAST_IMG="$img"
done <<< "$IMG_LIST"
# concat demuxer の仕様: 末尾画像はもう一度 file として追記（duration 無し）
[ -n "$LAST_IMG" ] && printf "file '%s'\n" "$LAST_IMG" >> "$CONCAT_FILE"

# ---- BGM 検出 ----
BGM=""
if [ -f "${INPUTS_DIR}/bgm.mp3" ]; then
  BGM="${INPUTS_DIR}/bgm.mp3"
  log "BGM 検出: $BGM"
fi

# ---- ffmpeg 実行 ----
VF="scale=${TARGET_W}:${TARGET_H}:force_original_aspect_ratio=decrease"
VF="${VF},pad=${TARGET_W}:${TARGET_H}:(ow-iw)/2:(oh-ih)/2:black"
VF="${VF},fps=${TARGET_FPS},format=yuv420p"

FFARGS=(-y -f concat -safe 0 -i "$CONCAT_FILE")
[ -n "$BGM" ] && FFARGS+=(-i "$BGM")
FFARGS+=(-vf "$VF" -c:v libx264 -preset medium -crf "$CRF" -pix_fmt yuv420p)
if [ -n "$BGM" ]; then
  FFARGS+=(-c:a aac -b:a 192k -shortest)
else
  FFARGS+=(-an)
fi
FFARGS+=("$OUT_FILE")

log "ffmpeg ${FFARGS[*]}"
ffmpeg -hide_banner -loglevel warning "${FFARGS[@]}"

# ---- 検証 (簡易) ----
if [ ! -f "$OUT_FILE" ]; then
  echo "[render] ERROR: 出力が生成されていません: $OUT_FILE" >&2
  exit 1
fi
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT_FILE" 2>/dev/null || echo 0)
SIZE=$(wc -c < "$OUT_FILE" | tr -d ' ')
log "✓ OK duration=${DUR}s size=${SIZE}B output=${OUT_FILE}"
