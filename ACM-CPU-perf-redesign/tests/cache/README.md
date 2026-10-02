Run `bash tests/cache/run.sh` for the 1/2/4-way, 16/32/64-byte line and
1/8/16-MSHR sweep, including read-only caches. `--quick` runs representative
data/instruction caches, all four packet-width limits, 8/16-entry instruction
waiter pools, and both controller FIFO capacities. Generated files
stay under `build/tests-cache`; failures return a nonzero exit status. `VERILATOR`
selects a compiler and `JOBS` controls its build concurrency. For the pinned
modern compiler, set `VERILATOR=build/tools/oss-cad-suite/bin/verilator`.

`MAX_CPU_WORDS` bounds supported read packets (1 through 4 words). The CPU
instantiates its data cache with 1 and its instruction cache with the default 4;
waiter result storage uses exactly `32*MAX_CPU_WORDS` bits and zero-extends onto
the 128-bit response port. The suite tests 2/3-word limits, upper response zeros,
and rejection of larger requests. The CPU instruction waiter pool matches
`FETCH_REQUESTS`; accepted canceled requests retain their frontend slot until
the response arrives, so this limit also covers cancellation.
Writeback and flush share their mutually exclusive data read port. Read-only
instances remove CPU-store data write ports explicitly. Their data array stores
one whole cache line per row: one line read supplies each hit packet and one
supplies each completed waiter. A 32-bit memory response updates only its valid
fill bytes. Data caches retain 32-bit rows and one-word requests.

The external channel is a 32-bit ordered pipeline: one request and one response
can transfer each cycle, with up to 64 accepted requests in flight. The controller
test fills its owner FIFO, exercises simultaneous enqueue/dequeue, checks fair
grants, independently stalls each response client, and verifies stable payloads
and error routing at 3/20/97-cycle latency. It requires sustained request bursts
and tests both 4-entry and 64-entry owner FIFOs.

The cache test checks:

- Counted 1/2/3/4-word (128-bit) responses, no-bubble hits, and tagged response
  stability under backpressure.
- Full and partial store sectors without read-for-ownership, preservation of
  untouched bytes, and fills that merge with committed dirty bytes.
- 8/16/32 same-line waiters, FIFO ordering of mixed reads/writes, unrelated hits while
  misses are blocked, and multiple outstanding miss slots and word requests.
- Critical-word early restart, errors isolated to requesting waiters, successful
  sectors retained after a different prefetch fails, and retry of the failed word.
- Per-word error masks on four-word packets (failed words 0/1/3), preservation of
  every successful word, and mask/data stability while the CPU response stalls.
- Dirty-word-only victim writes and flushes, successful WB-to-fill transitions,
  errors after partial write completion, retained dirty bytes, and flush retries.
- Flush asserted with pending operations, 1,800 overlapping randomized accesses
  at each of 3/20-cycle RAM latency, and independent request/response backpressure.

Writeback errors set `flush_error` until reset. Victim data and all its dirty bits
remain intact unless every victim write succeeds. During flush, each successful
word response clears only its written dirty bytes; a failed word retains them.
The flush drains already-presented/accepted requests and returns `flush_done`
with the sticky error. The core must prohibit exit after such an error.

Read failures affect only pending operations that still need the failed bytes.
Previously returned reads remain valid. A failed prefetch word stays invalid;
later requests retry it. A multiword response waits until each requested word is
valid or has an error, preserves successful words, and sets bit `i` of
`cpu_rsp_error_mask` only for failed requested word `i`. `cpu_rsp_error` is the
aggregate error for data clients; instruction clients can keep a valid prefix.
Unknown bytes of a store response have no architectural
meaning, so tests check the store's tagged completion and its eventual RAM bytes.

Each generated cache binary also supports `--window-trace N`. It limits accepted,
unanswered requests to `N`, checks every response, and prints cycles, RAM reads,
response count and a hash of RAM addresses and response order. This makes exact
flow comparisons between the frontend's bounded window and larger waiter pools
reproducible; `N` must not exceed the compiled waiter count.
`--exact-trace` runs the complete directed/randomized suite and prints a cumulative
cycle count and hash of accepted CPU requests, successful response words, error
masks and RAM request payloads, with each transaction's cycle. This compares RTL
implementations without treating unspecified store-response data as meaningful.
