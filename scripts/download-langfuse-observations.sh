#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[download-observations] $*"
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
MAX_PAGES="${LANGFUSE_MAX_PAGES:-10}"
PROJECT_NAME="${1:-${LANGFUSE_PROJECT_NAME:-default}}"
OUT_FILE="${2:-}"

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
RUN_DIR="./tmp/langfuse-observations-${RUN_ID}"
mkdir -p "$RUN_DIR"
log "start"
log "base_url=$BASE_URL"
log "project_name=$PROJECT_NAME"
log "page_limit=$LIMIT"
log "max_pages=$MAX_PAGES"
log "run_dir=$RUN_DIR"

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

if [[ -z "$OUT_FILE" ]]; then
  if [[ -n "$PROJECT_NAME" ]]; then
    OUT_FILE="./tmp/langfuse-observations-$(slugify "$PROJECT_NAME")-${RUN_ID}.json"
  else
    OUT_FILE="./tmp/langfuse-observations-all-${RUN_ID}.json"
  fi
fi

PROJECT_ID=""
PROJECTS_FILE="$RUN_DIR/projects.json"
log "auth check + list projects"
AUTH_HTTP="$(
  curl -sS \
    -u "$PUBLIC_KEY:$SECRET_KEY" \
    -o "$PROJECTS_FILE" \
    -w '%{http_code}' \
    "$BASE_URL/api/public/projects"
)"
if [[ "$AUTH_HTTP" != "200" ]]; then
  msg="$(jq -r '.message // empty' "$PROJECTS_FILE" 2>/dev/null || true)"
  echo "auth failed: status=$AUTH_HTTP base_url=$BASE_URL" >&2
  [[ -n "$msg" ]] && echo "$msg" >&2
  exit 1
fi

if [[ -n "$PROJECT_NAME" ]]; then
  PROJECT_ID="$(jq -r --arg name "$PROJECT_NAME" '.data[] | select(.name == $name) | .id' "$PROJECTS_FILE" | head -n1)"
  if [[ -z "$PROJECT_ID" ]]; then
    echo "project not found: $PROJECT_NAME" >&2
    echo "available projects:" >&2
    jq -r '.data[].name' "$PROJECTS_FILE" >&2
    exit 1
  fi
  log "project_id=$PROJECT_ID"
fi

TMP_OUT="$RUN_DIR/observations.json"
echo '[]' >"$TMP_OUT"

page=1
total=0
used_project_filter=true
truncated=false

while true; do
  PAGE_FILE="$RUN_DIR/page-${page}.json"

  url="$BASE_URL/api/public/observations?page=${page}&limit=${LIMIT}"
  if [[ -n "$PROJECT_ID" && "$used_project_filter" == "true" ]]; then
    url+="&projectId=${PROJECT_ID}"
  fi

  http_code="$(
    curl -sS \
      -u "$PUBLIC_KEY:$SECRET_KEY" \
      -o "$PAGE_FILE" \
      -w '%{http_code}' \
      "$url"
  )"

  if [[ "$http_code" != "200" ]]; then
    if [[ "$page" -eq 1 && "$used_project_filter" == "true" && -n "$PROJECT_ID" ]]; then
      log "projectId query unsupported; fallback to client-side filter"
      used_project_filter=false
      continue
    fi
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

  jq -s '.[0] + .[1].data' "$TMP_OUT" "$PAGE_FILE" >"$RUN_DIR/merge.json"
  mv "$RUN_DIR/merge.json" "$TMP_OUT"

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

if [[ "$used_project_filter" == "false" && -n "$PROJECT_ID" ]]; then
  log "apply client-side project filter"
  jq --arg pid "$PROJECT_ID" '
    map(select((.projectId // "") == $pid))
  ' "$TMP_OUT" >"$RUN_DIR/filtered.json"
  mv "$RUN_DIR/filtered.json" "$TMP_OUT"
  total="$(jq 'length' "$TMP_OUT")"
fi

jq -n \
  --arg baseUrl "$BASE_URL" \
  --arg projectName "$PROJECT_NAME" \
  --arg projectId "$PROJECT_ID" \
  --arg fetchedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson count "$total" \
  --argjson maxPages "$MAX_PAGES" \
  --argjson pageLimit "$LIMIT" \
  --argjson truncated "$truncated" \
  --argjson pagesFetched "$page" \
  --slurpfile observations "$TMP_OUT" \
  '{
    meta: {
      baseUrl: $baseUrl,
      projectName: ($projectName | select(length > 0)),
      projectId: ($projectId | select(length > 0)),
      fetchedAt: $fetchedAt,
      count: $count,
      pageLimit: $pageLimit,
      maxPages: $maxPages,
      pagesFetched: $pagesFetched,
      truncated: $truncated
    },
    observations: ($observations[0] // [])
  }' >"$OUT_FILE"

echo "saved: $OUT_FILE"
echo "observations: $total"
log "done"
