#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[download-dataset] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd jq

BASE_URL="${LANGFUSE_BASE_URL:-http://localhost:3000}"
PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-pk-00000000}"
SECRET_KEY="${LANGFUSE_SECRET_KEY:-sk-00000000}"
LIMIT="${LANGFUSE_PAGE_LIMIT:-100}"
MAX_PAGES="${LANGFUSE_MAX_PAGES:-100}"
DATASET_NAME="${1:-${LANGFUSE_DATASET_NAME:-my-dataset}}"
OUT_FILE="${2:-}"

if [[ "$DATASET_NAME" == "-h" || "$DATASET_NAME" == "--help" ]]; then
  echo "usage: $0 <dataset-name> [output.json]"
  echo "default dataset-name: my-dataset (or env LANGFUSE_DATASET_NAME)"
  echo "env: LANGFUSE_PAGE_LIMIT=1..100 (default 100)"
  echo "env: LANGFUSE_MAX_PAGES>=1 (default 100)"
  exit 0
fi

if [[ "$LIMIT" -lt 1 || "$LIMIT" -gt 100 ]]; then
  echo "invalid LANGFUSE_PAGE_LIMIT=$LIMIT (use 1..100)" >&2
  exit 1
fi
if [[ "$MAX_PAGES" -lt 1 ]]; then
  echo "invalid LANGFUSE_MAX_PAGES=$MAX_PAGES (use >=1)" >&2
  exit 1
fi

mkdir -p ./tmp
RUN_ID="$(date +%Y%m%d-%H%M%S)_$RANDOM"
RUN_DIR="./tmp/langfuse-dataset-${RUN_ID}"
mkdir -p "$RUN_DIR"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

if [[ -z "$OUT_FILE" ]]; then
  OUT_FILE="./tmp/langfuse-dataset-$(slugify "$DATASET_NAME")-${RUN_ID}.json"
fi

log "start"
log "base_url=$BASE_URL"
log "dataset_name=$DATASET_NAME"
log "page_limit=$LIMIT"
log "max_pages=$MAX_PAGES"
log "run_dir=$RUN_DIR"

PROJECTS_FILE="$RUN_DIR/projects.json"
AUTH_HTTP="$({
  curl -sS \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -o "$PROJECTS_FILE" \
    -w '%{http_code}' \
    "$BASE_URL/api/public/projects"
} || true)"
if [[ "$AUTH_HTTP" != "200" ]]; then
  msg="$(jq -r '.message // empty' "$PROJECTS_FILE" 2>/dev/null || true)"
  echo "auth failed: status=$AUTH_HTTP base_url=$BASE_URL" >&2
  [[ -n "$msg" ]] && echo "$msg" >&2
  exit 1
fi

DATASETS_FILE="$RUN_DIR/datasets.json"
DATASETS_HTTP="$({
  curl -sS \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -o "$DATASETS_FILE" \
    -w '%{http_code}' \
    "$BASE_URL/api/public/datasets?page=1&limit=100"
} || true)"
if [[ "$DATASETS_HTTP" != "200" ]]; then
  msg="$(jq -r '.message // empty' "$DATASETS_FILE" 2>/dev/null || true)"
  echo "list datasets failed: status=$DATASETS_HTTP" >&2
  [[ -n "$msg" ]] && echo "$msg" >&2
  exit 1
fi

DATASET_JSON="$RUN_DIR/dataset.json"
jq --arg name "$DATASET_NAME" '.data[] | select(.name == $name)' "$DATASETS_FILE" > "$DATASET_JSON"
if [[ ! -s "$DATASET_JSON" ]]; then
  echo "dataset not found: $DATASET_NAME" >&2
  echo "available datasets:" >&2
  jq -r '.data[].name' "$DATASETS_FILE" >&2
  exit 1
fi

DATASET_ID="$(jq -r '.id // empty' "$DATASET_JSON")"
PROJECT_ID="$(jq -r '.projectId // empty' "$DATASET_JSON")"

TMP_ITEMS="$RUN_DIR/items.json"
echo '[]' > "$TMP_ITEMS"

page=1
total=0
truncated=false

while true; do
  PAGE_FILE="$RUN_DIR/items-page-${page}.json"
  url="$BASE_URL/api/public/dataset-items?page=${page}&limit=${LIMIT}&datasetName=${DATASET_NAME}"

  http_code="$({
    curl -sS \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -o "$PAGE_FILE" \
      -w '%{http_code}' \
      "$url"
  } || true)"

  if [[ "$http_code" != "200" ]]; then
    msg="$(jq -r '.message // empty' "$PAGE_FILE" 2>/dev/null || true)"
    echo "request failed: status=$http_code url=$url" >&2
    [[ -n "$msg" ]] && echo "$msg" >&2
    exit 1
  fi

  count="$(jq '.data | length' "$PAGE_FILE")"
  log "page=$page count=$count"
  if [[ "$count" -eq 0 ]]; then
    break
  fi

  jq -s '.[0] + .[1].data' "$TMP_ITEMS" "$PAGE_FILE" > "$RUN_DIR/merge.json"
  mv "$RUN_DIR/merge.json" "$TMP_ITEMS"

  total=$((total + count))
  if [[ "$page" -ge "$MAX_PAGES" ]]; then
    log "hit max_pages=$MAX_PAGES; stop early"
    truncated=true
    break
  fi
  if [[ "$count" -lt "$LIMIT" ]]; then
    break
  fi

  page=$((page + 1))
done

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg datasetName "$DATASET_NAME" \
  --arg datasetId "$DATASET_ID" \
  --arg projectId "$PROJECT_ID" \
  --arg fetchedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson count "$total" \
  --argjson maxPages "$MAX_PAGES" \
  --argjson pageLimit "$LIMIT" \
  --argjson pagesFetched "$page" \
  --argjson truncated "$truncated" \
  --slurpfile dataset "$DATASET_JSON" \
  --slurpfile items "$TMP_ITEMS" \
  '{
    meta: {
      baseUrl: $baseUrl,
      datasetName: $datasetName,
      datasetId: $datasetId,
      projectId: ($projectId | select(length > 0)),
      fetchedAt: $fetchedAt,
      count: $count,
      pageLimit: $pageLimit,
      maxPages: $maxPages,
      pagesFetched: $pagesFetched,
      truncated: $truncated
    },
    dataset: ($dataset[0] // {}),
    items: ($items[0] // [])
  }' > "$OUT_FILE"

echo "saved: $OUT_FILE"
echo "dataset: $DATASET_NAME"
echo "items: $total"
log "done"
