#!/usr/bin/env python3
"""Prove sum-before-bypass selection equals the original operand plus immediate."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT.parent/"scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool

def main():
    enter_appimage(DEFAULT_APPIMAGE)
    out=PROJECT/"reports/validation/dispatch-address"
    build=PROJECT/"build/dispatch-address-proof"
    generator=build/"generator";scala=generator/"src/main/scala/tier2"
    out.mkdir(parents=True,exist_ok=True);scala.mkdir(parents=True,exist_ok=True)
    sources=list((PROJECT/"src/main/scala/tier2").glob("*.scala"))+[PROJECT/"src/test/scala/tier2/DispatchAddressProof.scala"]
    source_hashes={}
    for p in scala.glob("*.scala"):p.unlink()
    for p in sources:shutil.copy2(p,scala/p.name)
    for p in sources:
        source_hashes[str(p.relative_to(PROJECT))]=hashlib.sha256((scala/p.name).read_bytes()).hexdigest()
    shutil.copy2(PROJECT/"build.sbt",generator/"build.sbt")
    (generator/"project").mkdir(exist_ok=True)
    shutil.copy2(PROJECT/"project/build.properties",generator/"project/build.properties")
    rtl=build/"rtl"
    with (out/"generate.log").open("w") as log:
        subprocess.run([str(Path.home()/".local/bin/sbt"),"-batch",f"runMain tier2.GenerateDispatchAddressProof {rtl}"],cwd=generator,stdout=log,stderr=subprocess.STDOUT,check=True)
    recipe=(f'read_verilog -sv "{rtl}/DispatchAddressProof.sv"; hierarchy -top DispatchAddressProof; proc; '
            'setattr -mod -unset keep_hierarchy; flatten; opt; sat -verify -prove correct 1 -show-inputs -show-outputs')
    with (out/"proof.log").open("w") as log:
        subprocess.run([packaged_tool("yosys"),"-Q","-T","-p",recipe],stdout=log,stderr=subprocess.STDOUT,check=True)
    generated=rtl/"DispatchAddressProof.sv"
    source_hashes[str(generated.relative_to(PROJECT))]=hashlib.sha256(generated.read_bytes()).hexdigest()
    (out/"result.json").write_text(json.dumps({"status":"proved","input_bits":218,"property":"parallel candidate sums with first matching CDB priority == selected dispatch operand + immediate modulo 2^32","sha256":source_hashes},indent=2)+"\n")
    print("All 218 input bits proved: parallel address equals dispatch operand + immediate",flush=True)

if __name__ == "__main__":main()
