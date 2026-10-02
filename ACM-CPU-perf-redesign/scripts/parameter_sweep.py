#!/usr/bin/env python3
"""Build parameter variants and measure the six cold-start performance cases."""
import argparse
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# One-variable-at-a-time changes, with a scalar width configuration also provided.
DEFAULT_CONFIGS = {
    "default": {},
    "scalar": {"FETCH_WIDTH": 1, "RENAME_WIDTH": 1, "ISSUE_WIDTH": 1, "WB_WIDTH": 1, "COMMIT_WIDTH": 1},
    "width2": {"FETCH_WIDTH": 2, "RENAME_WIDTH": 2, "ISSUE_WIDTH": 2, "WB_WIDTH": 2, "COMMIT_WIDTH": 2},
    "issue2": {"ISSUE_WIDTH": 2},
    "phys96": {"PHYS_REGS": 96},
    "rob32": {"ROB_ENTRIES": 32},
    "iq16": {"IQ_ENTRIES": 16},
    "dcache4096": {"DCACHE_BYTES": 4096},
    "dcache8192": {"DCACHE_BYTES": 8192},
    "bimodal": {"PREDICTOR_MODE": 0},
    "gshare": {"PREDICTOR_MODE": 1},
    "compact": {"PHYS_REGS":80,"ROB_ENTRIES":32,"IQ_ENTRIES":24,"LQ_ENTRIES":16,
                "SQ_ENTRIES":16,"CSB_ENTRIES":16,"FETCH_QUEUE_ENTRIES":16,
                "ICACHE_BYTES":1024,"DCACHE_BYTES":4096,"RAS_DEPTH":8},
}


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configs", nargs="*", help="named default configurations; omitted: every configuration")
    parser.add_argument("--config-file", type=Path, help="JSON object mapping names to parameter objects")
    parser.add_argument("--output", type=Path, default=ROOT / "build/sweep")
    parser.add_argument("--latency", type=int, default=20)
    parser.add_argument("--max-outstanding", type=int, default=64)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--max-cycles", type=int, default=100_000_000)
    args = parser.parse_args()
    configs = json.loads(args.config_file.read_text()) if args.config_file else DEFAULT_CONFIGS
    names = args.configs or list(configs)
    unknown = set(names) - configs.keys()
    if unknown:
        parser.error(f"unknown configurations: {sorted(unknown)}")
    args.output.mkdir(parents=True, exist_ok=True)
    # Every point in one sensitivity sweep uses the same immutable source set.
    # Building directly from the working tree can silently mix revisions when
    # RTL changes while Verilator or its C++ compiler is still running.
    inputs = [ROOT / "Makefile", *sorted((ROOT / "rtl").glob("*.sv")),
              ROOT / "sim/main.cpp", ROOT / "sim/memory_model.h"]
    contents = {str(path.relative_to(ROOT)): path.read_bytes() for path in inputs}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}
    snapshot_id = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:16]
    snapshot = args.output.resolve() / f"source-{snapshot_id}"
    for name, data in contents.items():
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_bytes() != data:
            parser.error(f"Existing snapshot differs: {target}")
        target.write_bytes(data)
    verilator = ROOT / "RISC-V-CPU-2026-Toolchain/bin/verilator"
    cases = sorted(path.name for path in (ROOT / "RISC-V-CPU-2026-Testcases").glob("perf_*"))
    images = {name: hashlib.sha256((ROOT / "RISC-V-CPU-2026-Testcases" / name / "program.data").read_bytes()).hexdigest() for name in cases}
    metadata = {
        "rtl_git_commit": capture(["git", "rev-parse", "HEAD"]),
        "git_status": capture(["git", "status", "--porcelain"]),
        "source_sha256": hashes, "source_snapshot": str(snapshot),
        "verilator": capture([str(verilator), "--version"]),
        "platform": platform.platform(), "latency": args.latency, "memory_outstanding": args.max_outstanding, "memory_initiation_interval": 1,
        "memory_data_bits": 32, "images_sha256": images, "results": [],
    }
    for name in names:
        directory = (args.output / name).resolve()
        directory.mkdir(parents=True, exist_ok=True)
        params = " ".join(f"-G{key}={value}" for key, value in configs[name].items())
        build = ["make", "-C", str(snapshot), "build", f"BUILD_DIR={directory}",
                 f"VERILATOR={verilator}", f"PARAMS={params}", f"JOBS={args.jobs}"]
        print(f"Building {name}: {params or '(defaults)'}", flush=True)
        with (directory / "build.log").open("w") as log:
            result = subprocess.run(build, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        row = {"configuration": name, "parameters": configs[name], "build_command": build,
               "source_sha256": hashes, "source_snapshot": str(snapshot)}
        if result.returncode:
            row.update(status="build_failed", log=str(directory / "build.log"))
        else:
            command = [sys.executable, str(ROOT / "scripts/run_tests.py"), *cases,
                       "--binary", str(directory / "cpu_sim"), "--output", str(directory / "results"),
                       "--latency", str(args.latency), "--max-outstanding", str(args.max_outstanding), "--jobs", str(args.jobs),
                       "--timeout", str(args.timeout), "--max-cycles", str(args.max_cycles)]
            result = subprocess.run(command, cwd=ROOT)
            row["status"] = "pass" if not result.returncode else "test_failed"
            row["binary_sha256"] = hashlib.sha256((directory / "cpu_sim").read_bytes()).hexdigest()
            summary = directory / "results/summary.json"
            if summary.is_file():
                row["measurements"] = json.loads(summary.read_text())
        metadata["results"].append(row)
        (args.output / "sweep.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Measurements: {args.output / 'sweep.json'}")
    return any(row["status"] != "pass" for row in metadata["results"])


if __name__ == "__main__":
    raise SystemExit(main())
