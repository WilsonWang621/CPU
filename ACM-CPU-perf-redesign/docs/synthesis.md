# Reproducible Verilog export, synthesis and static timing

`python3 scripts/bootstrap_synth.py` installs the pinned official OSS CAD Suite
2026-09-20, sv2v 0.0.13, OpenSTA 2.0.17 with its Tcl runtime, 7zip, and five
ASAP7 RVT TT NLDM libraries under `build/tools`. No system installation or sudo
is required. The suite supplies Yosys 0.69+75, Slang and ABC. Every download has
a SHA-256 lock; the suite archive is also checked against the publisher's
release digest. See `scripts/modern_synthesis.lock.json` and
`scripts/synthesis.lock.json`. Existing verified suite binaries are reused;
the installer refuses to overwrite a different or unverified suite in place.
Original tool and library licenses remain in their extracted directories.

```sh
python3 scripts/bootstrap_synth.py
python3 scripts/export_verilog.py
bash scripts/synth.sh --mode check --output build/synth-check
bash scripts/synth.sh --mode generic --output build/synth-generic
bash scripts/synth.sh --mode asap7 --output build/synth-asap7
```

The standalone export produces complete Verilog-2005 in `build/synth/cpu.v`,
including debug outputs. Its metadata records every RTL source hash, converter
version and output hash. sv2v preserves process kinds during conversion; the
exporter then expresses them as ordinary Verilog `always` processes.

Assessment synthesis first converts the frozen source snapshot to Verilog-2005
and reads that Verilog with the pinned Slang frontend. `--systemverilog` is an
explicit diagnostic option. It
copies every source into the output directory before running and records those
copies' hashes. A generated `cpu_synth` wrapper exposes only the memory bus and
halt/fault status, allowing unused debug logic to be pruned before expensive
passes. Core, caches, physical registers, predictor and queues are all included;
there are no cache black boxes or excluded on-chip memories. The external RAM
is a simulator component and is outside the synthesis inputs.

`read_slang --best-effort-hierarchy --no-implicit-memories` retains module
boundaries for initial simplification. Control arrays use decoded register
writes; only actual storage arrays carry an explicit memory attribute. The
D-cache data array is one-dimensional with 32-bit words and byte write enables;
I-cache uses line-wide storage words and two packet read ports. Packed metadata
is exposed as unpacked narrow row/word columns before dynamic selection.
This avoids both next-state copies becoming hundreds of apparent RAM ports and
multidimensional data arrays becoming a few extremely wide memory words.

The core computes bounded execution, writeback and dispatch events once per
port. Each physical ROB/RAS entry decodes its destination. RAT recovery reconstructs
the surviving mappings in one edge rather than storing a full map per ROB entry. Store
forwarding reads fixed physical entries and compares circular ages instead of
rotating an array index through a full scan. These RTL changes remove repeated
full-record crossbars and whole-array field updates before synthesis starts.

After per-module optimization, the flow flattens and prunes disconnected debug
logic, collects genuine memories and maps every storage bit to standard logic.
`memory_share -nosat -nowiden` merges byte enables only when their addresses
match, producing the three actual word write ports. `memory_collect; memory_map`
then preserves write priority without the optional memory-priority SAT search.
Width reduction and `techmap` lower the remaining logic. Unused temporary gates
are removed before checkpointing. ABC topological structural hashing replaces
the pathological bit-level `opt_merge` loop (261 full rehashes in the diagnosed
run). The default mapping path omits `dc2`: on the full graph, that pass alone
also exceeded a 180-second diagnostic limit. `--abc-effort rewrite` explicitly
enables it for bounded experiments; `resynthesis` selects ABC's default script.
See the [per-stage ABC audit](../reports/abc_stage_audit.md).
Flip-flops are legalized before combinational mapping;
constant FF cleanup and final Liberty mapping follow it. The default `&nf` map
is followed by real fanout buffering and bounded gate sizing. Generic checks
use the corresponding generic ABC flow. Final checks include `check -assert -mapped -nolatches`; loops, undriven
wires, multiple drivers, unmapped cells, latches and missing modules are not
waived. See the bounded reproducers in [tests/synthesis](../tests/synthesis/README.md)
and the [cache scaling audit](../reports/cache_synthesis_scaling.md).

`--source-root PATH` selects a repository or frozen snapshot containing `rtl/`.
Its actual file hashes identify the inputs; the recorded Git commit describes
the workspace context and need not be the frozen source revision.
`--param NAME=INTEGER` selects the same `cpu_top` parameters used by simulation.
All overrides are recorded. The measured lean four-wide candidate (IPC 1.092137; physical acceptance pending) is:

```sh
bash scripts/synth.sh --mode asap7 --output build/synth-lean \
  --param PHYS_REGS=64 --param ROB_ENTRIES=32 --param IQ_ENTRIES=24 \
  --param LQ_ENTRIES=16 --param SQ_ENTRIES=16 --param CSB_ENTRIES=16 \
  --param FETCH_QUEUE_ENTRIES=16 --param FETCH_REQUESTS=8 --param RAS_DEPTH=4 \
  --param BHT_ENTRIES=256 --param BTB_ENTRIES=64 --param PREDICTOR_MODE=0 \
  --param ICACHE_BYTES=1024 --param DCACHE_BYTES=4096 --param DCACHE_WAYS=4 \
  --param I_MSHRS=4 --param D_MSHRS=8
```

`elaborate` resolves modules and parameters and lowers processes; `check` also
lowers to generic logic and checks connectivity; `generic` additionally exports
the generic netlist; `asap7`
maps to the pinned RVT TT cells and then runs OpenSTA. Each run preserves its
script, full log, source snapshot and metadata, including failures/timeouts.
`--skip-sta` stops after mapping with status `mapped_only`, never a timing pass.
`--sta-timeout` controls the separate OpenSTA limit (default 600 seconds).
Metadata separates `yosys_status` from `static_timing_status`; an unsuccessful
timing run also makes the driver's overall status `timing_failed`.
`elaborated.il`, `coarse.il`, `techmapped.il`, generic or mapped final output, and corresponding JSON statistics
preserve successfully completed stages before more expensive work. The default
Yosys timeout is 1,800 seconds; it terminates the entire tool process group.
Old Yosys 0.33 experiment logs may remain under `build/perf-synth`, but neither
the bootstrap nor the active driver downloads or executes that obsolete flow.

ASAP7 tables use 1 ps time units. The default ABC delay target is 3,333.333 ps
(`--delay-ps`); that target is an optimization request, not a measured frequency.
Mapped areas use the original Liberty area numbers without rescaling. Area
results describe standard-cell implementations of all included arrays; they do
not assume unprovided SRAM macros or an undocumented course scoring conversion.

OpenSTA reads the actual mapped netlist and merged Liberty. It uses an ideal
3,333.333 ps clock, zero input/output delays, 20 ps input/clock transitions,
1 fF output loads, and no wire parasitics. All non-clock inputs, including the
synchronous reset, are timed; there are no false paths. `sta/timing.log` includes
setup/hold paths, constraint checks and electrical checks. `sta/timing.json`
records exact netlist/library hashes, assumptions and worst setup slack. A
cell-only maximum frequency is derived from period minus worst setup slack
only when setup coverage checks are clean. A successful script execution does
not mean the chosen period passes: inspect `setup_meets_target` and the hold
and electrical reports. Rerun timing independently with:

```sh
python3 scripts/static_timing.py --netlist build/synth-lean/netlist.v \
  --output build/synth-lean/sta --period-ps 3333.333
```

These are pre-layout RVT TT 0.7 V, 25 C cell timing results. They do not include
place-and-route, extracted interconnect, a clock tree or PVT signoff. Report any
area/frequency result with its exact RTL hashes, parameters and these limits.

Primary upstream sources: [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build),
[release and published digest](https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-09-20),
[Slang frontend](https://github.com/povik/yosys-slang),
[sv2v](https://github.com/zachjs/sv2v),
[OpenSTA](https://github.com/parallaxsw/OpenSTA),
[ASAP7 standard cells](https://github.com/The-OpenROAD-Project/asap7sc7p5t_28).
