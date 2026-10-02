# Parallel selection proof

`prove_parallel_selection.py` extracts `CPU_ORDER_FUNCTION` and
`CPU_RANK_FUNCTION` verbatim from the specified core. It also extracts the actual
memory rank cutoff and lane rank comparison, so truncated narrow casts are tested
instead of silently repaired by the proof wrapper.

```sh
python3 tests/synthesis/prove_parallel_selection.py --source rtl/core.sv
```

Each Yosys process has a 60-second wall limit. Exit 0 means all requested miters
proved; 2 means at least one bounded `unknown`; 1 means a failed proof. Logs,
source and emitted-wrapper hashes are retained. These are combinational proofs,
not full-core sequential equivalence.

The decomposition has three separately checked steps:

1. For arbitrary encoded ages, the actual order macro equals the strict key
   `(unsigned age, original candidate index)`. This includes age ties, diagonal
   bits, and encoded values outside the valid ROB-age interval.
2. For an arbitrary older matrix and arbitrary valid bits, every row of the
   actual balanced rank function equals an independent serial integer count.
   This proof does not assume the matrix is a total order and does not assume
   that the rank implementation is correct.
3. Given canonical strict priority positions, actual-rank WB selection and IQ
   class filtering are compared with a serial greedy scan. Ready bits, classes
   (ALU/MEM/MUL/DIV), MDU occupancy/readiness/accepted-DIV gates, enable, and all
   16 free-lane masks are unconstrained. IQ limits are two memory instructions
   and one MDU instruction. Ordered miters cover 1/2/4 lanes at 21 and 24 entries.

Step 3 covers arbitrary strict orders: enumerate candidates by the strict key
proved in step 1. Permuting matrix rows and columns and the corresponding
eligibility/class bits preserves every row count proved in step 2. Both
algorithms therefore produce the same selected **identities**, after applying
the inverse permutation. The only slot-based tie break is already included in
the strict key. Equality of per-lane one-hot selections also establishes the
masked-OR payload/index encoding and assignment to increasing free lane numbers.
No assumption of distinct numeric ages is needed.

The greedy comparison starts after static operand/resource eligibility. Source
review must check that eligibility is invariant during selection except for:
selected-entry removal, the memory count, and the MDU count. In the reviewed
core, selecting a load sets `address_sent`; selecting a store with ready data
clears its validity; selecting a store without ready data sets `address_sent`
and cannot become eligible again because its old `iq_address_ready` is false.
Non-memory operations clear validity. Operand readiness does not change between
issue lanes. Existing MDU occupancy and DIV acceptance are gated before selection.
The proof does not independently establish these whole-core sequential facts.

Additional full, unsorted miters directly compose the actual macros with
selection and compare against age-based greedy scans. They cover arbitrary age
values, including the strict `ROB_ENTRIES+1` sentinel. Age width implies
`ROB_ENTRIES = 2**(AGE_WIDTH-1)` in the wrapper. Minimal ROB=4/IQ=1 and IQ=2
configurations retain four issue lanes, exercising narrow-count corner cases.
Large unsorted miters may time out even when the decomposition is complete;
those outcomes are recorded as unknown rather than counted as direct proofs.

The `rank_cap:W:6:1` case checks the extracted actual memory-class predicate for
all unsigned `W`-bit values against `rank <= 1`; widths 1 through 8 are in the
default case list. The predicate is taken from the complete unique
`(!issue_memory[k] || PRED) &&` source line. This includes reduction/shift forms
without constraining the proof extractor to one comparison spelling.
