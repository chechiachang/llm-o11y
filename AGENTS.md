# AGENTS

Main instruction index for this repo.
All instructions and skills must be compact and extremely minimal.

## Hard Rules
- Keep outputs short, actionable, and minimal.
- Never ask approval. Execute directly with the safest reasonable default.
- Ask only if blocked by missing required secret/credential/account value.
- Use repo-local `./tmp` for temporary files; do not use OS-wide temp directories.

## Index
- `skills/docker.md`
- `skills/docker-health.md`

## Upgrade + Verify (Docker Compose)
- Example Langfuse bump: `3.169.0 -> 3.172.1` in `docker-compose.yml` for:
  - `langfuse-web` image tag
  - `langfuse-worker` image tag
- Apply:
  - `docker compose pull langfuse-web langfuse-worker`
  - `docker compose up -d langfuse-web langfuse-worker`
- Verify version:
  - `curl -fsS http://localhost:3000/api/public/health | jq .`
  - Expect `"version": "3.172.1"` (or target version)
- Verify integration:
  - `docker compose up -d postgres redis minio clickhouse langfuse-web langfuse-worker bifrost`
  - `./scripts/test-bifrost-langfuse-e2e.sh`
- Verify evaluator bootstrap/workflow:
  - `./scripts/bootstrap-langfuse-evaluator.sh data/langfuse/bootstrap.example.json`
  - `./scripts/verify-langfuse-llm-judge-workflow.sh data/langfuse/bootstrap.example.json`
  - If output has `unstable_evaluators_api=unsupported`, current Langfuse build lacks unstable evaluator API.

## Actions
- `./actions` = issues found from observing LLM traces + observations and their corresponding actionable fixes.
- Maintain action index in `./actions/README.md`.
