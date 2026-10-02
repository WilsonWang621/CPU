#!/usr/bin/env python3
"""Map v2 port/storage prototypes; never report the sum as full-CPU area."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "scripts"))
from export_verilog import convert
from synthesize import abc_inline, yosys_quote

# (width, rows, read ports, write ports, mask bits, copies)
ARRAYS = {
    "dcache_data": (32, 512, 1, 1, 4, 1),
    "icache_data": (32, 128, 1, 1, 1, 2),
    "dcache_tags": (22, 32, 1, 1, 1, 2),
    "icache_tags": (18, 32, 1, 1, 1, 1),
    "architectural_registers": (32, 32, 4, 2, 1, 1),
    "rob_results": (32, 32, 6, 3, 1, 1),
    "rob_metadata": (64, 32, 2, 2, 1, 1),
    "issue_metadata": (80, 8, 1, 1, 1, 3),
    "store_buffer": (56, 16, 1, 1, 1, 1),
    "miss_records": (48, 8, 1, 1, 1, 1),
    "fill_buffer": (32, 8, 1, 1, 1, 1),
    "fetch_queue": (72, 8, 2, 2, 1, 1),
    "bht": (2, 256, 2, 1, 1, 1),
    "btb": (32, 32, 2, 1, 1, 1),
}


def array_wrapper(config):
    width, rows, reads, writes, mask, _ = config
    ab = (rows - 1).bit_length()
    ports = ["input clk", f"input [{reads*ab-1}:0] read_address",
             f"output [{reads*width-1}:0] read_data",
             f"input [{writes-1}:0] write_valid",
             f"input [{writes*ab-1}:0] write_address",
             f"input [{writes*width-1}:0] write_data",
             f"input [{writes*mask-1}:0] write_mask"]
    return "module v2_probe (" + ",\n".join(ports) + ");\n" + f"""
v2_array #(.WIDTH({width}), .DEPTH({rows}), .READ_PORTS({reads}),
 .WRITE_PORTS({writes}), .MASK_BITS({mask})) impl (
 .clk(clk), .read_address(read_address), .read_data(read_data),
 .write_valid(write_valid), .write_address(write_address),
 .write_data(write_data), .write_mask(write_mask));
endmodule
"""


def execute(command, directory, timeout):
    started = time.monotonic()
    with (directory / "yosys.log").open("w") as log:
        process = subprocess.Popen(command, cwd=directory, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait()
            status = 124
    return status, time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/area")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    tools = ROOT / "build/tools"
    yosys, abc = [tools / "oss-cad-suite/bin" / n for n in ("yosys", "yosys-abc")]
    library = tools / "asap7-libs/asap7_rvt_tt.lib"
    sources = [HERE / "rtl/storage.sv", HERE / "rtl/v2_rename.sv", HERE / "rtl/v2_load_hit.sv", HERE / "rtl/v2_select.sv"]
    frozen = directory / "source"
    frozen.mkdir(exist_ok=True)
    script_bytes = Path(__file__).read_bytes()
    (frozen / "measure_area.py").write_bytes(script_bytes)
    source_hashes = {}
    for path in sources:
        data = path.read_bytes()
        (frozen / path.name).write_bytes(data)
        source_hashes[str(path.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
    converted, conversion = convert([frozen / path.name for path in sources], tools / "sv2v-Linux/sv2v")
    source = directory / "storage.v"
    source.write_text(converted)
    results = []
    tasks = [(name, "v2_probe", array_wrapper(config), config[-1]) for name, config in ARRAYS.items()]
    tasks += [("operands", "v2_operands", "", 1), ("integer_select", "v2_select", "", 2)]
    tasks += [("rename_checkpoints", "v2_rename", "", 1)]
    # This overlaps the data/tag array prototypes. Keep its area out of the
    # component sum; it exists to time the composed AGU -> cache -> result path.
    tasks += [("load_hit_path", "v2_load_hit", "", 0)]
    for name, top, wrapper, copies in tasks:
        if args.only and name not in args.only:
            continue
        target = directory / name
        target.mkdir(exist_ok=True)
        (target / "wrapper.v").write_text(wrapper)
        (target / "sources.f").write_text(yosys_quote(source) + "\n" + yosys_quote(target / "wrapper.v") + "\n")
        mapping = "strash\n&get -n\n&nf -D 3333.333\n&put\nbuffer -p -N 8 -S 100\nupsize -D 3333.333 -T 10\n"
        script = [f"read_slang --top {top} --no-implicit-memories -f sources.f",
                  f"hierarchy -check -top {top}", "opt -fast", "flatten", "opt -fast", "wreduce",
                  "memory_share -nosat -nowiden", "memory_collect", "memory_map", "opt -fast",
                  "techmap", "opt_clean", f"read_liberty -lib {yosys_quote(library)}",
                  f"dfflibmap -prepare -liberty {yosys_quote(library)}",
                  f"abc -exe {yosys_quote(abc)} -liberty {yosys_quote(library)} -D 3333.333 -script {abc_inline(mapping)}",
                  "opt_clean", "opt_dff -nodffe -nosdff",
                  f"dfflibmap -map-only -liberty {yosys_quote(library)}", "clean",
                  "check -assert -mapped -nolatches",
                  f"tee -o area.json stat -json -liberty {yosys_quote(library)}",
                  "write_verilog -noattr -simple-lhs netlist.v"]
        (target / "synth.ys").write_text("\n".join(script) + "\n")
        code, seconds = execute([str(yosys), "-Q", "-s", "synth.ys"], target, args.timeout)
        row = dict(name=name, copies=copies, status=code, seconds=seconds,
                   configuration=list(ARRAYS[name]) if name in ARRAYS else "module defaults",
                   script_sha256=hashlib.sha256((target / "synth.ys").read_bytes()).hexdigest())
        if code == 0:
            data = json.loads((target / "area.json").read_text())["modules"]["\\" + top]
            row.update(area=data["area"], sequential_area=data.get("sequential_area", 0),
                       cells=data["num_cells"], storage_bits=(ARRAYS[name][0]*ARRAYS[name][1] if name in ARRAYS else None),
                       netlist_sha256=hashlib.sha256((target / "netlist.v").read_bytes()).hexdigest())
        results.append(row)
        print(json.dumps(row), flush=True)
    report = dict(scope="Isolated structural prototypes, NOT full CPU mapping or STA. No excluded array bits or macros.",
                  sources_sha256=source_hashes,
                  script_sha256=hashlib.sha256(script_bytes).hexdigest(),
                  yosys=subprocess.check_output([str(yosys), "-V"], text=True).strip(),
                  liberty_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  conversion=conversion, exported_sha256=hashlib.sha256(converted.encode()).hexdigest(),
                  results=results, prototype_sum=sum(r.get("area", 0)*r["copies"] for r in results),
                  all_passed=all(r["status"] == 0 for r in results),
                  whole_cpu_area=None, whole_cpu_frequency_mhz=None)
    (directory / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return not report["all_passed"]


if __name__ == "__main__":
    raise SystemExit(main())
