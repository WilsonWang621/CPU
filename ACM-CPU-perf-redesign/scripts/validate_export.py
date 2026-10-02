#!/usr/bin/env python3
"""Check exported Verilog against a source-matched SystemVerilog simulator."""
import argparse
import concurrent.futures
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from run_tests import run_case
from export_verilog import export

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/final-verilog")
    parser.add_argument("--sv-binary", type=Path, required=True)
    parser.add_argument("--sv-metadata", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=ROOT,
                        help="source tree matching the reference binary; frozen locally before conversion")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    output, reference_binary = args.output.resolve(), args.sv_binary.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reference = json.loads(args.sv_metadata.read_text())
    if "snapshot" in reference:
        snapshot_path = ROOT / reference["snapshot"]
        if sha(snapshot_path) != reference["snapshot_sha256"]:
            raise RuntimeError("Reference source snapshot metadata checksum differs")
        reference = {**json.loads(snapshot_path.read_text()), **reference}
    reference_hashes = reference.get("sources_sha256", reference.get("source_sha256"))
    if reference_hashes is None and "rtl_sha256" in reference:
        reference_hashes = {**reference["rtl_sha256"], **reference.get("harness_sha256", {})}
    if not reference_hashes:
        raise RuntimeError("Reference metadata must identify its measured RTL sources")
    if sha(reference_binary) != reference["binary_sha256"]:
        raise RuntimeError("SystemVerilog reference binary differs from its recorded checksum")
    parameters = reference.get("parameters", {})
    source_root = args.source_root.resolve()
    frozen = output / "source"
    for source in [*sorted((source_root / "rtl").glob("*.sv")),
                   source_root / "sim/main.cpp", source_root / "sim/memory_model.h"]:
        name = str(source.relative_to(source_root))
        if reference_hashes.get(name) != sha(source):
            raise RuntimeError(f"Source mismatch between reference and conversion input: {name}")
        target = frozen / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target != source:
            target.write_bytes(source.read_bytes())
    verilog = output / "cpu.v"
    verilator = ROOT / "RISC-V-CPU-2026-Toolchain/bin/verilator"
    binary = output / "cpu_sim"
    command = [str(verilator), "--cc", "--exe", "--build", "--assert", "-j", str(args.jobs),
               "--top-module", "cpu_top", "--Mdir", str(output / "obj"), "-o", str(binary),
               "--unroll-count", "1024", "--unroll-stmts", "100000", "-Wall",
               "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM", "-Wno-PINCONNECTEMPTY",
               "-Wno-WIDTH", "-Wno-DECLFILENAME", "-Wno-ASCRANGE",
               "-CFLAGS", "-std=c++17", "-MAKEFLAGS", "OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1",
               *[f"-G{name}={value}" for name, value in parameters.items()],
               str(verilog), str(frozen / "sim/main.cpp")]
    if not args.skip_build:
        export(verilog, ROOT / "build/tools/sv2v-Linux/sv2v", frozen)
        with (output / "build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        (output / "build.json").write_text(json.dumps({
            "parameters": parameters, "verilog_sha256": sha(verilog),
            "binary_sha256": sha(binary), "command": command,
            "harness_sha256": {name: sha(frozen / name)
                               for name in ("sim/main.cpp", "sim/memory_model.h")}}, indent=2) + "\n")
    else:
        built = json.loads((output / "build.json").read_text())
        if (built["parameters"] != parameters or built["verilog_sha256"] != sha(verilog)
                or built["binary_sha256"] != sha(binary)
                or any(sha(frozen / name) != value for name, value in built["harness_sha256"].items())):
            raise RuntimeError("Skipped Verilog build does not match recorded source/parameters/binary")
    exported = json.loads(verilog.with_suffix(".metadata.json").read_text())
    if sha(verilog) != exported["output_sha256"]:
        raise RuntimeError("Exported Verilog differs from its recorded checksum")
    for name, expected in exported["sources_sha256"].items():
        if reference_hashes.get(name) != expected or sha(frozen / name) != expected:
            raise RuntimeError(f"RTL source mismatch between export and reference snapshot: {name}")
    subprocess.run([sys.executable, str(ROOT / "tests/system/generate.py"),
                    "--output", str(output / "system-cases"), "--random-cases", "8"], cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT / "tests/core/generate.py"),
                    "--output", str(output / "core-cases")], cwd=ROOT, check=True)
    groups = [("system", output / "system-cases", True),
              ("core", output / "core-cases", True),
              ("performance", ROOT / "RISC-V-CPU-2026-Testcases", False)]
    cases = []
    for group, directory, random_wait in groups:
        pattern = "perf_*/program.data" if group == "performance" else "*/program.data"
        cases += [(group, path.parent, random_wait) for path in sorted(directory.glob(pattern))]
        for variant in ("systemverilog", "verilog"):
            (output / group / variant).mkdir(parents=True, exist_ok=True)

    def compare_case(item):
        group, case, random_wait = item
        measurements = {}
        for variant, simulator in (("systemverilog", reference_binary), ("verilog", binary)):
            options = SimpleNamespace(binary=simulator, output=output / group / variant,
                latency=20, max_cycles=100_000_000, seed=20260925 if random_wait else 1,
                random_wait=7 if random_wait else 0, request_wait=2 if random_wait else 0,
                max_outstanding=64, differential=True, keep_traces=True, timeout=300)
            measurements[variant] = run_case(case, options)
        # Host runtime and RSS can change with generated C++ layout; every
        # simulated event counter, cycle count and fault/result must agree.
        ignored = {"wall_seconds", "peak_rss_kib"}
        left = {key: value for key, value in measurements["systemverilog"].items() if key not in ignored}
        right = {key: value for key, value in measurements["verilog"].items() if key not in ignored}
        if left != right:
            differences = {key: [left.get(key), right.get(key)] for key in left.keys() | right.keys()
                           if left.get(key) != right.get(key)}
            raise RuntimeError(f"Simulation metrics differ: {differences}")
        trace_reference = output / group / "systemverilog" / f"{case.name}.csv"
        trace_exported = output / group / "verilog" / f"{case.name}.csv"
        trace_hash = None
        if trace_reference.is_file():
            trace_hash = sha(trace_reference)
            if trace_hash != sha(trace_exported):
                raise RuntimeError("Retirement traces differ despite architectural differential passing")
        return {"group": group, "case": case.name, "status": "pass",
                "exact_cycles": left["cycles"], "exact_simulated_metrics": True,
                "trace_sha256": trace_hash, "measurements": measurements}

    results, failures = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(compare_case, case): case for case in cases}
        for future in concurrent.futures.as_completed(futures):
            group, case, _ = futures[future]
            try:
                result = future.result()
                results.append(result)
                print(f"PASS {group}/{case.name}: {result['exact_cycles']} identical cycles", flush=True)
            except Exception as error:
                failures.append({"group": group, "case": case.name, "error": str(error)})
                print(f"FAIL {group}/{case.name}: {error}", file=sys.stderr, flush=True)
    summary = {"export": exported, "reference_metadata": reference,
               "build_skipped": args.skip_build, "reproduction_build_command": command,
               "verilator_build_record": (output / "obj/Vcpu_top__verFiles.dat").read_text().splitlines()[1],
               "binary_sha256": sha(binary),
               "parameters": parameters,
               "simulator_sources_sha256": {name: sha(frozen / name)
                    for name in ("sim/main.cpp", "sim/memory_model.h")},
               "generated_only_warning_exceptions": {
                   "WIDTH": "sv2v emits explicit width-adapter functions",
                   "DECLFILENAME": "single Verilog artifact contains multiple modules",
                   "ASCRANGE": "sv2v emits ascending [0:1] function jump helpers"},
               "passed": len(results), "failed": len(failures),
               "results": sorted(results, key=lambda row: (row["group"], row["case"])),
               "failures": failures}
    (output / "validation.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Export validation: {len(results)}/{len(cases)} pass; {output / 'validation.json'}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
