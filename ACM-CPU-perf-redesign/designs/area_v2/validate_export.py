#!/usr/bin/env python3
"""Cross-check a frozen v2 build with Verilog-2005 and supplied Verilator."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/area-v2/cpu")
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/export-portable")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    metadata = json.loads((args.build_dir / "build.json").read_text())
    if metadata["returncode"]:
        parser.error("Select a successful build")
    metadata["parameters"] = {k: int(v) for k, v in (p.split("=") for p in metadata["parameters"])}
    args.output.mkdir(parents=True, exist_ok=True)
    reference = args.output / "reference-build.json"
    reference.write_text(json.dumps(metadata, indent=2) + "\n")
    return subprocess.call([sys.executable, str(ROOT / "scripts/validate_export.py"),
                            "--source-root", metadata["source_root"], "--sv-binary", str(args.build_dir / "cpu_sim"),
                            "--sv-metadata", str(reference), "--output", str(args.output), "--jobs", str(args.jobs)])


if __name__ == "__main__":
    raise SystemExit(main())
