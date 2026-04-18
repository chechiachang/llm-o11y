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
