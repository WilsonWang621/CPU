# RTL and simulation interfaces

The owner confirmed that the three supplied repositories are the complete course
input. This project owns its CPU, pipelined memory model, simulator and build.
See [performance-redesign.md](performance-redesign.md) for the architectural
contract and [../design.md](../design.md) for the current design. The serial
baseline is historical Git data, not a supported hidden runtime mode.

All modules use a rising-edge clock and synchronous active-high rst. A transfer
occurs on valid AND ready; an unaccepted request/response holds its payload.
External memory is unified 256 KiB little-endian RAM, 32-bit transactions,
initiation interval one cycle, up to MAX_MEM_OUTSTANDING=64 requests, ordered
responses. Fixed latency is 20 cycles for performance and 3 for correctness;
reads and writes both complete via response. Random waits only extend latency.

## Public cpu_top

Request outputs: mem_req_valid, mem_req_write, mem_req_addr[31:0],
mem_req_wdata[31:0], mem_req_wstrb[3:0]; input mem_req_ready.
Response inputs: mem_rsp_valid, mem_rsp_rdata[31:0], mem_rsp_error;
output mem_rsp_ready. No IDs are needed on the ordered external channel.

Debug outputs: halted, faulted, fault_pc/inst/addr[31:0], fault_inst_valid,
fault_cause[3:0]. Fault numbers are defined in rtl/cpu_pkg.sv.
Four fixed retirement lanes (lane zero in low bits): retire_valid/store[3:0],
retire_pc/inst/value/addr/wdata[127:0], retire_rd[19:0], retire_wstrb[15:0].
Only a continuous valid prefix retires. rd=0 denotes no architectural GPR write.
Store addr is its original byte address; wdata/wstrb occupy aligned word lanes.

Counters are 64 bits: cycle_count, retired_count, branch_miss_count,
load_replay_count, icache_miss_count, dcache_miss_count. Counters include all work
through the final exit acceptance and remain frozen after halt.
SW to exactly 0x80000000 exits without modifying RAM. Every preceding dirty write
has completed before its request appears. That request's acceptance retires the
exit Store and asserts halted at the same rising edge.

## Cache CPU interface

Request: cpu_req_valid/ready/write, addr[31:0], wdata[31:0], wstrb[3:0],
count[2:0] (1..4 words), tag[TAG_BITS-1:0]. Addresses are word aligned and the
requested words stay within one line. Stores have count=1.
Response: cpu_rsp_valid/ready, data[127:0], tag, error, error_mask[3:0].
Low word is the addressed word, then consecutive words. The mask identifies
failed requested words independently; aggregate error is its reduction OR.
Successful words remain meaningful even when another word fails. Unrequested
prefetch errors never fault a successful waiter.

Every accepted request has exactly one tagged response. Cache operations are
not withdrawn on branch recovery; the core/frontend cancel architectural
waiters while continuing to drain responses. Multiple requests can merge into
one line, with Store/Load ordering preserved within that line.

flush_valid is held until flush_done, which holds until flush_valid drops.
Flush begins after idle and exclusively owns cache updates. flush_error is
sticky since reset for writeback errors; failed writes never silently clear
dirty. idle includes waiters, held responses, MSHRs and memory work.

Each cache memory port has the public mem_* request/response shape and supports
multiple ordered outstanding requests. The memory_controller arbitrates two
clients using packed s_req_valid/write[1:0], addr/wdata[63:0], wstrb[7:0] and
s_rsp_valid/error[1:0], rdata[63:0]. Client zero uses low bits. Ownership is queued
until response acceptance. Request and response credit calculations are separate
from response routing, preventing a handshake combinational cycle.

## Frontend, arithmetic and integration

The frontend uses four cpu_pkg::fetch_t outputs and pop_count[2:0]. Fetch records
carry original PC/instruction/valid/fault, predicted PC, pre-instruction history,
RAS snapshot/count and fetch-time direction predictor components. Redirects
restore these snapshots and apply the actual branch; Load replay applies no
branch effect. Four commit training lanes fold predictor updates in age order.

Decoder, ALU and branch_unit ports are declared directly in their small RTL
modules. Tagged muldiv accepts req_op/a/b/tag[7:0], holds rsp_result/tag under
backpressure, supports global kill plus selective kill_mask[255:0]. Its
mul_ready/div_ready hints expose independent resource capacity without depending
on the currently selected request's opcode/tag. Core tags are ROB slots; pending
MDU stages are invalidated before a killed slot is allocated again.

The simulator CLI is `build/cpu_sim --image PATH --expected PATH --memory PATH
--instructions N --latency 20 [--trace PATH] [--max-outstanding 64]`.
`--random-wait` and `--request-wait` enable pressure testing. It rejects protocol
violations, exit with outstanding work, non-prefix retirement, mismatched exit,
incorrect final RAM and incorrect retirement count. Traces feed the independent
RV32IM interpreter in scripts/differential.py. JSON statistics include all five
retirement histogram bins, actual memory concurrency, execution time and RSS.
