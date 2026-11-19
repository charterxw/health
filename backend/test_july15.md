Run this on your pi:
```bash
docker compose exec backend python -c "import asyncio, json; from app.google_health import get_sleep_history, _load_tokens; _load_tokens(); data = asyncio.run(get_sleep_history(5)); jul15 = [d for d in data if d['date'] == '2026-07-15']; print(f'Count: {len(jul15)}'); print(json.dumps(jul15, indent=2))"
```
