# Cache synthesis expansion diagnosis

The corrected cache uses explicitly inferred, flat 32-bit data words and
constant-index metadata records for each line. The data memory is fully lowered
to flip-flops during synthesis. Fill, serviced committed store and CPU hit store
retain their original byte-write priority; no cache storage is excluded.

Two RTL patterns caused excess expansion. Dynamic byte writes lowered directly
to registers produced muxes as wide as the complete cache array. Separately,
inferring the original three-dimensional data array produced 32 rows of 1,024
bits at the 4 KiB configuration. The flat array expresses the intended 1,024
rows of 32 bits. Metadata updates now manipulate one fixed-size line record,
not packed vectors spanning every set and way.

Measurements use the pinned OSS CAD Suite 2026-09-20, Yosys 0.69+75 and Slang
revisions in `scripts/modern_synthesis.lock.json`. Counts below follow
`read_slang --no-implicit-memories` and `opt_clean`. They describe intermediate
representation size, not gate area or frequency. Local wall times vary with
machine load. Exact source/tool identities and statistics are archived in
[data/cache_synthesis_scaling.json](data/cache_synthesis_scaling.json).

| Standalone configuration | Cells | Wire bits | Elaboration + clean |
| --- | ---: | ---: | ---: |
| Original 256 B, 2 ways, 2 MSHRs, 4 waiters | 4,339 | 473,640 | 1.22 s |
| Original 1 KiB, same queues | 4,819 | 1,114,720 | 3.32 s |
| Original 4 KiB, same queues | 6,739 | 3,674,744 | 25.64 s |
| Original 4 KiB, 4 ways, 8 MSHRs, 32 waiters | 12,117 | 4,744,042 | 53.81 s |
| Intermediate all-decoded 4 KiB experiment | 187,219 | 1,429,163 | 18.25 s |
| Final flat-data / decoded-metadata 4 KiB cache | 26,769 | 1,103,516 | See archived tool log |

The final row also contains one explicitly inferred 32,768-bit data memory.
It is not omitted from area: the subsequent `memory_collect; memory_map` check
has **zero memories and zero `$mem` cells**. Optimization, memory mapping,
checkpoint writing and `check -assert -nolatches` completed in 97.71 seconds
with zero problems. The intermediate all-decoded version was replaced because
its large generated FF structure made simulator preprocessing expensive.
The final adversarial cache test consumed 0.04 seconds of user CPU time, the
same measured runtime as the original test binary.

The controller was not a material source of expansion: 64 outstanding entries
gave 199 cells / 1,491 wire bits and 0.17 seconds for the initial stages.

A minimal reproducer isolates dynamic register updates from cache behavior.
Both forms store 32-bit words and support identical three-port byte writes:

| Words | Dynamic wire bits | Decoded wire bits | Dynamic strict check | Decoded strict check |
| ---: | ---: | ---: | ---: | ---: |
| 128 | 213,753 | 21,237 | 20.99 s | 0.27 s |
| 1,024 | 1,704,748 | 168,196 | 45 s timeout | 3.62 s |

The 8-word forms passed formal equivalence for all 288 matched state/output
points. This proof covers the isolated storage rewrite, not the entire cache
protocol. `tests/synthesis/run.py` reproduces the models, proof and bounded
checks; it preserves logs, scripts, source hashes and JSON results. Protocol
behavior passed all 22 cache configurations and all six controller
latency/capacity runs in `build/cache-hybrid-suite.log`. Each cache configuration
includes 1,800 overlapping randomized accesses at each of 3/20-cycle latency,
plus directed backpressure/error/flush cases including 97-cycle latency.

A frontend comparison confirmed that parsing SystemVerilog was not the issue:
the same 1,024-word dynamic model with ordinary RAM inference took 0.032 seconds
in Slang and 0.065 seconds in sv2v plus modern Yosys. Each inferred one 32,768-bit
memory with 12 byte-write ports. Global register lowering was needed for
next-state metadata arrays, but real cache data storage benefits from explicit
memory inference and the correct word shape.

A separate optional `memory -nomap` optimization experiment reached its
120-second bound inside memory-port optimization. Direct memory collection and
mapping preserve the specified write priorities and completed strict checking;
no unsafe memory assumptions or connectivity-check waivers are used. Raw logs
and stopped/timeout statuses remain under `build/synthesis-audit`.

This report establishes tractable cache lowering and strict connectivity,
not full-CPU ASAP7 area or 300 MHz timing. See
[the synthesis workflow](../docs/synthesis.md) for mapped-area and OpenSTA scope.

The subsequent instruction-cache layout uses one whole line per storage row.
For the measured 1 KiB / 32-byte-line instance, storage remains 8,192 bits:
32 rows × 256 bits, with two read ports and one masked fill write port. The
previous word-row specialization had 256 rows × 32 bits and eight read ports.
The ideal binary memory read trees consequently contain 15,872 bit-muxes
instead of 65,280; this is a structural count, not measured standard-cell area.
Byte fills, partial-word errors and held packet masks passed the existing
16/32/64-byte-line instruction-cache tests; the data-cache regression also
passed. Exact facts are in
[data/instruction_cache_layout.json](data/instruction_cache_layout.json).
