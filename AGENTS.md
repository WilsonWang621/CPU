# ParaRISC — Coding Agent Instructions

These instructions apply to the repository unless a more specific `AGENTS.md` overrides them. They are persistent engineering constraints, **not** a request to restart the implementation. The active Codex `/goal` specifies the current target and completion criteria.

## 1. Mission and source of truth

Build and optimize a **parameterized, multi-issue, out-of-order-execution, in-order-commit RV32IM CPU in Chisel**, reusing and improving the existing implementation wherever feasible.

Use the following priority order when requirements conflict:

1. Explicit instructions in the current user request / active Goal.
2. The **latest official course repository**, including `README.md`, `docs/axi4-lite.md`, `docs/sram.md`, evaluation scripts and official testcases: <https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026>.
3. Verified behavior of the current project's code, together with agreed team interface contracts.
4. Team design and planning documents in `docs/` (which may be outdated).

In particular, older team documents contain obsolete ISA exceptions, scoring thresholds and memory-latency assumptions. Do **not** use those over the official course specifications. Read official material before implementing or evaluating. Do not assume an existing `README.md` describes completed functionality; inspect actual code.

**Stretch target (104 points):** pass every required correctness test and simultaneously achieve **total area <= 36,000 µm² (including FakeRAM), performance IPC geometric mean >= 1.0985 across every official `testcases/perf_*` benchmark, and measured Fmax >= 500 MHz**, all under the official evaluation environment. These are targets, not known achieved results. A 2.0 ns clock period is a timing target; supplying `CLOCK_PERIOD_NS=2.0` is not proof that timing is met.

## 2. Start by auditing and reusing existing work

Before changing the architecture:

- Inspect `git status`, local and remote branches, Git history, uncommitted changes, submodules, and actual project sources.
- Look for existing frontends, decoders, ALUs, branch units, AGUs, multipliers/dividers, ROBs, renamers, RS/IQs, LSQs, caches, Chisel generators and testing infrastructure. Some earlier implementations may exist only in local branches or working-tree files.
- Read `README.md`, `build.mill`, `Makefile`, `verilog/filelist.f`, the relevant source files and `docs/planning/` contracts.
- Create a factual inventory: usable modules, verified modules, missing modules, defects, available tests and current performance/area/timing evidence.
- Prefer adapting or extending working components, fixing integration points and removing specific bottlenecks over a wholesale rewrite.
- If no usable complete CPU exists, implement missing stages incrementally while retaining tested components. Explain why replacement of any existing module is necessary.

The project's public `main` branch may not represent the user's latest local implementation. Never overwrite uncommitted work or assume branch names imply module ownership.
