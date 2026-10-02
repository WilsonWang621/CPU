#!/usr/bin/env python3
"""Measure architectural dependencies, branches and cache demand of benchmarks.

This reference-only analysis is independent of speculative RTL scheduling. Cache
counts use architectural-order LRU; predictor counts use architectural-order
training. Neither is a cycle estimate or a substitute for RTL measurements.
"""
import argparse
import collections
import json
from pathlib import Path
from reference import EXIT_ADDRESS, MASK32, load_image, run, signed

ROOT = Path(__file__).resolve().parents[1]


class Cache:
    def __init__(self, capacity, ways, line_bytes=32):
        self.ways, self.line_bytes = ways, line_bytes
        self.sets = [collections.OrderedDict() for _ in range(capacity // ways // line_bytes)]
        self.misses, self.dirty_evictions = 0, 0

    def access(self, address, write=False):
        line = address // self.line_bytes
        ways = self.sets[line % len(self.sets)]
        if line in ways:
            dirty = ways.pop(line)
            ways[line] = dirty or write
        else:
            self.misses += 1
            if len(ways) == self.ways:
                _, dirty = ways.popitem(last=False)
                self.dirty_evictions += bool(dirty)
            ways[line] = write

    def counts(self):
        dirty_remaining = sum(sum(ways.values()) for ways in self.sets)
        return {"misses": self.misses, "dirty_evictions": self.dirty_evictions,
                "dirty_lines_at_exit": dirty_remaining,
                "external_word_transactions": (self.misses + self.dirty_evictions + dirty_remaining) * (self.line_bytes // 4)}


def analyze(case):
    regs = [0] * 32
    writer = [None] * 32
    reg_depths = {latency: [0] * 32 for latency in (1, 2, 3)}
    byte_writer = {}
    memory_depths = {latency: {} for latency in (1, 2, 3)}
    longest_depth = {latency: 0 for latency in (1, 2, 3)}
    counts, dependency_distances, store_load_distances = [collections.Counter() for _ in range(3)]
    dependency_classes = collections.Counter()
    branches = collections.defaultdict(lambda: {"executions": 0, "taken": 0, "bimodal_misses": 0})
    bht = collections.defaultdict(lambda: 1)
    indexed_bht = {size: [1] * size for size in (512, 4096)}
    indexed_misses = collections.Counter()
    gshare_tables = {bits: [1] * 4096 for bits in (4, 8, 12)}
    gshare_histories = {bits: 0 for bits in gshare_tables}
    gshare_misses = collections.Counter()
    tournament_states = {bits: collections.defaultdict(int) for bits in gshare_tables}
    tournament_misses = collections.Counter()
    local_histories = collections.defaultdict(int)
    local_counters = collections.defaultdict(lambda: [1] * 16)
    local_misses = 0
    pcs, data_lines = set(), set()
    target_counts = collections.defaultdict(collections.Counter)
    caches = {size: Cache(size, 4 if size >= 16384 else 2) for size in (4096, 16384, 32768)}
    icache = Cache(4096, 2)
    previous = None
    position = 0

    def observe(row):
        nonlocal previous, position, local_misses
        pc, inst, rd, value, store, address, _, _ = row
        if previous:
            prev_pc, prev_inst = previous
            opcode = prev_inst & 127
            if opcode == 0x63:
                taken = pc != ((prev_pc + 4) & MASK32)
                item = branches[f"0x{prev_pc:08x}"]
                item["executions"] += 1
                item["taken"] += taken
                base_prediction = bht[prev_pc] >= 2
                item["bimodal_misses"] += base_prediction != taken
                bht[prev_pc] = min(3, bht[prev_pc]+1) if taken else max(0, bht[prev_pc]-1)
                for size, table in indexed_bht.items():
                    index = (prev_pc >> 2) % size
                    indexed_misses[size] += (table[index] >= 2) != taken
                    table[index] = min(3, table[index]+1) if taken else max(0, table[index]-1)
                for bits, table in gshare_tables.items():
                    index = ((prev_pc >> 2) ^ gshare_histories[bits]) & 4095
                    global_prediction = table[index] >= 2
                    gshare_misses[bits] += global_prediction != taken
                    chooser = tournament_states[bits][prev_pc]
                    tournament_misses[bits] += (global_prediction if chooser >= 2 else base_prediction) != taken
                    if global_prediction != base_prediction:
                        tournament_states[bits][prev_pc] = min(3, chooser+1) if global_prediction == taken else max(0, chooser-1)
                    table[index] = min(3, table[index]+1) if taken else max(0, table[index]-1)
                    gshare_histories[bits] = ((gshare_histories[bits] << 1) | taken) & ((1 << bits)-1)
                history = local_histories[prev_pc]
                table = local_counters[prev_pc]
                local_misses += (table[history] >= 2) != taken
                table[history] = min(3, table[history]+1) if taken else max(0, table[history]-1)
                local_histories[prev_pc] = ((history << 1) | taken) & 15
            elif opcode == 0x67:
                target_counts[f"0x{prev_pc:08x}"][f"0x{pc:08x}"] += 1
        opcode = inst & 127
        funct3 = (inst >> 12) & 7
        rs1, rs2 = (inst >> 15) & 31, (inst >> 20) & 31
        sources = []
        if opcode in (0x03, 0x23, 0x13, 0x33, 0x63, 0x67):
            sources.append(rs1)
        if opcode in (0x23, 0x33, 0x63):
            sources.append(rs2)
        used = {reg for reg in sources if reg}
        for reg in used:
            if writer[reg] is not None:
                distance = position - writer[reg][0]
                dependency_distances[distance] += 1
                if distance <= 4:
                    dependency_classes["load_to_consumer_within4" if writer[reg][1] == 0x03 else "other_dependency_within4"] += 1
        pcs.add(pc)
        icache.access(pc)
        counts["instructions"] += 1
        if opcode == 0x03:
            kind = "load"
            address = (regs[rs1] + signed(inst >> 20, 12)) & MASK32
            width = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[funct3]
        elif opcode == 0x23:
            kind = "exit" if address == EXIT_ADDRESS else "store"
            width = {0: 1, 1: 2, 2: 4}[funct3]
        elif opcode == 0x63:
            kind = "branch"
        elif opcode == 0x67:
            kind = "return" if rs1 in (1, 5) and ((inst >> 7) & 31) == 0 else "jalr"
        elif opcode == 0x6f:
            kind = "jal"
        elif opcode == 0x33 and (inst >> 25) == 1:
            kind = "multiply_divide"
        else:
            kind = "alu"
        counts[kind] += 1
        if kind in ("load", "store"):
            data_lines.add(address // 32)
            for cache in caches.values():
                cache.access(address, kind == "store")
        if kind == "load":
            older = [byte_writer[a] for a in range(address, address+width) if a in byte_writer]
            if older:
                store_load_distances[position-max(older)] += 1
        for latency, depths in reg_depths.items():
            ready = max((depths[reg] for reg in used), default=0)
            if kind == "load":
                ready = max(ready, max((memory_depths[latency].get(a, 0) for a in range(address, address+width)), default=0))
            finish = ready + (latency if kind == "load" else 1)
            longest_depth[latency] = max(longest_depth[latency], finish)
            if rd:
                depths[rd] = finish
            if kind == "store":
                for a in range(address, address+width):
                    memory_depths[latency][a] = finish
        if kind == "store":
            for a in range(address, address+width):
                byte_writer[a] = position
        if rd:
            regs[rd] = value
            writer[rd] = position, opcode
        previous = pc, inst
        position += 1

    result, retired, final_memory = run(load_image(case / "program.data"), on_retire=observe)
    if result != int((case / "expected.txt").read_text(), 0) or retired != json.loads((case / "metrics.json").read_text())["dynamic_instructions"]:
        raise RuntimeError(f"{case.name}: reference exit/instruction mismatch")
    if final_memory != load_image(case / "expected.memory"):
        raise RuntimeError(f"{case.name}: reference final memory mismatch")
    unaliased_misses = sum(b["bimodal_misses"] for b in branches.values())
    return {
        "case": case.name, "exit_value": result, "counts": dict(counts),
        "unique_instruction_words": len(pcs), "unique_data_lines32": len(data_lines),
        "register_dependency_distances": dict(sorted(dependency_distances.items())),
        "close_dependencies": dict(dependency_classes),
        "store_to_load_distance_le64": sum(count for distance, count in store_load_distances.items() if distance <= 64),
        "store_to_load_distance_le8": sum(count for distance, count in store_load_distances.items() if distance <= 8),
        "conditional_bimodal_misses": unaliased_misses,
        "conditional_bimodal_mpki": unaliased_misses * 1000 / retired,
        "indexed_bimodal_misses": dict(indexed_misses),
        "gshare4096_misses_by_history_bits": dict(gshare_misses),
        "tournament4096_bimodal_biased_misses": dict(tournament_misses),
        "unaliased_local4_history_misses": local_misses,
        "hottest_branches": sorted(({"pc": pc, **values} for pc, values in branches.items()), key=lambda b: b["executions"], reverse=True)[:12],
        "indirect_target_counts": {pc: dict(targets) for pc, targets in target_counts.items()},
        "optimistic_dependency_path": {latency: {"cycles": longest_depth[latency], "ipc_upper_bound": retired / longest_depth[latency]} for latency in longest_depth},
        "architectural_order_icache4096_2way": icache.counts(),
        "architectural_order_dcache": {size: cache.counts() for size, cache in caches.items()},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/benchmark-analysis.json")
    args = parser.parse_args()
    data = [analyze(case) for case in sorted((ROOT / "RISC-V-CPU-2026-Testcases").glob("perf_*"))]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    for item in data:
        counts = item["counts"]
        print(f"{item['case']}: instructions={counts['instructions']} loads={counts.get('load', 0)} stores={counts.get('store', 0)} "
              f"bimodalMPKI={item['conditional_bimodal_mpki']:.2f} closeStoreLoads={item['store_to_load_distance_le8']}")
    print(args.output)


if __name__ == "__main__":
    main()
