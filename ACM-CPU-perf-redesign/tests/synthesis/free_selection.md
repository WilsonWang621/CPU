# Lowest-free-slot proof

`prove_free_selection.py` extracts the actual `CPU_LOWEST_FUNCTION` macro from
its `--source` core and compares it with the old descending-index assignment
scan. It checks signed integer results, including the empty-mask `-1`, rather
than only checking whether the selected bit is available.

```sh
python3 tests/synthesis/prove_free_selection.py --source rtl/core.sv
```

The default 48 SAT cases cover capacities 1, 4, 6, 16, 24, 32, 64 and 128;
1/2/4 ordered rename lanes; and both ordinary queues and PRF-style exclusion of
index zero. Initial availability, earlier release/occupation masks, and each
lane's allocation enable are unconstrained. Every lane's chosen index and
resulting availability mask must agree with the serial reference. This tests
non-power-of-two padded leaves, exhaustion partway through a rename group,
unused choices, and exclusion of x0 even when an input marks it free.

Integration keeps the lookups at their original location inside each rename
lane. IQ and LQ masks read the current `*_work[].valid` values; the PRF mask reads
`free_d` and explicitly clears bit zero. Thus earlier commit/recovery/issue frees
and earlier rename allocations retain the original procedural order. These
unchanged whole-core event updates are reviewed in the prototype patch; the
SAT miter proves the helper and ordered mask consumption, not a full CPU state
machine equivalence.

The prototype report distinguishes structural cell/wire counts from mapped
area or timing. A balanced source tree alone is not an STA result.
