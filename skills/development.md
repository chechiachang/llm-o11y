# Development Skill

## Rules
- Be concise.
- Do only what is asked.
- Prefer safe, non-destructive actions.
- Use repo-local `./tmp` for temp files.

## Upgrade + Verify (Docker Compose)
- Bump `langfuse-web` + `langfuse-worker` in `docker-compose.yml`.
- Apply:
  - `docker compose pull langfuse-web langfuse-worker`
  - `docker compose up -d langfuse-web langfuse-worker`
- Verify version:
  - `curl -fsS http://localhost:3000/api/public/health | jq .`
- Verify integration:
  - `docker compose up -d postgres redis minio clickhouse langfuse-web langfuse-worker bifrost`
  - `./scripts/test-bifrost-langfuse-e2e.sh`
- Verify evaluator workflow:
  - `./scripts/bootstrap-langfuse.sh data/langfuse/bootstrap.example.json`
  - `unstable_evaluators_api=unsupported` => build lacks unstable evaluator API
