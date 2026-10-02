#!/usr/bin/env python3
"""Export the exact parameterized RTL sources of an Area-v2 build."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from export_verilog import export


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/area-v2/cpu")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    built = json.loads((args.build_dir / "build.json").read_text())
    if built["returncode"]:
        parser.error("Select a successful build")
    output = (args.output or args.build_dir / "cpu.v").resolve()
    export(output, ROOT / "build/tools/sv2v-Linux/sv2v", Path(built["source_root"]))
    metadata_path = output.with_suffix(".metadata.json")
    metadata = json.loads(metadata_path.read_text())
    metadata["build_parameters"] = built["parameters"]
    metadata["parameter_scope"] = "Parameterized RTL retained; use recorded build parameters for nondefault configurations."
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
