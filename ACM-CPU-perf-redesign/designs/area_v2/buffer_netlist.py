#!/usr/bin/env python3
"""Insert counted ASAP7 buffers on mapped high-fanout nets and data inputs.

Yosys/ABC maps combinational partitions independently. After reconnecting the
partitions, shared register outputs can still have thousands of loads. This
post-map pass builds physical buffer trees, without changing logic or clocks.
An exact connectivity contraction check verifies every original connection.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from synthesize import yosys_quote


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--netlist", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fanout", type=int, default=8)
    args = parser.parse_args()
    if args.fanout < 2:
        parser.error("fanout must be at least 2")
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    netlist = args.netlist.resolve()
    library = ROOT / "build/tools/asap7-libs/asap7_rvt_tt.lib"
    yosys = ROOT / "build/tools/oss-cad-suite/bin/yosys"
    read_script = f"""read_liberty -lib {yosys_quote(library)}
read_verilog {yosys_quote(netlist)}
hierarchy -check -top cpu_synth
write_json {yosys_quote(directory / 'original.json')}
"""
    (directory / "read.ys").write_text(read_script)
    with (directory / "read.log").open("w") as log:
        subprocess.run([str(yosys), "-Q", "-s", str(directory / "read.ys")], stdout=log, stderr=subprocess.STDOUT, check=True)
    design = json.loads((directory / "original.json").read_text())
    top = design["modules"]["cpu_synth"]
    cells = top["cells"]
    original_names = set(cells)
    original_connections = {n: {p: tuple(v) for p, v in c["connections"].items()} for n, c in cells.items()}
    uses = defaultdict(list)
    highest_bit = 0
    for net in top["netnames"].values():
        for bit in net["bits"]:
            if isinstance(bit, int):
                highest_bit = max(highest_bit, bit)
    for name, cell in cells.items():
        for port, bits in cell["connections"].items():
            for index, bit in enumerate(bits):
                if isinstance(bit, int):
                    highest_bit = max(highest_bit, bit)
                    if cell["port_directions"][port] == "input" and port != "CLK":
                        uses[bit].append((name, port, index))
    clocks = set(top["ports"]["clk"]["bits"])
    input_bits = {b for n, p in top["ports"].items() if p["direction"] == "input" and n != "clk"
                  for b in p["bits"] if isinstance(b, int)}
    parent, inserted = {}, []
    buffer_type = "BUFx2_ASAP7_75t_R"
    assert design["modules"][buffer_type]["ports"]["A"]["direction"] == "input"
    assert design["modules"][buffer_type]["ports"]["Y"]["direction"] == "output"
    liberty_text = library.read_text()
    start = liberty_text.index("cell (" + buffer_type + ")")
    start = liberty_text.index("{", start)
    depth, end = 1, start+1
    while depth:
        depth += (liberty_text[end] == "{") - (liberty_text[end] == "}")
        end += 1
    cell_text = liberty_text[start:end]
    assert re.search(r'pin\s*\(Y\)\s*\{\s*direction\s*:\s*output;\s*function\s*:\s*"A";', cell_text)

    def buffer(source, destinations):
        nonlocal highest_bit
        highest_bit += 1
        name = f"v2_fanout_buffer_{len(inserted)}"
        assert name not in cells
        output = highest_bit
        cells[name] = dict(hide_name=0, type=buffer_type, parameters={}, attributes={},
                           port_directions={"A": "input", "Y": "output"}, connections={"A": [source], "Y": [output]})
        top["netnames"][name + "_wire"] = dict(hide_name=0, bits=[output], attributes={})
        parent[output] = source
        inserted.append(name)
        for cell, pin, index in destinations:
            cells[cell]["connections"][pin][index] = output
        return name, output

    max_before = max(map(len, uses.values()))
    repaired = 0
    for bit, destinations in list(uses.items()):
        if bit in clocks:
            continue
        source = bit
        if bit in input_bits:
            # A real input buffer provides nonzero minimum delay; this is not
            # a relaxed input-delay constraint or a timing false path.
            _, source = buffer(bit, destinations)
        if len(destinations) <= args.fanout:
            continue
        repaired += 1
        while len(destinations) > args.fanout:
            next_level = []
            for start in range(0, len(destinations), args.fanout):
                name, _ = buffer(source, destinations[start:start+args.fanout])
                next_level.append((name, "A", 0))
            destinations = next_level

    # A tree's parent may have been reconnected while constructing a higher
    # level. Derive the final parents from the actual cells, not stale state.
    parent = {cells[n]["connections"]["Y"][0]: cells[n]["connections"]["A"][0] for n in inserted}
    def contract(bit):
        seen = set()
        while bit in parent:
            assert bit not in seen, "buffer loop"
            seen.add(bit)
            bit = parent[bit]
        return bit
    checked = 0
    for name in original_names:
        for port, bits in cells[name]["connections"].items():
            assert tuple(map(contract, bits)) == original_connections[name][port], (name, port)
            checked += len(bits)
    for name, port in top["ports"].items():
        if name == "clk":
            assert set(port["bits"]) == clocks
    final_uses = defaultdict(int)
    for cell in cells.values():
        for port, bits in cell["connections"].items():
            if cell["port_directions"][port] == "input" and port != "CLK":
                for bit in bits:
                    if isinstance(bit, int) and bit not in clocks:
                        final_uses[bit] += 1
    max_after = max(final_uses.values())
    assert max_after <= args.fanout
    (directory / "buffered.json").write_text(json.dumps(design, separators=(",", ":")))
    script = f"""read_json {yosys_quote(directory / 'buffered.json')}
hierarchy -check -top cpu_synth
check -assert -mapped -nolatches
tee -o {yosys_quote(directory / 'area.json')} stat -json -liberty {yosys_quote(library)}
write_verilog -noattr -simple-lhs {yosys_quote(directory / 'netlist.v')}
"""
    (directory / "write.ys").write_text(script)
    with (directory / "write.log").open("w") as log:
        subprocess.run([str(yosys), "-Q", "-s", str(directory / "write.ys")], stdout=log, stderr=subprocess.STDOUT, check=True)
    area = json.loads((directory / "area.json").read_text())["modules"]["\\cpu_synth"]
    report = dict(input_sha256=hashlib.sha256(netlist.read_bytes()).hexdigest(),
                  output_sha256=hashlib.sha256((directory / "netlist.v").read_bytes()).hexdigest(),
                  script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  liberty_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  buffer_type=buffer_type, inserted_buffers=len(inserted), high_fanout_nets=repaired,
                  max_fanout_before=max_before, max_fanout_after=max_after,
                  exact_original_pin_connections_checked=checked, connectivity_contraction="pass",
                  buffer_function_verified="Y=A in pinned Liberty",
                  clocks_modified=False, input_delays_relaxed=False, area=area["area"], cells=area["num_cells"])
    (directory / "buffering.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


if __name__ == "__main__":
    main()
