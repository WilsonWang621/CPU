#!/usr/bin/env python3
"""Check/synthesize the CPU with pinned modern Slang/Yosys and optional ASAP7 STA."""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from export_verilog import convert

ROOT = Path(__file__).resolve().parents[1]


def wrapper(parameters):
    assignments = ", ".join(f".{name}({value})" for name, value in parameters.items())
    overrides = f"#({assignments})" if assignments else ""
    return f"""module cpu_synth (
  input clk, rst, mem_req_ready, mem_rsp_valid, mem_rsp_error,
  input [31:0] mem_rsp_rdata,
  output mem_req_valid, mem_req_write, mem_rsp_ready, halted, faulted,
  output [31:0] mem_req_addr, mem_req_wdata,
  output [3:0] mem_req_wstrb
);
  cpu_top {overrides} cpu (
    .clk(clk), .rst(rst), .mem_req_ready(mem_req_ready),
    .mem_rsp_valid(mem_rsp_valid), .mem_rsp_error(mem_rsp_error),
    .mem_rsp_rdata(mem_rsp_rdata), .mem_req_valid(mem_req_valid),
    .mem_req_write(mem_req_write), .mem_rsp_ready(mem_rsp_ready),
    .mem_req_addr(mem_req_addr), .mem_req_wdata(mem_req_wdata),
    .mem_req_wstrb(mem_req_wstrb), .halted(halted), .faulted(faulted)
  );
endmodule
"""


def yosys_quote(path):
    return '"' + str(path).replace("\\", "\\\\").replace('"', '\\"') + '"'


def abc_inline(script):
    # ABC's generated `source PATH` command does not quote paths containing
    # spaces. Pass the documented inline form; still archive the readable file.
    return yosys_quote("+" + ";".join(line.replace(" ", ",")
                                    for line in script.splitlines() if line))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/synth")
    parser.add_argument("--source-root", type=Path, default=ROOT,
                        help="repository or frozen snapshot containing rtl/")
    parser.add_argument("--tools-dir", type=Path, default=ROOT / "build/tools")
    parser.add_argument("--mode", choices=["elaborate", "check", "generic", "asap7"], default="check")
    parser.add_argument("--param", action="append", default=[], metavar="NAME=INTEGER")
    parser.add_argument("--delay-ps", type=float, default=3333.333)
    parser.add_argument("--abc-effort", choices=["direct", "rewrite", "resynthesis"], default="direct",
                        help="rewrite uses one dc2 pass then &nf; direct omits dc2; resynthesis uses ABC defaults")
    parser.add_argument("--timeout", type=int, default=1800)
    parser.add_argument("--unroll-limit", type=int, default=16384,
                        help="Slang static loop guard; large queue configurations may need a higher explicit limit")
    parser.add_argument("--sta-timeout", type=int, default=600)
    parser.add_argument("--skip-sta", action="store_true",
                        help="save a mapped netlist without claiming timing verification")
    parser.add_argument("--systemverilog", action="store_true",
                        help="diagnostic SV input; assessment default exports Verilog-2005 first")
    args = parser.parse_args()
    directory, tools, source_root = args.output.resolve(), args.tools_dir.resolve(), args.source_root.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    parameters = {}
    valid_names = set(re.findall(r"\b([A-Z][A-Z0-9_]*)\s*=", (source_root / "rtl/cpu_top.sv").read_text().split(") (")[0]))
    for argument in args.param:
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=([0-9]+)", argument)
        if not match or match[1] not in valid_names:
            parser.error(f"Invalid CPU parameter: {argument}")
        parameters[match[1]] = int(match[2])
    if args.delay_ps <= 0 or args.timeout <= 0 or args.sta_timeout <= 0 or args.unroll_limit <= 0:
        parser.error("Delay and timeout must be positive")
    source_dir = directory / "source"
    source_dir.mkdir(exist_ok=True)
    sources = [source_root / "rtl/cpu_pkg.sv"] + sorted(
        path for path in (source_root / "rtl").glob("*.sv") if path.name != "cpu_pkg.sv")
    hashes = {}
    for source in sources:
        target = source_dir / source.name
        shutil.copyfile(source, target)
        hashes[str(source.relative_to(source_root))] = hashlib.sha256(target.read_bytes()).hexdigest()
    top = directory / "cpu_synth.v"
    top.write_text(wrapper(parameters))
    yosys = tools / "oss-cad-suite/bin/yosys"
    abc = tools / "oss-cad-suite/bin/yosys-abc"
    library = tools / "asap7-libs/asap7_rvt_tt.lib"
    if not yosys.is_file():
        parser.error("Modern Yosys missing; run python3 scripts/bootstrap_synth.py")
    environment = dict(os.environ)
    # OSS CAD Suite wrappers select their own bundled runtime and Yosys data.
    environment.pop("YOSYS_DATDIR", None)
    input_sources = [source_dir / source.name for source in sources]
    export_metadata = None
    if not args.systemverilog:
        sv2v = tools / "sv2v-Linux/sv2v"
        if not sv2v.is_file():
            parser.error("sv2v missing; run python3 scripts/bootstrap_synth.py")
        exported = directory / "cpu_source.v"
        converted, command = convert(input_sources, sv2v)
        exported.write_text(converted)
        export_metadata = {"sv2v": subprocess.check_output([str(sv2v), "--version"], text=True).strip(),
                           "command": command,
                           "sha256": hashlib.sha256(exported.read_bytes()).hexdigest()}
        input_sources = [exported]
    # The maintained Slang frontend also reads plain Verilog. Its command-file
    # parser, unlike direct filename arguments, supports quoted paths correctly.
    (directory / "sources.f").write_text("\n".join(
        yosys_quote(source) for source in input_sources + [top]) + "\n")
    # This is a static elaboration guard, not an optimization effort setting.
    # Bounded selection trees at the selected queue capacities can exceed
    # Slang's default 4,000 loop iterations within one combinational process.
    # Keep a finite guard and measure the resulting graph at every stage.
    commands = [f"read_slang --best-effort-hierarchy --top cpu_synth --no-implicit-memories --unroll-limit {args.unroll_limit} -D SYNTHESIS -f sources.f",
                f"tee -o {yosys_quote(directory / 'elaborated-stat.json')} stat -json",
                f"write_rtlil {yosys_quote(directory / 'elaborated.il')}"]
    if args.mode in ("check", "generic", "asap7"):
        # Simplify each real module before flattening; then prune disconnected
        # debug ports. Explicit data arrays are true 32-bit-word memories.
        # Direct memory_map preserves write priority; the optional quadratic
        # memory-priority search adds no required correctness transformation.
        commands += ["hierarchy -check -top cpu_synth", "opt_clean", "opt -fast", "wreduce",
                     "flatten -noscopeinfo", "opt -fast", "wreduce", "peepopt", "opt_clean",
                     "alumacc", "opt -fast", "memory_share -nosat -nowiden", "memory_collect", "opt_clean",
                     f"tee -o {yosys_quote(directory / 'coarse-stat.json')} stat -json",
                     f"write_rtlil {yosys_quote(directory / 'coarse.il')}",
                     "memory_map", "opt -fast", "techmap", "opt_clean",
                     f"tee -o {yosys_quote(directory / 'techmapped-stat.json')} stat -json",
                     f"write_rtlil {yosys_quote(directory / 'techmapped.il')}"]
        # A bit-level opt_merge on this design took 261 full graph rehashes.
        # ABC strash deduplicates combinational nodes in topological order;
        # Optional Boolean rewriting can further simplify the network. Keep FF simplification and
        # strict final checks, without the repeated multi-million-cell merge.
        if args.mode != "asap7":
            generic_script = directory / "generic.abc"
            rewrite = "dc2\n" if args.abc_effort == "rewrite" else ""
            generic_script.write_text(f"strash\n{rewrite}map\n")
            mapping_option = f" -script {abc_inline(generic_script.read_text())}" if args.abc_effort != "resynthesis" else ""
            commands += ["dffunmap",
                         f"abc -exe {yosys_quote(abc)} -g simple{mapping_option}",
                         "opt_clean", "opt_dff -nodffe -nosdff", "opt_clean",
                         f"tee -o {yosys_quote(directory / 'generic-stat.json')} stat -json",
                         f"write_rtlil {yosys_quote(directory / 'generic.il')}",
                         "check -assert -nolatches",
                         f"write_verilog -noattr -simple-lhs {yosys_quote(directory / 'cpu.v')}"]
    if args.mode == "asap7":
        if not library.is_file():
            parser.error("Merged Liberty missing; run python3 scripts/bootstrap_synth.py")
        abc_script = directory / "map.abc"
        rewrite = "dc2\n" if args.abc_effort == "rewrite" else ""
        abc_script.write_text(f"strash\n{rewrite}&get -n\n&nf -D {args.delay_ps}\n&put\nbuffer -p -N 8 -S 100\nupsize -D {args.delay_ps} -T 10\n")
        mapping_option = f" -script {abc_inline(abc_script.read_text())}" if args.abc_effort != "resynthesis" else ""
        commands += [f"read_liberty -lib {yosys_quote(library)}",
                     f"dfflibmap -prepare -liberty {yosys_quote(library)}",
                     f"abc -exe {yosys_quote(abc)} -liberty {yosys_quote(library)} -D {args.delay_ps}{mapping_option}",
                     "opt_clean", "opt_dff -nodffe -nosdff",
                     f"dfflibmap -map-only -liberty {yosys_quote(library)}",
                     "clean", "hierarchy -check -top cpu_synth",
                     f"write_rtlil {yosys_quote(directory / 'mapped.il')}",
                     "check -assert -mapped -nolatches",
                     f"tee -o {yosys_quote(directory / 'area.json')} stat -json -liberty {yosys_quote(library)}"]
    else:
        commands += [f"tee -o {yosys_quote(directory / 'stat.json')} stat -json"]
    if args.mode in ("generic", "asap7"):
        commands += [f"write_verilog -noattr -simple-lhs {yosys_quote(directory / 'netlist.v')}"]
    script = directory / "synth.ys"
    script.write_text("\n".join(commands) + "\n")
    metadata = {
        "rtl_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_root": str(source_root),
        "commit_scope": "workspace Git context; exact synthesis inputs are identified by sources_sha256",
        "sources_sha256": hashes,
        "frontend": "read_slang --best-effort-hierarchy --no-implicit-memories",
        "static_loop_unroll_limit": args.unroll_limit,
        "input_language": "systemverilog" if args.systemverilog else "verilog-2005",
        "bit_optimization": "ABC topological structural hashing; optional explicit rewriting; no global bit opt_merge",
        "export": export_metadata,
        "toolchain_lock": json.loads((ROOT / "scripts/modern_synthesis.lock.json").read_text()),
    }
    metadata.update(mode=args.mode, parameters=parameters,
                    yosys=subprocess.check_output([str(yosys), "-V"], env=environment, text=True).strip(),
                    abc_delay_target_ps=args.delay_ps if args.mode == "asap7" else None,
                    abc_effort=args.abc_effort if args.mode != "elaborate" else None,
                    library_lock=json.loads((ROOT / "scripts/synthesis.lock.json").read_text())["asap7"],
                    debug_outputs_connected=False, external_ram_included=False,
                    physical_timing_verified=False, timeout_seconds=args.timeout)
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    start = time.monotonic()
    print(f"Running Yosys {args.mode}; log: {directory / 'yosys.log'}", flush=True)
    with (directory / "yosys.log").open("w") as log:
        process = subprocess.Popen([str(yosys), "-Q", "-d", "--perffile",
                                    str(directory / "pass-timing.json"), "-s", str(script)], cwd=directory,
                                   stdout=log, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        (directory / "process.json").write_text(json.dumps({"pid": process.pid}) + "\n")
        try:
            status = process.wait(timeout=args.timeout)
            metadata["status"] = "pass" if status == 0 else "failed"
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait()
            status = 124
            metadata["status"] = "timeout"
    metadata["wall_seconds"] = time.monotonic() - start
    metadata["yosys_status"] = metadata["status"]
    (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if status == 0 and args.mode == "asap7" and not args.skip_sta:
        status = subprocess.call(["python3", str(ROOT / "scripts/static_timing.py"),
                                  "--netlist", str(directory / "netlist.v"),
                                  "--tools-dir", str(tools), "--output", str(directory / "sta"),
                                  "--period-ps", str(args.delay_ps),
                                  "--timeout", str(args.sta_timeout)])
        metadata["static_timing_status"] = "pass" if status == 0 else "failed"
        if status != 0:
            metadata["status"] = "timing_failed"
        (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    elif status == 0 and args.mode == "asap7":
        metadata["static_timing_status"] = "not_run"
        metadata["status"] = "mapped_only"
        (directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Synthesis {metadata['status']}; metadata: {directory / 'metadata.json'}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
