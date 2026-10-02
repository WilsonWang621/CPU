#!/usr/bin/env python3
"""Build the complete Area-v2 CPU against the unchanged retirement harness."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SHARED = ["cpu_pkg.sv", "decoder.sv", "alu.sv", "branch_unit.sv", "muldiv.sv", "memory_controller.sv"]
LOCAL = ["cpu_top.sv", "v2_frontend.sv", "v2_dcache.sv", "v2_rename.sv", "v2_select.sv"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/cpu")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--cxx", default="clang++")
    parser.add_argument("--lint", action="store_true")
    parser.add_argument("--verify", action="store_true", help="enable expensive internal invariants and event coverage")
    parser.add_argument("--param", action="append", default=[])
    parser.add_argument("--verilator", type=Path, default=ROOT / "build/tools/oss-cad-suite/bin/verilator")
    args = parser.parse_args()
    version = subprocess.check_output([str(args.verilator), "--version"], text=True).strip()
    parsed_version = re.search(r"Verilator (\d+)\.(\d+)", version)
    modern_groups = parsed_version and (int(parsed_version[1]), int(parsed_version[2])) >= (5, 50)
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    contents = {"rtl/" + n: (ROOT / "rtl" / n).read_bytes() for n in SHARED}
    contents.update({"rtl/" + n: (HERE / "rtl" / n).read_bytes() for n in LOCAL})
    contents.update({"sim/" + n: (ROOT / "sim" / n).read_bytes() for n in ("main.cpp", "memory_model.h")})
    hashes = {n: hashlib.sha256(data).hexdigest() for n, data in contents.items()}
    identity = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:16]
    snapshot = directory / ("source-" + identity)
    for name, data in contents.items():
        path = snapshot / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.read_bytes() != data:
            raise RuntimeError("Source snapshot collision: " + str(path))
        path.write_bytes(data)
    sources = [snapshot / "rtl/cpu_pkg.sv"] + sorted(p for p in (snapshot / "rtl").glob("*.sv") if p.name != "cpu_pkg.sv")
    command = [str(args.verilator), "--top-module", "cpu_top", "--assert", "-O3", "-Wall",
               "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM", "-Wno-PINCONNECTEMPTY",
               "--unroll-count", "1024", "--unroll-stmts", "100000"]
    command += ["-G" + p for p in args.param]
    if "clang" in Path(args.cxx).name:
        command += ["--compiler", "clang"]
    if args.verify:
        command += ["-DV2_VERIFY"]
    if args.lint:
        command += ["--lint-only"]
    else:
        command += ["--cc", "--exe", "--build", "-j", str(args.jobs),
                    "--Mdir", str(directory / "obj"), "-o", str(directory / "cpu_sim"),
                    "-CFLAGS", "-std=c++17", "-MAKEFLAGS", f"CXX={args.cxx} OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1"]
        if modern_groups:
            command += ["--output-groups", "0"]
    command += list(map(str, sources))
    if not args.lint:
        command += [str(snapshot / "sim/main.cpp")]
    start = time.monotonic()
    result = subprocess.run(command, cwd=ROOT)
    metadata = dict(source_root=str(snapshot), sources_sha256=hashes, command=command,
                    parameters=args.param, verification_monitor=args.verify,
                    returncode=result.returncode, seconds=time.monotonic()-start,
                    verilator=version,
                    cxx=subprocess.check_output([args.cxx, "--version"], text=True).splitlines()[0])
    if result.returncode == 0 and not args.lint:
        metadata["binary_sha256"] = hashlib.sha256((directory / "cpu_sim").read_bytes()).hexdigest()
    (directory / ("lint.json" if args.lint else "build.json")).write_text(json.dumps(metadata, indent=2) + "\n")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
