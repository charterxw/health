#!/usr/bin/env python3
"""Convert the current web catalog's MuscleMap geometry into native path commands.
Build-time dependency: fonttools==4.60.1. No SVG/JavaScript parser ships in the app.
"""
import hashlib
import json
import re
from pathlib import Path
from fontTools.pens.basePen import BasePen
from fontTools.svgLib.path import parse_path

ROOT=Path(__file__).resolve().parents[2]
source=ROOT/'frontend/src/training/vendor/body-paths.js'
geometry=json.loads(source.read_text().split('export default ',1)[1].strip().rstrip(';'))
class NativePen(BasePen):
    def __init__(self):super().__init__(None);self.commands=[]
    def _moveTo(self,p):self.commands.append(['M',*p])
    def _lineTo(self,p):self.commands.append(['L',*p])
    def _curveToOne(self,a,b,p):self.commands.append(['C',*a,*b,*p])
    def _qCurveToOne(self,a,p):self.commands.append(['Q',*a,*p])
    def _closePath(self):self.commands.append(['Z'])
    def _endPath(self):pass

result={}
for gender,sides in geometry.items():
 result[gender]={}
 for side,view in sides.items():
  parts={}
  for part,paths in view['p'].items():
   pen=NativePen()
   for path in paths:parse_path(re.sub(r"([zZ])(?:\s*[zZ])+", r"\1", path),pen)
   parts[part]=[[c[0],*[round(float(v),5) for v in c[1:]]] for c in pen.commands]
  result[gender][side]={'vb':[float(v) for v in view['vb'].split()],'parts':parts}
result['source_sha256']=hashlib.sha256(source.read_bytes()).hexdigest()
output=ROOT/'ios/App/Resources/MusclePaths.json';output.parent.mkdir(parents=True,exist_ok=True)
output.write_text(json.dumps(result,separators=(',',':'))+'\n')
print('Generated native geometry for all four views:',output)
