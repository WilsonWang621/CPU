"""Timing-contract tests for the design model, not architectural CPU tests."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model import Cache, Config, Instruction, Memory, simulate


class Contracts(unittest.TestCase):
    def test_unified_memory_latency_bandwidth_and_credits(self):
        cfg = Config(memory_credits=2)
        memory, events = Memory(cfg), []
        for i in range(3):
            memory.enqueue(lambda now, i=i: events.append((i, now)))
        for cycle in range(42):
            memory.tick(cycle)
        self.assertEqual(events, [(0, 20), (1, 21), (2, 40)])
        self.assertTrue(memory.idle())
        self.assertEqual(memory.peak, 2)

    def test_critical_word_fill_store_order(self):
        cfg = Config()
        memory = Memory(cfg)
        cache = Cache(2048, 2, 4, memory, cfg, "data")
        self.assertFalse(cache.request(12, 0))
        for cycle in range(21):
            memory.tick(cycle)
        self.assertTrue(cache.request(12, 20))
        self.assertFalse(cache.store(12, 4, 20))
        for cycle in range(21, 29):
            memory.tick(cycle)
        self.assertTrue(cache.store(12, 4, 28))
        self.assertEqual(memory.requests, 8)
        self.assertEqual(cache.active, 0)

    def test_dependency_chain_cannot_execute_in_same_cycle(self):
        chain = [Instruction((i % 8)*4, 0x13, 1, (i-1,) if i else (), "alu", 0, 0, (i+1) % 8*4)
                 for i in range(100)]
        independent = [Instruction((i % 8)*4, 0x13, 1, (), "alu", 0, 0, (i+1) % 8*4) for i in range(100)]
        config = Config(icache_bytes=1024)
        dependent = simulate(chain, config)
        separate = simulate(independent, config)
        self.assertGreater(dependent["cycles"], separate["cycles"])
        self.assertGreaterEqual(dependent["cycles"], 100)


if __name__ == "__main__":
    unittest.main()
