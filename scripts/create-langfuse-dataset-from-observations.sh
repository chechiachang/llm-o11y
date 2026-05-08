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
OBS_TYPE="${LANGFUSE_OBSERVATION_TYPE:-GENERATION}"
OBS_ENV="${LANGFUSE_OBSERVATION_ENV:-}"
LIMIT="${LANGFUSE_DATASET_ITEM_LIMIT:-50}"
START_PAGE="${LANGFUSE_OBSERVATION_START_PAGE:-1}"

DATASET_NAME="${1:-}"
if [[ "${DATASET_NAME}" == "" || "${DATASET_NAME}" == "-h" || "${DATASET_NAME}" == "--help" ]]; then
  echo "usage: $0 <dataset-name> [limit]"
  echo "env: LANGFUSE_OBSERVATION_TYPE=GENERATION|SPAN|EVENT"
  echo "env: LANGFUSE_OBSERVATION_ENV=<environment>"
  exit 0
fi

if [[ -n "${2:-}" ]]; then
  LIMIT="$2"
fi

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -le 0 ]]; then
  echo "invalid limit: $LIMIT" >&2
  exit 1
fi

mkdir -p ./tmp
RUN_ID="$(date +%s)_$RANDOM"
RUN_DIR="./tmp/langfuse-dataset-${RUN_ID}"
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

# create/get dataset by name
CREATE_DATASET_PAYLOAD="$RUN_DIR/create-dataset.json"
cat > "$CREATE_DATASET_PAYLOAD" <<JSON
{"name":"$DATASET_NAME","description":"created from observations by script"}
JSON

CREATE_DATASET_HTTP="$({
  curl -sS \
    --max-time "$HTTP_TIMEOUT" \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -H 'Content-Type: application/json' \
    -X POST "$BASE_URL/api/public/datasets" \
    -d @"$CREATE_DATASET_PAYLOAD" \
    -o "$RUN_DIR/dataset.json" \
    -w '%{http_code}'
} || true)"

if [[ "$CREATE_DATASET_HTTP" != "200" ]]; then
  echo "create dataset fail: HTTP $CREATE_DATASET_HTTP" >&2
  cat "$RUN_DIR/dataset.json" >&2
  exit 1
fi

DATASET_ID="$(jq -r '.id // empty' "$RUN_DIR/dataset.json")"
if [[ "$DATASET_ID" == "" ]]; then
  echo "dataset id missing" >&2
  exit 1
fi

echo "dataset=ok name=$DATASET_NAME id=$DATASET_ID"

# existing sourceObservationId in dataset -> dedupe
EXISTING_IDS_FILE="$RUN_DIR/existing-source-observation-ids.txt"
: > "$EXISTING_IDS_FILE"
ITEM_PAGE=1
while true; do
  ITEMS_URL="$BASE_URL/api/public/dataset-items?page=$ITEM_PAGE&limit=100&datasetName=$DATASET_NAME"
  curl -fsS --max-time "$HTTP_TIMEOUT" -u "$PUBLIC_KEY:$SECRET_KEY" "$ITEMS_URL" > "$RUN_DIR/dataset-items-$ITEM_PAGE.json"
  jq -r '.data[] | .sourceObservationId // empty' "$RUN_DIR/dataset-items-$ITEM_PAGE.json" >> "$EXISTING_IDS_FILE"

  TOTAL_PAGES="$(jq -r '.meta.totalPages // 1' "$RUN_DIR/dataset-items-$ITEM_PAGE.json")"
  if [[ "$ITEM_PAGE" -ge "$TOTAL_PAGES" ]]; then
    break
  fi
  ITEM_PAGE=$((ITEM_PAGE + 1))
done
sort -u "$EXISTING_IDS_FILE" -o "$EXISTING_IDS_FILE"

added=0
skipped_existing=0
skipped_invalid=0
obs_page="$START_PAGE"

while [[ "$added" -lt "$LIMIT" ]]; do
  OBS_URL="$BASE_URL/api/public/observations?page=$obs_page&limit=100&type=$OBS_TYPE"
  if [[ -n "$OBS_ENV" ]]; then
    OBS_URL+="&environment=$OBS_ENV"
  fi

  OBS_FILE="$RUN_DIR/observations-$obs_page.json"
  OBS_HTTP="$({
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -o "$OBS_FILE" \
      -w '%{http_code}' \
      "$OBS_URL"
  } || true)"

  if [[ "$OBS_HTTP" != "200" ]]; then
    echo "fetch observations fail: HTTP $OBS_HTTP page=$obs_page" >&2
    cat "$OBS_FILE" >&2
    exit 1
  fi

  TOTAL_PAGES="$(jq -r '.meta.totalPages // 1' "$OBS_FILE")"

  while IFS= read -r obs; do
    [[ "$added" -ge "$LIMIT" ]] && break

    obs_id="$(jq -r '.id // empty' <<<"$obs")"
    trace_id="$(jq -r '.traceId // empty' <<<"$obs")"

    if [[ "$obs_id" == "" ]]; then
      skipped_invalid=$((skipped_invalid + 1))
      continue
    fi

    if grep -qx "$obs_id" "$EXISTING_IDS_FILE"; then
      skipped_existing=$((skipped_existing + 1))
      continue
    fi

    item_payload="$RUN_DIR/item-$obs_id.json"
    jq -c --arg datasetName "$DATASET_NAME" '
      {
        datasetName: $datasetName,
        input: .input,
        expectedOutput: .output,
        metadata: {
          source: "observations",
          observationId: .id,
          traceId: .traceId,
          observationName: .name,
          observationType: .type,
          observationEnvironment: .environment,
          observationStartTime: .startTime,
          observationEndTime: .endTime
        },
        sourceObservationId: .id,
        sourceTraceId: .traceId
      }
      | with_entries(select(.value != null))
    ' <<<"$obs" > "$item_payload"

    CREATE_ITEM_HTTP="$({
      curl -sS \
        --max-time "$HTTP_TIMEOUT" \
        -u "$PUBLIC_KEY:$SECRET_KEY" \
        -H 'Content-Type: application/json' \
        -X POST "$BASE_URL/api/public/dataset-items" \
        -d @"$item_payload" \
        -o "$RUN_DIR/item-$obs_id-res.json" \
        -w '%{http_code}'
    } || true)"

    if [[ "$CREATE_ITEM_HTTP" != "200" ]]; then
      msg="$(jq -r '.message // empty' "$RUN_DIR/item-$obs_id-res.json" 2>/dev/null || true)"
      if [[ "$msg" == *"already exists"* ]]; then
        skipped_existing=$((skipped_existing + 1))
        echo "$obs_id" >> "$EXISTING_IDS_FILE"
        continue
      fi
      # input null, validation fail, etc.
      skipped_invalid=$((skipped_invalid + 1))
      continue
    fi

    echo "$obs_id" >> "$EXISTING_IDS_FILE"
    added=$((added + 1))
  done < <(jq -c '.data[] | select(.input != null)' "$OBS_FILE")

  if [[ "$obs_page" -ge "$TOTAL_PAGES" ]]; then
    break
  fi

  obs_page=$((obs_page + 1))
done

echo "done dataset=$DATASET_NAME added=$added skipped_existing=$skipped_existing skipped_invalid=$skipped_invalid"
if [[ "$added" -eq 0 ]]; then
  echo "warning: no new dataset item added" >&2
fi
