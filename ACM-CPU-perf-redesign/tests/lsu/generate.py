#!/usr/bin/env python3
"""Generate directed LSU/recovery programs without a RISC-V assembler."""
import argparse
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("system_generator", ROOT / "tests/system/generate.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
i, s, b, j, r = helpers.i, helpers.s, helpers.b, helpers.j, helpers.r


class Program(helpers.Program):
    def __init__(self):
        super().__init__()
        self.labels = {}
        self.fixups = []

    def label(self, name):
        assert name not in self.labels
        self.labels[name] = self.pc

    def branch(self, funct3, rs1, rs2, label):
        self.fixups.append((self.pc, lambda offset: b(funct3, rs1, rs2, offset), label))
        self.emit(0)

    def jump(self, label):
        self.fixups.append((self.pc, lambda offset: j(0, offset), label))
        self.emit(0)

    def align(self, alignment=32):
        while self.pc % alignment:
            self.emit(i(0x13, 0, 0, 0, 0))

    def seed(self, address, word):
        self.memory[address:address+4] = word.to_bytes(4, "little")

    def save(self, root, name, **kwargs):
        for pc, encode, label in self.fixups:
            word = encode(self.labels[label] - pc)
            self.memory[pc:pc+4] = word.to_bytes(4, "little")
            self.listing[pc//4] = f"{pc:08x}: {word:08x} # -> {label}"
        super().save(root, name, **kwargs)


def dependency_chain(program, register, additions):
    """Real dependent arithmetic, restoring the original value at its end."""
    for _ in range(additions):
        program.emit(i(0x13, 0, register, register, 1))
    program.emit(i(0x13, 0, register, register, -additions))


def unknown_store(root, unknown_data=False):
    p = Program()
    p.li(30, 0x10000)
    p.li(29, 0x18000)
    p.li(2, 3 if unknown_data else 0x8000)
    for n in range(20):
        offset = 4*(n % 8)
        p.seed(0x10000+offset, 0x11223300+n)
        p.li(1, (0x10000+offset)*0x8000 if not unknown_data else 0x76543210+n*21)
        p.li(3, 0xaabb0000+n)
        p.emit(i(0x03, 2, 9, 30, offset))  # Warm the data line before the hazard.
        p.align()
        # All four instructions occupy one already-filled I-cache line. The
        # younger load is ready while the older store waits on a full-width, uncached DIVU.
        p.emit(r(5, 10, 1, 2, 1))
        p.emit(s(2, 30 if unknown_data else 10, 10 if unknown_data else 3,
                 offset if unknown_data else 0))
        p.emit(i(0x03, 2, 5, 30, offset))
        p.emit(s(2, 29, 5, n*4))
    p.exit(5)
    p.save(root, "unknown_store_data" if unknown_data else "unknown_store_address")


def partial_stores(root):
    p = Program()
    p.li(29, 0x18000)
    p.li(1, 0x80000000)
    p.li(2, 7)
    # Each group starts at a distinct cold line. DIVU delays retirement while
    # narrow stores become known and the younger partial-forwarded load issues.
    # The final byte writer wins; untouched bytes must come from the fill.
    patterns = [
        [(0, 1), (1, 0), (0, 1)],
        [(1, 2), (0, 3), (0, 2)],
        [(0, 0), (0, 2), (0, 0)],
        [(0, 1), (0, 2), (0, 3)],
        [(1, 0), (1, 2), (0, 1)],
        [(0, 3), (0, 2), (1, 0)],
    ]
    for n in range(36):
        base = 0x10000+n*64
        p.seed(base, 0x80ef1172 ^ (n*0x010203))
        p.li(30, base)
        for reg in range(3, 6):
            p.li(reg, (0x81abfc10+reg*0x10203+n*0x987) & 0xffffffff)
        p.emit(i(0x13, 0, 1, 1, 7))  # Distinct full-width operands for every group.
        p.align()
        p.emit(r(5, 20, 1, 2, 1))
        for reg, (size, offset) in zip(range(3, 6), patterns[n % len(patterns)]):
            p.emit(s(size, 30, reg, offset))
        p.emit(i(0x03, 2, 6, 30, 0))
        p.emit(s(2, 29, 6, n*20))
        for index, (funct3, offset) in enumerate([(0, 3), (4, 3), (1, 2), (5, 2)]):
            p.emit(i(0x03, funct3, 7, 30, offset))
            p.emit(s(2, 29, 7, n*20+(index+1)*4))
    p.exit(6)
    p.save(root, "partial_overlapping_stores")


def cancellation(root, late_error=False, nested_delay=None, preaccept=False):
    p = Program()
    p.li(29, 0x18000)
    p.li(28, 0x10000)  # Warm-up load is legitimate; second pass uses a cold line.
    p.li(27, 0x10000)  # Correct-path line, warmed on the first pass.
    p.li(1, 0x80000000)
    p.li(2, 7)
    p.li(24, 0)       # Warm-up mode.
    p.li(25, 0x80000000 // 7)
    p.seed(0x10000, 0x13579bdf)
    for offset in range(0, 32, 4):
        p.seed(0x20000+offset, 0xfedcba98 ^ offset)
    # Execute the whole region once with both conditional branches not taken.
    # That warms all instruction lines, including the younger branch. On pass
    # two, the older branch and younger branch both change to taken while the
    # load is redirected to a cold line whose response can arrive much later.
    p.jump("test")
    p.align()
    p.label("test")
    if nested_delay is not None:
        # This chain is older than DIVU but executes slowly while DIVU can
        # issue out of order. The younger branch waits for its last version;
        # many following instructions can enter ROB before it redirects.
        p.emit(i(0x13, 0, 11, 24, 0))
        for _ in range(nested_delay):
            p.emit(i(0x13, 0, 11, 11, 0))
    p.emit(r(5, 10, 1, 2, 1))
    p.branch(1, 10, 25, "correct")
    p.emit(i(0x03, 2, 5, 28, 0))
    if nested_delay is not None:
        p.branch(1, 11, 0, "younger_target")
    for n in range(32):
        p.emit(i(0x13, 0, 6+(n % 12), 0, 0x400+n))
    p.label("younger_target")
    for n in range(32):
        p.emit(i(0x13, 0, 6+(n % 12), 0, 0x600+n))
    p.jump("correct")
    p.align()
    p.label("correct")
    p.emit(i(0x13, 0, 5, 0, 0x123))
    for n in range(96):
        # Repeated WAWs exercise physical-register freeing/reallocation while
        # the canceled load still owns its original tag and ROB generation.
        p.emit(i(0x13, 0, 5, 5, 1))
        if n % 16 == 0:
            p.emit(s(2, 29, 5, n//4))
    p.emit(i(0x03, 2, 6, 27, 0))
    p.emit(r(4, 7, 5, 6))
    p.emit(s(2, 29, 7, 64))
    p.branch(1, 24, 0, "finish")
    p.emit(i(0x13, 0, 24, 0, 1))
    p.emit(i(0x13, 0, 25, 0, 0))
    p.li(28, 0x20000)
    p.emit(i(0x13, 0, 1, 1, 7))  # Prevent a completed-pair hit on the cold-path pass.
    if preaccept:
        # The committed store owns this cold line when the speculative load is
        # offered. The cache stalls the same-line request across the redirect.
        p.emit(s(0, 28, 1, 0))
    p.jump("test")
    p.label("finish")
    p.exit(7)
    name = "canceled_load_reuse"
    if nested_delay is not None:
        name = f"nested_redirect_load_{nested_delay:02d}"
    elif late_error:
        name += "_late_error"
    elif preaccept:
        name += "_preaccept"
    args = ["--error-address", "0x20000", "--error-read"] if late_error else None
    p.save(root, name, sim_args=args)


def nested_with_load(root, old_delay=2, young_delay=2):
    p = Program()
    p.li(30, 0x18000)
    p.li(28, 0x20000)
    p.li(1, 0x80000000)
    p.li(2, 3)
    p.li(3, 17)
    p.li(6, 1)
    p.li(20, 4)
    p.label("loop")
    for _ in range(old_delay):
        p.emit(i(0x13, 0, 1, 1, 0))
    p.emit(r(5, 5, 1, 2, 1))
    p.branch(0, 5, 5, "outer")
    p.emit(i(0x03, 2, 7, 28, 0))
    for _ in range(young_delay):
        p.emit(i(0x13, 0, 6, 6, 1))
    p.branch(0, 6, 6, "inner")
    for n in range(18):
        p.emit(i(0x13, 0, 3, 3, n+1))
    p.label("inner")
    for _ in range(8):
        p.emit(i(0x13, 0, 3, 3, 1))
    p.label("outer")
    p.emit(s(2, 30, 3, 0))
    p.emit(i(0x13, 0, 1, 1, 3))  # New full-width division pair next iteration.
    p.emit(i(0x13, 0, 20, 20, -1))
    p.branch(1, 20, 0, "loop")
    p.exit(3)
    p.save(root, f"recovery_with_load_{old_delay}_{young_delay}",
           sim_args=["--error-address", "0x20000", "--error-read"])


def replay_old_map(root):
    """An unknown older address must replay a Load and its dependent WAW chain."""
    p = Program()
    p.li(30, 0x10000)
    p.li(29, 0x18000)
    p.li(1, 0x80000000)
    p.li(2, 0x8000)
    p.li(3, 0x76543210)
    p.li(5, 7)
    p.seed(0x10000, 0x01020304)
    # Complete a true dependency on the warm-up load before entering the hazard.
    p.emit(i(0x03, 2, 9, 30, 0))
    p.emit(r(4, 9, 9, 9))
    p.emit(r(0, 1, 1, 9))
    p.align()
    p.emit(r(5, 10, 1, 2, 1))
    p.emit(i(0x13, 0, 10, 10, 4))
    p.emit(s(2, 10, 3, -4))
    p.emit(i(0x03, 2, 5, 30, 0))
    p.emit(i(0x13, 0, 5, 5, 1))
    p.emit(i(0x13, 0, 6, 5, 2))
    p.emit(s(2, 29, 6, 0))
    p.emit(i(0x13, 0, 5, 5, 4))
    p.emit(s(2, 29, 5, 4))
    p.exit(5)
    p.save(root, "speculative_load_replay_old_map")
    path=root/"speculative_load_replay_old_map"/"metrics.json"
    import json
    metadata=json.loads(path.read_text())
    metadata["required_metrics"]={"load_replay_count":1}
    path.write_text(json.dumps(metadata,indent=2)+"\n")


def cancellation_pressure(root):
    """Fill all D-MSHRs before the branch cancels a presented younger miss."""
    p=Program()
    p.li(29,0x18000)
    p.li(28,0x10000)
    p.li(1,0x80000000)
    p.li(2,7)
    p.li(24,0)
    p.li(25,0x80000000//7)
    for n in range(16):
        p.seed(0x10000+n*64,0x12340000+n)
        p.seed(0x20000+n*64,0x56780000+n)
    p.jump("test")
    p.align()
    p.label("test")
    p.emit(r(5,10,1,2,1))
    dependency_chain(p,10,8)
    p.branch(1,10,25,"correct")
    for n in range(16):
        p.emit(i(0x03,2,5+(n%12),28,n*64))
    p.label("correct")
    p.emit(i(0x13,0,5,0,0x123))
    for n in range(160):
        p.emit(i(0x13,0,5,5,1))
        if n%16==0:p.emit(s(2,29,5,n//4))
    p.branch(1,24,0,"finish")
    p.emit(i(0x13,0,24,0,1))
    p.emit(i(0x13,0,25,0,0))
    p.li(28,0x20000)
    p.emit(i(0x13,0,1,1,7))
    p.jump("test")
    p.label("finish")
    p.exit(5)
    p.save(root,"canceled_load_pressure",sim_args=["--error-address","0x20200","--error-read"])


def store_shadow(root, known_address, partial=False, split=False):
    p=Program()
    p.li(30,0x10000)
    p.li(29,0x18000)
    p.li(1,0x80000000)
    p.li(2,0x8000)
    p.li(3,0xaabbccdd)
    p.li(4,0x11223344)
    p.li(20,2)
    p.seed(0x10000,0x55443322)
    p.emit(i(0x03,2,9,30,0))
    p.align()
    p.label("loop")
    p.emit(r(5,10,1,2,1))
    dependency_chain(p,10,12)
    p.emit(s(2,30 if known_address else 10,10 if known_address else 4,0))
    if split:
        p.emit(s(1,30,3,0))
        p.emit(s(1,30,4,2))
    else:p.emit(s((1 if known_address else 0) if partial else 2,30,3,0))
    p.emit(i(0x03,2,5,30,0))
    p.emit(s(2,29,5,0))
    p.emit(i(0x13,0,1,1,1))  # Quotient remains 0x10000; the raw operand pair changes.
    p.emit(i(0x13,0,20,20,-1))
    p.branch(1,20,0,"loop")
    p.exit(5)
    name=("known_data_wait" if known_address else "unknown_address")+("_split_shadow" if split else "_partial_shadow" if partial else "_full_shadow")
    p.save(root,name)
    import json
    path=root/name/"metrics.json"
    metadata=json.loads(path.read_text())
    if not known_address and partial:metadata["required_metrics"]={"load_replay_count":1}
    else:metadata["maximum_metrics"]={"load_replay_count":0}
    path.write_text(json.dumps(metadata,indent=2)+"\n")


def wait_owner_reuse(root):
    p=Program()
    p.li(30,0x10000)
    p.li(29,0x18000)
    p.li(1,0x80000000)
    p.li(2,7)
    p.li(20,2)
    for offset in (0,32,64):p.emit(i(0x03,2,9,30,offset))
    p.align()
    p.label("loop")
    p.emit(r(5,10,1,2,1))
    dependency_chain(p,10,32)
    for n in range(20):p.emit(s(2,30,10,n*4))
    p.emit(i(0x03,2,5,30,0))
    for n in range(96):p.emit(i(0x13,0,6+(n%10),0,n+1))
    p.emit(s(2,29,5,0))
    p.emit(i(0x13,0,1,1,1))
    p.emit(i(0x13,0,20,20,-1))
    p.branch(1,20,0,"loop")
    p.exit(5)
    p.save(root,"known_alias_wait_owner_reuse")


def generate(root):
    for known in (False,True):
        for partial in (False,True):store_shadow(root,known,partial)
        store_shadow(root,known,split=True)
    wait_owner_reuse(root)
    replay_old_map(root)
    cancellation_pressure(root)
    unknown_store(root)
    unknown_store(root, unknown_data=True)
    partial_stores(root)
    cancellation(root)
    cancellation(root, late_error=True)
    cancellation(root, preaccept=True)
    for delay in (16, 20, 21):
        cancellation(root, late_error=True, nested_delay=delay)
    nested_with_load(root, old_delay=3, young_delay=2)


def case_names():
    return ["unknown_address_full_shadow", "unknown_address_partial_shadow", "unknown_address_split_shadow",
            "known_data_wait_full_shadow", "known_data_wait_partial_shadow", "known_data_wait_split_shadow", "known_alias_wait_owner_reuse",
            "speculative_load_replay_old_map", "canceled_load_pressure", "unknown_store_address", "unknown_store_data", "partial_overlapping_stores",
            "canceled_load_reuse", "canceled_load_reuse_late_error", "canceled_load_reuse_preaccept",
            "nested_redirect_load_16", "nested_redirect_load_20", "nested_redirect_load_21",
            "recovery_with_load_3_2"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/lsu_tests")
    args = parser.parse_args()
    generate(args.output)
    print(f"Generated {len(case_names())} LSU cases in {args.output}")


if __name__ == "__main__":
    main()
