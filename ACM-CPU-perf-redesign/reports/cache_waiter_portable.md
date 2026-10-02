# Portable fixed-entry cache waiter candidate

The private candidate passes all **27 existing cache configurations plus four
non-power-of-two configurations**. Complete transaction traces match production,
with one production reference recovered using Clang after a recorded GCC crash.
Production RTL remains unchanged; the candidate is preserved as a
[patch](../tests/synthesis/cache_waiter_portable.patch).

| Source | SHA256 |
|---|---|
| Production cache, from `08ddb74` | `f0f82e4c0905aa2bbf220f418a520705bc0d76e307b614cfd0e66ffb813ecf3e` |
| Earlier private waiter-event candidate | `d49f1a41358af0228155a30cb3443cb90038f6be91f3fc971102cee57073f667` |
| Portable candidate | `4c5c008547bc50b9718f4177ea8eefe5fe1aadf38e923653ed99b17fbb8f6cb6` |

The local candidate is `build/cache-waiter-portable/cache.sv`. Its parent
candidate replaced dynamic waiter-bank field writes with fixed-entry events in
the original order: response dequeue, read-error forwarding, service completion,
allocation, then tail linking. Current-cycle read errors remain visible to
service selection.

One additional representation change makes tag-valid, address, valid-byte and
dirty-byte state unpacked per-line arrays; replacement state becomes an unpacked
per-set array. Existing field widths and updates are preserved. There are no
extra storage bits, pipeline stages, or CPU/memory ports. The generated D model
no longer contains the full packed-bank delayed copies of valid/dirty metadata
that exposed the earlier native alignment failure. No padding or disabled
compiler optimization was used.

## Validation

D32, I8 and I16 passed the full directed/randomized suite and five-event collision
fixture under modern Verilator 5.053 with GCC 13.3 at both effective `-O2` and
`-O3`, and under supplied Verilator 5.020 with its default generated-code build.
All nine runs match the production full-suite hashes:

| Configuration | Cycles | Transaction hash |
|---|---:|---:|
| D32 | 9,411 | 7548406868903025878 |
| I8 | 20,575 | 10938711410506995163 |
| I16 | 20,614 | 18066428018431030814 |

Compiler command auditing found that 5.020 appends default `OPT_FAST=-Os` after
the requested user `-O2`, so its generated fast-code optimization is effectively
`-Os`. Historical local directory names `bundled-o2` describe the requested
flags, not the effective level. Modern 5.053 places the requested `-O2`/`-O3`
last. The recorded commands preserve this distinction; no vectorizer disabling,
`-O0`, or sanitizer workaround was used for the portable-candidate tests.

`tests/cache/run.sh` has no cache-source override. A private runner therefore
used the same public C++ test and exactly its 27 cache configurations against
the private RTL. The three already-tested configurations were reused. The other
24 pass under the supplied 5.020 toolchain and match their archived production
traces. Coverage includes 1/2/4 ways, 16/32/64-byte lines, 1/8/16 MSHRs,
read-only operation, packet-width limits 1/2/3/4 and 8/16/32 waiters.

Four additional configurations exercise non-power-of-two queue sizes:

| Ways | Line bytes | MSHRs | Read-only | Word limit | Waiters | Cycles | Hash |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 16 | 3 | 0 | 4 | 7 | 17,753 | 11520578148346326690 |
| 4 | 64 | 5 | 0 | 1 | 11 | 10,887 | 12986050641658901313 |
| 1 | 16 | 1 | 1 | 4 | 3 | 56,164 | 17474603558410564775 |
| 2 | 64 | 3 | 1 | 4 | 7 | 38,681 | 13383641692626149554 |

All four candidate runs pass. Three production references pass with identical
hashes. The production reference for the last row crashes under 5.020/GCC during
an aligned `movdqa` load from an address ending in `...1b8` (8 modulo 16).
Rebuilding only that generated translation unit with Clang 18.1.3 at `-O2`,
while retaining the remaining GCC objects, produces the exact candidate hash.
The original `SIGSEGV` remains in the data; it is not counted as a passing GCC
reference. The candidate itself needs no alternate compiler for that row.

## Structural comparison and reproduction

Same-parameter sv2v → Slang/Yosys runs include full data-memory mapping and
generic bit expansion. These counts are intermediate structure, not final
Liberty area or timing.

| Cache | Production expanded cells | Earlier event candidate | Portable candidate |
|---|---:|---:|---:|
| D4K, 32 waiters, one word | 1,646,631 | 1,353,508 | 1,351,900 |
| I1K, 8 waiters, four words | 600,499 | 479,344 | 478,747 |

Portable-candidate coarse wire bits are 392,245 (D) and 158,550 (I), versus
638,229 and 264,680 in production. Flip-flop bit totals remain unchanged.
Native generated C++ size is not claimed to decrease.

To recreate the candidate privately from the hash-matched production source:

```sh
mkdir -p build/cache-waiter-replay
git show 08ddb74:rtl/cache.sv > build/cache-waiter-replay/cache.sv
git apply --directory=build/cache-waiter-replay tests/synthesis/cache_waiter_portable.patch
sha256sum build/cache-waiter-replay/cache.sv
```

The expected result is the candidate SHA above. The
[JSON record](data/cache_waiter_portable.json) contains exact build commands,
source/patch/test hashes, all matrix results, the retained production compiler
failure and recovered reference, and synthesis statistics. Private runners and
logs remain under `build/cache-waiter-portable`. Whole-core validation and
physical area/timing are separate from this cache-only result.
