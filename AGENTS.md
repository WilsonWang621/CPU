# ParaRISC — Coding Agent Instructions

These instructions apply unless a more specific `AGENTS.md` overrides them. They are persistent engineering constraints, **not** a request to restart implementation. Follow the current user task and active Goal, if any.

## 1. Mission and source of truth

Build and optimize a **parameterized, multi-issue, out-of-order-execution, in-order-commit RV32IM CPU in Chisel**, reusing existing implementations wherever feasible.

Use this priority order:

1. Explicit instructions in the current user request / active Goal.
2. The **latest official course repository**, including its README, `docs/axi4-lite.md`, `docs/sram.md`, evaluation scripts and official testcases: <https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026>.
3. Verified behavior of this project's code and agreed interface contracts.
4. Local design documents and archived plans, which may be outdated.

Read official material before changing hardware requirements or evaluating results. Older documents contain obsolete ISA exceptions, scoring thresholds and memory-latency assumptions. Read actual code; a README assertion is not implementation evidence. Remote-tracking refs can also be stale: the framework synchronization provenance is recorded in [the 2026-10-15 report](reports/framework/upstream-sync-2026-10-15.md).

**Stretch target (104 points):** pass every required correctness test and simultaneously achieve **total area ≤36,000 µm² including actual FakeRAM, IPC geometric mean ≥1.0985 across every official `testcases/perf_*`, and measured Fmax ≥500 MHz**, under the official evaluation environment. These are acceptance targets. A `CLOCK_PERIOD_NS=2.0` constraint is not proof that timing is met.

Archived, configuration-specific measurements are separate from these targets: [dual-issue Chisel, 2026-10-16](dual-issue-chisel/reports/requirements-2026-10-16/report.md), [single-issue v110, 2026-10-21](single-issue-chisel/reports/area-recovery-2026-10-21/report.md), and [Verilog reference, 2026-10-16](reports/dual-issue/frequency-stage10.md). Do not describe historical measurements or an evidence audit as a fresh simulation, synthesis or STA run. See [the homepage](README.md) and [report index](reports/README.md) for their conditions and limitations.

## 2. Audit and preserve existing work

Before making changes:

- Read this file and any applicable nested instructions. Inspect `git status`, the current branch, local and remote branches, remotes, recent history, worktrees and submodules, plus the actual relevant files.
- Preserve all uncommitted and staged work. Do not reset, overwrite or discard teammates' changes. Branch names and the public remote `main` do not establish which implementation is latest.
- For repository-management, documentation, validation and presentation improvements, work on `chore/repository-improvements`. If it already exists, inspect its contents and relation to the current work before reusing it; create it from the inspected local implementation if absent. Do not force-switch a dirty worktree.
- Keep CPU behavior, default parameters, the course interface, evaluation scripts, area accounting and synthesis constraints unchanged during repository-improvement work. Reuse existing scripts, configurations and reports instead of creating a parallel framework.
- Complete authorized local edits and necessary checks. Do not push, merge or publish until explicitly authorized. After each completed step report the changes, checks actually run and unresolved issues.

Before architecture work, also inventory usable modules, verified modules, missing modules, defects, tests and performance/area/timing evidence. Look for existing frontends, decoders, ALUs, branch units, AGUs, MDU, ROB, renaming, IQ/RS, load/store logic, caches and generators, including other local branches and working-tree files. Prefer specific fixes and integration improvements over a rewrite; explain any necessary replacement.

## 3. Current implementation and build entry points

| Implementation | Editable source and generator | Delivery / use |
| --- | --- | --- |
| **Default dual-issue Chisel** | [tier3 Scala](dual-issue-chisel/src/main/scala/tier3/), `Top.scala: StudentTop`, `Generate.scala: tier3.Generate`; [build.sbt](dual-issue-chisel/build.sbt) and [Makefile](dual-issue-chisel/Makefile) | Root [verilog/filelist.f](verilog/filelist.f) selects `dual-issue-chisel/rtl/student_top.sv`; the project's [rtl/filelist.f](dual-issue-chisel/rtl/filelist.f) selects the same RTL. |
| Independent single-issue Chisel | [tier2 Scala](single-issue-chisel/src/main/scala/tier2/), `Core.scala: StudentTop / tier2.Generate`; [build.sbt](single-issue-chisel/build.sbt) | [Makefile](single-issue-chisel/Makefile) selects [rtl/filelist.f](single-issue-chisel/rtl/filelist.f); [baseline.json](single-issue-chisel/baseline.json) selects the frozen delivery baseline. |
| Dual-issue Verilog reference | [verilog/area_v2/](verilog/area_v2/), [student_top.sv](verilog/student_top.sv), [pararisc_axi_adapter.sv](verilog/pararisc_axi_adapter.sv) | Explicit [reference_filelist.f](verilog/reference_filelist.f) selects exported `area_v2_core.v`, adapter and top; used for reference builds and differential/equivalence checks. |

All three tops are named `student_top`; build each separately. Default Chisel has two dispatch lanes, two integer ports, one LSU and two commit lanes. `issueWidth=3` counts all three potential new issues, not three integer ALUs. Single-issue `Config` requires `issueWidth==1`. Read actual parameter constraints before experiments.

Read the root `README.md`, `Makefile`, `config.mk`, all relevant filelists, the chosen project's `build.sbt` / `Makefile`, generator and source files. Both active Chisel projects use sbt. There is **no root `build.mill` or `docs/planning/`**: the inactive Mill prototype is in [archive/chisel-prototype/](archive/chisel-prototype/), and old planning documents are in [archive/planning/](archive/planning/). They are historical context, not the active build or implementation contract.

Generation commands, from the repository root:

```sh
make -C dual-issue-chisel generate
make -C single-issue-chisel generate
make export-verilog
```

These regenerate delivery artifacts; run only the relevant command when generation is part of the task. Dual-issue generation uses the editable Scala sources. Single-issue `generate` invokes [generate_baseline.py](single-issue-chisel/scripts/generate_baseline.py): regenerate from the selected report's frozen sources, compare the circuit, then publish the byte-identical measured RTL. It does **not** publish arbitrary changes in editable `src/`. For single-issue source experiments, invoke `tier2.Generate` via sbt with a separate `--out build/...` and explicit recorded parameters, as described in [its README](single-issue-chisel/README.md). Verilog export updates the reference core and hash manifest, not the Chisel delivery or root filelist.

## 4. Run checks for the selected implementation

Commands below run from the repository root. Configure tools in [config.mk](config.mk); use `APPIMAGE_EXTRACT_AND_RUN=1` for AppImage environments without FUSE. Root Make targets build the default dual-issue Chisel RTL. Supplying `SIM` uses that existing executable and skips compilation for `run/test/perf`: keep implementation-specific `BUILD` / `OUT` and `SIM` paths, and never assume a different `FILELIST` changes an already selected simulator.

Default build and functional/performance checks:

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make build BUILD=build/default JOBS=8
make test SIM=build/default/sim LATENCY=10 MAX_CYCLES=20000000
make test SIM=build/default/sim LATENCY=20 MAX_CYCLES=20000000
make perf SIM=build/default/sim LATENCY=10 MAX_CYCLES=20000000
make perf SIM=build/default/sim LATENCY=20 MAX_CYCLES=20000000
APPIMAGE_EXTRACT_AND_RUN=1 make synth SYNTH_OUT=build/default-synth
```

Independent single-issue checks:

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make -C single-issue-chisel build
make -C single-issue-chisel test LATENCY=20
make -C single-issue-chisel perf LATENCY=20
APPIMAGE_EXTRACT_AND_RUN=1 make -C single-issue-chisel synth
```

The single-issue Makefile defaults to a 30,000,000-cycle limit; also use `LATENCY=10` when both latency results are needed. To reproduce the archived v110 measurement, follow its [report](single-issue-chisel/reports/area-recovery-2026-10-21/report.md) and existing `reproduce.sh`, which preserves inputs and uses an English temporary path for the documented tool path-encoding issue.

Reference-only checks:

```sh
APPIMAGE_EXTRACT_AND_RUN=1 make build FILELIST=verilog/reference_filelist.f BUILD=build/reference JOBS=8
make test SIM=build/reference/sim LATENCY=20 MAX_CYCLES=20000000
make perf SIM=build/reference/sim LATENCY=10 MAX_CYCLES=20000000
make perf SIM=build/reference/sim LATENCY=20 MAX_CYCLES=20000000
make verify-rtl
APPIMAGE_EXTRACT_AND_RUN=1 make synth FILELIST=verilog/reference_filelist.f SYNTH_OUT=build/reference-synth
```

`make verify-rtl` checks Verilog reference modules; it is not native Chisel validation. Native unit/associativity checks use `python3 dual-issue-chisel/scripts/verify_units.py --associativity --generate`; parameter, formal and whole-CPU differential workflows are documented in [the dual-issue README](dual-issue-chisel/README.md). Reuse those workflows rather than substituting reference-only checks.

`python3 dual-issue-chisel/scripts/audit_requirements.py` is a read-only audit of archived input hashes, raw logs and summaries against current delivery inputs. It does not rerun simulation or STA. An input-identity mismatch requires investigation; never refresh hashes or rewrite archived reports just to make an audit pass. Historical Verilog reports may call Verilog the default: use today's explicit reference filelist when reproducing that implementation.

## 5. Documentation and evidence

- Run checks appropriate to the changes. Documentation-only tasks require link, command-routing and diff checks, not an automatic CPU regeneration or full remeasurement. State exactly which checks ran.
- Record new measurement inputs, RTL/source identities, parameters, tools/constraints, correctness coverage, all official performance cases and raw area/STA results. Do not combine frequency, area and IPC from different configurations or tool flows. Keep old measurements intact and identify failed or unverified candidates.
- Keep [README.md](README.md), [docs/README.md](docs/README.md) and [reports/README.md](reports/README.md) navigable in both directions; check repository-relative links and changed anchors.
- Default architecture links refer to `dual-issue-chisel`. Preserve the independent single-issue diagram and clearly label its implementation. Existing diagram sources, HTML, GIF and receipts are indexed in [docs/architecture/README.md](docs/architecture/README.md). Diagram validation is separate from CPU validation; do not hand-edit checked HTML or its evidence when only changing navigation.
