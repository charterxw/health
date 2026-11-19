Run this on your pi:
```bash
docker compose exec backend python -c "import asyncio, json; from app.google_health import _list_sleep, _load_tokens; _load_tokens(); print(json.dumps(asyncio.run(_list_sleep(1)), indent=2))"
```
