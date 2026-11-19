import asyncio
import json
from app.google_health import _list_sleep, _load_tokens

async def main():
    _load_tokens()
    data = await _list_sleep(1)
    print(json.dumps(data, indent=2))

asyncio.run(main())
