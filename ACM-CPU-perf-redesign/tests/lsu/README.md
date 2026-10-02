Run `python3 tests/lsu/run.py`. It builds a separate simulator with the production
RTL and a simulation-only bound observer, generates nineteen programs, and checks
all 76 combinations of programs, 3/20-cycle RAM latency, and fixed/random waits.
Every run checks exit value, retired count, every final RAM byte, and every
retirement against the independent reference interpreter. RAM retains the same
ordered II=1 interface and default capacity of 64 transactions as production.

The observed build disables branch prediction to keep deliberately wrong paths
reachable across loop iterations. Long producer dependencies use full-width
unsigned division pairs, changing raw operands across passes, and dependent
arithmetic chains. Divider normalization and the completed-pair cache remain
enabled; the observer requires actual hazards and recovery events. `--build-dir PATH` selects its output directory.
To use an existing production simulator without internal coverage requirements:

```sh
python3 tests/lsu/run.py --skip-build --binary build/perf-v1/cpu_sim --no-coverage
```

The programs cover:

- An older Store whose address waits on DIVU while a younger aliasing Load can
  speculatively read an already cached line. Address resolution must replay the
  Load and younger instructions. A dedicated checkpoint fixture includes a
  dependent WAW chain and requires `load_replay_count >= 1` in every run, even
  when internal observer coverage is disabled.
- An older Store with a known address but delayed data, which must block the
  conflicting younger Load until its value is available.
- Overlapping SB/SH writers, youngest matching bytes, signed/unsigned narrow
  loads, partial forwarding and committed-store-buffer progress during fills.
- A ready younger SW or two SH writers collectively shadowing every byte of an
  older Store whose data is unavailable. The Load must forward without waiting
  for those superseded bytes. A late unknown older address is similarly harmless
  when every requested byte was forwarded from newer stores; these cases require
  zero replays. A partial shadow leaves a real dependency and must replay.
- Twenty older stores sharing delayed data, followed by a Load waiting for the
  first store. After that store completes, the Load remains behind other ready
  memory operations while the old store's ROB slot is reused. Its wait condition
  must already be cleared, so the new unrelated slot owner cannot cause deadlock.
- Canceled reads whose delayed result or error arrives after physical-register
  and ROB-slot reuse, without corrupting the new instruction or raising a fault.
- Sixteen distinct cold wrong-path loads filling all D-MSHRs. The older branch
  cancels a presented request under cache backpressure; that request must remain
  stable, be accepted eventually, and drain without reusing its tag early.
- An older branch redirect after a younger branch already resolved, while a
  wrong-path read remains outstanding. Recovery restores a checkpoint in one
  edge; the obsolete multi-cycle reverse-walk state is not required.

Error injection targets the actual requested word (`0x20000` or `0x20200`).
The cache can return a critical word early, and an error in an unrelated later
prefetch word does not invalidate an already successful requested-word response.

The monitor observes every LQ slot with its saved ROB generation and destination
physical register. `LSU_COVERAGE` reports partial forwarding, speculative bypass,
explicit replay, pending/preaccept cancellation, canceled errors, physical/ROB
reuse and older redirects with pending loads. It also requires full per-byte
shadow forwarding, avoided shadowed replays, deferred wakeup after a Store becomes
ready, and reuse of that Store's slot while its former Load waiter is still live. The runner requires each event
category across all schedules; it does not assume a particular obsolete cycle
count. All architectural answers remain mandatory for each individual run.

Images, listings, reference answers, build logs, event counts and run metrics
remain in the build directory. Supplied testcases and their answers are unchanged.
