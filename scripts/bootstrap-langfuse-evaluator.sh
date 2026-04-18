#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

BASE_URL="${LANGFUSE_BASE_URL:-http://localhost:3000}"
PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"
CONFIG_FILE="${1:-data/langfuse/bootstrap.json}"

if [[ -z "$PUBLIC_KEY" || -z "$SECRET_KEY" ]]; then
  echo "Set LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if ! jq -e '.evaluator.scoreConfig' "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "No evaluator.scoreConfig found in $CONFIG_FILE"
  exit 0
fi

score_cfg="$(jq -c '.evaluator.scoreConfig' "$CONFIG_FILE")"
score_name="$(jq -r '.name // empty' <<<"$score_cfg")"
data_type="$(jq -r '.dataType // empty' <<<"$score_cfg")"

if [[ -z "$score_name" || -z "$data_type" ]]; then
  echo "evaluator.scoreConfig requires name and dataType" >&2
  exit 1
fi

existing_id="$({
  curl -fsS -u "$PUBLIC_KEY:$SECRET_KEY" \
    "$BASE_URL/api/public/score-configs?page=1&limit=100" \
    | jq -r --arg name "$score_name" '
      .data
      | map(select(.name == $name))
      | sort_by(.updatedAt // .createdAt)
      | reverse
      | .[0].id // empty
    '
} || true)"

payload="$(jq -c '{
  name,
  dataType,
  description,
  minValue,
  maxValue,
  categories
} | with_entries(select(.value != null))' <<<"$score_cfg")"

if [[ -n "$existing_id" ]]; then
  curl -fsS \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -H 'Content-Type: application/json' \
    -X PATCH "$BASE_URL/api/public/score-configs/$existing_id" \
    -d "$payload" >/dev/null
  echo "Updated score config: $score_name ($existing_id)"
else
  created="$(curl -fsS \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -H 'Content-Type: application/json' \
    -X POST "$BASE_URL/api/public/score-configs" \
    -d "$payload")"
  created_id="$(jq -r '.id' <<<"$created")"
  echo "Created score config: $score_name ($created_id)"
fi

echo "Note: Managed LLM-as-a-judge evaluator definition is not exposed via public API."
echo "Create it in Langfuse UI and select score config: $score_name"
