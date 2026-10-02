#!/usr/bin/env python3
"""Prove all 65 input bits of the prefix adder against unsigned addition."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT.parent/"scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool

enter_appimage(DEFAULT_APPIMAGE)
rtl = PROJECT/"build/adder-proof/AdderProof.sv"
out = PROJECT/"reports/validation/adder"
out.mkdir(parents=True,exist_ok=True)
recipe = (f'read_verilog -sv "{rtl}"; hierarchy -top AdderProof; proc; '
          'setattr -mod -unset keep_hierarchy; flatten; opt; '
          'sat -verify -prove correct 1 -show-inputs -show-outputs')
with (out/"proof.log").open("w") as log:
    subprocess.run([packaged_tool("yosys"),"-Q","-T","-p",recipe],stdout=log,stderr=subprocess.STDOUT,check=True)
sources = [PROJECT/"src/main/scala/tier2/Adder.scala",PROJECT/"src/test/scala/tier2/AdderProof.scala",rtl]
(out/"result.json").write_text(json.dumps({"status":"proved","input_bits":65,
    "property":"sum == (a + b + cin) modulo 2^32",
    "sha256":{str(p.relative_to(PROJECT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}},indent=2)+"\n")
print("All 65 input bits proved: prefix sum equals a+b+cin modulo 2^32")
