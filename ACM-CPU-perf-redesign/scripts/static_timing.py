#!/usr/bin/env python3
"""Run cell-only OpenSTA with explicit I/O assumptions on a mapped CPU netlist."""
import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def tcl_path(path):
    text = str(path)
    if any(c in text for c in "{}\n\r"):
        raise ValueError("Tcl paths must not contain braces or line breaks")
    return "{" + text + "}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--netlist", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "build/sta")
    parser.add_argument("--tools-dir", type=Path, default=ROOT / "build/tools")
    parser.add_argument("--top", default="cpu_synth")
    parser.add_argument("--period-ps", type=float, default=3333.333)
    parser.add_argument("--transition-ps", type=float, default=20.0)
    parser.add_argument("--load-ff", type=float, default=1.0)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", args.top):
        parser.error("Invalid top module name")
    if min(args.period_ps, args.transition_ps, args.load_ff, args.timeout) <= 0:
        parser.error("Period, transitions, output load and timeout must be positive")
    output, netlist, tools = args.output.resolve(), args.netlist.resolve(), args.tools_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    library = tools / "asap7-libs/asap7_rvt_tt.lib"
    support = tools / "synth-support/usr"
    sta = support / "bin/sta"
    environment = dict(os.environ)
    environment["LD_LIBRARY_PATH"] = str(support / "lib/x86_64-linux-gnu")
    environment["TCL_LIBRARY"] = str(support / "share/tcltk/tcl8.6")
    commands = f"""read_liberty {tcl_path(library)}
set_cmd_units -time ps -capacitance fF
read_verilog {tcl_path(netlist)}
link_design {args.top}
create_clock -name clk -period {args.period_ps} [get_ports clk]
set data_inputs {{}}
foreach port [all_inputs] {{
  if {{[get_full_name $port] ne "clk"}} {{ lappend data_inputs $port }}
}}
set_input_delay -clock clk 0 $data_inputs
set_output_delay -clock clk 0 [all_outputs]
set_input_transition {args.transition_ps} $data_inputs
set_clock_transition {args.transition_ps} [get_clocks clk]
set_load {args.load_ff} [all_outputs]
puts "TIME_UNIT_SECONDS [sta::time_ui_sta 1.0]"
puts "BEGIN_CHECK_SETUP"
check_setup -verbose
puts "END_CHECK_SETUP"
puts "BEGIN_SETUP_PATHS"
report_checks -path_delay max -group_count 10 -digits 6
report_worst_slack -digits 6
report_wns
report_tns
puts "END_SETUP_PATHS"
puts "BEGIN_HOLD_PATHS"
report_checks -path_delay min -group_count 5 -digits 6
puts "END_HOLD_PATHS"
puts "BEGIN_ELECTRICAL_CHECKS"
report_check_types -max_transition -min_pulse_width -min_period -all_violators
puts "END_ELECTRICAL_CHECKS"
puts "TIMING_COMPLETE"
"""
    script = output / "timing.tcl"
    script.write_text(commands)
    metadata = {
        "netlist": str(netlist),
        "netlist_sha256": hashlib.sha256(netlist.read_bytes()).hexdigest(),
        "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
        "opensta": subprocess.check_output([str(sta), "-version"], env=environment, text=True).strip(),
        "top": args.top, "period_ps": args.period_ps,
        "input_delay_ps": 0, "output_delay_ps": 0,
        "input_and_clock_transition_ps": args.transition_ps, "output_load_ff": args.load_ff,
        "clock_network": "ideal", "wire_parasitics": "none",
        "reset": "synchronous, timed as ordinary input, no false paths",
        "scope": "cell-only pre-layout RVT TT 0.7V 25C; not physical signoff",
    }
    start = time.monotonic()
    with (output / "timing.log").open("w") as log:
        process = subprocess.Popen([str(sta), "-exit", "-no_init", str(script)],
                                   stdout=log, stderr=subprocess.STDOUT,
                                   env=environment, start_new_session=True)
        try:
            status = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait()
            status = 124
    report = (output / "timing.log").read_text()
    metadata["wall_seconds"] = time.monotonic() - start
    metadata["errors"] = re.findall(r"^Error:.*$", report, re.MULTILINE)
    metadata["warnings"] = re.findall(r"^Warning:.*$", report, re.MULTILINE)
    setup = re.search(r"BEGIN_CHECK_SETUP\n(.*?)END_CHECK_SETUP", report, re.DOTALL)
    metadata["setup_checks"] = setup[1].strip() if setup else None
    hold = re.search(r"BEGIN_HOLD_PATHS\n(.*?)END_HOLD_PATHS", report, re.DOTALL)
    if hold:
        slacks = re.findall(r"([-+0-9.eE]+)\s+slack\s+\(", hold[1])
        if slacks:
            metadata["worst_hold_slack_ps"] = min(map(float, slacks))
            metadata["hold_meets_target"] = metadata["worst_hold_slack_ps"] >= 0
    electrical = re.search(r"BEGIN_ELECTRICAL_CHECKS\n(.*?)END_ELECTRICAL_CHECKS", report, re.DOTALL)
    metadata["electrical_checks_clean"] = electrical is not None and not electrical[1].strip()
    slack = re.search(r"^worst slack\s+([-+0-9.eE]+)", report, re.MULTILINE)
    complete = bool(status == 0 and "TIMING_COMPLETE" in report and not metadata["errors"] and slack)
    metadata["analysis_complete"] = complete
    coverage_clean = setup is not None and not setup[1].strip()
    linked = not any("black box" in warning.lower() for warning in metadata["warnings"])
    if complete:
        metadata["worst_setup_slack_ps"] = float(slack[1])
        metadata["setup_meets_target"] = float(slack[1]) >= 0
        if coverage_clean and linked:
            period = args.period_ps - float(slack[1])
            metadata["cell_only_critical_period_ps"] = period
            metadata["cell_only_setup_fmax_mhz"] = 1e6 / period if period > 0 else None
    verified = complete and coverage_clean and linked
    metadata["status"] = "pass" if verified else "failed"
    (output / "timing.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"OpenSTA {metadata['status']}: {output / 'timing.json'}")
    return 0 if verified else status or 1


if __name__ == "__main__":
    raise SystemExit(main())
