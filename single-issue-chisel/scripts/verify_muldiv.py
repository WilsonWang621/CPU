#!/usr/bin/env python3
"""Check actual Chisel MDU arithmetic, result caching and cancellation against C++."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(PROJECT.parent/"scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool

def run(command, log, cwd):
    with log.open("w") as f:
        subprocess.run([str(x) for x in command],cwd=cwd,stdout=f,stderr=subprocess.STDOUT,check=True)

def main():
    enter_appimage(DEFAULT_APPIMAGE)
    out = PROJECT/"reports/validation/muldiv"
    build = PROJECT/"build/muldiv-validation"
    out.mkdir(parents=True,exist_ok=True)
    generator = build/"generator"
    scala = generator/"src/main/scala/tier2"
    scala.mkdir(parents=True,exist_ok=True)
    sources = list((PROJECT/"src/main/scala/tier2").glob("*.scala"))
    sources += [PROJECT/"src/test/scala/tier2/MulDivHarness.scala"]
    source_hashes = {}
    for p in scala.glob("*.scala"): p.unlink()
    for p in sources: shutil.copy2(p,scala/p.name)
    for p in sources:
        source_hashes[str(p.relative_to(PROJECT))] = hashlib.sha256((scala/p.name).read_bytes()).hexdigest()
    shutil.copy2(PROJECT/"build.sbt",generator/"build.sbt")
    (generator/"project").mkdir(exist_ok=True)
    shutil.copy2(PROJECT/"project/build.properties",generator/"project/build.properties")
    cpp = PROJECT/"tests/muldiv_test.cpp"
    shutil.copy2(cpp,build/cpp.name)
    source_hashes[str(cpp.relative_to(PROJECT))] = hashlib.sha256((build/cpp.name).read_bytes()).hexdigest()
    results=[]
    for bits,cache in ((1,0),(2,0),(1,1),(2,1)):
        name=f"step{bits}-cache{cache}"; candidate=build/name
        rtl=candidate/"rtl"; obj=candidate/"obj"
        run([Path.home()/".local/bin/sbt","-batch",f"runMain tier2.GenerateMulDivHarness {rtl} {bits} {cache}"],out/(name+"-generate.log"),generator)
        run([packaged_tool("verilator"),"--cc","--exe","--build","--top-module","MulDivHarness","-Wno-fatal","-O3","-j","2","--Mdir",obj,rtl/"MulDivHarness.sv",build/cpp.name],out/(name+"-build.log"),PROJECT)
        proc=subprocess.run([str(obj/"VMulDivHarness"),str(bits),str(cache)],text=True,capture_output=True)
        (out/(name+"-test.log")).write_text(proc.stdout+proc.stderr)
        proc.check_returncode()
        result={"div_step_bits":bits,"div_result_cache":cache,**json.loads(proc.stdout)}
        result["rtl_sha256"]=hashlib.sha256((rtl/"MulDivHarness.sv").read_bytes()).hexdigest()
        results.append(result);print(name,result,flush=True)
    (out/"result.json").write_text(json.dumps({"status":"passed","variants":results,"source_sha256":source_hashes},indent=2)+"\n")

if __name__ == "__main__": main()
