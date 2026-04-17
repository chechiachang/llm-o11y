# Docker Skill

## Steps
1. Start: `docker compose up -d`
2. Status: `docker compose ps`
3. Logs: `docker compose logs --tail=200`
4. Health checks:
   - Bifrost: `curl -fsS http://localhost:3000/health`
   - Langfuse: `curl -fsS http://localhost:3001/api/public/health`
