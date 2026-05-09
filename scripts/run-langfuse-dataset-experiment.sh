#!/usr/bin/env bash
set -euo pipefail

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
HTTP_TIMEOUT="${LANGFUSE_HTTP_TIMEOUT:-30}"
PAGE_LIMIT="${LANGFUSE_PAGE_LIMIT:-100}"
MAX_PAGES="${LANGFUSE_MAX_PAGES:-100}"

DATASET_NAME="${1:-${LANGFUSE_DATASET_NAME:-my-dataset}}"
RUN_NAME="${2:-${LANGFUSE_RUN_NAME:-dataset-exp-$(date +%Y%m%d-%H%M%S)}}"
ITEM_LIMIT="${3:-${LANGFUSE_ITEM_LIMIT:-50}}"

if [[ "$DATASET_NAME" == "-h" || "$DATASET_NAME" == "--help" ]]; then
  echo "usage: $0 [dataset-name] [run-name] [item-limit]"
  echo "default dataset-name: my-dataset"
  echo "default run-name: dataset-exp-<timestamp>"
  echo "default item-limit: 50"
  exit 0
fi

if ! [[ "$PAGE_LIMIT" =~ ^[0-9]+$ ]] || [[ "$PAGE_LIMIT" -lt 1 || "$PAGE_LIMIT" -gt 100 ]]; then
  echo "invalid LANGFUSE_PAGE_LIMIT=$PAGE_LIMIT (use 1..100)" >&2
  exit 1
fi
if ! [[ "$MAX_PAGES" =~ ^[0-9]+$ ]] || [[ "$MAX_PAGES" -lt 1 ]]; then
  echo "invalid LANGFUSE_MAX_PAGES=$MAX_PAGES (use >=1)" >&2
  exit 1
fi
if ! [[ "$ITEM_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "invalid item-limit=$ITEM_LIMIT" >&2
  exit 1
fi

mkdir -p ./tmp
RUN_ID="$(date +%s)_$RANDOM"
RUN_DIR="./tmp/langfuse-dataset-exp-${RUN_ID}"
mkdir -p "$RUN_DIR"

# auth
AUTH_HTTP="$({
  curl -sS \
    --max-time "$HTTP_TIMEOUT" \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -o "$RUN_DIR/auth.json" \
    -w '%{http_code}' \
    "$BASE_URL/api/public/projects"
} || true)"
if [[ "$AUTH_HTTP" != "200" ]]; then
  echo "auth fail: HTTP $AUTH_HTTP" >&2
  jq -r '.message // empty' "$RUN_DIR/auth.json" 2>/dev/null || true
  exit 1
fi

# dataset lookup by name
curl -fsS --max-time "$HTTP_TIMEOUT" -u "$PUBLIC_KEY:$SECRET_KEY" \
  "$BASE_URL/api/public/datasets?page=1&limit=100" > "$RUN_DIR/datasets.json"

DATASET_ID="$(jq -r --arg name "$DATASET_NAME" '.data[] | select(.name == $name) | .id' "$RUN_DIR/datasets.json" | head -n1)"
if [[ -z "$DATASET_ID" ]]; then
  echo "dataset not found: $DATASET_NAME" >&2
  echo "available datasets:" >&2
  jq -r '.data[].name' "$RUN_DIR/datasets.json" >&2
  exit 1
fi

echo "dataset=ok name=$DATASET_NAME id=$DATASET_ID"
echo "run_name=$RUN_NAME"

# existing run item datasetItemIds for dedupe
EXISTING_IDS_FILE="$RUN_DIR/existing-run-dataset-item-ids.txt"
: > "$EXISTING_IDS_FILE"
existing_page=1
while true; do
  RUN_ITEMS_URL="$BASE_URL/api/public/dataset-run-items?datasetId=$DATASET_ID&runName=$RUN_NAME&page=$existing_page&limit=100"
  RUN_ITEMS_HTTP="$({
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -o "$RUN_DIR/run-items-$existing_page.json" \
      -w '%{http_code}' \
      "$RUN_ITEMS_URL"
  } || true)"
  if [[ "$RUN_ITEMS_HTTP" == "404" ]]; then
    run_not_found_msg="$(jq -r '.message // empty' "$RUN_DIR/run-items-$existing_page.json" 2>/dev/null || true)"
    if [[ "$run_not_found_msg" == *"Dataset run not found"* ]]; then
      break
    fi
  fi
  if [[ "$RUN_ITEMS_HTTP" != "200" && "$RUN_ITEMS_HTTP" != "404" ]]; then
    echo "list run items fail: HTTP $RUN_ITEMS_HTTP" >&2
    cat "$RUN_DIR/run-items-$existing_page.json" >&2
    exit 1
  fi
  if [[ "$RUN_ITEMS_HTTP" == "404" ]]; then
    break
  fi

  jq -r '.data[] | .datasetItemId // empty' "$RUN_DIR/run-items-$existing_page.json" >> "$EXISTING_IDS_FILE"

  total_pages="$(jq -r '.meta.totalPages // 1' "$RUN_DIR/run-items-$existing_page.json")"
  if [[ "$existing_page" -ge "$total_pages" ]]; then
    break
  fi
  existing_page=$((existing_page + 1))
done
sort -u "$EXISTING_IDS_FILE" -o "$EXISTING_IDS_FILE"

added=0
skipped_existing=0
skipped_no_source=0
skipped_limit=0
failed=0
page=1

while true; do
  if [[ "$page" -gt "$MAX_PAGES" ]]; then
    break
  fi

  ITEMS_URL="$BASE_URL/api/public/dataset-items?page=$page&limit=$PAGE_LIMIT&datasetName=$DATASET_NAME"
  ITEMS_HTTP="$({
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -o "$RUN_DIR/dataset-items-$page.json" \
      -w '%{http_code}' \
      "$ITEMS_URL"
  } || true)"
  if [[ "$ITEMS_HTTP" != "200" ]]; then
    echo "fetch dataset items fail: HTTP $ITEMS_HTTP" >&2
    cat "$RUN_DIR/dataset-items-$page.json" >&2
    exit 1
  fi

  count="$(jq '.data | length' "$RUN_DIR/dataset-items-$page.json")"
  [[ "$count" -eq 0 ]] && break

  while IFS= read -r item; do
    item_id="$(jq -r '.id // empty' <<<"$item")"
    obs_id="$(jq -r '.sourceObservationId // empty' <<<"$item")"
    trace_id="$(jq -r '.sourceTraceId // empty' <<<"$item")"

    if [[ -z "$item_id" ]]; then
      continue
    fi

    if grep -qx "$item_id" "$EXISTING_IDS_FILE"; then
      skipped_existing=$((skipped_existing + 1))
      continue
    fi

    if [[ -z "$obs_id" && -z "$trace_id" ]]; then
      skipped_no_source=$((skipped_no_source + 1))
      continue
    fi

    if [[ "$ITEM_LIMIT" -gt 0 && "$added" -ge "$ITEM_LIMIT" ]]; then
      skipped_limit=$((skipped_limit + 1))
      continue
    fi

    payload_file="$RUN_DIR/create-run-item-$item_id.json"
    jq -n \
      --arg runName "$RUN_NAME" \
      --arg datasetItemId "$item_id" \
      --arg observationId "$obs_id" \
      --arg traceId "$trace_id" \
      '{
        runName: $runName,
        datasetItemId: $datasetItemId,
        observationId: ($observationId | select(length > 0)),
        traceId: ($traceId | select(length > 0))
      }' > "$payload_file"

    CREATE_HTTP="$({
      curl -sS \
        --max-time "$HTTP_TIMEOUT" \
        -u "$PUBLIC_KEY:$SECRET_KEY" \
        -H 'Content-Type: application/json' \
        -X POST "$BASE_URL/api/public/dataset-run-items" \
        -d @"$payload_file" \
        -o "$RUN_DIR/create-run-item-$item_id-res.json" \
        -w '%{http_code}'
    } || true)"

    if [[ "$CREATE_HTTP" != "200" ]]; then
      failed=$((failed + 1))
      continue
    fi

    echo "$item_id" >> "$EXISTING_IDS_FILE"
    added=$((added + 1))
  done < <(jq -c '.data[]' "$RUN_DIR/dataset-items-$page.json")

  total_pages="$(jq -r '.meta.totalPages // 1' "$RUN_DIR/dataset-items-$page.json")"
  if [[ "$page" -ge "$total_pages" ]]; then
    break
  fi
  page=$((page + 1))
done

echo "done run_name=$RUN_NAME dataset=$DATASET_NAME added=$added skipped_existing=$skipped_existing skipped_no_source=$skipped_no_source skipped_limit=$skipped_limit failed=$failed"
if [[ "$added" -eq 0 ]]; then
  echo "warning: no new run item created" >&2
fi
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
