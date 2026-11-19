Run this on your pi to delete today's sleep insight and trigger a regeneration:
```bash
docker compose exec backend sqlite3 fitness.db "DELETE FROM ai_insights WHERE date = date('now') AND title = 'Deep Sleep Analysis';"
```
