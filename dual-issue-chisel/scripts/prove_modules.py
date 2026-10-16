#!/usr/bin/env python3
"""Compare native Chisel modules with the current delivered Verilog using SAT.

This checks the emitted circuit, not a second Scala reference implementation.
Each proof records both input hashes and the exact Yosys recipe and output.
Sequential proofs start both circuits from zero and exercise arbitrary inputs
for the recorded number of cycles; they are explicitly bounded, not induction.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
sys.path.insert(0, str(ROOT / "scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, executable, packaged_tool

CASES = {
    "prefix-adder": ("v2_prefix_adder", {}, 0),
    "decoder": ("decoder", {}, 0),
    "alu": ("alu", {}, 0),
    "branch-unit": ("branch_unit", {}, 0),
    "distribution": ("v2_distribution", {"WIDTH": 32, "LEAVES": 6}, 0),
    "operand": ("v2_operand", {}, 0),
    "parallel-select": ("v2_parallel_select", {}, 0),
    "cache-lookup": ("v2_cache_lookup", {}, 0),
    "rename": ("v2_rename", {"CHECKPOINTS": 3, "COMMIT_TREE": 1}, 5),
    "axi-adapter": ("pararisc_axi_adapter", {}, 8),
    "memory-controller": ("memory_controller", {"MAX_MEM_OUTSTANDING": 16}, 8),
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--modules", default=",".join(CASES))
    p.add_argument("--yosys")
    p.add_argument("--rtl-prefix", default="", help="Prefix of generated module directories, e.g. v4-")
    p.add_argument("--native-file", type=Path, help="Extract the named module directly from this complete generated CPU")
    args = p.parse_args()
    if not args.yosys:
        enter_appimage(DEFAULT_APPIMAGE)
    yosys = args.yosys or packaged_tool("yosys") or executable("yosys")
    out = PROJECT / "build" / (args.rtl_prefix + "module-proofs")
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for name in args.modules.split(","):
        top, params, cycles = CASES[name]
        sources = [args.native_file.resolve()] if args.native_file else sorted((PROJECT / "build" / (args.rtl_prefix + name)).glob("*.sv"))
        if len(sources) != 1:
            raise SystemExit(f"Generate {name} first: expected one SV file, found {sources}")
        gold = ROOT / "verilog" / ("pararisc_axi_adapter.sv" if name == "axi-adapter" else "area_v2_core.v")
        commands = [f'read_verilog -sv "{gold}"']
        if params:
            commands += ["chparam " + " ".join(f"-set {k} {v}" for k, v in params.items()) + f" {top}"]
        commands += [f"hierarchy -top {top}", "proc", "memory_map", "setattr -mod -unset keep_hierarchy",
                     "flatten", "opt", f"rename {top} gold", "design -stash gold",
                     f'read_verilog -sv "{sources[0]}"', f"hierarchy -top {top}" if args.native_file else "hierarchy -auto-top", "proc", "memory_map",
                     "setattr -mod -unset keep_hierarchy", "flatten", "opt", "rename -top gate",
                     "design -copy-from gold -as gold gold", "miter -equiv -make_assert -flatten gold gate miter",
                     "hierarchy -top miter", "opt_clean"]
        recipe = out / f"{name}.ys"
        log = out / f"{name}.log"
        assumptions = []
        if name == "rename":
            # CHECKPOINTS=3 uses a two-bit address with one illegal encoding.
            # The CPU allocator only supplies 0..2. Avoid comparing undefined
            # Verilog out-of-array reads with Chisel's defined mux fallback.
            prepared = out / f"{name}-prepared.il"
            interface = out / f"{name}-interface.json"
            prep = out / f"{name}-prepare.ys"
            prep.write_text("\n".join(commands + [f'write_rtlil "{prepared}"', f'write_json "{interface}"']) + "\n")
            with (out / f"{name}-prepare.log").open("w") as f:
                subprocess.run([str(yosys), "-Q", "-T", "-s", str(prep)], stdout=f, stderr=subprocess.STDOUT, check=True)
            ports = json.loads(interface.read_text())["modules"]["miter"]["ports"]
            declarations = []
            for port, spec in ports.items():
                width = len(spec["bits"])
                declarations.append(f'{spec["direction"]} wire ' + (f'[{width-1}:0] ' if width > 1 else '') + port)
            assumptions = ["in_restore_index < 3", "in_save_index < 3"]
            constraints = out / f"{name}-legal.sv"
            constraints.write_text("module checked(\n" + ",\n".join(declarations) + ");\n" +
                "miter dut(" + ",".join(f".{port}({port})" for port in ports) + ");\n" +
                "always @* begin\n" + "\n".join(f"assume({a});" for a in assumptions) + "\nend\nendmodule\n")
            commands = [f'read_rtlil "{prepared}"', f'read_verilog -formal -sv "{constraints}"',
                        "hierarchy -top checked", "proc", "chformal -lower", "flatten", "opt_clean"]
        sequential = f"-seq {cycles} -set-init-zero" if cycles else ""
        commands += [f"sat -verify -prove-asserts -set-assumes {sequential} -show-inputs -show-outputs"]
        recipe.write_text("\n".join(commands) + "\n")
        with log.open("w") as f:
            subprocess.run([str(yosys), "-Q", "-T", "-s", str(recipe)], stdout=f, stderr=subprocess.STDOUT, check=True)
        assert "SUCCESS!" in log.read_text(), f"No completed SAT proof in {log}"
        result = {"module": name, "status": "bounded-equivalent" if cycles else "combinational-equivalent",
                  "cycles": cycles, "assumptions": assumptions, "original_parameters": params,
                  "original_sha256": sha(gold), "chisel_rtl_sha256": sha(sources[0]),
                  "recipe_sha256": sha(recipe), "log_sha256": sha(log)}
        (out / f"{name}.json").write_text(json.dumps(result, indent=2) + "\n")
        results.append(result)
        print(f"{name}: {result['status']}" + (f" ({cycles} cycles)" if cycles else ""), flush=True)
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")

if __name__ == "__main__":
    main()
