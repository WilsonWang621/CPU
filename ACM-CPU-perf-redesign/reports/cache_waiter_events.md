# Private fixed-entry waiter update candidate

This is a measured candidate based on `08ddb74`; production `rtl/cache.sv` is
unchanged. The prototype is `build/cache-waiter-events/cache.sv`, with source SHA256
`d49f1a41358af0228155a30cb3443cb90038f6be91f3fc971102cee57073f667`.
The [prototype patch](data/cache_waiter_events.patch) preserves it without adding
another active RTL implementation or a fallback configuration.

Each waiter now has a constant-entry next-state block. The control block emits
indexed events in the existing order: response dequeue, read-error forwarding,
service completion, new allocation, then previous-tail linking. Read-error
forwarding is a separate narrow field computed from registered state and the
current bus response. Service selection therefore sees an error arriving in
the same cycle, without reading back the generated waiter next-state array.

## Structural result

Both versions pass through sv2v and the same modern Slang/Yosys flow, including
complete `memory_map`. Counts are taken immediately after generic `techmap`,
before final bit optimization, strict mapped checks or Liberty mapping. They
are not final gate counts, area or timing results.

| Configuration | Coarse wire bits | Expanded cells | Expanded one-bit muxes |
|---|---:|---:|---:|
| D: 4 KiB, 4 ways, 8 MSHRs, 32 waiters, 1 word | 638,229 → 392,237 | 1,646,631 → 1,353,508 | 1,121,324 → 858,145 |
| I: 1 KiB, 2 ways, 4 MSHRs, 8 waiters, 4 words | 264,680 → 158,557 | 600,499 → 479,344 | 432,596 → 325,238 |

The 4,160-bit D-cache waiter-bank update disappears. The largest remaining
coarse output is 1,216 bits in the existing memory-response ownership FIFO;
the corresponding I-cache maximum is 1,024 bits. Expanded cell counts decrease
17.8% and 20.2%. Elapsed times in the data file were measured during concurrent
work and do not establish a synthesis speedup.

## Behavioral checks and compiler diagnosis

The complete directed/randomized suite preserves every accepted CPU/RAM
transaction's cycle and payload. Its cumulative traces match production:

| Test configuration | Cycles | Event hash |
|---|---:|---:|
| D, 32 waiters | 9,411 | 7548406868903025878 |
| I, 8 waiters | 20,575 | 10938711410506995163 |
| I, 16 waiters | 20,614 | 18066428018431030814 |

The additional private collision test deliberately combines response dequeue,
read-error forwarding, service completion, allocation and tail linking in one
cycle. It also accepts a committed store on the read-error cycle. Production
and the candidate match: D takes 162 cycles with hash 15234588714420458571;
I takes 98 cycles with hash 7904045799228535718. The
[test patch](data/cache_waiter_collision.patch) reproduces this fixture from
`tests/cache/cache_test.cpp` at `08ddb74`.

There is one reproducible native-tool failure, retained explicitly in the
results rather than counted as a passing test:

- Supplied Verilator **5.020 + GCC 13.3, `-O2`** passes the D suite and collision
  test with the exact production hashes.
- Diagnostic Verilator **5.053 + GCC 13.3, `-O2`** passes I8/I16, but D32 crashes
  during reset. The generated NBA function loads
  `__Vdly__cache__DOT__dirty_bytes` with `movdqa` at root offset `0xc88`.
  The root object is 64-byte aligned, making this valid source address 8 modulo
  16, while the emitted instruction requires 16-byte alignment. GDB records the
  fault in a generated 64-word copy loop. Recompiling without PCH also fails.
- Recompiling **only that exact generated C++ translation unit with Clang
  18.1.3, `-O2`**, keeping the remaining GCC-built objects, passes the D suite
  with the exact production hash. No optimization is disabled.
- The complete 5.053 D model built with GCC `-O1` and **ASan + UBSan** passes
  both tests with `abort_on_error=1` and `halt_on_error=1`; neither run reports
  an error. The final initialization translation unit uses `-g1` rather than
  `-g` to avoid pathological debug-information compilation time; both sanitizers
  and optimization remain enabled.

These checks identify a compiler/generated-C++ alignment failure for this
specific tool combination. They do not establish a general upstream GCC bug
number or prove that every C++ undefined behavior is absent. A standalone copy
loop extracted from the function does not reproduce the failure; the larger
translation unit and fault evidence remain under `build/cache-waiter-events`.
The supplied 5.020 toolchain remains a passing path, so the candidate is not
discarded. Production adoption is deferred until the current whole-core mapping
finishes and the team chooses the next source snapshot.

All source hashes, parameters, native-fault details, passing results and explicit
failed runs are in [cache_waiter_events.json](data/cache_waiter_events.json).
The private synthesis and test drivers are under `build/cache-waiter-events`.
