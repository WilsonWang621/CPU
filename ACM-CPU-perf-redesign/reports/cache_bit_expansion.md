# Cache bit-expansion diagnosis

The frozen `build/synth-integrated-lean` snapshot reached 106,589 coarse cells
and 3,012,054 wire bits, then expanded to **8,806,205 generic cells**, including
7,826,753 one-bit muxes. Its 600-second run timed out in optimization after
writing the 3.8 GiB `techmapped.il`. These are **intermediate expansion counts**,
not optimized circuit size, mapped ASAP7 area, or timing results.

The source snapshot includes cache commit `8835f00`, the integrated narrow core,
RAT reconstruction and predictor storage changes. Machine-readable counts and
attribution rules are in [cache_bit_expansion.json](data/cache_bit_expansion.json).
Source references below refer to this snapshot's exported `cpu_source.v`.

| Attributed block | One-bit muxes before final optimization |
|---|---:|
| Data cache | 4,017,069 |
| Instruction cache | 1,613,335 |
| Cache common/generated logic | 40,076 |
| Core | 1,737,284 |
| Frontend | 227,467 |
| Predictor | 173,559 |

The largest cache source hotspots are repeated variable selects from packed
valid/dirty planes. Flattening `valid_bytes[set][way][4*word+:4]` combines the
indices into a wide bit offset; generic shift lowering constructs a network
over the entire plane before later passes remove unused portions.

| Source expression | Export line | One-bit muxes |
|---|---:|---:|
| Issue scan: serviced store completes a word | 1133 | 1,534,316 |
| Waiter rotation: read only valid/done | 856 | 478,304 |
| Requested-word error mask | 970 | 371,395 |
| Retry an invalid requested word | 1071 | 321,893 |
| Writeback word dirty strobe | 1160 | 208,982 |
| Flush word dirty strobe | 1115 | 208,960 |

The ordinary RAM ports remained as intended. Instruction storage has 32 rows of
256 bits, two line read ports and one merged byte-enabled fill port: memory_map
reported 62 word muxes and 8,192 write mux blocks. Data storage has 1,024 rows of
32 bits, three read ports and three merged byte-enabled write ports: 3,069 word
muxes and 98,304 write mux blocks. These counts must not be equated to final area;
constant enables and unused bits are removed later.

Whole-record waiter updates are a second remaining source of expansion. The
snapshot contains 51 data-cache reads of 226-bit records from 32 entries and
43 instruction-cache reads of 225-bit records from 32 entries, even when only
one field is consumed. Dynamic field writes introduce 7,232/7,200-bit whole-pool
`$bwmux` updates. A bounded event interface with constant-entry updates can remove
those pool-wide updates while preserving the original ordering of response
dequeue, error forwarding, service completion, allocation and tail linking.

Commit `bc1923a` first bounds instruction waiters by `FETCH_REQUESTS` and waiter
result storage by `32*MAX_CPU_WORDS`. The directed and randomized matrix passes
for packet widths 1/2/3/4 and waiter counts 8/16/32. A 160-request trace at
20-cycle base memory latency, with stalls and 0–2-cycle jitter, is identical for the original 32-slot pool and bounded
8/16-slot pools when the client window matches: 1,981 cycles, 1,280 RAM reads and
identical response ordering. See [cache_width_trim.json](data/cache_width_trim.json).

The next change gives valid/dirty metadata explicit unpacked four-bit word views
and line views, and exposes waiter fields as narrow read columns. Constant-index
aliases carry the existing state; no storage, port, queue ordering or pipeline
stage is added. This prevents the Verilog export from combining row and word
selection into a barrel shift over the complete packed plane.
The independent [packed-select reproducer](../tests/synthesis/packed_plane_select.sv)
and [SAT runner](../tests/synthesis/audit_packed_select.py) reproduce this lowering
problem after Verilog export and prove the selector transformation for arbitrary
bitmaps and legal word indices. This is a selector proof, not whole-cache formal
equivalence; whole-cache evidence comes from the transaction tests below.

The standalone comparison uses the same parameters before and after, exports
both versions through sv2v, then runs the same pinned Slang/Yosys passes and fully
maps the data RAM. Counts below are immediately after generic bit expansion,
before final optimization or Liberty mapping.

| Cache | Cells before → after | One-bit muxes before → after | Tool time |
|---|---:|---:|---:|
| D: 4 KiB, 4 ways, 8 MSHRs, 32 waiters, 1 word | 4,240,977 → 1,646,631 | 3,730,168 → 1,121,324 | 63.0 → 43.6 s |
| I: 1 KiB, 2 ways, 4 MSHRs, 8 waiters, 4 words | 1,217,687 → 600,499 | 1,058,993 → 432,596 | 17.1 → 9.2 s |

Coarse word-cell counts increase slightly because the views expose more small
selectors; bit expansion is the relevant measure for this diagnosed failure.
No reduction in final area or simulator runtime is inferred from these counts.
The D32/I8/I16 directed and randomized tests preserve every CPU/RAM transaction's
cycle, address, payload, tag and response ordering, including errors and flushes.
Their complete event hashes match the preceding implementation exactly.
The full 27-configuration cache matrix also passes: 1/2/4 ways, 16/32/64-byte
lines, 1/8/16 MSHRs, read-only operation, packet widths 1/2/3/4 and 8/16/32 waiters.
Parameters, hashes, counts and commands are archived in
[cache_column_reads.json](data/cache_column_reads.json).
