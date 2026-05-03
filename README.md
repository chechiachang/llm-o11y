# llm-o11y

Demonstration of LLM observability with Bifrost and Langfuse.

## Bifrost

Set env vars in your shell, then start the service:

Azure OpenAI
```bash
export AZURE_ENDPOINT=https://your-resource.openai.azure.com/
export AZURE_OPENAI_API_KEY=xxx
docker compose up -d bifrost
```

OPENAI
```bash
export OPENAI_API_KEY=xxx
docker compose up -d bifrost
```

## Langfuse

Langfuse OTEL (local)
```text
Default Langfuse project keys in docker-compose.yml:
- LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-00000000
- LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-00000000
```

Bifrost OTEL export is configured in `data/bifrost/config.json` under `plugins[].name = "otel"`.

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

Note: `BIFROST_MODEL` must be `provider/model` format (default: `azure/gpt-5.4-nano`).

The script verifies:
- LLM request sent to Bifrost
- LLM response returned
- Matching Langfuse observation contains same marker in input/output

## Bootstrap Langfuse setup from config

Copy the example and edit:

```bash
cp data/langfuse/bootstrap.example.json data/langfuse/bootstrap.json
```

Set API keys for Langfuse Public API auth (project keys):

```bash
export LANGFUSE_BASE_URL=http://localhost:3000
export LANGFUSE_PUBLIC_KEY=pk-00000000
export LANGFUSE_SECRET_KEY=sk-00000000
./scripts/bootstrap-langfuse-connections.sh data/langfuse/bootstrap.json
./scripts/bootstrap-langfuse-evaluator.sh data/langfuse/bootstrap.json
```

Note: the evaluator script bootstraps score config only. Managed LLM-as-a-judge evaluator definitions are created in Langfuse UI.

Default example connection is `azure`:
- `adapter`: `azure`
- `baseURL`: set to your azure resource URL
- `customModels`: `gpt-5.4-mini`
- `secretKey`: optional for local Bifrost. If omitted/unset, bootstrap script auto-uses `bifrost-noauth`.

Important: Langfuse LLM connections reject `localhost` and private-network base URLs.
If you see `Invalid baseURL: Blocked hostname/IP`, expose Bifrost through a public HTTPS URL and use that URL in `baseURL`.
