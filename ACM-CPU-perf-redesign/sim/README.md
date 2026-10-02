# Standalone simulation

`main.cpp` drives the `cpu_top` interface specified in `docs/interfaces.md`. The
three supplied repositories contain the complete course inputs; no additional
framework is needed. The default binary path used by scripts is `build/cpu_sim`.

```sh
build/cpu_sim --image RISC-V-CPU-2026-Testcases/correctness_add_to_100/program.data \
  --expected RISC-V-CPU-2026-Testcases/correctness_add_to_100/expected.txt \
  --memory RISC-V-CPU-2026-Testcases/correctness_add_to_100/expected.memory \
  --instructions 421 --latency 3
python3 scripts/run_tests.py --latency 3 --jobs 2
python3 scripts/run_tests.py --latency 20 --jobs 2
python3 scripts/run_tests.py correctness_add_to_100 --differential
bash tests/frontend/run.sh
tests/system/run_memory.sh
python3 tests/system/generate.py
python3 scripts/run_tests.py --root build/system_tests --differential \
  --latency 20 --random-wait 7 --request-wait 2 --seed 7
python3 scripts/parameter_sweep.py default issue2 phys96 rob32
```

The memory model initializes all 256 KiB to zero, then parses `@address` and
hexadecimal byte tokens, ignoring `#` and `//` comments. It rejects out-of-range
image data and every unaligned/out-of-range external memory request. RAM is one
unified 32-bit port with ordered pipelined requests, initiation interval one, and
`--max-outstanding N` capacity (default 64). A request accepted at edge C first
becomes eligible to respond at edge C + latency. With fixed delays and no
response backpressure, every read and write therefore completes at exactly that
latency, including 20 cycles in performance runs. At most one request and one
response transfer per edge; both can transfer together, including when the
response releases the last occupied slot of a full queue.

Responses preserve request order even when injected delays differ. Writes become
visible when their responses are accepted. A read samples RAM when it first
reaches the response channel, after all older writes completed; younger writes
cannot bypass it. Its sampled data remains stable during response backpressure.
This is equivalent to sampling on completion because no write can pass a stalled
head response. The reusable model is `sim/memory_model.h`; its independent test is
`tests/system/run_memory.sh`.

`--request-wait N` adds N idle acceptance cycles between transactions;
`--random-wait N` additionally picks a reproducible delay from 0 through N for
request acceptance and response presentation using `--seed`. Request valid and
all payload fields must remain stable while ready is low. Response valid/data
remain stable until accepted.

The exit store to `0x80000000` is observed at request acceptance. The CPU must
halt and retire that store on the same edge, after all RAM write responses have
completed. The harness checks final retirement, exact instruction count, result,
and every external RAM byte, including omitted zero bytes in `expected.memory`.
Four additional edges check that halted stays asserted with no extra requests,
retirements, or counter changes. These edges do not enter the IPC window.
Counter IPC includes cold instruction/data fills and the final dirty flush. The
harness checks its observed retirement count against the RTL counter every cycle.
JSON metrics go to stdout; mismatches, timeout, and unexpected faults return a
nonzero status. JSON records cycles retiring 0 through 4 instructions, external
memory occupancy cycles, simulation wall time in seconds, and Linux peak RSS in
KiB. `memory_pending_cycles` counts intervals with any pending transaction;
`memory_transaction_cycles` sums the pending depth each interval, so each fixed
latency-L transaction contributes L even when transactions overlap.
`memory_peak_outstanding` reports observed concurrency, and `max_outstanding`
records the configured queue capacity. `load_replay_count` reports the core replay counter.
Wall time and cycle histograms exclude the four post-halt guard edges.
`--dump-memory PATH` writes the complete final RAM in sparse form.

`--trace PATH` emits CSV retirements in program order. Each numeric field is
hexadecimal without a prefix: `pc,inst,rd,value,store,addr,wdata,wstrb`. Physical
lanes retire in increasing order as a continuous prefix. The top exposes four physical lanes, including when narrower pipeline parameters
are selected. Store addresses retain byte offsets; data/strobes occupy their
shifted word lanes. `scripts/differential.py` compares each retirement against an
independent architectural interpreter adapted from the supplied reference, with
upstream source left untouched. Register values for rd=0 and memory fields of
non-store instructions and disabled byte lanes of store data are ignored; all
meaningful architectural fields match.
The regression runner deletes successful traces unless `--keep-traces` is given.

Fault injection: `--error-address ADDR` errors bus transactions at one aligned
word address, optionally limited by `--error-read` or `--error-write`. Failed
writes do not update RAM. `--expect-fault` requires the core to report a fault
without issuing exit, and optional `--fault-pc`, `--fault-cause`,
`--fault-address`, `--fault-inst-valid`, and `--fault-inst` check attribution. The last option also
requires `fault_inst_valid=1`. Fault IDs are defined in `rtl/cpu_pkg.sv`.

System test generation requires only Python. It covers all M operations and
arithmetic corners, mixed-size forwarding, dirty evictions followed by exit,
wrong-path stores/exits/faults, a legal jump from the last RAM word, genuine
alignment/range/bus faults, and seeded random dependency streams. Expected exits,
retirement counts, and full RAM images are generated by the reference interpreter.
Fault cases use explicit expected metadata. These are additional local tests;
they do not replace the supplied suite or prove coverage of hidden tests.

Parameter sweeps cold-reset all six `perf_*` images per configuration at the same
latency and request capacity. `sweep.json` records Git state, tool version, image hashes, parameters,
per-program results and aggregate IPC (total instructions divided by total
cycles). Area and frequency must be measured separately; simulation IPC alone
cannot establish a scoring tier.
