# ABC stage audit

The added `dc2` optimization exceeded the 180-second experiment limit on this
snapshot. Direct technology mapping completed in 160.98 seconds, and the
separate buffering and sizing experiments also completed. This audit covers
the extracted combinational network. Whole-core strict checks, flip-flop area
and STA are recorded separately.

No RTL or Yosys frontend was rerun for this audit. Each ABC experiment used its
own process group and a 180-second wall limit. Giant BLIF/AIG files remain under
`build/abc-stage-probe`; only this report and the
[measurement data](data/abc_stage_audit.json) are committed.

## Snapshot and phase measurements

The input came from `build/synth-structural-hash`, whose metadata records RTL
commit `d38e6e76d1ba5f89a2e5a413bb69ddc82e9ee945`. Source hashes, parameters,
toolchain metadata and exact library cell areas are archived in the data file.
The 432,711,734-byte input BLIF has SHA256:

```
51df44d7805ca74a3484a0198989485ccaa42230562432aafbba1a68c0fc339c
```

| Experiment | Result | Process wall time | ABC-reported phase times |
|---|---|---:|---|
| Read BLIF, strash, save named AIG | Completed | 29.45 s | read 23.52; strash 5.48; write 0.26 s |
| Restore AIG, dc2 | Timeout | 180.12 s | read 6.18 s; dc2 did not finish |
| Restore AIG, default `&nf`, save BLIF | Completed | 160.98 s | read 6.15; `&get` 3.35; `&nf` 141.02; `&put` 1.20; write 9.11 s |
| Read mapped BLIF, buffer, save | Completed | 29.94 s | read 9.02; buffer 10.45; write 10.35 s |
| Read buffered BLIF, upsize, save | Completed | 34.43 s | read 11.23; upsize 12.78; write 10.27 s |
| `&nf -A 0` | Internal assertion failure | 100.86 s | `Nf_MatchDeref_rec`: `pM->fBest` |
| `&nf -A 1` | Completed | 128.72 s | read 5.94; `&get` 2.93; `&nf` 109.81; `&put` 1.26; write 8.60 s |

`dc2` used approximately 174 seconds after loading the AIG without producing
a result. `upsize -T 10` completed normally after its bounded sizing search;
ABC reported 10.56 seconds for that search, within the 12.78-second command.
ABC phase timers and externally measured process wall times are retained as
distinct measurements. Concurrent work can affect elapsed times.

The named `strash.aig` checkpoint is 23,294,036 bytes. The original BLIF contains
3,279,564 Boolean nodes and 6,457 logic levels; structural hashing produces
4,580,908 AND nodes and 5,732 levels. Its SHA256 is
`43ba3ba903c67864ddd4749405e8169efef9302cce98e8570803b359c25e0aaa`.

The demonstrated mapping path uses `strash`, `&get -n`, `&nf -D 3333.333`,
`&put`, `buffer -p -N 8 -S 100`, and `upsize -D 3333.333 -T 10`.
Removing the optional `dc2` phase leaves the complete logic network available
to technology mapping. No black box, logic deletion or validation waiver was
introduced by these experiments.

## Cell area and timing scope

Every mapped `.gate` cell was found in the pinned merged ASAP7 Liberty. Areas
below are sums of exact decimal Liberty `area` values multiplied by cell counts,
with no scaling factor. The JSON retains both counts and cell area values.

| Output | Mapped combinational cells | Raw Liberty area |
|---|---:|---:|
| Default direct `&nf` | 1,932,547 | 147,583.92132 |
| Direct `&nf -A 1` | 1,941,462 | 148,259.44188 |
| Default mapping after buffering | 2,321,728 | 176,308.21260 |
| Default mapping after upsizing | 2,321,728 | 176,554.80414 |

One final exact-area pass (`-A 1`) completed about 32 seconds sooner than the
default two passes, with a 0.458% combinational area increase. `-A 0` aborted
with the recorded ABC assertion and is not a validated setting for this graph.
ABC `print_stats` areas differ slightly from the exact Liberty sums; the latter
are the area values reported here.

ABC's NLDM sizing estimate ended at 56,375.12 ps against the requested
3,333.333 ps target. The earlier mapping delay of 1,613 equals the mapped logic
level metric and is not this physical delay estimate. This audit supplies no
OpenSTA result or achieved Fmax. Its area excludes flip-flops, and it does not
establish that the complete CPU meets area or frequency targets.

All four successful mapped outputs preserve the original **101,151 input and
101,188 output names, in the same order**. The port hashes and file hashes are
archived. Checkpoint reuse must match the exact extracted input BLIF hash,
because internal ABC boundary names belong to that extraction.

## Reproduction from the preserved input

The following commands use the preserved, hash-matched `input.blif` and
`asap7.scl` in `build/abc-stage-probe`. They recreate experiment scripts from the
committed JSON; no large input or checkpoint is embedded in the repository.

```sh
cd build/abc-stage-probe
python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path('../../reports/data/abc_stage_audit.json').read_text())
for name, stage in data['stages'].items():
    Path(name + '.abc').write_text(stage['commands'] + '\n')
PY
timeout --signal=TERM --kill-after=2s 180 ../tools/oss-cad-suite/bin/yosys-abc -f strash.abc
timeout --signal=TERM --kill-after=2s 180 ../tools/oss-cad-suite/bin/yosys-abc -f nf-direct.abc
timeout --signal=TERM --kill-after=2s 180 ../tools/oss-cad-suite/bin/yosys-abc -f buffer.abc
timeout --signal=TERM --kill-after=2s 180 ../tools/oss-cad-suite/bin/yosys-abc -f upsize.abc
```

The same bounded invocation with `dc2.abc`, `nf-one-ela.abc` or `nf-no-ela.abc`
reproduces the diagnostic alternatives. Timeout and assertion failure are
recorded outcomes, not successful mapping results. Per-experiment logs and the
original pseudo-terminal runner remain in `build/abc-stage-probe`.
