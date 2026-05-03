#!/usr/bin/env bash
set -euo pipefail

mkdir -p ./tmp
RUN_ID="$(date +%s)_$RANDOM"
RUN_DIR="./tmp/bifrost-langfuse-e2e-${RUN_ID}"
mkdir -p "$RUN_DIR"
echo "=== Bifrost→LLM→Langfuse E2E ==="
echo "run_dir=$RUN_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1"
    exit 1
  }
}

need_cmd curl
need_cmd jq

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "missing env: $name"
    exit 1
  fi
}

: "${BIFROST_BASE_URL:=http://localhost:8080}"
: "${LANGFUSE_BASE_URL:=http://localhost:3000}"
: "${LANGFUSE_PUBLIC_KEY:=pk-00000000}"
: "${LANGFUSE_SECRET_KEY:=sk-00000000}"
: "${BIFROST_MODEL:=azure/gpt-5.4-nano}" # must be provider/model. set "auto" to pick first model.
: "${BIFROST_PROVIDER:=azure}" # azure | openai

if [ "$BIFROST_PROVIDER" = "azure" ]; then
  require_env AZURE_OPENAI_API_KEY
  require_env AZURE_ENDPOINT
elif [ "$BIFROST_PROVIDER" = "openai" ]; then
  require_env OPENAI_API_KEY
else
  echo "invalid BIFROST_PROVIDER: $BIFROST_PROVIDER (use azure|openai)"
  exit 1
fi

echo "wait bifrost..."
for _ in $(seq 1 30); do
  if curl -fsS "${BIFROST_BASE_URL}/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
MODELS_FILE="${RUN_DIR}/bifrost-models.json"
curl -fsS "${BIFROST_BASE_URL}/v1/models" >"$MODELS_FILE"

if [ "$BIFROST_MODEL" = "auto" ]; then
  BIFROST_MODEL="$(jq -r '.data[0].id // empty' "$MODELS_FILE")"
  if [ -z "$BIFROST_MODEL" ]; then
    echo "cannot auto-pick model from /v1/models"
    cat "$MODELS_FILE"
    exit 1
  fi
  echo "auto model: $BIFROST_MODEL"
fi

# normalize short model -> provider/model for bifrost
if [ "${BIFROST_MODEL#*/}" = "$BIFROST_MODEL" ]; then
  BIFROST_MODEL="${BIFROST_PROVIDER}/${BIFROST_MODEL}"
  echo "normalized model: $BIFROST_MODEL"
fi

MARKER="BIFROST_LANGFUSE_E2E_$(date +%s)_$RANDOM"
REQUEST_FILE="${RUN_DIR}/bifrost-request.json"
RESPONSE_FILE="${RUN_DIR}/bifrost-response.json"
OBS_FILE="${RUN_DIR}/langfuse-observations.json"
MATCH_FILE="${RUN_DIR}/match.json"

jq -n \
  --arg model "$BIFROST_MODEL" \
  --arg marker "$MARKER" \
  '{
    model: $model,
    temperature: 0,
    messages: [
      { role: "system", content: "Return exact token only." },
      { role: "user", content: ("Return exact token: " + $marker) }
    ]
  }' >"$REQUEST_FILE"

echo "call bifrost..."
HTTP_CODE="$(
curl -sS \
  -X POST "${BIFROST_BASE_URL}/v1/chat/completions" \
  -H "content-type: application/json" \
  --data @"$REQUEST_FILE" \
  -o "$RESPONSE_FILE" \
  -w '%{http_code}'
)"

if [ "$HTTP_CODE" != "200" ]; then
  echo "bifrost chat failed: HTTP $HTTP_CODE"
  echo "--- request ---"
  cat "$REQUEST_FILE"
  echo ""
  echo "--- response ---"
  cat "$RESPONSE_FILE"
  echo ""
  echo "--- /v1/models (first 20 ids) ---"
  jq -r '.data[:20][]?.id' "$MODELS_FILE" || true
  echo "hint: set BIFROST_MODEL to one id above, or fix AZURE_ENDPOINT/AZURE_OPENAI_API_KEY"
  exit 1
fi

RESPONSE_TEXT="$(
  jq -r '
    .choices[0].message.content // .choices[0].text // empty
  ' "$RESPONSE_FILE"
)"

if [ -z "$RESPONSE_TEXT" ]; then
  echo "empty llm response"
  cat "$RESPONSE_FILE"
  exit 1
fi

echo "wait langfuse observation..."
FOUND=0
for _ in $(seq 1 45); do
  curl -fsS \
    -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
    "${LANGFUSE_BASE_URL}/api/public/observations?limit=100&page=1&type=GENERATION" \
    >"$OBS_FILE"

  MATCH_COUNT="$(
    jq -r --arg marker "$MARKER" '
      [.data[] | select((.input|tostring|contains($marker)) or (.output|tostring|contains($marker)))] | length
    ' "$OBS_FILE"
  )"

  if [ "${MATCH_COUNT:-0}" -gt 0 ]; then
    FOUND=1
    break
  fi
  sleep 2
done

if [ "$FOUND" -ne 1 ]; then
  echo "no matching observation found"
  cat "$OBS_FILE"
  exit 1
fi

jq -r --arg marker "$MARKER" '
  .data
  | map(select((.input|tostring|contains($marker)) or (.output|tostring|contains($marker))))
  | sort_by(.startTime)
  | reverse
  | .[0]
' "$OBS_FILE" >"$MATCH_FILE"

OBS_ID="$(jq -r '.id // empty' "$MATCH_FILE")"
OBS_TRACE_ID="$(jq -r '.traceId // empty' "$MATCH_FILE")"
OBS_MODEL="$(jq -r '.model // empty' "$MATCH_FILE")"
OBS_INPUT_HAS_MARKER="$(jq -r --arg marker "$MARKER" '(.input|tostring|contains($marker))' "$MATCH_FILE")"
OBS_OUTPUT_HAS_MARKER="$(jq -r --arg marker "$MARKER" '(.output|tostring|contains($marker))' "$MATCH_FILE")"
RESP_HAS_MARKER="$([ "${RESPONSE_TEXT#*"$MARKER"}" != "$RESPONSE_TEXT" ] && echo true || echo false)"

echo "=== verify ==="
echo "request.model = $BIFROST_MODEL"
echo "response.text = $RESPONSE_TEXT"
echo "response.has_marker = $RESP_HAS_MARKER"
echo "obs.id = $OBS_ID"
echo "obs.traceId = $OBS_TRACE_ID"
echo "obs.model = $OBS_MODEL"
echo "obs.input.has_marker = $OBS_INPUT_HAS_MARKER"
echo "obs.output.has_marker = $OBS_OUTPUT_HAS_MARKER"

if [ "$RESP_HAS_MARKER" != "true" ]; then
  echo "verify fail: response missing marker"
  exit 1
fi
if [ "$OBS_INPUT_HAS_MARKER" != "true" ]; then
  echo "verify fail: observation input missing marker"
  exit 1
fi
if [ "$OBS_OUTPUT_HAS_MARKER" != "true" ]; then
  echo "verify fail: observation output missing marker"
  exit 1
fi

REQ_MODEL_SHORT="${BIFROST_MODEL#*/}"
MODEL_MATCH=true
if [ -n "$OBS_MODEL" ]; then
  if [ "$OBS_MODEL" = "$BIFROST_MODEL" ] || [ "$OBS_MODEL" = "$REQ_MODEL_SHORT" ]; then
    MODEL_MATCH=true
  elif [[ "$OBS_MODEL" == "${REQ_MODEL_SHORT}-"* ]]; then
    # allow provider prefix + version suffix differences, e.g. azure/gpt-5.4-nano vs gpt-5.4-nano-2026-03-17
    MODEL_MATCH=true
  else
    MODEL_MATCH=false
  fi
fi

if [ "$MODEL_MATCH" != "true" ]; then
  echo "warn: obs.model ($OBS_MODEL) != request.model ($BIFROST_MODEL)"
fi

echo "PASS: llm request/response matches langfuse observation"
