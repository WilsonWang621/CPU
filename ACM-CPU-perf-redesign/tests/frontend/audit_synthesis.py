#!/usr/bin/env python3
"""Bounded Slang/Yosys audit of frontend storage updates and their reproducer."""
import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(yosys, command, log, timeout):
    start = time.monotonic()
    with log.open("w") as output:
        try:
            result = subprocess.run([str(yosys), "-Q", "-p", command], cwd=log.parent,
                stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
            status = result.returncode
        except subprocess.TimeoutExpired:
            status = "timeout"
    return {"status": status, "seconds": time.monotonic() - start}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/frontend-synthesis")
    parser.add_argument("--check-timeout", type=int, default=20)
    parser.add_argument("--reproducer-only", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    yosys = ROOT / "build/tools/oss-cad-suite/bin/yosys"
    jobs = [(name, [], [ROOT / "tests/frontend/update_reproducer.sv"])
            for name in ("update_dynamic", "update_decoded")]
    if not args.reproducer_only:
        for top in ("branch_predictor", "frontend"):
            for entries in (512, 2048):
                params = [f"BHT_ENTRIES={entries}"]
                if top == "frontend":
                    params += ["FETCH_WIDTH=4", "FETCH_QUEUE_ENTRIES=16", "FETCH_REQUESTS=16"]
                jobs.append((top, params, [ROOT / "rtl/cpu_pkg.sv", ROOT / "rtl/branch_predictor.sv",
                                          ROOT / "rtl/frontend.sv"]))
    results = []
    for top, params, sources in jobs:
        name = top + ("-" + params[0].split("=")[1] if params else "")
        directory = output / name
        directory.mkdir(exist_ok=True)
        command = f"read_slang --keep-hierarchy --no-implicit-memories -D SYNTHESIS --top {top} "
        command += " ".join(f"-G {param}" for param in params) + " "
        # Slang handles quoted filenames through its command-file parser.
        source_list = directory / "sources.f"
        source_list.write_text("\n".join(json.dumps(str(source)) for source in sources) + "\n")
        command += '-f sources.f'
        command += f'; tee -o "{directory}/stat.json" stat -json; write_json "{directory}/raw.json"'
        row = {"top": top, "parameters": params, "command": command,
               "sources_sha256": {str(source.relative_to(ROOT)): hashlib.sha256(source.read_bytes()).hexdigest()
                                  for source in sources},
               "read": run(yosys, command, directory / "read.log", 90)}
        if row["read"]["status"] == 0:
            stats = json.loads((directory / "stat.json").read_text())
            design = json.loads((directory / "raw.json").read_text())
            row["modules"] = {}
            for module, data in design["modules"].items():
                cells = []
                for cell in data.get("cells", {}).values():
                    widths = {port: len(bits) for port, bits in cell.get("connections", {}).items()}
                    cells.append({"type": cell["type"], "ports": widths, "port_bits": sum(widths.values()),
                                  "source": cell.get("attributes", {}).get("src", "")})
                row["modules"][module] = {
                    **{field: stats["modules"]["\\" + module][field]
                       for field in ("num_cells", "num_wire_bits")},
                    "largest_cells": sorted(cells, key=lambda cell: cell["port_bits"], reverse=True)[:10],
                }
            row["raw_check"] = run(yosys, f'read_json "{directory}/raw.json"; check -assert -nolatches',
                                   directory / "raw-check.log", args.check_timeout)
            # Remove disconnected elaboration intermediates before checking
            # the live netlist. This does not omit any active logic or relax
            # loop, driver, or latch diagnostics.
            row["check"] = run(yosys,
                               f'read_json "{directory}/raw.json"; opt_clean; check -assert -nolatches',
                               directory / "check.log", args.check_timeout)
        results.append(row)
        (output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name, "read", row["read"], "raw_check", row.get("raw_check"),
              "check", row.get("check"), flush=True)
    # The dynamic baseline is intentionally retained as a bounded diagnostic;
    # a timeout there is evidence, not a reason to weaken or skip production checks.
    return any(row["read"]["status"] != 0 or
               (row["top"] != "update_dynamic" and row.get("check", {}).get("status") != 0)
               for row in results)


if __name__ == "__main__":
    raise SystemExit(main())
