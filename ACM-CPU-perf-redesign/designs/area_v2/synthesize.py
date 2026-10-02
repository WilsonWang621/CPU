#!/usr/bin/env python3
"""Whole Area-v2 mapping, counted fanout repair, and strict cell-only STA."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/area-v2/cpu")
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/synthesis")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    build = json.loads((args.build_dir / "build.json").read_text())
    if build["returncode"]:
        parser.error("Select a successful immutable CPU build")
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    commands = [
        [sys.executable, str(ROOT / "scripts/synthesize.py"), "--source-root", build["source_root"],
         "--output", str(directory / "raw"), "--mode", "asap7", "--skip-sta", "--timeout", str(args.timeout)] +
        [item for p in build["parameters"] for item in ("--param", p)],
        [sys.executable, str(HERE / "buffer_netlist.py"), "--netlist", str(directory / "raw/netlist.v"),
         "--output", str(directory / "mapped")],
        [sys.executable, str(ROOT / "scripts/static_timing.py"), "--netlist", str(directory / "mapped/netlist.v"),
         "--output", str(directory / "mapped/sta"), "--timeout", "120"],
    ]
    for command in commands:
        subprocess.run(command, cwd=ROOT, check=True)
    area = json.loads((directory / "mapped/area.json").read_text())["modules"]["\\cpu_synth"]
    timing = json.loads((directory / "mapped/sta/timing.json").read_text())
    acceptance = dict(area=area["area"] <= 40000, setup=timing.get("setup_meets_target", False),
                      hold=timing.get("hold_meets_target", False), electrical=timing.get("electrical_checks_clean", False),
                      coverage=timing.get("status") == "pass")
    report = dict(build=build, area=area, timing=timing, acceptance=acceptance,
                  all_constraints_passed=all(acceptance.values()),
                  source_language="sv2v Verilog-2005", arrays_excluded=False,
                  buffering=json.loads((directory / "mapped/buffering.json").read_text()),
                  raw_mapping=json.loads((directory / "raw/metadata.json").read_text()), commands=commands,
                  driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  scope="Whole CPU, cell-only ASAP7 RVT TT; ideal clock, zero I/O delays, no parasitics or place-and-route.")
    (directory / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(area=area["area"], setup_fmax_mhz=timing.get("cell_only_setup_fmax_mhz"),
                         acceptance=acceptance)), flush=True)
    return not report["all_constraints_passed"]


if __name__ == "__main__":
    raise SystemExit(main())
