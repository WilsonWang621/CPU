#include "Visa_top.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <optional>
#include <vector>

// Independent architectural operations, matching the public cpu_pkg enum.
enum Op { ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND, LUI, AUIPC,
          JAL, JALR, BEQ, BNE, BLT, BGE, BLTU, BGEU, LOAD, STORE,
          MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU };
static Visa_top dut;
static std::mt19937 rng(0x20260921);
static uint64_t checks = 0;
#ifndef TEST_DIV_STEP_BITS
#define TEST_DIV_STEP_BITS 4
#endif
static constexpr unsigned divide_step_bits=TEST_DIV_STEP_BITS;

static std::string hex(uint32_t x) {
    std::ostringstream s;
    s << "0x" << std::hex << std::setw(8) << std::setfill('0') << x;
    return s.str();
}
static void check(bool ok, const std::string& what) {
    ++checks;
    if (!ok) throw std::runtime_error(what);
}
static void check_equal(uint32_t got, uint32_t want, const std::string& what) {
    check(got == want, what + ": got " + hex(got) + ", expected " + hex(want));
}
static void tick() {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
    dut.clk = 0; dut.eval();
}
static uint32_t sext(uint32_t x, unsigned n) {
    const uint32_t sign = uint32_t(1) << (n - 1);
    return (x ^ sign) - sign;
}
static int64_t signed32(uint32_t x) {
    return (x & 0x80000000u) ? int64_t(x) - (int64_t(1) << 32) : x;
}
static uint32_t arithmetic_shift(uint32_t x, unsigned amount) {
    if (!amount) return x;
    return (x >> amount) | ((x >> 31) ? (~uint32_t(0) << (32 - amount)) : 0);
}

struct Dec {
    bool legal = false, rs1 = false, rs2 = false, write = false, immediate = false;
    Op op = ADD;
    uint32_t imm = 0;
    unsigned size = 0;
    bool sign = false;
};

static Dec decode_ref(uint32_t word) {
    const unsigned opcode = word & 127, f3 = (word >> 12) & 7, f7 = word >> 25;
    const std::array<Op, 8> base = {ADD, SLL, SLT, SLTU, XOR, SRL, OR, AND};
    const std::array<Op, 8> m = {MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU};
    Dec d;
    if (opcode == 0x37 || opcode == 0x17) {
        d.legal = d.write = true;
        d.op = opcode == 0x37 ? LUI : AUIPC;
        d.imm = word & 0xfffff000u;
    } else if (opcode == 0x6f) {
        d.legal = d.write = true;
        d.op = JAL;
        d.imm = sext(((word >> 31) << 20) | (word & 0xff000) |
                     (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1), 21);
    } else if (opcode == 0x67 && f3 == 0) {
        d.legal = d.write = d.rs1 = d.immediate = true;
        d.op = JALR; d.imm = sext(word >> 20, 12);
    } else if (opcode == 0x63 && f3 != 2 && f3 != 3) {
        const std::array<Op, 8> branches = {BEQ, BNE, ADD, ADD, BLT, BGE, BLTU, BGEU};
        d.legal = d.rs1 = d.rs2 = true;
        d.op = branches[f3];
        d.imm = sext(((word >> 31) << 12) | (((word >> 7) & 1) << 11) |
                     (((word >> 25) & 63) << 5) | (((word >> 8) & 15) << 1), 13);
    } else if (opcode == 0x03 && (f3 <= 2 || f3 == 4 || f3 == 5)) {
        d.legal = d.rs1 = d.write = d.immediate = true;
        d.op = LOAD; d.imm = sext(word >> 20, 12); d.size = f3 & 3; d.sign = f3 < 4;
    } else if (opcode == 0x23 && f3 <= 2) {
        d.legal = d.rs1 = d.rs2 = d.immediate = true;
        d.op = STORE; d.imm = sext(((word >> 25) << 5) | ((word >> 7) & 31), 12);
        d.size = f3;
    } else if (opcode == 0x13) {
        d.legal = f3 == 1 ? f7 == 0 : f3 == 5 ? (f7 == 0 || f7 == 32) : true;
        d.rs1 = d.write = d.immediate = true;
        d.op = (f3 == 5 && f7 == 32) ? SRA : base[f3];
        d.imm = (f3 == 1 || f3 == 5) ? (word >> 20) & 31 : sext(word >> 20, 12);
    } else if (opcode == 0x33) {
        d.legal = f7 == 0 || f7 == 1 || (f7 == 32 && (f3 == 0 || f3 == 5));
        d.rs1 = d.rs2 = d.write = true;
        d.op = f7 == 1 ? m[f3] : f7 == 32 ? (f3 == 0 ? SUB : SRA) : base[f3];
    }
    d.write = d.write && ((word >> 7) & 31) != 0;
    return d;
}

static void test_decode_word(uint32_t word) {
    dut.inst = word; dut.eval();
    Dec d = decode_ref(word);
    std::string context = "decode " + hex(word);
    check_equal(dut.dec_illegal, !d.legal, context + " legality");
    check_equal(dut.dec_rs1, (word >> 15) & 31, context + " rs1");
    check_equal(dut.dec_rs2, (word >> 20) & 31, context + " rs2");
    check_equal(dut.dec_rd, (word >> 7) & 31, context + " rd");
    if (!d.legal) {
        check(!dut.dec_uses_rs1 && !dut.dec_uses_rs2 && !dut.dec_writes_rd &&
              !dut.dec_use_imm, context + " illegal side effects");
        return;
    }
    check_equal(dut.dec_op, d.op, context + " operation");
    check_equal(dut.dec_imm, d.imm, context + " immediate");
    check_equal(dut.dec_uses_rs1, d.rs1, context + " source 1 enable");
    check_equal(dut.dec_uses_rs2, d.rs2, context + " source 2 enable");
    check_equal(dut.dec_writes_rd, d.write, context + " destination enable");
    check_equal(dut.dec_use_imm, d.immediate, context + " immediate enable");
    check_equal(dut.dec_mem_size, d.size, context + " memory width");
    check_equal(dut.dec_load_signed, d.sign, context + " load sign");
}

static void test_decoder() {
    // All opcode/funct3/funct7 combinations, with randomized register fields.
    for (unsigned opcode = 0; opcode < 128; ++opcode)
        for (unsigned f3 = 0; f3 < 8; ++f3)
            for (unsigned f7 = 0; f7 < 128; ++f7)
                test_decode_word((rng() & 0x01ff8f80u) | opcode | (f3 << 12) | (f7 << 25));
    for (unsigned i = 0; i < 50000; ++i) test_decode_word(rng());
    // Ensure x0 writes and immediate encodings cover exact sign boundaries.
    for (unsigned rd : {0u, 1u, 31u})
        for (unsigned imm : {0u, 1u, 0x7ffu, 0x800u, 0xfffu})
            for (unsigned f3 = 0; f3 < 8; ++f3)
                test_decode_word((imm << 20) | (31u << 15) | (f3 << 12) | (rd << 7) | 0x13);
}

static void test_alu_branch() {
    for (unsigned i = 0; i < 20000; ++i) {
        uint32_t a = rng(), b = rng(), pc = rng(), imm = rng();
        if (i % 4 == 0) b = a;
        if (i < 64) { a = i < 32 ? 0x80000000 : 0xffffffff; b = i; }
        dut.a = a; dut.b = b; dut.pc = pc; dut.imm = imm;
        std::array<uint32_t, 12> expected = {
            a + b, a - b, a << (b & 31), uint32_t(signed32(a) < signed32(b)),
            uint32_t(a < b), a ^ b, a >> (b & 31), arithmetic_shift(a, b & 31),
            a | b, a & b, imm, pc + imm
        };
        for (unsigned op = ADD; op <= AUIPC; ++op) {
            dut.op = op; dut.eval();
            check_equal(dut.alu_result, expected[op], "ALU op=" + std::to_string(op));
        }
        std::array<bool, 8> take = {true, true, a == b, a != b,
            signed32(a) < signed32(b), signed32(a) >= signed32(b), a < b, a >= b};
        for (unsigned op = JAL; op <= BGEU; ++op) {
            dut.op = op; dut.eval();
            const bool taken = take[op - JAL];
            const uint32_t target = op == JALR ? (a + imm) & ~1u : pc + imm;
            check_equal(dut.branch_result, pc + 4, "branch link");
            check_equal(dut.taken, taken, "branch direction");
            check_equal(dut.next_pc, taken ? target : pc + 4, "branch target");
            check_equal(dut.misaligned, taken && (target & 3) != 0, "branch alignment");
        }
    }
}

static uint32_t m_ref(Op op, uint32_t a, uint32_t b) {
    switch (op) {
        case MUL: return uint64_t(a) * b;
        case MULH: return uint64_t(signed32(a) * signed32(b)) >> 32;
        case MULHSU: return uint64_t(signed32(a) * int64_t(b)) >> 32;
        case MULHU: return (uint64_t(a) * b) >> 32;
        case DIV: return b ? uint32_t(signed32(a) / signed32(b)) : ~0u;
        case DIVU: return b ? a / b : ~0u;
        case REM: return b ? uint32_t(signed32(a) % signed32(b)) : a;
        case REMU: return b ? a % b : a;
        default: throw std::runtime_error("invalid reference M operation");
    }
}

static uint8_t next_tag=0, active_tag=0;
static void clear_kill_mask() {
    for(unsigned word=0;word<8;++word) dut.kill_mask[word]=0;
}
static void kill_tag(unsigned tag) {dut.kill_mask[tag/32] |= uint32_t(1) << (tag%32);}

static void start_m(Op op, uint32_t a, uint32_t b) {
    active_tag=next_tag++;
    dut.req_valid = 1; dut.req_op = op; dut.req_a = a; dut.req_b = b;dut.req_tag=active_tag;
    dut.rsp_ready = 0; dut.eval();
    check(dut.req_ready, "MDU available before request");
    tick();
    dut.req_valid=0;
    dut.req_op = MUL; dut.req_a = rng(); dut.req_b = rng(); dut.eval();
}

static unsigned test_m(Op op, uint32_t a, uint32_t b, unsigned hold) {
    start_m(op, a, b);
    unsigned cycles = 0;
    while (!dut.rsp_valid && cycles < 20) {tick(); ++cycles;}
    if(op<=MULHU) check_equal(cycles,0,"one-edge multiply response from an empty buffer");
    else check(cycles<=17,"radix divider latency bounded by sixteen iterations plus arbitration");
    const uint32_t expected = m_ref(op, a, b);
    const std::string context = "MDU op=" + std::to_string(op) +
        " a=" + hex(a) + " b=" + hex(b);
    check(dut.rsp_valid, context + " response");
    check_equal(dut.rsp_result, expected, context);
    check_equal(dut.rsp_tag,active_tag,context+" tag");
    for (unsigned n = 0; n < hold; ++n) {
        tick();check(dut.rsp_valid,"MDU retains blocked response");
        check_equal(dut.rsp_result, expected, context + " held result");
        check_equal(dut.rsp_tag,active_tag,context+" held tag");
    }
    dut.rsp_ready = 1; tick();
    check(!dut.rsp_valid && dut.req_ready, "MDU response consumed once");
    return cycles;
}

static void test_kill() {
    // Each phase, including held completion, must be cancelable for every op.
    for (unsigned op = MUL; op <= REMU; ++op)
        for (unsigned phase = 0; phase <= 34; ++phase) {
            start_m(Op(op), 0x87654321, 0x12345);
            for (unsigned n = 0; n < phase; ++n) tick();
            dut.kill = 1; dut.rsp_ready = 1; dut.eval();
            check(!dut.req_ready && !dut.rsp_valid, "kill suppresses handshakes");
            tick();
            dut.kill = 0; dut.req_valid = 0; dut.eval();
            check(dut.req_ready && !dut.rsp_valid, "kill clears occupancy");
            for (unsigned n = 0; n < 35; ++n) {
                tick(); check(!dut.rsp_valid, "no canceled response");
            }
            test_m(MULHSU, 0xffffffff, 0xffffffff, 1);
        }
    // A kill coincident with an otherwise acceptable request cancels that request.
    dut.kill = 1; dut.req_valid = 1; dut.req_op = DIV; dut.req_a = 1; dut.req_b = 0;
    dut.eval(); check(!dut.req_ready && !dut.rsp_valid, "kill on idle"); tick();
    dut.kill = 0; dut.req_valid = 0; dut.eval();
    check(!dut.rsp_valid && dut.req_ready, "kill prevents new request");
    // Reset cancels both active computation and a completed blocked result.
    for (unsigned phase : {0u, 32u}) {
        start_m(DIVU, 0xffffffff, 17);
        for (unsigned n = 0; n < phase; ++n) tick();
        dut.rst = 1; tick(); dut.rst = 0; dut.req_valid = 0; dut.eval();
        check(dut.req_ready && !dut.rsp_valid, "reset clears MDU");
    }
}

static void test_readiness_hints() {
    dut.req_valid=0;dut.req_tag=33;dut.rsp_ready=0;clear_kill_mask();
    dut.req_op=ADD;dut.eval();
    check(dut.mul_ready && dut.div_ready && !dut.req_ready,"idle capacity hints independent of invalid request opcode");
    start_m(DIVU,0xfedcba98,0x12345);
    const bool mul_hint=dut.mul_ready,div_hint=dut.div_ready;
    check(mul_hint && !div_hint,"division occupancy does not block multiply hint");
    for(unsigned op=MUL;op<=REMU;++op) {
        dut.req_op=op;dut.eval();
        check_equal(dut.mul_ready,mul_hint,"multiply capacity does not depend on opcode");
        check_equal(dut.div_ready,div_hint,"divide capacity does not depend on opcode");
        check_equal(dut.req_ready,op<=MULHU ? mul_hint : div_hint,"request readiness selects matching hint");
    }
    dut.req_op=MUL;dut.req_tag=33;kill_tag(33);dut.eval();
    check(dut.mul_ready && !dut.req_ready,"tag cancellation gates request, not structural capacity hint");
    clear_kill_mask();dut.kill=1;dut.eval();
    check(!dut.mul_ready && !dut.div_ready,"global kill suppresses capacity hints");
    tick();dut.kill=0;dut.req_valid=0;dut.req_op=MUL;dut.eval();
    check(dut.mul_ready && dut.div_ready,"capacity returns after kill");
}

static void test_multiply_throughput() {
    std::array<uint32_t,128> expected{};
    dut.rsp_ready=1;dut.req_valid=0;clear_kill_mask();
    unsigned received=0;
    for(unsigned cycle=0;cycle<132;++cycle) {
        dut.req_valid=cycle<128;
        if(cycle<128) {
            Op op=Op(MUL+cycle%4);uint32_t a=rng(),b=rng();
            expected[cycle]=m_ref(op,a,b);
            dut.req_op=op;dut.req_a=a;dut.req_b=b;dut.req_tag=cycle;
        }
        dut.eval();
        if(cycle<128) check(dut.req_ready,"multiply pipeline accepts every cycle");
        if(dut.rsp_valid) {
            check_equal(dut.rsp_tag,received,"multiply pipeline tag order");
            check_equal(dut.rsp_result,expected[received],"multiply pipeline result");
            ++received;
        }
        tick();
    }
    check_equal(received,128,"multiply throughput response count");
    dut.req_valid=0;tick();check(!dut.rsp_valid,"multiply pipeline fully drained");
}

static void test_selective_kill() {
    for(unsigned op=MUL;op<=REMU;++op)
        for(unsigned phase=0;phase<20;++phase) {
            start_m(Op(op),0xfedcba98,0x12345);
            for(unsigned n=0;n<phase;++n) tick();
            kill_tag(active_tag);dut.eval();
            check(!dut.rsp_valid,"selective kill suppresses matching output");
            tick();clear_kill_mask();dut.rsp_ready=1;dut.eval();
            for(unsigned n=0;n<20;++n) {tick();check(!dut.rsp_valid,"selectively killed operation never responds");}
            test_m(MULHU,0xfedcba98,0x87654321,0);
        }
    dut.req_valid=1;dut.req_tag=42;dut.req_op=MUL;dut.req_a=7;dut.req_b=11;
    kill_tag(42);dut.eval();check(!dut.req_ready,"incoming canceled tag is rejected");tick();
    dut.req_valid=0;clear_kill_mask();
    for(unsigned n=0;n<10;++n) {tick();check(!dut.rsp_valid,"rejected tag does not produce result");}
}

static void clear_mdu() {
    dut.req_valid=0;dut.rsp_ready=1;clear_kill_mask();dut.kill=1;tick();
    dut.kill=0;dut.req_op=MUL;dut.eval();
}

static unsigned cold_divide_latency(Op op,uint32_t a,uint32_t b) {
    bool sign=op==DIV || op==REM;
    uint32_t am=sign && (a>>31) ? ~a+1u:a;
    uint32_t bm=sign && (b>>31) ? ~b+1u:b;
    if(!b || (sign && a==0x80000000 && b==0xffffffff) || am<bm || !am || bm==1) return 1;
    unsigned groups=0;
    do {++groups;am>>=divide_step_bits;} while(am);
    return groups+1; // Registered response arbitration after the last radix step.
}

static void test_divide_cache_and_normalization() {
    const std::array<uint32_t,14> values={0,1,2,3,7,15,16,255,256,65536,0x7fffffff,0x80000000,0xfffffffd,0xffffffff};
    uint64_t cold_cycles=0,cached_cycles=0,pairs=0;
    // Cover both sides of every leading-zero group boundary independently of
    // the RTL's group-priority implementation, including signed magnitudes.
    for(unsigned bit=0;bit<32;++bit) for(unsigned below=0;below<2;++below) {
        uint32_t a=(uint32_t(1)<<bit)-below,b=bit<2 ? 2:3;
        clear_mdu();
        check_equal(test_m(DIVU,a,b,0),cold_divide_latency(DIVU,a,b),"unsigned leading-group boundary");
        clear_mdu();
        check_equal(test_m(REM,0u-a,b,0),cold_divide_latency(REM,0u-a,b),"signed leading-group boundary");
    }
    for(bool sign:{false,true}) for(uint32_t a:values) for(uint32_t b:values) {
        clear_mdu();
        Op quotient=sign ? DIV:DIVU,remainder=sign ? REM:REMU;
        const auto cold=test_m(quotient,a,b,3);
        check_equal(cold,cold_divide_latency(quotient,a,b),"normalized cold quotient latency");
        test_m(MULHSU,0x87654321,0xfedcba98,2); // Multiply must not evict a completed division.
        const auto cached=test_m(remainder,a,b,5);
        check_equal(cached,1,"completed quotient yields cached remainder");
        check_equal(test_m(quotient,a,b,1),1,"completed pair yields cached quotient");
        cold_cycles+=cold;cached_cycles+=cached;++pairs;
        // Compute the pair starting from REM too; both halves must be populated.
        clear_mdu();
        check_equal(test_m(remainder,a,b,1),cold_divide_latency(remainder,a,b),"normalized cold remainder latency");
        check_equal(test_m(quotient,a,b,2),1,"completed remainder yields cached quotient");
    }
    check(cold_cycles>cached_cycles,"operand pair reuse has a measured latency benefit");
    const uint32_t a=0xfedcba98,b=0x12345;
    clear_mdu();
    check_equal(test_m(DIVU,a,b,0),32/divide_step_bits+1,"full-width unsigned cold latency");
    check_equal(test_m(REMU,a,b,0),1,"unsigned pair cache hit");
    check_equal(test_m(DIV,a,b,0),cold_divide_latency(DIV,a,b),"signedness forms part of cache key");
    check_equal(test_m(REM,a,b,0),1,"signed pair cache hit");
    // Replacing the single entry must not accidentally hit the old operand pair.
    test_m(DIVU,a,b+2,0);
    check_equal(test_m(DIVU,a,b,0),cold_divide_latency(DIVU,a,b),"operand cache replacement");
    check_equal(test_m(DIVU,a^0x10000u,b,0),cold_divide_latency(DIVU,a^0x10000u,b),"dividend forms part of cache key");

    clear_mdu();
    start_m(DIVU,a,b);tick();tick(); // Neither radix configuration has completed.
    kill_tag(active_tag);tick();clear_kill_mask();dut.rsp_ready=1;
    for(unsigned n=0;n<20;++n) {tick();check(!dut.rsp_valid,"partial canceled division cannot respond");}
    check_equal(test_m(DIVU,a,b,0),cold_divide_latency(DIVU,a,b),"partial canceled division cannot populate cache");
    // A completed mathematical result remains safe across cancellation of its tag.
    start_m(REMU,a,b);tick();check(dut.rsp_valid,"cached result reaches held output");
    kill_tag(active_tag);dut.eval();check(!dut.rsp_valid,"held cached result canceled");
    tick();clear_kill_mask();dut.rsp_ready=1;tick();
    check_equal(test_m(DIVU,a,b,1),1,"selective kill preserves previously completed pair");
    clear_mdu();
    check_equal(test_m(DIVU,a,b,0),cold_divide_latency(DIVU,a,b),"global kill clears pair cache");
    dut.rst=1;tick();dut.rst=0;dut.req_valid=0;dut.eval();
    check_equal(test_m(DIVU,a,b,0),cold_divide_latency(DIVU,a,b),"reset clears pair cache");
    clear_mdu();
    std::cout<<"MDU latency: radix-step-bits="<<divide_step_bits<<" pairs="<<pairs
             <<" cold cycles="<<cold_cycles<<" cached cycles="<<cached_cycles<<"\n";
}

static void test_mixed_traffic() {
    struct Transaction {Op op;uint32_t a,b,expected;uint8_t tag;};
    std::array<std::optional<Transaction>,256> expected;
    std::optional<Transaction> request;
    std::optional<std::pair<unsigned,uint32_t>> held;
    unsigned accepted=0,received=0,canceled=0,holds=0,multiply_with_divide=0,max_pending=0;
    const unsigned target=12000;
    for(unsigned cycle=0;cycle<200000;++cycle) {
        clear_kill_mask();
        unsigned active=0;
        for(const auto& item:expected) active+=bool(item);
        max_pending=std::max(max_pending,active);
        if(accepted>=target && !request && !active) break;
        if(cycle && cycle%977==0) {
            dut.kill=1;dut.req_valid=0;dut.rsp_ready=1;dut.eval();
            check(!dut.req_ready && !dut.rsp_valid,"global kill masks mixed traffic");
            for(auto& item:expected) if(item) {item.reset();++canceled;}
            request.reset();held.reset();tick();dut.kill=0;continue;
        }
        if(active && rng()%8==0) {
            const unsigned victims=std::min(active,1u+unsigned(rng()%3));
            for(unsigned n=0;n<victims;++n) {
                unsigned tag=rng()%256;
                while(!expected[tag]) tag=(tag+1)%256;
                kill_tag(tag);expected[tag].reset();++canceled;
                if(held && held->first==tag) held.reset();
            }
        }
        if(!request && accepted<target && rng()%5!=0) {
            unsigned tag=rng()%256;
            while(expected[tag]) tag=(tag+1)%256;
            Op op=Op(MUL+rng()%8);uint32_t a=rng(),b=rng();
            if(rng()%32==0) b=0;
            if(rng()%5==0) {op=(rng()%2) ? DIVU:REMU;a=0xfedcba98;b=7;}
            request=Transaction{op,a,b,m_ref(op,a,b),uint8_t(tag)};
        }
        dut.req_valid=bool(request);
        if(request) {dut.req_op=request->op;dut.req_a=request->a;dut.req_b=request->b;dut.req_tag=request->tag;}
        dut.rsp_ready=(cycle%101>=17) && rng()%4!=0;
        dut.eval();
        if(held) {
            check(dut.rsp_valid,"blocked response valid retained");
            check_equal(dut.rsp_tag,held->first,"blocked response tag stable");
            check_equal(dut.rsp_result,held->second,"blocked response data stable");
        }
        held.reset();
        if(dut.rsp_valid) {
            unsigned tag=dut.rsp_tag;
            check(bool(expected[tag]),"response belongs to a live accepted tag");
            check_equal(dut.rsp_result,expected[tag]->expected,"mixed tagged result");
            if(dut.rsp_ready) {expected[tag].reset();++received;}
            else {held={{tag,dut.rsp_result}};++holds;}
        }
        if(dut.req_valid && dut.req_ready) {
            bool divider_live=false;
            for(const auto& item:expected) divider_live |= item && item->op>=DIV;
            if(request->op<=MULHU && divider_live) ++multiply_with_divide;
            check(!expected[request->tag],"tag not reused while outstanding");
            expected[request->tag]=request;
            request.reset();++accepted;
        }
        tick();
    }
    check_equal(accepted,target,"mixed traffic completed requested input count");
    check_equal(received+canceled,accepted,"every accepted operation responded or canceled once");
    check(canceled>100 && holds>100 && max_pending>=4 && multiply_with_divide>100,
          "mixed traffic exercised cancel/backpressure/overlap");
    clear_kill_mask();dut.req_valid=0;dut.rsp_ready=1;
    for(unsigned n=0;n<25;++n) {tick();check(!dut.rsp_valid,"mixed stream drained with no late results");}
}

static void test_completed_multiply_capacity() {
    clear_mdu();dut.rsp_ready=0;dut.req_valid=1;
    for(unsigned n=0;n<4;++n) {
        dut.req_op=MULHSU;dut.req_a=0xffffffffu;dut.req_b=11+n;dut.req_tag=10+n;
        dut.eval();check(dut.req_ready,"four total multiply result slots");tick();
        check(dut.rsp_valid,"empty multiply queue bypass reaches registered output");
        check_equal(dut.rsp_tag,10,"oldest held multiply is stable while filling queue");
        check_equal(dut.rsp_result,m_ref(MULHSU,0xffffffffu,11),"held bypass result");
    }
    dut.req_tag=14;dut.req_b=15;dut.eval();
    check(!dut.req_ready,"fifth multiply backpressures while all result slots are full");
    kill_tag(12);kill_tag(13);dut.eval();
    check(dut.req_ready,"selective cancellation frees capacity immediately");
    tick();clear_kill_mask();dut.req_valid=0;dut.rsp_ready=1;dut.eval();
    const std::array<unsigned,3> tags={10,11,14};unsigned received=0;
    for(unsigned cycle=0;cycle<12;++cycle) {
        if(dut.rsp_valid) {
            check(received<tags.size(),"no duplicate after buffer cancellation");
            const unsigned tag=tags[received++];check_equal(dut.rsp_tag,tag,"surviving multiply order");
            check_equal(dut.rsp_result,m_ref(MULHSU,0xffffffffu,tag+1),"surviving buffered product");
        }
        tick();
    }
    check_equal(received,3,"all uncanceled buffered products drain");
    clear_mdu();
}

static void test_muldiv() {
    std::array<uint32_t, 12> values = {0, 1, 2, 3, 0x7fffffff, 0x80000000,
        0x80000001, 0xfffffffe, 0xffffffff, 0x00010000, 0x55555555, 0xaaaaaaaa};
    for (unsigned op = MUL; op <= REMU; ++op)
        for (uint32_t a : values)
            for (uint32_t b : values) test_m(Op(op), a, b, rng() % 7);
    for (unsigned n = 0; n < 10000; ++n)
        test_m(Op(MUL + rng() % 8), rng(), rng(), rng() % 7);
    test_kill();
    test_readiness_hints();
    test_multiply_throughput();
    test_completed_multiply_capacity();
    test_selective_kill();
    test_divide_cache_and_normalization();
    test_mixed_traffic();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        clear_kill_mask();dut.req_valid=0;dut.req_op=MUL;dut.req_tag=0;dut.rsp_ready=0;
        dut.rst = 1; tick(); dut.rst = 0; dut.eval();
        test_decoder();
        test_alu_branch();
        test_muldiv();
        std::cout << "ISA PASS: exhaustive decode fields, random ALU/branch, "
                  << "11152 scalar and 12000 mixed tagged M operations, cached pairs/normalization/pipeline/cancellation/backpressure ("
                  << checks << " checks)\n";
        dut.final();
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "ISA FAIL: " << e.what() << "\n";
        return 1;
    }
}
