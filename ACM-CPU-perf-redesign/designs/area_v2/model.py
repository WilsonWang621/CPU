#!/usr/bin/env python3
"""Architectural trace timing experiment, NOT a CPU simulator or IPC proof.

The reference executes the actual programs and checks their results. This model
then schedules that correct-path trace with finite queues, dependency readiness,
ordered memory issue, a shared II=1/latency=20 RAM, cold caches, and explicit
branch recovery delays. Wrong-path resource/cache pollution is not modeled.
"""
import argparse
from collections import Counter, deque
from dataclasses import asdict, dataclass, field
import hashlib
import heapq
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from reference import EXIT_ADDRESS, MASK32, load_image, run, signed


@dataclass(frozen=True)
class Instruction:
    pc: int
    inst: int
    rd: int
    dependencies: tuple
    kind: str
    address: int
    size: int
    next_pc: int = 0


def trace_program(case):
    registers, writers, rows = [0]*32, [-1]*32, []
    def retire(row):
        pc, inst, rd, value, store, address, _, _ = row
        opcode, f3 = inst & 127, (inst >> 12) & 7
        rs1, rs2 = (inst >> 15) & 31, (inst >> 20) & 31
        sources = []
        if opcode in (3, 0x23, 0x13, 0x33, 0x63, 0x67):
            sources.append(rs1)
        if opcode in (0x23, 0x33, 0x63):
            sources.append(rs2)
        deps = tuple(sorted({writers[r] for r in sources if r and writers[r] >= 0}))
        size = 0
        if opcode == 3:
            kind, size = "load", {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            address = (registers[rs1] + signed(inst >> 20, 12)) & MASK32
        elif store:
            kind, size = ("exit" if address == EXIT_ADDRESS else "store"), {0: 1, 1: 2, 2: 4}[f3]
        elif opcode == 0x63:
            kind = "branch"
        elif opcode == 0x67:
            kind = "indirect"
        elif opcode == 0x6f:
            kind = "jump"
        elif opcode == 0x33 and inst >> 25 == 1:
            kind = "divide" if f3 >= 4 else "multiply"
        else:
            kind = "alu"
        rows.append(Instruction(pc, inst, rd, deps, kind, address, size))
        if rd:
            registers[rd], writers[rd] = value, len(rows)-1
    exit_value, count, memory = run(load_image(case / "program.data"), on_retire=retire)
    assert exit_value == int((case / "expected.txt").read_text(), 0)
    assert count == json.loads((case / "metrics.json").read_text())["dynamic_instructions"]
    assert memory == load_image(case / "expected.memory")
    from dataclasses import replace
    return [replace(row, next_pc=rows[i+1].pc if i+1 < len(rows) else 0) for i, row in enumerate(rows)]


@dataclass
class Config:
    name: str = "v2"
    rob: int = 32
    integer_entries: int = 8
    memory_entries: int = 8
    dispatch: int = 2
    commit: int = 2
    integer_ports: int = 2
    load_slots: int = 8
    store_slots: int = 16
    icache_bytes: int = 1024
    dcache_bytes: int = 2048
    dcache_ways: int = 2
    dcache_mshrs: int = 4
    line_bytes: int = 32
    hit_latency: int = 2
    recovery_cycles: int = 5
    branch_checkpoints: int = 0
    fetch_packet_bytes: int = 32
    bht_entries: int = 256
    btb_entries: int = 32
    memory_latency: int = 20
    memory_credits: int = 64
    load_policy: str = "line"
    in_order: bool = False


class Memory:
    def __init__(self, config):
        self.config = config
        self.queue, self.pending = deque(), []
        self.requests, self.writes, self.serial = 0, 0, 0
        self.peak, self.last_fill = 0, -1

    def enqueue(self, callback, write=False, channel="data"):
        self.queue.append((callback, write, channel))

    def tick(self, cycle):
        while self.pending and self.pending[0][0] <= cycle:
            _, _, callback, write, channel = heapq.heappop(self.pending)
            callback(cycle)
            if not write and channel == "data":
                self.last_fill = cycle
        if self.queue and len(self.pending) < self.config.memory_credits:
            callback, write, channel = self.queue.popleft()
            self.serial += 1
            heapq.heappush(self.pending, (cycle+self.config.memory_latency, self.serial, callback, write, channel))
            self.requests += 1
            self.writes += write
            self.peak = max(self.peak, len(self.pending))

    def idle(self):
        return not self.queue and not self.pending


@dataclass
class Line:
    tag: int = -1
    words: set = field(default_factory=set)
    pending: set = field(default_factory=set)
    age: int = 0


class Cache:
    def __init__(self, capacity, ways, mshrs, memory, config, channel):
        self.sets = [[Line() for _ in range(ways)] for _ in range(capacity//ways//config.line_bytes)]
        self.mshrs, self.memory, self.config, self.channel = mshrs, memory, config, channel
        self.active, self.misses, self.fills = 0, 0, 0

    def locate(self, address):
        tag = address//self.config.line_bytes
        ways = self.sets[tag % len(self.sets)]
        return tag, ways, next((line for line in ways if line.tag == tag), None)

    def request(self, address, cycle):
        tag, ways, line = self.locate(address)
        word = address % self.config.line_bytes // 4
        if line is not None:
            line.age = cycle
            if word in line.words:
                return True
            if word in line.pending:
                return False
        if self.active >= self.mshrs:
            return False
        if line is None:
            victims = [l for l in ways if not l.pending]
            if not victims:
                return False
            line = min(victims, key=lambda l: (-1 if l.tag < 0 else l.age))
            line.tag, line.words, line.age = tag, set(), cycle
            self.misses += 1
        if self.channel == "data" and self.config.load_policy == "word":
            words = [word]
        else:
            words = [(word+i) % (self.config.line_bytes//4) for i in range(self.config.line_bytes//4)]
        words = [w for w in words if w not in line.words and w not in line.pending]
        line.pending.update(words)
        self.active += 1
        remaining = [len(words)]
        def complete(w, now):
            line.words.add(w)
            line.pending.remove(w)
            remaining[0] -= 1
            self.fills += 1
            if not remaining[0]:
                self.active -= 1
        for w in words:
            self.memory.enqueue(lambda now, w=w: complete(w, now), channel=self.channel)
        return False

    def waiting_for_word(self, address):
        _, _, line = self.locate(address)
        return line is not None and address % self.config.line_bytes // 4 in line.pending

    def store(self, address, size, cycle):
        _, _, line = self.locate(address)
        # One fill/store write port. Wait for a fill of the same line so a
        # late read response cannot overwrite the committed store.
        if self.memory.last_fill == cycle or (line and line.pending):
            return False
        # Write-through, no write allocation. Existing full word is updated;
        # a narrow store to an invalid word leaves it invalid.
        if line:
            word = address % self.config.line_bytes // 4
            if size == 4:
                line.words.add(word)
            line.age = cycle
        return True


def simulate(trace, config):
    n, infinity = len(trace), 10**12
    finish, issued, committed = [infinity]*n, [False]*n, [False]*n
    memory = Memory(config)
    icache = Cache(config.icache_bytes, 1, 1, memory, config, "instruction")
    dcache = Cache(config.dcache_bytes, config.dcache_ways, config.dcache_mshrs, memory, config, "data")
    rob, queues, memq, stores, loads = deque(), [deque(), deque()], deque(), deque(), {}
    bht, btb = [1]*config.bht_entries, [None]*config.btb_entries
    branch_events, checkpoint_owners = [], set()
    retire_pos, dispatch_pos, cycle, steer = 0, 0, 0, 0
    blocked_branch, fetch_resume = None, 0
    branch_misses, forwarded = 0, 0
    reasons = Counter()
    peak_rob = peak_loads = 0
    predictions = {}

    def ready(i):
        return all(finish[d] <= cycle for d in trace[i].dependencies)

    def predict(i):
        row = trace[i]
        idx, bi = (row.pc//4) % len(bht), (row.pc//4) % len(btb)
        if row.kind == "branch":
            taken = bht[idx] >= 2
            entry = btb[bi]
            return entry[1] if taken and entry and entry[0] == row.pc else row.pc+4
        if row.kind == "jump":
            # Direct JAL target predecode. Charge a frontend bubble below.
            return row.next_pc
        entry = btb[bi]
        return entry[1] if entry and entry[0] == row.pc else row.pc+4

    while retire_pos < n or stores or loads or not memory.idle():
        if cycle > 5_000_000:
            raise RuntimeError(f"model stalled at {retire_pos}/{n}: {config}")
        memory.tick(cycle)
        # Resolution/training has one writer because branches use port 0.
        while branch_events and branch_events[0][0] <= cycle:
            _, i = heapq.heappop(branch_events)
            row = trace[i]
            checkpoint_owners.discard(i)
            idx = row.pc//4 % len(bht)
            if row.kind == "branch":
                taken = row.next_pc != row.pc+4
                bht[idx] = min(3, bht[idx]+1) if taken else max(0, bht[idx]-1)
                inst = row.inst
                immediate = signed(((inst >> 31) << 12) | (((inst >> 7) & 1) << 11) |
                                   (((inst >> 25) & 63) << 5) | (((inst >> 8) & 15) << 1), 13)
                target = (row.pc+immediate) & MASK32
            else:
                target = row.next_pc
            btb[row.pc//4 % len(btb)] = (row.pc, target)
            if i == blocked_branch:
                fetch_resume = cycle + config.recovery_cycles
                blocked_branch = None
        # Cache misses do not occupy the AGU. Eight finite load slots retry
        # their requested word; already issued external traffic retains credit.
        cache_read_used = False
        for i in list(loads):
            if dcache.waiting_for_word(trace[i].address):
                continue
            cache_read_used = True
            if dcache.request(trace[i].address, cycle):
                finish[i] = cycle+config.hit_latency
                del loads[i]
            break
        peak_loads = max(peak_loads, len(loads))
        # Commit at most two instructions and one store per cycle.
        store_committed = False
        for _ in range(config.commit):
            if not rob or finish[rob[0]] > cycle:
                break
            i = rob[0]
            if trace[i].kind == "store":
                if store_committed:
                    break
                store_committed = True
            committed[i] = True
            rob.popleft()
            retire_pos += 1
        # Committed stores drain in order, remain forwardable until the RAM
        # acknowledgement, and compete with fills at the cache's write port.
        candidate = next((s for s in stores if not s[1]), None)
        if candidate and committed[candidate[0]]:
            i = candidate[0]
            if dcache.store(trace[i].address, trace[i].size, cycle):
                candidate[1] = True
                memory.enqueue(lambda now, entry=candidate: entry.__setitem__(2, True), write=True)
        while stores and stores[0][2]:
            stores.popleft()
        # Two independent 8-entry integer queues; no multi-winner global sort.
        for port in range(config.integer_ports):
            eligible = [i for i in queues[port] if ready(i)]
            if config.in_order:
                oldest = next((i for i in rob if not issued[i]), None)
                eligible = [i for i in eligible if i == oldest]
            if eligible:
                i = eligible[0]
                queues[port].remove(i)
                issued[i] = True
                latency = 32 if trace[i].kind == "divide" else 3 if trace[i].kind == "multiply" else 1
                finish[i] = cycle+latency
                if trace[i].kind in ("branch", "indirect", "jump"):
                    heapq.heappush(branch_events, (finish[i], i))
        # Memory operations issue strictly in program order, so no unknown
        # older-store bypass, associative load replay, or load checkpoints.
        if memq and ready(memq[0]):
            i, row = memq[0], trace[memq[0]]
            allow = not config.in_order or i == next((j for j in rob if not issued[j]), None)
            if row.kind in ("store", "exit"):
                if allow and (row.kind == "exit" or len(stores) < config.store_slots):
                    memq.popleft()
                    issued[i], finish[i] = True, cycle+1
                    if row.kind == "store":
                        stores.append([i, False, False])
            elif allow and len(loads) < config.load_slots:
                aliases = [s[0] for s in stores if trace[s[0]].address < row.address+row.size and
                           row.address < trace[s[0]].address+trace[s[0]].size]
                last = trace[aliases[-1]] if aliases else None
                complete_forward = last and last.address <= row.address and last.address+last.size >= row.address+row.size
                if complete_forward or (not aliases and not cache_read_used):
                    memq.popleft()
                    issued[i] = True
                    if complete_forward:
                        finish[i] = cycle+config.hit_latency
                        forwarded += 1
                    elif dcache.request(row.address, cycle):
                        finish[i] = cycle+config.hit_latency
                    else:
                        loads[i] = True
        # No newly dispatched instruction executes on this same edge.
        used_banks = set()
        if blocked_branch is None and cycle >= fetch_resume:
            for lane in range(config.dispatch):
                if dispatch_pos == n or len(rob) == config.rob:
                    reasons["rob_or_end"] += 1
                    break
                i, row = dispatch_pos, trace[dispatch_pos]
                # Even/odd 32-bit banks support an unaligned pair. The default
                # pair may cross an 8-byte boundary, but not a cache line.
                if lane and row.pc//config.fetch_packet_bytes != trace[i-1].pc//config.fetch_packet_bytes:
                    break
                if not icache.request(row.pc, cycle):
                    reasons["icache"] += 1
                    break
                mem = row.kind in ("load", "store", "exit")
                branch = row.kind in ("branch", "indirect", "jump")
                if mem:
                    bank, capacity = 2, config.memory_entries
                    queue = memq
                else:
                    options = [p for p in range(config.integer_ports) if p not in used_banks and
                               len(queues[p]) < config.integer_entries]
                    if branch or row.kind in ("multiply", "divide"):
                        options = [0] if 0 in options else []
                    if not options:
                        reasons["integer_queue_or_port"] += 1
                        break
                    bank = min(options, key=lambda p: (len(queues[p]), p != steer))
                    queue, capacity = queues[bank], config.integer_entries
                    steer = 1-bank
                if bank in used_banks or len(queue) == capacity:
                    reasons["queue_or_dispatch_bank"] += 1
                    break
                if branch and config.branch_checkpoints and len(checkpoint_owners) >= config.branch_checkpoints:
                    reasons["branch_checkpoints"] += 1
                    break
                used_banks.add(bank)
                queue.append(i)
                rob.append(i)
                dispatch_pos += 1
                if branch:
                    checkpoint_owners.add(i)
                    predictions[i] = predict(i)
                    if predictions[i] != row.next_pc:
                        branch_misses += 1
                        blocked_branch = i
                        break
                    if row.kind == "jump":
                        fetch_resume = cycle+2
                        break
                    if row.next_pc != row.pc+4:
                        break
        else:
            reasons["branch_recovery"] += 1
        peak_rob = max(peak_rob, len(rob))
        cycle += 1
    # EXIT is emitted only after all write-through stores and reads drain.
    cycle += 1
    return dict(instructions=n, cycles=cycle, ipc=n/cycle, branch_misses=branch_misses,
                icache_misses=icache.misses, dcache_misses=dcache.misses, memory_requests=memory.requests+1,
                memory_writes=memory.writes, peak_memory_outstanding=memory.peak,
                peak_rob=peak_rob, peak_loads=peak_loads, forwarded_loads=forwarded,
                dispatch_block_observations=dict(reasons))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/area-v2/model.json")
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("configs.json"))
    args = parser.parse_args()
    configs = [Config(**row) for row in json.loads(args.config.read_text())]
    cases = sorted((ROOT / "RISC-V-CPU-2026-Testcases").glob("perf_*"))
    traces = {case.name: trace_program(case) for case in cases}
    results = []
    for config in configs:
        rows = []
        for case, trace in traces.items():
            row = dict(case=case, **simulate(trace, config))
            rows.append(row)
            print(config.name, case, row["cycles"], f'{row["ipc"]:.6f}', flush=True)
        results.append(dict(config=asdict(config), results=rows,
                            aggregate_ipc=sum(r["instructions"] for r in rows)/sum(r["cycles"] for r in rows)))
    report = dict(scope="Correct-path trace timing model, not RTL measurement or proof of meeting IPC.",
                  limitations=["Wrong-path queue occupancy, instructions and cache traffic absent.",
                               "No frontend request/decode pipeline; cache hit is visible to dispatch in its current cycle.",
                               "One cache read per cycle; forwarding versus returning-miss writeback contention is not modeled.",
                               "Recovery delay is a sensitivity parameter, not a measured rollback implementation.",
                               "Data values/faults are validated by the reference, not by the timing model."],
                  model_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  configuration_sha256=hashlib.sha256(args.config.read_bytes()).hexdigest(),
                  reference_sha256=hashlib.sha256((ROOT / "scripts/reference.py").read_bytes()).hexdigest(),
                  images_sha256={case.name: hashlib.sha256((case / "program.data").read_bytes()).hexdigest() for case in cases},
                  results=results)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    for row in results:
        print(row["config"]["name"], "estimated aggregate IPC", row["aggregate_ipc"])


if __name__ == "__main__":
    main()
