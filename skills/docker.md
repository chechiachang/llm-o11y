# Docker Skill

## Steps
1. Clean down: `docker compose down -v`
2. Clean up: `docker compose up -d`
3. Reset all: `docker compose down -v --remove-orphans && docker rm -f bifrost 2>/dev/null || true`
4. Fresh start all: `docker compose up -d`
5. Start bifrost only: `docker compose up -d bifrost || docker start bifrost`
6. Start core services: `docker compose up -d langfuse-web langfuse-worker minio clickhouse redis postgres`
7. Status (all): `docker compose ps`
8. Status (bifrost): `docker ps --filter name='^/bifrost$'`
9. Logs (bifrost): `docker logs --tail=200 bifrost`
10. Logs (langfuse-web): `docker logs --tail=200 $(docker compose ps -q langfuse-web)`
11. Logs (langfuse-worker): `docker logs --tail=200 $(docker compose ps -q langfuse-worker)`
12. Logs (minio): `docker logs --tail=200 $(docker compose ps -q minio)`
13. Logs (clickhouse): `docker logs --tail=200 $(docker compose ps -q clickhouse)`
14. Logs (redis): `docker logs --tail=200 $(docker compose ps -q redis)`
15. Logs (postgres): `docker logs --tail=200 $(docker compose ps -q postgres)`
