# Performance architecture contract

Owner requirements supersede the historical conservative draft: target IPC >=
1.0140 with 20-cycle RAM, pipelining explicitly allowed, no inherited serial
model or temporary correctness-only scheduling restrictions. The old validated
implementation is tagged `baseline-correct-serial`; it is not a selectable legacy
mode in the new architecture. Historical measurements are in
`reports/serial-baseline.json`.

## External memory

One unified 32-bit little-endian port, 256 KiB RAM, ordered responses. A request
may be accepted every cycle; the fixed-latency model presents its response exactly
20 cycles after acceptance (3 for correctness runs). Both reads and writes obey
this latency. Default maximum outstanding is 64. Backpressure/random additional
waits are verification options and do not reduce the fixed latency. Reads observe
all earlier completed writes. Exit requires every earlier RAM operation complete.

## Front end

Four instruction lanes, pipelined cache requests, 16 independently cancellable
request tags, ordered delivery into a 32-entry fetch queue. Cache returns up to
four consecutive words from any word-aligned address; fetch truncates only at
line boundaries or predicted control transfers. Speculative global history and
RAS snapshots travel with each instruction. A redirect restores the snapshot
and applies the actual transfer. Up to four committed transfers train the
predictor in order, including aliases of the same table entry.

## Back end

Default fetch/rename/issue/writeback/commit width 4 (supports 1,2,4), 128 physical
registers, 64 ROB, 32 IQ, 32 LQ/SQ/CSB. Four ALUs, two AGUs, up to four branch resolutions
per cycle, one MDU input per cycle. Completion-to-selection forwarding permits
one-cycle dependent ALU throughput, without executing a dependency chain of two
ALUs combinationally in the same clock interval.

The RAT is reconstructed combinationally from the committed map and surviving
ROB writers in circular age order, including the recovering branch or excluding
the replayed Load. Recovery frees younger destinations in one cycle. Full RAT
checkpoints exist only as an independent simulation oracle, not physical state. Loads can bypass unknown older Store addresses; Store
resolution checks already executed younger Loads and replays the oldest conflict
from its pre-Load checkpoint. Known overlapping Store data must be ready before
the Load reads its bytes. Store address generation may run before its data is
ready. Per-byte forwarding uses youngest older SQ/CSB entries.

Loads have independent tags, addresses, forwarding snapshots and completion
buffers; cancellation persists until any presented/accepted request drains. ROB
slot reuse never alone authenticates late cache data. Multiple committed Stores
can be in the cache request pipeline; their CSB records remain available for
forwarding until ordered retirement from the buffer.

## Caches and arithmetic

I-cache 4 KiB/2-way/4 MSHRs, D-cache 16 KiB/4-way/8 MSHRs; initial line 32 B.
Cache CPU requests carry 8-bit tag and `cpu_req_count[2:0]` (1..4 words), responses
carry 128 bits plus tag/error. I-cache waiter capacity matches FETCH_REQUESTS; D-cache has 32 waiters.
Multiple waiters per line, byte-valid sectors, byte dirty masks, no read on full-word Store allocation,
early restart, pipelined dirty-word writeback and flush. A speculative prefetch
word error cannot fault a successfully returned different word. No failed write
can silently clear dirty state.

The MDU accepts tagged operations, with a one-cycle multiplier, four elastic result slots and a separate
iterative high-radix divider. `req_tag/rsp_tag` are 8 bits; selective
`kill_mask[255:0]` clears every matching in-flight/held response. Global `kill`
clears all operations. Results hold under backpressure.

## Verification remains architectural

Four fixed retirement lanes: valid/store4, pc/inst/value/addr/wdata128, rd20,
wstrb16. `load_replay_count` accompanies prior counters. Full final RAM, exit
value, exact instruction count and in-order retirement differential remain
mandatory at 3/20 cycles. Cold caches, startup, recovery, drain and flush all
remain in IPC. Until an aggregation preference is supplied, report both summed
instructions/summed cycles and arithmetic mean of all six program IPCs; do not
claim target satisfaction using an unstated aggregation rule.
