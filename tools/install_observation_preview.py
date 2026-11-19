"""Install only the reviewed current reports; preserve all other history."""
import json
import sqlite3
from datetime import datetime, timedelta

from app.database import init_db
from app.observations import VERSION, validate_report
from app.openai_service import _upsert_insight

source = sqlite3.connect("file:/data/observations-preview-20261103.db?mode=ro", uri=True)
source.row_factory = sqlite3.Row
today = datetime.now().strftime("%Y-%m-%d")
yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
rows = source.execute(
    "SELECT * FROM ai_insights WHERE prompt_version=? AND "
    "((time_slot='sleep' AND date=?) OR (time_slot='weekly' AND date=?))",
    (VERSION, today, yesterday),
).fetchall()
if len(rows) != 2:
    raise SystemExit("Expected exactly two reviewed current reports")
for row in rows:
    validate_report(json.loads(row["report_json"]), row["time_slot"] == "weekly")
init_db()
for row in rows:
    _upsert_insight(row["date"], row["time_slot"], row["title"], row["content"], row["category"],
                    report=json.loads(row["report_json"]), input_hash=row["input_hash"],
                    input_json=row["input_json"], prompt_version=row["prompt_version"])
print("Installed two reviewed current reports; historical reports retained")
