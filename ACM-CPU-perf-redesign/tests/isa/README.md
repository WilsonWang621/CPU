# ISA module regression

Run `bash tests/isa/run.sh` from the project root. It uses the bundled Verilator
unless `VERILATOR` is set. Build products and the compiler log live in `build/isa`.

The C++ reference checks all 128 opcode × 8 funct3 × 128 funct7 combinations,
50,000 random instruction words, immediate sign boundaries, x0 destinations,
20,000 sets of ALU and branch operands, and 11,152 multiply/divide operand cases.
The tagged MDU computes all four multiply variants in one cycle. Three elastic
entries buffer completed products behind a shared registered response. An empty
queue lets a fresh product enter that output directly; otherwise the oldest live
buffered result wins. The unsigned 64-bit product plus high-word sign corrections
implements MUL, MULH, MULHSU and MULHU. It accepts a multiply every cycle while a
separate divider works concurrently.
`mul_ready` and `div_ready` expose structural capacity independently of request
opcode/tag, gated by reset and global kill; `req_ready` selects the applicable
hint and additionally excludes an incoming tag named by `kill_mask`.
The default divider processes four restoring steps per cycle (radix 16, at most
eight iterations); `DIV_STEP_BITS=2` selects radix 4 and at most sixteen iterations.
Leading zero radix groups are skipped before iteration. Divide by zero, signed
overflow, zero/small dividend and unit divisor bypass iteration.

One completed operand pair is cached, including both its quotient and remainder.
The key contains both raw operands and signedness, so DIV/REM or DIVU/REMU with
identical inputs can reuse the completed arithmetic. MUL operations do not evict
this entry. Incomplete canceled divisions never populate it. Selective tag
cancellation may retain completed pure arithmetic, while reset/global kill clear
the entry. There are no PC or program-specific conditions.

The response arbiter alternates when both multiply and divide are ready. Tags
identify out-of-order results, and held responses remain stable. `kill` clears
every unit; `kill_mask[tag]` removes only matching pipeline, divider and output
entries, and forbids accepting that tag on the same edge. A tag must not be
reused until the previous operation completed or was canceled.

Tests cover 11,152 scalar operand cases, 128 consecutive multiply requests,
12,000 mixed tagged requests with concurrent multiply/divide execution, random
response backpressure, individual/multiple selective cancellation and global
kill. Every accepted request must return its independently calculated value once
or be explicitly canceled; no canceled tag may return later. All divider phases
and multiply entries, including the held output, are covered by cancellation.
The four total multiply result slots are filled under backpressure; canceled
entries must immediately admit a replacement while preserving surviving order.
An empty unit returns a multiply in one request-to-response handshake cycle.
The suite also checks every leading-zero group boundary, signed/unsigned cached
pairs including zero/overflow, cache key separation/replacement, exact reduced
latency, interleaved MULs and cancellation of partial or completed divisions.
Run the same suite for the alternate divider with:

```sh
ISA_BUILD_DIR=build/isa-radix4 DIV_STEP_BITS=2 bash tests/isa/run.sh
```

`reports/data/mdu_single_cycle.json` records the matching standalone ASAP7 area
and OpenSTA assumptions. At a 3333.333 ps target the mapped unit passes setup,
hold, coverage and electrical checks after fanout buffering/sizing. These are
cell-only results with ideal clock and no wire parasitics, not whole-CPU or
physical signoff measurements.

The decoder's `mem_size` is log2(bytes). `writes_rd` is false for x0; this does
not suppress execution of jumps or loads. Illegal encodings have source and
destination enables cleared. `use_imm` covers immediate ALU, memory addressing
and JALR; LUI/AUIPC and branch units consume their explicit `imm` input.
