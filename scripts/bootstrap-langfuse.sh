#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

need_cmd jq
need_cmd curl

BASE_URL="${LANGFUSE_BASE_URL:-http://localhost:3000}"
PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-pk-00000000}"
SECRET_KEY="${LANGFUSE_SECRET_KEY:-sk-00000000}"
HTTP_TIMEOUT="${LANGFUSE_HTTP_TIMEOUT:-30}"
CONFIG_FILE="data/langfuse/bootstrap.json"
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      echo "usage: $0 [config.json]"
      echo "  bootstrap + verify llm-as-a-judge workflow"
      exit 0
      ;;
    *)
      CONFIG_FILE="$arg"
      ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" && -f "data/langfuse/bootstrap.example.json" ]]; then
  CONFIG_FILE="data/langfuse/bootstrap.example.json"
fi

mkdir -p ./tmp
RUN_ID="$(date +%s)_$RANDOM"
RUN_DIR="./tmp/langfuse-bootstrap-${RUN_ID}"
mkdir -p "$RUN_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if ! jq -e '.llmConnections and (.llmConnections | type == "array")' "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "Invalid config: .llmConnections must be an array ($CONFIG_FILE)" >&2
  exit 1
fi

AUTH_FILE="$RUN_DIR/auth-check.json"
AUTH_HTTP="$(
  curl -sS \
    --max-time "$HTTP_TIMEOUT" \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -o "$AUTH_FILE" \
    -w '%{http_code}' \
    "$BASE_URL/api/public/projects"
)"
if [[ "$AUTH_HTTP" != "200" ]]; then
  msg="$(jq -r '.message // empty' "$AUTH_FILE" 2>/dev/null || true)"
  echo "Auth check failed: status=$AUTH_HTTP base_url=$BASE_URL" >&2
  [[ -n "$msg" ]] && echo "$msg" >&2
  exit 1
fi
PROJECT_ID="$(jq -r '.data[0].id // empty' "$AUTH_FILE" 2>/dev/null || true)"

echo "verify llm-as-a-judge workflow"
echo "base_url=$BASE_URL"
echo "config=$CONFIG_FILE"
HEALTH_FILE="$RUN_DIR/health.json"
curl -fsS "$BASE_URL/api/public/health" >"$HEALTH_FILE"
VERSION="$(jq -r '.version // "unknown"' "$HEALTH_FILE")"
echo "langfuse.version=$VERSION"
echo "auth=ok"

COUNT="$(jq '.llmConnections | length // 0' "$CONFIG_FILE")"
if [[ "$COUNT" == "0" ]]; then
  echo "No llmConnections found in $CONFIG_FILE"
  exit 0
fi

echo "Upserting $COUNT LLM connection(s) to $BASE_URL"

success=0
skipped=0

while IFS= read -r conn; do
  provider="$(jq -r '.provider' <<<"$conn")"
  adapter="$(jq -r '.adapter' <<<"$conn")"
  secret_key="$(jq -r '.secretKey // empty' <<<"$conn")"
  base_url="$(jq -r '.baseURL // empty' <<<"$conn")"

  if [[ "$provider" == "null" || -z "$provider" || "$adapter" == "null" || -z "$adapter" ]]; then
    echo "Skipping invalid connection entry (provider/adapter required)" >&2
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -n "$base_url" && ! "$base_url" =~ ^https?:// ]]; then
    echo "Skipping $provider: invalid baseURL (must start with http:// or https://)" >&2
    skipped=$((skipped + 1))
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
    skipped=$((skipped + 1))
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

  response_file="$RUN_DIR/llm-connection-response.json"
  http_code="$(
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
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
  success=$((success + 1))
done < <(jq -c '.llmConnections[]' "$CONFIG_FILE")

echo "Done: success=$success skipped=$skipped total=$COUNT"
if [[ "$success" -eq 0 ]]; then
  echo "No connection upserted" >&2
  exit 1
fi

if jq -e '.evaluator.scoreConfig' "$CONFIG_FILE" >/dev/null 2>&1; then
  score_cfg="$(jq -c '.evaluator.scoreConfig' "$CONFIG_FILE")"
  score_name="$(jq -r '.name // empty' <<<"$score_cfg")"
  data_type="$(jq -r '.dataType // empty' <<<"$score_cfg")"

  if [[ -z "$score_name" || -z "$data_type" ]]; then
    echo "evaluator.scoreConfig requires name and dataType" >&2
    exit 1
  fi

  score_list_file="$RUN_DIR/score-configs.json"
  curl -fsS -u "$PUBLIC_KEY:$SECRET_KEY" \
    "$BASE_URL/api/public/score-configs?page=1&limit=100" \
    >"$score_list_file"

  existing_id="$(jq -r --arg name "$score_name" '
    .data
    | map(select(.name == $name))
    | sort_by(.updatedAt // .createdAt)
    | reverse
    | .[0].id // empty
  ' "$score_list_file")"

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
    created="$(
      curl -fsS \
        -u "$PUBLIC_KEY:$SECRET_KEY" \
        -H 'Content-Type: application/json' \
        -X POST "$BASE_URL/api/public/score-configs" \
        -d "$payload"
    )"
    created_id="$(jq -r '.id // empty' <<<"$created")"
    echo "Created score config: $score_name ($created_id)"
  fi
fi

UNSTABLE_LIST_FILE="$RUN_DIR/unstable-evaluators-list.json"
UNSTABLE_HTTP="$(
  curl -sS \
    --max-time "$HTTP_TIMEOUT" \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -o "$UNSTABLE_LIST_FILE" \
    -w '%{http_code}' \
    "$BASE_URL/api/public/unstable/evaluators?page=1&limit=1"
)"
if [[ "$UNSTABLE_HTTP" != "200" ]]; then
  echo "unstable_evaluators_api=unsupported http=$UNSTABLE_HTTP"
  echo "cannot verify full API workflow on this Langfuse version"
  exit 2
fi
echo "unstable_evaluators_api=ok"

EVAL_PROVIDER="$(jq -r '.llmConnections[0].provider // empty' "$CONFIG_FILE")"
EVAL_MODEL="$(jq -r '.llmConnections[0].customModels[0] // empty' "$CONFIG_FILE")"

EVAL_NAME="ci-default-model-check-${RUN_ID}"
CREATE_REQ="$RUN_DIR/create-evaluator.json"
CREATE_RES="$RUN_DIR/create-evaluator-res.json"
jq -n --arg name "$EVAL_NAME" '{
  name: $name,
  prompt: "Judge correctness.\nInput:\n{{input}}\nOutput:\n{{output}}\nReturn score 0..1.",
  outputDefinition: {
    dataType: "NUMERIC",
    reasoning: { description: "Reasoning" },
    score: { description: "Score 0..1" }
  }
}' >"$CREATE_REQ"

CREATE_HTTP="$(
  {
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -H 'Content-Type: application/json' \
      -X POST "$BASE_URL/api/public/unstable/evaluators" \
      -d @"$CREATE_REQ" \
      -o "$CREATE_RES" \
      -w '%{http_code}'
  } || true
)"
if [[ -z "$CREATE_HTTP" ]]; then
  echo "create_evaluator=error timeout_or_network" >&2
  exit 1
fi
if [[ "$CREATE_HTTP" == "200" ]]; then
  EVAL_ID="$(jq -r '.id // empty' "$CREATE_RES")"
  if [[ -n "$EVAL_ID" ]]; then
    curl -sS -u "$PUBLIC_KEY:$SECRET_KEY" -X DELETE \
      --max-time "$HTTP_TIMEOUT" \
      -o /dev/null -w '%{http_code}' \
      "$BASE_URL/api/public/unstable/evaluators/$EVAL_ID" >/dev/null || true
  fi
  echo "default_evaluator_model=ok"
fi

if [[ "$CREATE_HTTP" != "200" ]]; then
  ERR_CODE="$(jq -r '.code // empty' "$CREATE_RES" 2>/dev/null || true)"
  ERR_MSG="$(jq -r '.message // empty' "$CREATE_RES" 2>/dev/null || true)"
  if [[ "$ERR_CODE" == "evaluator_preflight_failed" && "$ERR_MSG" == *"No valid LLM model found"* ]]; then
    echo "default_evaluator_model=missing"
    if [[ -n "$PROJECT_ID" ]]; then
      echo "Set default evaluator model in UI: $BASE_URL/project/$PROJECT_ID/evals/new" >&2
    else
      echo "Set default evaluator model in UI: $BASE_URL/project/<project-id>/evals/new" >&2
    fi
  else
    echo "create_evaluator=fail http=$CREATE_HTTP" >&2
    if [[ -n "$ERR_MSG" ]]; then
      echo "$ERR_MSG" >&2
    elif [[ -s "$CREATE_RES" ]]; then
      cat "$CREATE_RES" >&2
    fi
    exit 1
  fi
fi

if [[ "$CREATE_HTTP" != "200" && ( -z "$EVAL_PROVIDER" || -z "$EVAL_MODEL" ) ]]; then
  echo "retry_create_evaluator=skipped (missing provider/model in config)" >&2
  exit 1
fi

RETRY_NAME="ci-explicit-model-check-${RUN_ID}"
RETRY_REQ="$RUN_DIR/retry-create-evaluator.json"
RETRY_RES="$RUN_DIR/retry-create-evaluator-res.json"
jq -n --arg name "$RETRY_NAME" --arg provider "$EVAL_PROVIDER" --arg model "$EVAL_MODEL" '{
  name: $name,
  modelConfig: {
    provider: $provider,
    model: $model
  },
  prompt: "Judge correctness.\nInput:\n{{input}}\nOutput:\n{{output}}\nReturn score 0..1.",
  outputDefinition: {
    dataType: "NUMERIC",
    reasoning: { description: "Reasoning" },
    score: { description: "Score 0..1" }
  }
}' >"$RETRY_REQ"

RETRY_HTTP="$(
  {
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -H 'Content-Type: application/json' \
      -X POST "$BASE_URL/api/public/unstable/evaluators" \
      -d @"$RETRY_REQ" \
      -o "$RETRY_RES" \
      -w '%{http_code}'
  } || true
)"
if [[ -z "$RETRY_HTTP" ]]; then
  echo "retry_create_evaluator=error timeout_or_network" >&2
  exit 1
fi
if [[ "$CREATE_HTTP" != "200" && "$RETRY_HTTP" != "200" ]]; then
  echo "retry_create_evaluator=fail http=$RETRY_HTTP" >&2
  if [[ -s "$RETRY_RES" ]]; then
    cat "$RETRY_RES" >&2
  fi
  exit 1
fi

RETRY_ID="$(jq -r '.id // empty' "$RETRY_RES")"
if [[ "$CREATE_HTTP" != "200" && -n "$RETRY_ID" ]]; then
  curl -sS -u "$PUBLIC_KEY:$SECRET_KEY" -X DELETE \
    --max-time "$HTTP_TIMEOUT" \
    -o /dev/null -w '%{http_code}' \
    "$BASE_URL/api/public/unstable/evaluators/$RETRY_ID" >/dev/null || true
fi
if [[ "$CREATE_HTTP" != "200" ]]; then
  echo "retry_create_evaluator=ok provider=$EVAL_PROVIDER model=$EVAL_MODEL"
  echo "warning: default_evaluator_model still missing (explicit model works)"
fi

SCORE_NAME="$(jq -r '.evaluator.scoreConfig.name // empty' "$CONFIG_FILE")"
if [[ -z "$SCORE_NAME" ]]; then
  echo "missing evaluator.scoreConfig.name in $CONFIG_FILE" >&2
  exit 1
fi

SCORES_FILE="$RUN_DIR/score-configs-verify.json"
curl -fsS \
  --max-time "$HTTP_TIMEOUT" \
  -u "$PUBLIC_KEY:$SECRET_KEY" \
  "$BASE_URL/api/public/score-configs?page=1&limit=100" \
  >"$SCORES_FILE"
SCORE_ID="$(jq -r --arg name "$SCORE_NAME" '.data[] | select(.name == $name) | .id' "$SCORES_FILE" | head -n1)"
if [[ -z "$SCORE_ID" ]]; then
  echo "score config missing: $SCORE_NAME" >&2
  exit 1
fi
echo "score_config=ok id=$SCORE_ID"

  EVAL_NAME="ci-answer-correctness-${RUN_ID}"
  CREATE_EVAL_REQ="$RUN_DIR/create-evaluator-verify.json"
  CREATE_EVAL_RES="$RUN_DIR/create-evaluator-verify-res.json"

  jq -n \
    --arg name "$EVAL_NAME" \
    --arg provider "$EVAL_PROVIDER" \
    --arg model "$EVAL_MODEL" \
    '{
      name: $name,
      prompt: "You are grading an answer.\n\nInput:\n{{input}}\n\nOutput:\n{{output}}\n\nReturn a score between 0 and 1.",
      outputDefinition: {
        dataType: "NUMERIC",
        reasoning: { description: "Explain why the score was assigned." },
        score: { description: "Correctness score between 0 and 1." }
      }
    }
    | if ($provider != "" and $model != "")
        then . + { modelConfig: { provider: $provider, model: $model } }
        else .
      end' >"$CREATE_EVAL_REQ"

  CREATE_EVAL_HTTP="$(
    {
      curl -sS \
        --max-time "$HTTP_TIMEOUT" \
        -u "$PUBLIC_KEY:$SECRET_KEY" \
        -H 'Content-Type: application/json' \
        -X POST "$BASE_URL/api/public/unstable/evaluators" \
        -d @"$CREATE_EVAL_REQ" \
        -o "$CREATE_EVAL_RES" \
        -w '%{http_code}'
    } || true
  )"
  if [[ -z "$CREATE_EVAL_HTTP" ]]; then
    echo "create_evaluator=error timeout_or_network"
    exit 1
  fi
  if [[ "$CREATE_EVAL_HTTP" != "200" ]]; then
    echo "create_evaluator=fail http=$CREATE_EVAL_HTTP"
    cat "$CREATE_EVAL_RES"
    exit 1
  fi
  echo "create_evaluator=ok name=$EVAL_NAME"

  RULE_NAME="ci-observation-rule-${RUN_ID}"
  CREATE_RULE_REQ="$RUN_DIR/create-rule.json"
  CREATE_RULE_RES="$RUN_DIR/create-rule-res.json"

  jq -n \
    --arg name "$RULE_NAME" \
    --arg eval_name "$EVAL_NAME" \
    '{
      name: $name,
      evaluator: { name: $eval_name, scope: "project" },
      target: "observation",
      enabled: false,
      mapping: [
        { variable: "input", source: "input" },
        { variable: "output", source: "output" }
      ]
    }' >"$CREATE_RULE_REQ"

  CREATE_RULE_HTTP="$(
    {
      curl -sS \
        --max-time "$HTTP_TIMEOUT" \
        -u "$PUBLIC_KEY:$SECRET_KEY" \
        -H 'Content-Type: application/json' \
        -X POST "$BASE_URL/api/public/unstable/evaluation-rules" \
        -d @"$CREATE_RULE_REQ" \
        -o "$CREATE_RULE_RES" \
        -w '%{http_code}'
    } || true
  )"
  if [[ -z "$CREATE_RULE_HTTP" ]]; then
    echo "create_rule=error timeout_or_network"
    exit 1
  fi
  if [[ "$CREATE_RULE_HTTP" != "200" ]]; then
    echo "create_rule=fail http=$CREATE_RULE_HTTP"
    cat "$CREATE_RULE_RES"
    exit 1
  fi

  RULE_ID="$(jq -r '.id // empty' "$CREATE_RULE_RES")"
  if [[ -z "$RULE_ID" ]]; then
    echo "create_rule=fail missing id"
    cat "$CREATE_RULE_RES"
    exit 1
  fi
  echo "create_rule=ok id=$RULE_ID"

  GET_RULE_RES="$RUN_DIR/get-rule-res.json"
  GET_RULE_HTTP="$(
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -o "$GET_RULE_RES" \
      -w '%{http_code}' \
      "$BASE_URL/api/public/unstable/evaluation-rules/$RULE_ID"
  )"
  if [[ "$GET_RULE_HTTP" != "200" ]]; then
    echo "get_rule=fail http=$GET_RULE_HTTP"
    cat "$GET_RULE_RES"
    exit 1
  fi
  echo "get_rule=ok"

  DELETE_RULE_RES="$RUN_DIR/delete-rule-res.json"
  DELETE_RULE_HTTP="$(
    curl -sS \
      --max-time "$HTTP_TIMEOUT" \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -X DELETE \
      -o "$DELETE_RULE_RES" \
      -w '%{http_code}' \
      "$BASE_URL/api/public/unstable/evaluation-rules/$RULE_ID"
  )"
  if [[ "$DELETE_RULE_HTTP" != "200" ]]; then
    echo "delete_rule=fail http=$DELETE_RULE_HTTP"
    cat "$DELETE_RULE_RES"
    exit 1
  fi
  echo "delete_rule=ok"

CREATE_EVAL_ID="$(jq -r '.id // empty' "$CREATE_EVAL_RES")"
if [[ -n "$CREATE_EVAL_ID" ]]; then
  curl -sS -u "$PUBLIC_KEY:$SECRET_KEY" -X DELETE \
    --max-time "$HTTP_TIMEOUT" \
    -o /dev/null -w '%{http_code}' \
    "$BASE_URL/api/public/unstable/evaluators/$CREATE_EVAL_ID" >/dev/null || true
fi

echo "PASS: llm-as-a-judge workflow verified"
