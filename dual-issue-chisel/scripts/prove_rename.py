#!/usr/bin/env python3
"""Prove the final three-checkpoint RAT with explicit register correspondence.

Packed Verilog arrays and scalarized Chisel registers get identical proof-only
state aliases. No implementation or state transition is rewritten. The one
unused checkpoint encoding (3) maps to 0 in both proof inputs; all legal 0..2
indices retain their value. This avoids an undefined Verilog array read.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parent
sys.path.insert(0, str(ROOT / "scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def run(yosys, script, log):
    with log.open("w") as f:
        subprocess.run([str(yosys), "-Q", "-T", "-s", str(script)], stdout=f, stderr=subprocess.STDOUT, check=True)

def aliases(module, native):
    nets = module["netnames"]
    result = {}
    for r in range(32):
        pending = f"pending_q_{r}" if native else "pending_q"
        tag = f"tag_q_{r}" if native else f"tag_q[{r}]"
        if pending in nets:
            result[f"state_pending_{r}"] = nets[pending]["bits"] if native else [nets[pending]["bits"][r]]
        if tag in nets:
            result[f"state_tag_{r}"] = nets[tag]["bits"]
        for cp in range(3):
            pending = f"checkpoint_pending_{cp}_{r}" if native else f"checkpoint_pending[{cp}]"
            tag = f"checkpoint_tag_{cp}_{r}" if native else f"checkpoint_tag[{cp*32+r}]"
            if pending in nets:
                result[f"state_cp_pending_{cp}_{r}"] = nets[pending]["bits"] if native else [nets[pending]["bits"][r]]
            if tag in nets:
                result[f"state_cp_tag_{cp}_{r}"] = nets[tag]["bits"]
    return result

def legal_indices(module):
    all_bits = [b for n in module["netnames"].values() for b in n["bits"] if isinstance(b, int)]
    next_bit = max(all_bits) + 1
    binary = lambda n: format(n, "032b")
    for name in ("save_index", "restore_index"):
        raw = module["ports"][name]["bits"]
        assert len(raw) == 2
        select = next_bit
        safe = [next_bit + 1, next_bit + 2]
        next_bit += 3
        replacements = dict(zip(raw, safe))
        for cell in module["cells"].values():
            for port, bits in cell["connections"].items():
                cell["connections"][port] = [replacements.get(b, b) for b in bits]
        module["cells"][f"$proof${name}$invalid"] = {
            "hide_name": 1, "type": "$eq", "parameters": {
                "A_SIGNED": binary(0), "B_SIGNED": binary(0), "A_WIDTH": binary(2), "B_WIDTH": binary(2), "Y_WIDTH": binary(1)},
            "attributes": {}, "port_directions": {"A": "input", "B": "input", "Y": "output"},
            "connections": {"A": raw, "B": ["1", "1"], "Y": [select]}}
        module["cells"][f"$proof${name}$safe"] = {
            "hide_name": 1, "type": "$mux", "parameters": {"WIDTH": binary(2)}, "attributes": {},
            "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
            "connections": {"A": raw, "B": ["0", "0"], "S": [select], "Y": safe}}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--yosys")
    p.add_argument("--rtl", type=Path, default=PROJECT / "rtl/student_top.sv")
    p.add_argument("--out", type=Path, default=PROJECT / "build/final-rat-proof")
    args = p.parse_args()
    if not args.yosys:
        enter_appimage(DEFAULT_APPIMAGE)
    yosys = args.yosys or packaged_tool("yosys")
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=True)
    reference = ROOT / "verilog/area_v2_core.v"
    native = args.rtl.resolve()
    designs = {}
    states = {}
    for name, source in (("gold", reference), ("gate", native)):
        commands = [f'read_verilog -sv "{source}"']
        if name == "gold":
            commands += ["chparam -set SLOT_BITS 5 -set CHECKPOINTS 3 -set COMMIT_TREE 1 v2_rename"]
        commands += ["hierarchy -top v2_rename", "proc", "memory_map", "setattr -mod -unset keep_hierarchy",
                     "setattr -mod -unset keep", "setattr -unset keep", "flatten", "opt",
                     f"rename v2_rename {name}", f'write_json "{out / (name + ".json")}"']
        script = out / f"{name}.ys"; script.write_text("\n".join(commands) + "\n")
        run(yosys, script, out / f"{name}.log")
        designs[name] = json.loads((out / f"{name}.json").read_text())
        states[name] = aliases(designs[name]["modules"][name], name == "gate")
    shared = sorted(set(states["gold"]) & set(states["gate"]))
    state_bits = sum(len(states["gold"][name]) for name in shared)
    assert len(shared) >= 240 and state_bits >= 750, f"Incomplete state correspondence: {len(shared)} aliases, {state_bits} bits"
    for name, design in designs.items():
        module = design["modules"][name]
        ports = set(module["ports"])
        module["netnames"] = {(n if n in ports else "$private$" + n): v for n, v in module["netnames"].items()}
        for state in shared:
            module["netnames"][state] = {"hide_name": 0, "bits": states[name][state], "attributes": {}}
        legal_indices(module)
        (out / f"{name}-correspondence.json").write_text(json.dumps(design) + "\n")
    commands = [f'read_json "{out / "gold-correspondence.json"}"', f'read_json "{out / "gate-correspondence.json"}"',
                "equiv_make gold gate equiv", "hierarchy -top equiv", "opt_clean",
                "equiv_simple -seq 1", "equiv_induct -seq 2", "equiv_status -assert"]
    script = out / "proof.ys"; script.write_text("\n".join(commands) + "\n")
    run(yosys, script, out / "proof.log")
    result = {"status": "inductively-equivalent", "checkpoints": 3, "slot_bits": 5, "state_aliases": len(shared), "state_bits": state_bits,
              "proof_input_mapping": "Checkpoint index 3 maps to 0 in both circuits; legal indices 0..2 are unchanged",
              "reference_sha256": sha(reference), "native_rtl_sha256": sha(native),
              "script_sha256": sha(Path(__file__)), "recipe_sha256": sha(script), "log_sha256": sha(out / "proof.log")}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Three-checkpoint RAT: inductively equivalent, {len(shared)} matched register words/bits")

if __name__ == "__main__":
    main()
