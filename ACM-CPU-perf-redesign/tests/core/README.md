# Rename and recovery regression

Run `python3 tests/core/run.py --jobs 2`. It builds a separate simulator in
`build/core`, with prediction disabled so loops repeatedly exercise recovery.
Assertions are enabled. All cases compare exit values, full final RAM, retirement
counts and complete instruction retirement traces against the reference model.
The runner snapshots RTL, monitor, simulator and its memory-model header, and the
Makefile before building, so concurrent workspace changes cannot alter a running
validation. `build-metadata.json` records their hashes and the selected Verilator
and simulation flags before compilation starts.

The bound simulation-only monitor requires that the suite actually observes:

- two instructions renamed together, including two writes to the same register;
- two instructions retired together;
- branch checkpoint recovery and speculative Load replay;
- an older branch redirecting after a younger branch already resolved;
- cancellation of a busy speculative multiply/divide operation;
- four instructions renamed and retired together.

The programs also cover repeated ROB/physical-register reuse, a delayed source
retaining its old physical mapping across many WAWs, and a committed destination
restored after speculative MDU and WAW cancellation. A delayed older Store
address forces a younger Load that overwrites a register to replay, checking its
pre-load rename map and subsequent WAWs. The monitor asserts that every redirect
restores the exact saved RAT checkpoint on the following edge. Coverage counters
prevent a passing architectural result from silently missing these events.
Other timing/parameter configurations can need different stimuli, so this suite
reports its exact configuration in `summary.json`.

Delay-producing DIVU instructions use full-width, changing operands so divider
normalization and its completed-operand cache remain enabled without removing
the intended overlap. Dependency delays use arithmetic rather than moves.
