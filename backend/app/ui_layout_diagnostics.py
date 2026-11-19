"""Temporary, authenticated view-geometry diagnostics; no page text or health data."""
import json
import os
from pathlib import Path
import tempfile
from threading import Lock
import time
from typing import Literal
from uuid import UUID

from fastapi import APIRouter
from pydantic import BaseModel, ConfigDict, Field

router = APIRouter(prefix='/api/ui', tags=['ui'])
PATH = Path('/data/ui-layout-diagnostics.json')
LOCK = Lock()
TTL = 900

class Sample(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    stage: Literal['before','settled','resize','closing','closed']
    elapsed_ms: float = Field(ge=0,le=120000)
    inner_height: float
    inner_width: float
    outer_height: float
    client_height: float
    visual_height: float | None
    visual_offset_top: float | None
    visual_page_top: float | None
    visual_scale: float | None
    root_top: float | None
    root_height: float | None
    root_translate_y: float | None
    page_top: float | None
    page_height: float | None
    heading_top: float | None
    scroll_top: float | None
    window_scroll_y: float

class Report(BaseModel):
    model_config = ConfigDict(extra='forbid')
    build: Literal['dialog-diagnostics-20261118']
    cycle: UUID
    native_chrome: bool
    bottom_overlay: bool
    samples: list[Sample] = Field(min_length=1,max_length=24)

def read_recent():
    try:
        return [r for r in json.loads(PATH.read_text()) if time.time()-r['received_at']<TTL]
    except (OSError, ValueError, KeyError, TypeError):
        return []

@router.post('/layout-diagnostics', status_code=204)
def save_report(report: Report):
    with LOCK:
        reports=[r for r in read_recent() if r['report']['cycle']!=str(report.cycle)]
        reports.append({'received_at':time.time(),'report':report.model_dump(mode='json')})
        with tempfile.NamedTemporaryFile(mode='w',dir=PATH.parent,delete=False) as f:
            temp=f.name
            os.chmod(temp,0o600)
            json.dump(reports[-10:],f,separators=(',',':'))
        os.replace(temp,PATH)
