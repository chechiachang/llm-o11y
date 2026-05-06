# llm-o11y

LLM observability demo: Bifrost + Langfuse.

## Quick start

```bash
export AZURE_ENDPOINT=https://your-resource.openai.azure.com/
export AZURE_OPENAI_API_KEY=xxx
docker compose up -d postgres redis minio clickhouse langfuse-web langfuse-worker bifrost
```

Optional provider:

```bash
export OPENAI_API_KEY=xxx
```

Langfuse OTEL auth header for Bifrost (recommended: set in shell/.env, do not hardcode in JSON):

```bash
export LANGFUSE_OTEL_AUTH='Basic BASE64(pk:sk)'
export LANGFUSE_OTEL_INGESTION_VERSION=4
```

## Local E2E test: Bifrost -> LLM -> Langfuse observations

Run services:

```bash
docker compose up -d postgres redis minio clickhouse langfuse-web langfuse-worker bifrost
```

Required env (Azure path):

```bash
export AZURE_OPENAI_API_KEY=xxx
export AZURE_ENDPOINT=https://your-resource.openai.azure.com/
```

Optional alternative provider:

```bash
export OPENAI_API_KEY=xxx
```

Run test script:

```bash
./scripts/test-bifrost-langfuse-e2e.sh
```

Checks:
- Bifrost LLM request
- LLM response
- Langfuse observation input/output match marker

Defaults:
- `BIFROST_MODEL=azure/gpt-5.4-nano` (`provider/model` format required)
- `LANGFUSE_PUBLIC_KEY=pk-00000000`
- `LANGFUSE_SECRET_KEY=sk-00000000`

## Langfuse bootstrap (optional)

```bash
cp data/langfuse/bootstrap.example.json data/langfuse/bootstrap.json
export LANGFUSE_BASE_URL=http://localhost:3000
export LANGFUSE_PUBLIC_KEY=pk-00000000
export LANGFUSE_SECRET_KEY=sk-00000000
./scripts/bootstrap-langfuse-connections.sh data/langfuse/bootstrap.json
./scripts/bootstrap-langfuse-evaluator.sh data/langfuse/bootstrap.json
./scripts/verify-langfuse-llm-judge-workflow.sh data/langfuse/bootstrap.json
```

Notes:
- Bifrost OTEL config: `data/bifrost/config.json` (`plugins[].name="otel"`).
- Langfuse blocks localhost/private URLs for managed LLM connections.
- OTEL auth header is read from env: `LANGFUSE_OTEL_AUTH`.
- If verify output has `unstable_evaluators_api=unsupported`, current Langfuse build lacks unstable evaluator API.

## Tracing best-practice choices in this repo

- Keep model + token + hierarchy via Bifrost OTEL plugin.
- Keep secrets in env only (`LANGFUSE_OTEL_AUTH`), not committed JSON.
- Keep ingestion version explicit (`x-langfuse-ingestion-version=4`).
- Keep user prompt redaction in local CLI configs unless explicitly needed.

## LLM CLI config examples

- OpenCode example: `./opencode.json`
- Codex CLI example: `./.codex/config.toml`

Recommended:
- keep local base URL = `http://localhost:8080/v1` (Bifrost)
- keep secrets in env vars only
