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

COUNT="$(jq '.llmConnections | length // 0' "$CONFIG_FILE")"
if [[ "$COUNT" == "0" ]]; then
  echo "No llmConnections found in $CONFIG_FILE"
  exit 0
fi

echo "Upserting $COUNT LLM connection(s) to $BASE_URL"

jq -c '.llmConnections[]' "$CONFIG_FILE" | while IFS= read -r conn; do
  provider="$(jq -r '.provider' <<<"$conn")"
  adapter="$(jq -r '.adapter' <<<"$conn")"
  secret_key="$(jq -r '.secretKey // empty' <<<"$conn")"
  base_url="$(jq -r '.baseURL // empty' <<<"$conn")"

  if [[ "$provider" == "null" || -z "$provider" || "$adapter" == "null" || -z "$adapter" ]]; then
    echo "Skipping invalid connection entry (provider/adapter required)" >&2
    continue
  fi

  if [[ "$secret_key" == env:* ]]; then
    env_key="${secret_key#env:}"
    secret_key="${!env_key:-}"
  fi

  # Langfuse API requires secretKey even if upstream gateway does not enforce auth.
  if [[ -z "$secret_key" && "$base_url" =~ ^http://localhost:8080(/v1)?$ ]]; then
    secret_key="bifrost-noauth"
  fi

  if [[ -z "$secret_key" ]]; then
    echo "Skipping $provider: secretKey missing (or env var not set)" >&2
    continue
  fi

  payload="$(jq -c --arg secretKey "$secret_key" '
    .secretKey = $secretKey
    | {
      provider,
      adapter,
      secretKey,
      baseURL,
      customModels,
      withDefaultModels,
      extraHeaders,
      config
    }
    | with_entries(select(.value != null))
  ' <<<"$conn")"

  response_file="./tmp/langfuse-llm-connection-response.json"
  http_code="$(
    curl -sS \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -H 'Content-Type: application/json' \
      -X PUT "$BASE_URL/api/public/llm-connections" \
      -d "$payload" \
      -o "$response_file" \
      -w '%{http_code}'
  )"

  if [[ "$http_code" -ge 400 ]]; then
    message="$(jq -r '.message // empty' "$response_file" 2>/dev/null || true)"
    error_type="$(jq -r '.error // empty' "$response_file" 2>/dev/null || true)"
    echo "Failed to upsert connection: provider=$provider adapter=$adapter status=$http_code" >&2
    if [[ -n "$message" || -n "$error_type" ]]; then
      echo "Langfuse error: ${error_type:-unknown} ${message:-}" >&2
    else
      echo "Langfuse response: $(cat "$response_file")" >&2
    fi
    if [[ "$message" == *"Blocked hostname detected"* || "$message" == *"Blocked IP address detected"* ]]; then
      echo "Hint: Langfuse rejects localhost/private-network baseURL for LLM connections. Use a public HTTPS gateway URL." >&2
    fi
    exit 1
  fi

  echo "Upserted connection: provider=$provider adapter=$adapter"
done
