# Pipelined frontend regression

Run `bash tests/frontend/run.sh`. Builds are isolated in `build/frontend-tests`;
the suite tests fetch widths 4, 2 and 1 in bimodal, gshare and tournament modes,
plus a direct predictor harness and minimum queue/table capacities. It uses
the bundled Verilator, enables assertions and treats RTL warnings as errors
apart from expected unused test signals and package constants.

The fetch model accepts multiple tagged requests, delays and reorders responses,
and checks that request payloads remain stable across backpressure and redirects.
Every output instruction is checked against its address and the current path.
Random redirects also check exact history and RAS snapshots. Cases cover:

- a warm sequential stream delivering the full configured width every cycle;
- random request and dispatch stalls, out-of-order responses and repeated tag reuse;
- a stalled presented request surviving redirect, with new-path fetch continuing
  before a canceled old request returns an error;
- first-touch JAL predecode, target repair and speculative call-stack updates;
- ordered fetch-bus, alignment and range faults, including the last RAM word;
- valid prefixes before a failed response word, precise word-one/word-two fault
  PCs, and earlier taken JAL/conditional branches canceling those younger faults;
- complete draining without duplicate or stale responses.

Predictor tests cover four simultaneous updates to the same bimodal, gshare and
chooser counters. A 5,000-step independent reference model checks aliased training
and direction predictions for each mode, including history lengths 1, 8 and 16
with tables from two through 1,024 entries. Directed cases change both component tables between fetch
and retirement, requiring chooser updates to use the saved component votes.
Frontend cases similarly delay a fetch response while changing the tables and
check that its eventual instruction metadata still contains the original votes.
Other checks cover
per-instruction history folding, speculative nested calls and returns, stack
overflow, coroutine pop/push hints, branch recovery and load-replay restoration.
All JALR source/destination register pairs are tested with signed immediate
boundaries and empty/nonempty stacks. Tag tests cover same-index replacement,
high address bits, unaligned lookup rejection and odd stored target preservation.
The RAS snapshot stores the newest return address in bits 31:0. Every snapshot
describes state immediately before its instruction. Direct JAL predecode changes
that instruction's predicted target and cancels younger packets before dispatch.

`PREDICTOR_MODE=0/1/2` selects bimodal/gshare/tournament direction prediction;
all modes retain the tagged BTB and speculative RAS. Tournament is the default,
with a two-bit PC-indexed chooser initialized strongly toward bimodal. The
gshare index XORs PC word bits with the low `HISTORY_BITS` history bits (default
8, supported 1 through 16); snapshots still preserve the complete 16-bit history.
`fetch_t.bimodal_taken` and `fetch_t.gshare_taken` hold the raw direction votes
from the fetch lookup. Four retirement lanes return those bits through
`train_bimodal_taken` and `train_gshare_taken`. The chooser updates only when
the saved votes differ, and all aliased updates fold in retirement order.

Each BTB entry stores only the high PC tag, its full 32-bit target, and 15 bits
of instruction metadata (conditional/pop/push flags and a 12-bit return offset).
The lookup checks word alignment separately. With 256 entries this removes
6,912 stored bits versus full 32-bit PC tags and full instruction words; this
is a logical storage count, not a synthesized area or timing measurement.

Unused upper RAS snapshot bits are explicitly zeroed at predictor, request and
fetch-queue register inputs; the core applies the same boundary rule to its
saved snapshots. Each fetch-queue slot selects the highest enabled lane before
one gated register write, making the constant bits visible after lane selection.
The public 512-bit snapshot format is unchanged. With `RAS_DEPTH=4`, only the low
128 RAS bits require storage. The proof and storage measurements are recorded in
`reports/data/ras_physical_capacity.json` and can be checked with
`python3 tests/synthesis/prove_ras_storage.py`.

Run `python3 tests/frontend/audit_synthesis.py` after installing the pinned modern
Yosys toolchain to reproduce the bounded synthesis audit. It records source
hashes, raw cell/wire counts, the largest operators with source locations, and
strict loop/driver/latch checks for 512/2,048-entry predictors and four-wide
frontends with 16 queue/request entries. Raw checks have a time limit; the
required production check removes disconnected elaboration intermediates with
`opt_clean` and retains all live logic. Detailed logs and JSON go under
`build/frontend-synthesis` by default.

`update_reproducer.sv` isolates the expensive pattern: dynamically changing one
field of a packed-record array can elaborate into a masked write spanning the
entire bank. Its second module decodes the entry first and changes only that
record. Production request/FQ writes use constant entry indices; predictor
tables select the youngest matching retirement once per entry after folding
aliased updates. These changes reduce generated intermediate buses without
reducing queue, predictor, history, or RAS capacities. The 17-configuration
regression also passed a temporary old/new clock-edge miter during this change,
checking request timing, all valid output packets, and predictor snapshots.
