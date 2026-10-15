#!/usr/bin/env python3
"""Freeze exactly the RTL supplied to the native course synthesis flow."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from build import read_sources
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--out',type=Path,required=True)
p.add_argument('--filelist',type=Path,default=ROOT/'verilog/filelist.f')
a=p.parse_args()
sources=read_sources(a.filelist)
contents={p.name:p.read_bytes() for p in sources}
if len(contents)!=len(sources):raise ValueError('duplicate basenames')
hashes={n:hashlib.sha256(v).hexdigest() for n,v in contents.items()}
identity=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()[:16]
out=a.out/identity;out.mkdir(parents=True,exist_ok=True)
for n,data in contents.items():
    target=out/n
    if target.exists() and target.read_bytes()!=data:raise ValueError('snapshot collision')
    target.write_bytes(data)
(out/'filelist.f').write_text('\n'.join(contents)+'\n')
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
print(out.resolve()/'filelist.f')
