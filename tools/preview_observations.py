"""Run the new analysis against an isolated database before deployment.

Run inside the new backend image with the existing data/secrets volumes mounted.
No notifications are sent. The source database is opened read-only.
"""
import json
import os
import sqlite3
from datetime import datetime
from pathlib import Path

from app import database, observations

preview_path = "/data/observations-preview-20261103.db"
if Path(preview_path).exists():
    raise SystemExit("Preview database already exists; select a new explicit path")
source = sqlite3.connect("file:/data/fitness.db?mode=ro", uri=True)
target = sqlite3.connect(preview_path)
source.backup(target)
source.close()
target.close()
os.chmod(preview_path, 0o600)
database.DB_PATH = preview_path
database.init_db()

daily = observations.generate_sleep_observation(force=True, notify=False)
weekly = observations.generate_weekly_observation(force=True, notify=False)
for name, item in (("daily", daily), ("weekly", weekly)):
    print(json.dumps({"kind": name, "content": item["content"], "report": item["report"]}, ensure_ascii=False), flush=True)

# Exercise the weekly model contract on a prior, fully populated seven-day period.
history = observations.load_sleep(60)
context = observations.weekly_context(history, "2026-10-25", [])
if context["valid_nights"] >= 3:
    sample = observations._save_report("weekly", "2026-10-25", "每周观察", context,
                                       weekly=True, force=True, notify=False)
    print(json.dumps({"kind": "weekly_contract_sample", "content": sample["content"],
                      "report": sample["report"]}, ensure_ascii=False), flush=True)
