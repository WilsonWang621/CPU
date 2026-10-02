# Synthesis structure regression

These two small RAM descriptions have the same asynchronous read and three
ordered, byte-strobed write ports. The dynamic form writes `q[address][byte]`;
the decoded form gives each byte a constant storage index and decodes its enable.
Neither form changes write priority or initial-state semantics.

```sh
python3 scripts/bootstrap_synth.py
python3 tests/synthesis/run.py
```

The runner records source/tool hashes, RTLIL sizes and bounded strict-check
runtimes. It proves all matched state/output points of the 8-word versions with
`equiv_simple`/`equiv_induct` and requires every decoded variant to pass
`check -assert -nolatches`. A timeout in the dynamic variant is recorded as an
audit result; other errors fail the run. The default sizes are 128/1024 words;
`--words 8 32` provides a short smoke run. No unsafe memory flags or disabled
connectivity checks are used. RTLIL sizes are not mapped area measurements.

Inspect an actual CPU/cache checkpoint with:

```sh
python3 scripts/inspect_rtlil.py build/synth/elaborated.il > build/synth/structure.json
```

The inspector groups cells by source file/location and lists their largest
input/output widths. Counts of intermediate bits describe lowering overhead,
not distinct gates or physical area.

`python3 tests/synthesis/audit_packed_select.py` isolates the nested packed
bit-plane access that inflated cache elaboration. Both descriptions first pass
through sv2v, matching assessment input. For 4 and 32 sets it records the exact
pre/post-optimization cell counts and proves equal outputs for every bitmap and
legal line-word index. The replacement selects an unpacked narrow row before
its four-bit word. The archived `reports/data/packed_plane_select.json` records
172,524 versus 5,168 intermediate cells for the 32-set reproducer. This is a
structural regression and a combinational selection proof, not a whole-cache
equivalence proof or an area measurement.

`python3 tests/synthesis/prove_forwarding.py` uses pinned modern Slang/Yosys
(`bootstrap_modern_synth.py`) to compare rotating ROB/CSB scans with fixed-entry
newest-age selection. Inputs include arbitrary addresses, data, masks and
readiness; CSB validity is constrained to its circular live interval. It proves
requested-byte blocking/owners and unblocked forwarded values/producer IDs.
The archived `reports/data/forwarding_equivalence.json` records n=4 proven and
n=8 inconclusive at the 60 s SAT limit. Timeouts are explicit; the runner exits
2 when no instance is proved and 1 for other proof errors.

`python3 tests/synthesis/prove_ages.py` extracts the current core's circular-age
and cancellation formulas and proves equivalence to integer arithmetic for
capacities 4, 6, 16, 30, 32, 33, 64, 127 and 128. It covers every valid position,
recovery cutoffs including the capacity-plus-one sentinel, pointer wrapping,
legal queue-count transitions, and detectable single-step count overflow and
underflow. The recorded result is `reports/data/age_width_equivalence.json`.
These arithmetic proofs do not establish the full core's occupancy invariants;
the monitored core/LSU regressions check those during execution.

`python3 tests/synthesis/prove_rat_reconstruction.py` extracts `distance()`, the
surviving-writer qualifier and the actual reconstruction body from the current
core. It compares that logic with an independent chronological circular scan for
ROB capacities 4, 5, 8 and 9. An arbitrary architectural register quantifies all
32 mappings, with arbitrary seven-bit physical destinations, valid holes, WAWs,
head/cutoff positions, branch/load keep flags and redirect gating. x0 remains
zero. The runner saves the core snapshot, generated proof, tool/source hashes,
bounded logs and explicit timeout status. Results and the earlier 16-program
checkpoint-oracle regression are recorded in
`reports/data/rat_reconstruction_equivalence.json`; the latter identifies its
pre-integration prototype separately from the current extracted proof.
`rat_reconstruction_equivalence.sv` archives the exact generated proof source
whose hash is recorded there; normal runs regenerate it from the current core.

`python3 tests/synthesis/prove_ras_storage.py` proves the unused RAS bits remain
zero after reset through predictor, request, FQ and core snapshot storage, and
that explicit boundary masks preserve the next state. Invalid unreset FQ payloads
are unconstrained; checkpoint writes must consume a valid FQ entry, matching the
core's rename guard. The current `update_ras` function is extracted verbatim.
Depths 0, 1, 4, 8 and 16 are covered, including arbitrary redirect contents and
all stack-update/count controls. A separate 669-bit proof checks that selecting
the highest enabled lane before a single FQ register write preserves the original
conditional-write priority for every lane-enable pattern and data mask.
`reports/data/ras_physical_capacity.json` records these proofs, the frontend
clock-edge comparisons, and coarse/final bit-level storage counts. These are
storage/equivalence checks, not mapped area or physical timing claims.
