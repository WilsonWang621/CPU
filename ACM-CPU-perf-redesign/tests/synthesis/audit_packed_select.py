#!/usr/bin/env python3
"""Reproduce packed-plane expansion after sv2v and prove legal-index equivalence."""
import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(command, directory, limit):
    start = time.monotonic()
    with (directory / "yosys.log").open("w") as log:
        try:
            result = subprocess.run(command, cwd=directory, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=limit)
            status = "pass" if result.returncode == 0 else "failed"
        except subprocess.TimeoutExpired:
            status = "timeout"
    return {"status": status, "wall_seconds": time.monotonic() - start}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/tests-packed-select")
    parser.add_argument("--sets", type=int, nargs="+", default=[4, 32])
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if any(n < 2 or n & (n - 1) for n in args.sets) or args.timeout <= 0:
        parser.error("Set counts must be powers of two >=2; timeout must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / "tests/synthesis/packed_plane_select.sv"
    sv2v = ROOT / "build/tools/sv2v-Linux/sv2v"
    yosys = ROOT / "build/tools/oss-cad-suite/bin/yosys"
    converted = output / "select.v"
    converted.write_bytes(subprocess.check_output([str(sv2v), str(source)]))
    report = {"scope": "Synthetic selection structure, not whole-cache equivalence or area",
              "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
              "verilog_sha256": hashlib.sha256(converted.read_bytes()).hexdigest(),
              "yosys": subprocess.check_output([str(yosys), "-V"], text=True).strip(),
              "sv2v": subprocess.check_output([str(sv2v), "--version"], text=True).strip(),
              "results": []}
    for sets in args.sets:
        for name in ("packed_plane_select", "narrow_row_select", "plane_select_miter"):
            directory = output / f"{name}-{sets}"
            directory.mkdir(exist_ok=True)
            # Slang's file list parser handles spaces in filenames reliably.
            (directory / "sources.f").write_text(json.dumps(str(converted)) + "\n")
            commands = [f'read_slang --top {name} -GSETS={sets} --no-implicit-memories -f sources.f',
                        "flatten", "opt -fast", "wreduce", "peepopt", "opt_clean"]
            if name == "plane_select_miter":
                commands += ["sat -verify -prove ok 1 -show-inputs -show-outputs"]
            else:
                commands += ["techmap", f'tee -o "{directory}/expanded.json" stat -json',
                             "opt -fast", "check -assert -nolatches",
                             f'tee -o "{directory}/optimized.json" stat -json']
            script = directory / "run.ys"
            script.write_text("\n".join(commands) + "\n")
            row = {"sets": sets, "ways": 4, "words": 8, "variant": name,
                   "directory": str(directory.relative_to(ROOT)) if directory.is_relative_to(ROOT) else str(directory)}
            row.update(run([str(yosys), "-Q", "-d", "--perffile",
                            str(directory / "timing.json"), "-s", str(script)], directory, args.timeout))
            for stage in ("expanded", "optimized"):
                path = directory / f"{stage}.json"
                if path.exists():
                    row[stage] = json.loads(path.read_text())["design"]
            report["results"].append(row)
            (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"{name} sets={sets}: {row['status']} ({row['wall_seconds']:.2f}s)", flush=True)
    return int(any(row["status"] != "pass" for row in report["results"]))


if __name__ == "__main__":
    raise SystemExit(main())
