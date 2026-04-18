# Docker Health Skill

## Checks
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
