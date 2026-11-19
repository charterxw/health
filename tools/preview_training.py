"""Preview a workout report in an isolated DB, then install the reviewed row."""
import json
import os
from pathlib import Path
import sqlite3
import sys
from datetime import datetime

from app import database
from app.observations import render_text, validate_report
from app.training_observations import VERSION, generate_training_observation

preview = "/data/training-preview-20261103.db"
if "--install-reviewed" in sys.argv:
    source = sqlite3.connect(f"file:{preview}?mode=ro", uri=True)
    source.row_factory = sqlite3.Row
    date = datetime.now().strftime("%Y-%m-%d")
    row = source.execute("SELECT * FROM training_analysis WHERE date=? AND prompt_version=? ORDER BY id DESC LIMIT 1",
                         (date, VERSION)).fetchone()
    if row is None:
        raise SystemExit("No reviewed current workout report")
    report = validate_report(json.loads(row["report_json"]), weekly=True)
    if len(report["findings"]) > 2 or len(render_text(report)) > 300:
        raise SystemExit("Workout report exceeds the display contract")
    database.init_db()
    columns = ["date", "summary", "trends", "risks", "recommendations", "provider", "model",
               "report_json", "input_hash", "input_json", "prompt_version"]
    with database.get_db() as conn:
        conn.execute("DELETE FROM training_analysis WHERE date=?", (date,))
        conn.execute(f"INSERT INTO training_analysis ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})",
                     [row[k] for k in columns])
        conn.commit()
    print("Reviewed workout report installed; older training history retained")
else:
    if Path(preview).exists():
        raise SystemExit("Preview database already exists")
    source = sqlite3.connect("file:/data/fitness.db?mode=ro", uri=True)
    target = sqlite3.connect(preview)
    source.backup(target)
    source.close()
    target.close()
    os.chmod(preview, 0o600)
    database.DB_PATH = preview
    database.init_db()
    report = generate_training_observation(force=True, notify=False)
    print(json.dumps(report, ensure_ascii=False, indent=2))
