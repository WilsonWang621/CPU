#include "VMulDivHarness.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>

static uint32_t expected(uint32_t a, uint32_t b, unsigned fn) {
    switch (fn) {
    case 0: return uint32_t(uint64_t(a) * b);
    case 1: return uint32_t(uint64_t(int64_t(int32_t(a)) * int64_t(int32_t(b))) >> 32);
    case 2: return uint32_t(uint64_t(int64_t(int32_t(a)) * int64_t(b)) >> 32);
    case 3: return uint32_t((uint64_t(a) * b) >> 32);
    case 4: return b ? uint32_t(int64_t(int32_t(a)) / int64_t(int32_t(b))) : UINT32_MAX;
    case 5: return b ? a / b : UINT32_MAX;
    case 6: return b ? uint32_t(int64_t(int32_t(a)) % int64_t(int32_t(b))) : a;
    case 7: return b ? a % b : a;
    }
    throw std::runtime_error("invalid function");
}

struct Test {
    VMulDivHarness dut;
    unsigned next_tag = 0, checked = 0, canceled = 0, fast_hits = 0;
    void tick() {
        dut.clock = 0; dut.eval(); dut.clock = 1; dut.eval(); dut.clock = 0; dut.eval();
    }
    void reset() {
        dut.req_valid = 0; dut.kill = 0; dut.reset = 1; tick(); tick(); dut.reset = 0; dut.eval();
        if (!dut.req_ready || dut.rsp_valid) throw std::runtime_error("reset did not clear pending completion");
    }
    unsigned run(uint32_t a, uint32_t b, unsigned fn) {
        if (!dut.req_ready || dut.rsp_valid) throw std::runtime_error("unit failed to drain previous completion");
        unsigned tag = next_tag++ & 31;
        dut.req_valid = 1; dut.req_a = a; dut.req_b = b; dut.req_fn = fn; dut.req_tag = tag; tick();
        dut.req_valid = 0; dut.eval();
        unsigned cycles = 1;
        while (!dut.rsp_valid && cycles < 40) { tick(); ++cycles; }
        if (!dut.rsp_valid || dut.rsp_tag != tag || dut.rsp_data != expected(a,b,fn)) {
            std::cerr << "a=" << a << " b=" << b << " fn=" << fn << " tag=" << tag
                      << " got=" << dut.rsp_data << " expected=" << expected(a,b,fn) << '\n';
            throw std::runtime_error("arithmetic/tag/termination mismatch");
        }
        ++checked; if (fn >= 4 && cycles == 1) ++fast_hits;
        tick();
        if (dut.rsp_valid || !dut.req_ready) throw std::runtime_error("completion was repeated or ready did not recover");
        return cycles;
    }
    void cancel(uint32_t a, uint32_t b, unsigned ticks, bool use_reset) {
        unsigned tag = next_tag++ & 31;
        dut.req_valid = 1; dut.req_a = a; dut.req_b = b; dut.req_fn = 4; dut.req_tag = tag; tick();
        dut.req_valid = 0;
        for (unsigned i=0;i<ticks;++i) tick();
        if (dut.rsp_valid || dut.active_tag != tag) throw std::runtime_error("cancel case did not reach active divide");
        dut.kill = !use_reset; dut.reset = use_reset; tick(); dut.kill = 0; dut.reset = 0; dut.eval();
        for (unsigned i=0;i<40;++i) {
            if (dut.rsp_valid || !dut.req_ready) throw std::runtime_error("canceled tag reappeared");
            tick();
        }
        ++canceled;
        run(a,b,6); // Reuse the operand pair with a fresh, wrapping ROB tag.
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc,argv);
    try {
        const unsigned step_bits = unsigned(std::stoul(argv[1]));
        const bool cache = std::stoul(argv[2]) != 0;
        Test t; t.reset();
        const std::array<uint32_t,11> edge = {0,1,2,3,10,65536,0xffffffff,0x80000000,0x7fffffff,0xfffffffe,0x80000001};
        for (auto a:edge) for (auto b:edge) for (unsigned fn=0;fn<8;++fn) t.run(a,b,fn);
        std::mt19937 rng(0x4002026);
        for (unsigned n=0;n<12000;++n) {
            uint32_t a=rng(),b=rng();
            t.run(a,b,n%8);
            if (n%8 >= 4) t.run(a,b,(n%8)^2); // Independent quotient/remainder oracle, same pair.
        }
        t.reset();
        unsigned miss=t.run(0x80000001,23,4),hit=t.run(0x80000001,23,6);
        if (miss != 1+32/step_bits || hit != (cache ? 1 : 1+32/step_bits)) throw std::runtime_error("divide/cache latency mismatch");
        unsigned unsigned_miss=t.run(0x80000001,23,5),unsigned_hit=t.run(0x80000001,23,7);
        if (unsigned_miss != miss || unsigned_hit != hit) throw std::runtime_error("signed/unsigned cache key mismatch");
        for (unsigned i=0;i<160;++i) t.cancel(0x80010000+i,17+i,1+i%10,i%3==0);
        t.reset(); t.run(0,0,4); t.run(0,0,6); t.run(0x80000000,0xffffffff,4); t.run(0x80000000,0xffffffff,6);
        std::cout << "{\"status\":\"passed\",\"arithmetic_cases\":" << t.checked
                  << ",\"canceled_divides\":" << t.canceled << ",\"one_cycle_div_results\":" << t.fast_hits << "}\n";
    } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
