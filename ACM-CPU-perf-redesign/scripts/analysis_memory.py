#!/usr/bin/env python3
"""Measure mandatory RAM traffic and prototype cache policies on RV32IM traces.

This is an architectural trace analysis, not an RTL performance measurement.
It never changes supplied images or expected results. The absolute lower bound
allows unbounded storage and shared instruction/data reads; policy models use
architectural access order and omit wrong-path traffic and pipeline delays.
"""
import argparse
from collections import OrderedDict
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path

from reference import EXIT_ADDRESS, MASK32, load_image, run, signed

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def trace_case(path):
    initial = load_image(path / "program.data")
    memory = initial[:]
    registers = [0] * 32
    trace = []
    written_bytes, written_words = set(), set()
    code_words, initial_code_words = set(), set()
    initial_data_bytes, initial_data_words = set(), set()
    load_words = set()
    counts = dict(instructions=0, loads=0, stores=0, load_bytes=0, store_bytes=0)

    def retire(packet):
        pc, inst, rd, value, store, address, _, strobe = packet
        trace.append(("I", pc, 4))
        counts["instructions"] += 1
        code_words.add(pc // 4)
        if any(byte not in written_bytes for byte in range(pc, pc+4)):
            initial_code_words.add(pc // 4)
        if inst & 0x7f == 0x03:
            size = 1 << ((inst >> 12) & 3)
            address = (registers[(inst >> 15) & 31] + signed(inst >> 20, 12)) & MASK32
            trace.append(("R", address, size))
            counts["loads"] += 1
            counts["load_bytes"] += size
            load_words.add(address // 4)
            for byte in range(address, address+size):
                if byte not in written_bytes:
                    initial_data_bytes.add(byte)
                    initial_data_words.add(byte // 4)
        if store and address != EXIT_ADDRESS:
            size = strobe.bit_count()
            trace.append(("W", address, size))
            counts["stores"] += 1
            counts["store_bytes"] += size
            written_bytes.update(range(address, address+size))
            written_words.add(address // 4)
        if rd:
            registers[rd] = value
        registers[0] = 0

    exit_value, retired, final = run(memory, on_retire=retire)
    expected = load_image(path / "expected.memory")
    metrics = json.loads((path / "metrics.json").read_text())
    assert final == expected, f"reference final RAM differs: {path.name}"
    assert retired == metrics["dynamic_instructions"] == counts["instructions"]
    assert exit_value == int((path / "expected.txt").read_text().strip(), 0) & MASK32
    changed_bytes = {index for index, (old, new) in enumerate(zip(initial, final)) if old != new}
    changed_words = {byte // 4 for byte in changed_bytes}
    assert changed_words <= written_words
    required_reads = initial_code_words | initial_data_words
    result = dict(case=path.name, image_sha256=digest(path / "program.data"), **counts,
        executed_code_words=len(code_words), initial_code_words=len(initial_code_words),
        distinct_load_words=len(load_words), read_before_written_bytes=len(initial_data_bytes),
        read_before_written_words=len(initial_data_words), written_bytes=len(written_bytes),
        written_words=len(written_words), final_changed_bytes=len(changed_bytes),
        final_changed_words=len(changed_words), unchanged_written_words=len(written_words-changed_words),
        code_data_initial_read_overlap_words=len(initial_code_words & initial_data_words),
        code_store_overlap_words=len(code_words & written_words),
        mandatory_initial_read_transactions=len(required_reads),
        mandatory_final_write_transactions=len(changed_words),
        mandatory_ram_transactions=len(required_reads)+len(changed_words),
        dirty_word_ram_transactions=len(required_reads)+len(written_words),
        split_cache_dirty_word_ram_transactions=len(initial_code_words)+len(initial_data_words)+len(written_words))
    return result, trace


@dataclass
class Line:
    valid_bytes: int = 0
    dirty_words: int = 0


class TraceCache:
    """LRU cache with full-line fills or byte-valid, word-dirty sectors.

    A sector store can allocate bytes without reading RAM. Its eventual byte
    strobes preserve unknown bytes, so neither a partial store miss nor its
    eviction requires a read-for-ownership transaction. A later load reads a
    whole 32-bit word only when one requested byte is unknown. Dirty bytes are
    retained when that read is merged. No-write-allocate applies to tag misses.
    """
    def __init__(self, capacity, ways, line_bytes, sector=False, word_dirty=False,
                 no_write_allocate=False):
        assert capacity % line_bytes == 0
        self.line_bytes = line_bytes
        self.ways = ways or capacity // line_bytes  # zero means fully associative
        assert capacity % (self.ways * line_bytes) == 0
        self.sets = [OrderedDict() for _ in range(capacity // (self.ways * line_bytes))]
        self.sector = sector
        self.word_dirty = word_dirty or sector
        self.no_write_allocate = no_write_allocate
        self.reads = self.writes = self.tag_misses = self.sector_misses = self.evictions = 0
        self.flush_writes = 0

    def writeback(self, line):
        writes = line.dirty_words.bit_count() if self.word_dirty else (
            self.line_bytes//4 if line.dirty_words else 0)
        self.writes += writes
        line.dirty_words = 0
        return writes

    def access(self, address, size, write=False):
        assert address // self.line_bytes == (address+size-1) // self.line_bytes
        line_number = address // self.line_bytes
        cache_set = self.sets[line_number % len(self.sets)]
        line = cache_set.get(line_number)
        if line is None:
            self.tag_misses += 1
            if write and self.no_write_allocate:
                self.writes += 1
                return
            if len(cache_set) == self.ways:
                _, old = cache_set.popitem(last=False)
                self.writeback(old)
                self.evictions += 1
            line = Line()
            cache_set[line_number] = line
            if not self.sector:
                line.valid_bytes = (1 << self.line_bytes)-1
                self.reads += self.line_bytes//4
        cache_set.move_to_end(line_number)
        offset = address % self.line_bytes
        requested = ((1 << size)-1) << offset
        if write:
            line.valid_bytes |= requested
            line.dirty_words |= 1 << (offset//4)
        elif line.valid_bytes & requested != requested:
            assert self.sector
            self.sector_misses += 1
            self.reads += 1
            line.valid_bytes |= 0xf << (offset//4*4)

    def flush(self):
        for cache_set in self.sets:
            for line in cache_set.values():
                self.flush_writes += self.writeback(line)

    def metrics(self):
        return dict(reads=self.reads, writes=self.writes, tag_misses=self.tag_misses,
                    sector_misses=self.sector_misses, evictions=self.evictions,
                    flush_writes=self.flush_writes)


def ceilings(instructions, transactions, latency, width, bus_model="pipelined"):
    # The historical serial harness prohibited request acceptance in a response
    # cycle. The owner subsequently authorized pipelined RAM at II=1; this model
    # assumes enough outstanding capacity to sustain that interval. All cycles
    # below are lower bounds only, with unlimited compute/memory overlap.
    if bus_model == "serialized":
        optimistic_bus_cycles = latency*transactions+1
        bus_cycles = (latency+1)*transactions+1
    else:
        optimistic_bus_cycles = transactions+latency+1
        bus_cycles = optimistic_bus_cycles
    ideal_cycles = max(math.ceil(instructions/width), optimistic_bus_cycles)
    harness_cycles = max(math.ceil(instructions/width), bus_cycles)
    return dict(optimistic_bus_cycles_lower=optimistic_bus_cycles,
                current_harness_cycles_lower=harness_cycles,
                optimistic_cycles_lower=ideal_cycles,
                optimistic_ipc_upper=instructions/ideal_cycles,
                current_harness_ipc_upper=instructions/harness_cycles)


def cache_configs(full=False):
    result = [dict(name="baseline_full32_i2k2_d4k2", instruction=dict(capacity=2048, ways=2, line_bytes=32),
                   data=dict(capacity=4096, ways=2, line_bytes=32))]
    capacities = (4096, 8192, 16384, 32768) if full else (4096, 16384, 32768)
    for capacity in capacities:
        for ways in (1, 2, 0):
            for policy, settings in [
                ("full_word_dirty", dict(word_dirty=True)),
                ("full_nwa_word_dirty", dict(word_dirty=True, no_write_allocate=True)),
                ("sector", dict(sector=True)),
                ("word", dict(sector=True)),
            ]:
                line = 4 if policy == "word" else 32
                result.append(dict(name=f"{policy}_d{capacity}_w{ways or 'fa'}",
                    instruction=dict(capacity=2048, ways=2, line_bytes=32),
                    data=dict(capacity=capacity, ways=ways, line_bytes=line, **settings)))
    for capacity in (4096, 16384, 32768):
        result.append(dict(name=f"split_sector_i2k2_d{capacity}_w2",
            instruction=dict(capacity=2048, ways=2, line_bytes=32, sector=True),
            data=dict(capacity=capacity, ways=2, line_bytes=32, sector=True)))
        result.append(dict(name=f"unified_sector_{capacity}_fa",
            unified=dict(capacity=capacity, ways=0, line_bytes=32, sector=True)))
    return result


def simulate_policy(trace, config):
    if "unified" in config:
        instruction = data = TraceCache(**config["unified"])
    else:
        instruction = TraceCache(**config["instruction"])
        data = TraceCache(**config["data"])
    for kind, address, size in trace:
        (instruction if kind == "I" else data).access(address, size, kind == "W")
    data.flush()
    if instruction is data:
        return dict(ram_transactions=data.reads+data.writes, unified=data.metrics())
    return dict(ram_transactions=instruction.reads+data.reads+data.writes,
                instruction=instruction.metrics(), data=data.metrics())


def summarize(rows, cycle_key, ipc_key):
    return dict(instructions=sum(row["instructions"] for row in rows),
                cycles_lower=sum(row[cycle_key] for row in rows),
                aggregate_ipc_upper=sum(row["instructions"] for row in rows)/sum(row[cycle_key] for row in rows),
                arithmetic_mean_ipc_upper=sum(row[ipc_key] for row in rows)/len(rows),
                geometric_mean_ipc_upper=math.exp(sum(math.log(row[ipc_key]) for row in rows)/len(rows)))


def self_test():
    # Byte-valid sectors must not fetch a full-overwritten word, and partial
    # stores only need a read if a later load requests an unknown byte.
    cache = TraceCache(8, 1, 8, sector=True)
    cache.access(0, 1, True)
    cache.access(0, 1)
    assert cache.reads == 0
    cache.access(0, 4)
    assert cache.reads == 1
    cache.access(4, 4, True)
    cache.access(4, 4)
    cache.flush()
    assert (cache.reads, cache.writes) == (1, 2)
    cache = TraceCache(8, 1, 8)
    cache.access(0, 4, True)
    cache.access(8, 4)
    cache.flush()
    assert (cache.reads, cache.writes) == (4, 2)
    cache = TraceCache(8, 1, 8, sector=True)
    cache.access(4, 4)
    cache.access(4, 4)
    cache.access(0, 4)
    cache.access(0, 4)
    assert cache.reads == 2
    cache = TraceCache(8, 1, 8, no_write_allocate=True, word_dirty=True)
    cache.access(0, 1, True)
    assert (cache.reads, cache.writes, len(cache.sets[0])) == (0, 1, 0)
    cache.access(0, 4)
    cache.access(4, 4, True)
    cache.flush()
    assert (cache.reads, cache.writes) == (2, 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cases", nargs="*")
    parser.add_argument("--root", type=Path, default=ROOT / "RISC-V-CPU-2026-Testcases")
    parser.add_argument("--output", type=Path, default=ROOT / "build/memory-analysis.json")
    parser.add_argument("--latency", type=int, default=20)
    parser.add_argument("--width", type=int, default=2)
    parser.add_argument("--bus-model", choices=("pipelined", "serialized"), default="pipelined",
                        help="II=1 pipelined RAM, or the historical one-outstanding harness")
    parser.add_argument("--full", action="store_true", help="include the 8 KiB data-cache configurations")
    parser.add_argument("--bounds-only", action="store_true")
    args = parser.parse_args()
    assert args.latency > 0 and args.width > 0
    self_test()
    cases = [args.root/name for name in args.cases] if args.cases else sorted(args.root.glob("perf_*"))
    configs = [] if args.bounds_only else cache_configs(args.full)
    rows = []
    for case in cases:
        row, trace = trace_case(case)
        row.update(ceilings(row["instructions"], row["mandatory_ram_transactions"], args.latency, args.width, args.bus_model))
        row["dirty_word_bound"] = ceilings(row["instructions"], row["dirty_word_ram_transactions"], args.latency, args.width, args.bus_model)
        row["policies"] = []
        for config in configs:
            measured = simulate_policy(trace, config)
            measured.update(name=config["name"], instructions=row["instructions"])
            measured.update(ceilings(row["instructions"], measured["ram_transactions"], args.latency, args.width, args.bus_model))
            row["policies"].append(measured)
        rows.append(row)
        print(f"{case.name}: N={row['instructions']} code={row['initial_code_words']} "
              f"data_initial={row['read_before_written_words']} dirty={row['written_words']} "
              f"changed={row['final_changed_words']} tx_min={row['mandatory_ram_transactions']} "
              f"IPC_upper={row['current_harness_ipc_upper']:.6f}", flush=True)
    output = dict(latency=args.latency, max_retire_width=args.width, bus_model=args.bus_model,
        assumptions=["32-bit RAM, cold reset, every read/write has a response",
            "pipelined mode: initiation interval 1 with enough outstanding capacity to cover the latency",
            "serialized mode: historical one-outstanding harness; no accepting a request in the response cycle",
            "absolute bound permits unlimited storage, shared I/D reads, byte-write merging, and all computation overlapped",
            "final-changed-word bound permits redundant-store elimination; dirty-word bound requires one final write per touched word",
            "policy traffic uses architectural access order; no wrong-path fetches, speculative cache traffic or execution timing",
            "sector caches hold per-byte valid information and write only dirty words using byte strobes",
            "policy IPC values are optimistic ceilings, not predicted or measured RTL performance"],
        reference_sha256=digest(ROOT / "scripts/reference.py"), cases=rows, configs=configs,
        absolute=summarize(rows, "current_harness_cycles_lower", "current_harness_ipc_upper"),
        ideal_turnaround=summarize(rows, "optimistic_cycles_lower", "optimistic_ipc_upper"), policies=[])
    for config in configs:
        policy_rows = [next(policy for policy in row["policies"] if policy["name"] == config["name"]) for row in rows]
        output["policies"].append(dict(name=config["name"], ram_transactions=sum(row["ram_transactions"] for row in policy_rows),
            **summarize(policy_rows, "current_harness_cycles_lower", "current_harness_ipc_upper")))
    output["policies"].sort(key=lambda row: (row["aggregate_ipc_upper"], -row["ram_transactions"]), reverse=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print("Absolute current-harness upper bounds:", json.dumps(output["absolute"], sort_keys=True))
    for policy in output["policies"][:8]:
        print("Policy:", json.dumps(policy, sort_keys=True))
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
