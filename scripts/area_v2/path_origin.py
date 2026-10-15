#!/usr/bin/env python3
"""Resolve mapped STA pins to RTL nets without changing synthesis or timing."""
import argparse
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, executable, packaged_tool


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--yosys")
    parser.add_argument("--timing", type=Path,
                        help="timing JSON from the identical mapped design")
    parser.add_argument("--registers", action="store_true",
                        help="replay synthesis up to ABC to recover register names")
    parser.add_argument("--preabc", type=Path,
                        help="reuse a pre-ABC JSON generated for this synthesis")
    args = parser.parse_args()
    if not args.yosys:
        enter_appimage(DEFAULT_APPIMAGE)
    yosys = executable(args.yosys) if args.yosys else (packaged_tool("yosys") or executable("yosys"))
    out = args.directory.resolve()
    with (out / "path-renames.log").open("w") as log:
        subprocess.run([yosys, "-Q", "-T", "-p",
                        f'read_json "{out}/design.json"; '
                        f'write_verilog -v -noattr -noexpr "{out}/path-mapped.v"'],
                       stdout=log, check=True)
    renames = defaultdict(dict)
    scope = None
    for line in (out / "path-renames.log").read_text().splitlines():
        match = re.match(r"Dumping module `(.*)'\.", line)
        if match:
            scope = match[1].removeprefix("\\")
        match = re.match(r"\s+renaming `(.*)' to `(.*)'\.", line)
        if match:
            renames[scope][match[2]] = match[1]
    modules = json.loads((out / "design.json").read_text())["modules"]
    timing = json.loads((args.timing or out / "timing.json").read_text())
    before = None
    if args.preabc:
        before = json.loads(args.preabc.read_text())["modules"]
    if args.registers:
        recipe = re.split(r"(?m)^abc\b", (out / "synth.ys").read_text(), maxsplit=1)[0]
        if os.environ.get("CPU2026_APPDIR"):
            recipe = re.sub(r"/tmp/(?:\.mount_cpu202|appimage_extracted_)[^/]+",
                            lambda _: os.environ["CPU2026_APPDIR"], recipe)
        recipe += f'write_json "{out}/path-preabc.json"\n'
        (out / "path-preabc.ys").write_text(recipe)
        with (out / "path-preabc.log").open("w") as log:
            subprocess.run([yosys, "-Q", "-T", "-q", "-s", str(out / "path-preabc.ys")],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        before = json.loads((out / "path-preabc.json").read_text())["modules"]
    indexes = {}
    for name, module in modules.items():
        if name != "student_top" and name.endswith("_ASAP7_75t_R"):
            continue
        aliases, sinks = defaultdict(list), defaultdict(list)
        for net, value in module.get("netnames", {}).items():
            if net.startswith("$"):
                continue
            for index, bit in enumerate(value["bits"]):
                aliases[bit].append(f"{net}[{index + value.get('offset', 0)}]")
        for cell, value in module.get("cells", {}).items():
            for port, bits in value["connections"].items():
                if value.get("port_directions", {}).get(port) == "input":
                    for bit in bits:
                        sinks[bit].append(f"{cell}/{port}")
        indexes[name] = aliases, sinks

    def describe(pin):
        parts = pin.split("/")
        module_name = "student_top"
        for instance in parts[:-2]:
            cell = modules[module_name]["cells"][renames[module_name].get(instance, instance)]
            module_name = cell["type"]
        cell_name, port = parts[-2:]
        original = renames[module_name].get(cell_name, cell_name)
        cell = modules[module_name]["cells"].get(original)
        if cell is None:
            raise ValueError(f"Cannot resolve {pin} ({original}) in {module_name}")
        bits = cell["connections"][port]
        aliases, sinks = indexes[module_name]
        result = {"pin": pin, "original_cell": original, "type": cell["type"],
                  "aliases": sorted({n for bit in bits for n in aliases[bit]}),
                  "fanout": sum(len(sinks[bit]) for bit in bits),
                  "source": cell.get("attributes", {}).get("src")}
        if before and original in before[module_name].get("cells", {}):
            module = before[module_name]
            original_cell = module["cells"][original]
            register_bits = set(original_cell["connections"].get("QN", original_cell["connections"].get("Q", [])))
            if register_bits:
                for candidate in module["cells"].values():
                    if candidate["type"] == "$_NOT_" and any(
                            b in register_bits for b in candidate["connections"].get("A", [])):
                        register_bits.update(candidate["connections"]["Y"])
                result["register_aliases"] = sorted({
                    f"{name}[{index + value.get('offset', 0)}]"
                    for name, value in module["netnames"].items() if not name.startswith("$")
                    for index, bit in enumerate(value["bits"]) if bit in register_bits})
        if port in ("Q", "QN"):
            # dfflibmap may implement positive Q with a negative-Q cell + INV.
            for candidate in modules[module_name]["cells"].values():
                if candidate["type"].startswith("INV") and any(
                        b in bits for b in candidate["connections"].get("A", [])):
                    result["aliases_after_inverter"] = sorted({
                        n for bit in candidate["connections"].get("Y", []) for n in aliases[bit]})
        return result

    paths = []
    for path in timing["critical_paths"]:
        paths.append({"startpoint": describe(path["startpoint"]),
                      "endpoint": describe(path["endpoint"]),
                      "points": [describe(p["pin"]) for p in path["points"]]})
    destination = out / "path-origin.json"
    destination.write_text(json.dumps(paths, indent=2) + "\n")
    print(destination)
    for label in ("startpoint", "endpoint"):
        print(label + ": " + json.dumps(paths[0][label]))
    for point in paths[0]["points"]:
        if point["fanout"] >= 16:
            print(json.dumps(point))


if __name__ == "__main__":
    main()
