import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4
from pydantic import ValidationError
from app import ui_layout_diagnostics as ui

class LayoutDiagnostics(unittest.TestCase):
    def sample(self):
        return dict(stage='before',elapsed_ms=0,inner_height=734,inner_width=402,outer_height=874,
                    client_height=734,visual_height=734,visual_offset_top=0,visual_page_top=0,
                    visual_scale=1,root_top=0,root_height=734,root_translate_y=0,page_top=0,
                    page_height=734,heading_top=8,scroll_top=0,window_scroll_y=0)
    def report(self,**extra):
        return ui.Report.model_validate(dict(build='dialog-diagnostics-20261118',cycle=str(uuid4()),
                                       native_chrome=True,bottom_overlay=True,samples=[self.sample()],**extra))
    def test_no_page_text_or_health_fields_are_accepted(self):
        with self.assertRaises(ValidationError):self.report(page_text='not allowed')
        with self.assertRaises(ValidationError):ui.Sample.model_validate({**self.sample(),'hrv':25})
    def test_cycle_updates_replace_and_retention_is_bounded(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(ui,'PATH',Path(folder)/'layout.json'):
            first=self.report();ui.save_report(first);ui.save_report(first)
            self.assertEqual(len(ui.read_recent()),1)
            for _ in range(15):ui.save_report(self.report())
            self.assertEqual(len(ui.read_recent()),10)
            self.assertEqual(ui.PATH.stat().st_mode&0o777,0o600)
            with patch.object(ui.time,'time',lambda:__import__('time').monotonic()+10**12):
                self.assertEqual(ui.read_recent(),[])
