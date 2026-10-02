#!/usr/bin/env python3
"""Direct timing mapping for the course ABC executable.

Reuse Yosys's exact BLIF and Liberty inputs. Avoid its expensive speculative
fraiging pass; apply the reference design's mapping/buffering/sizing recipe.
The final physical fanout tree is checked separately by buffer_timing.py.
"""
import os
from pathlib import Path
import re
import subprocess
import sys

abc=Path(os.environ['CPU2026_APPDIR'])/'bin/yosys-abc'
args=sys.argv[1:]
if '-f' not in args:
    raise SystemExit(subprocess.call([str(abc),*args]))
position=args.index('-f')+1
original=Path(args[position]);text=original.read_text()
reads=[line for line in text.splitlines() if re.match(r'\s*read_(?:blif|lib)\b',line)]
write=[line for line in text.splitlines() if re.match(r'\s*write_blif\b',line)]
if not reads or len(write)!=1:raise RuntimeError('unexpected ABC input script')
delay=re.search(r'&nf\s+-D\s+([0-9.eE+-]+)',text)
delay=delay[1] if delay else '2000'
recipe=['strash;','&get -n;',f'&nf -D {delay};','&put;','buffer -p -N 8 -S 100;',f'upsize -D {delay} -T 10;']
script=original.with_name('area-v2-direct.abc');script.write_text('\n'.join([*reads,*recipe,*write])+'\n')
args[position]=str(script)
raise SystemExit(subprocess.call([str(abc),*args]))
