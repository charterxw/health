Run this on your pi to dump the raw duplicates for July 15:
```bash
docker compose exec backend python -c "import asyncio, json; from app.google_health import _list_sleep, _load_tokens; _load_tokens(); data = asyncio.run(_list_sleep(5)); jul15 = [d for d in data if d.get('sleep',{}).get('interval',{}).get('startTime','').startswith('2026-07-15')]; print(f'Count: {len(jul15)}'); print(json.dumps(jul15, indent=2))"
```
