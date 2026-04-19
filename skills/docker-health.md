# Docker Health Skill

## Health Checks
- Bifrost root: `curl -fsS http://localhost:8080/`
- Bifrost health: `curl -fsS http://localhost:8080/health`
- Bifrost version: `curl -fsS http://localhost:8080/api/version`
- Bifrost models: `curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/models`
- Langfuse health: `curl -fsS http://localhost:3000/api/public/health`
- Langfuse UI: `curl -fsS http://localhost:3000/`
- MinIO health: `curl -fsS http://localhost:9002/minio/health/live`
- ClickHouse ping: `curl -fsS http://127.0.0.1:8123/ping`
- Redis ping: `docker exec playgrounds-redis-1 redis-cli -a password ping`
- Postgres ready: `docker exec playgrounds-postgres-1 sh -lc 'pg_isready -U postgres -d postgres'`

## Functionality Tests
- ClickHouse query: `curl -fsS 'http://127.0.0.1:8123/?query=SELECT%201'`
- MinIO bucket list: `curl -sS -o /dev/null -w '%{http_code}\n' -u 'chechia:password' http://localhost:9002/langfuse`
- Redis set/get: `docker exec playgrounds-redis-1 redis-cli -a password SET test-key test-val && docker exec playgrounds-redis-1 redis-cli -a password GET test-key`
- Postgres query: `docker exec playgrounds-postgres-1 psql -U postgres -d postgres -tAc 'SELECT 1'`
- Langfuse auth (default keys): `curl -fsS -u 'pk-00000000:sk-00000000' http://localhost:3000/api/public/projects`
- Langfuse worker health: `curl -fsS http://127.0.0.1:3030/api/public/health`
- Bifrost chat completions: `curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/chat/completions`

## Env Var Coverage Check
Verify all env vars in docker-compose.yml use `${VAR:-default}` syntax (no bare `${VAR}`):
- Check: `sed 's/\$\$/ESCAPED_DOLLAR/g' docker-compose.yml | grep -oE '\$\{[A-Z_0-9]+\}' | tr -d '${}'`
- List all vars with defaults: `grep -oE '\$\{[A-Z_0-9]+:-[^}]*\}' docker-compose.yml | sort -u`
