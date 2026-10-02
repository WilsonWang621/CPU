// Standalone cycle-accurate cpu_top driver. No course-specific framework needed.
#include "Vcpu_top.h"
#include "verilated.h"
#include "memory_model.h"
#include <algorithm>
#include <cstdint>
#include <chrono>
#include <sys/resource.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <type_traits>
#include <utility>

namespace {
constexpr uint32_t RAM_BYTES = 256 * 1024, EXIT_ADDRESS = 0x80000000;
using Memory = std::vector<uint8_t>;
uint64_t number(const std::string &s) {
    size_t used = 0;
    uint64_t value = std::stoull(s, &used, 0);
    if (used != s.size()) throw std::runtime_error("invalid integer: " + s);
    return value;
}
std::string hex(uint64_t value) {
    std::ostringstream out; out << "0x" << std::hex << value; return out.str();
}
struct Options {
    std::string image, expected, memory, trace, dump_memory;
    uint64_t latency = 3, max_cycles = 100000000, seed = 1, random_wait = 0, request_wait = 0, max_outstanding = 64;
    std::optional<uint64_t> instructions, error_address, fault_pc, fault_cause, fault_address, fault_inst, fault_inst_valid;
    bool expect_fault = false, error_write = false, error_read = false;
};
Options parse(int argc, char **argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--expect-fault") { o.expect_fault = true; continue; }
        if (a == "--error-write") { o.error_write = true; continue; }
        if (a == "--error-read") { o.error_read = true; continue; }
        if (a == "--help") {
            std::cout << "cpu_sim --image PATH [--expected PATH --memory PATH --instructions N]\n"
                      << "  [--latency N --max-cycles N --trace PATH --dump-memory PATH]\n"
                      << "  [--seed N --random-wait N --request-wait N --max-outstanding N]\n"
                      << "  [--error-address ADDR [--error-read|--error-write]]\n"
                      << "  [--expect-fault [--fault-pc N --fault-cause N --fault-address N --fault-inst N --fault-inst-valid N]]\n";
            std::exit(0);
        }
        if (i + 1 == argc) throw std::runtime_error("missing value for " + a);
        std::string v = argv[++i];
        if (a == "--image") o.image = v;
        else if (a == "--expected") o.expected = v;
        else if (a == "--memory") o.memory = v;
        else if (a == "--trace") o.trace = v;
        else if (a == "--dump-memory") o.dump_memory = v;
        else if (a == "--latency") o.latency = number(v);
        else if (a == "--max-cycles") o.max_cycles = number(v);
        else if (a == "--instructions") o.instructions = number(v);
        else if (a == "--seed") o.seed = number(v);
        else if (a == "--random-wait") o.random_wait = number(v);
        else if (a == "--request-wait") o.request_wait = number(v);
        else if (a == "--max-outstanding") o.max_outstanding = number(v);
        else if (a == "--error-address") o.error_address = number(v);
        else if (a == "--fault-pc") o.fault_pc = number(v);
        else if (a == "--fault-cause") o.fault_cause = number(v);
        else if (a == "--fault-address") o.fault_address = number(v);
        else if (a == "--fault-inst") o.fault_inst = number(v);
        else if (a == "--fault-inst-valid") o.fault_inst_valid = number(v);
        else throw std::runtime_error("unknown option: " + a);
    }
    if (o.image.empty()) throw std::runtime_error("--image is required");
    if (!o.max_outstanding) throw std::runtime_error("max outstanding must be positive");
    if (!o.latency) throw std::runtime_error("latency must be positive");
    if (o.error_read && o.error_write) throw std::runtime_error("choose at most one error direction");
    return o;
}
Memory load_image(const std::string &path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open " + path);
    Memory memory(RAM_BYTES, 0);
    uint64_t address = 0; std::string line; size_t line_number = 0;
    while (std::getline(in, line)) {
        ++line_number;
        auto comment = std::min(line.find("//"), line.find('#'));
        if (comment != std::string::npos) line.resize(comment);
        std::istringstream words(line); std::string word;
        while (words >> word) {
            size_t used = 0; bool at = word.front() == '@';
            auto token = at ? word.substr(1) : word;
            uint64_t value;
            try { value = std::stoull(token, &used, 16); }
            catch (...) { throw std::runtime_error(path + ":" + std::to_string(line_number) + ": invalid image token " + word); }
            if (used != token.size() || (at ? value >= RAM_BYTES : (value > 255 || address >= RAM_BYTES)))
                throw std::runtime_error(path + ": invalid byte/address " + word);
            if (at) address = value; else memory[address++] = static_cast<uint8_t>(value);
        }
    }
    return memory;
}
void dump_image(const Memory &memory, const std::string &path) {
    std::ofstream out(path);
    if (!out) throw std::runtime_error("cannot write " + path);
    for (size_t a = 0; a < memory.size(); a += 16) {
        if (std::none_of(memory.begin() + a, memory.begin() + a + 16, [](uint8_t v){ return v != 0; })) continue;
        out << '@' << std::hex << std::setfill('0') << std::setw(8) << a;
        for (size_t j = 0; j < 16; ++j) out << ' ' << std::setw(2) << unsigned(memory[a+j]);
        out << '\n';
    }
}
using Request = BusRequest;
template<class Packed> uint32_t word(const Packed &value, unsigned lane) {
    if constexpr (std::is_integral_v<Packed>) return uint32_t(value >> (32 * lane));
    else return value[lane];
}
}

int main(int argc, char **argv) {
    try {
        Options o = parse(argc, argv);
        auto memory = load_image(o.image);
        std::optional<Memory> expected_memory;
        std::optional<uint32_t> expected_value;
        if (!o.memory.empty()) expected_memory = load_image(o.memory);
        if (!o.expected.empty()) {
            std::ifstream in(o.expected); std::string word;
            if (!(in >> word)) throw std::runtime_error("cannot read " + o.expected);
            expected_value = static_cast<uint32_t>(number(word));
        }
        std::ofstream trace;
        if (!o.trace.empty()) {
            trace.open(o.trace);
            if (!trace) throw std::runtime_error("cannot write " + o.trace);
            trace << "pc,inst,rd,value,store,addr,wdata,wstrb\n";
        }
        VerilatedContext context;
        context.commandArgs(argc, argv);
        Vcpu_top top(&context);
        std::mt19937_64 rng(o.seed);
        auto random_delay = [&](uint64_t maximum) { return maximum ? rng() % (maximum + 1) : 0; };
        OrderedMemory pending(memory, o.max_outstanding);
        std::optional<Request> held;
        uint64_t cooldown = o.request_wait + random_delay(o.random_wait);
        uint64_t observed_retired = 0, requests = 0, writes = 0, responses = 0, exit_count = 0;
        uint32_t exit_value = 0;
        constexpr unsigned RETIRE_LANES = sizeof(top.retire_pc) / sizeof(uint32_t);
        static_assert(RETIRE_LANES == 4, "cpu_top must expose four physical retirement lanes");
        uint64_t retire_cycles[5] = {}, memory_pending_cycles = 0;
        uint64_t memory_transaction_cycles = 0, memory_peak_outstanding = 0;
        top.rst = 1; top.mem_req_ready = 0; top.mem_rsp_valid = 0;
        top.mem_rsp_error = 0; top.mem_rsp_rdata = 0;
        for (unsigned i = 0; i < 5; ++i) {
            top.clk = 0; top.eval(); context.timeInc(1);
            top.clk = 1; top.eval(); context.timeInc(1);
        }
        top.rst = 0;
        const auto simulation_start = std::chrono::steady_clock::now();
        bool finished = false;
        for (uint64_t cycle = 0; cycle < o.max_cycles; ++cycle) {
            top.clk = 0;
            const auto response = pending.response(cycle);
            top.mem_req_ready = pending.can_accept() && !cooldown;
            top.mem_rsp_valid = response.has_value();
            top.mem_rsp_error = response && response->error;
            top.mem_rsp_rdata = response ? response->data : 0;
            top.eval();
            // A completing response frees its slot on this same edge. Normally
            // capacity exceeds latency, so this second evaluation is unnecessary.
            if (!pending.can_accept() && !cooldown && top.mem_rsp_valid && top.mem_rsp_ready) {
                top.mem_req_ready = 1;
                top.eval();
            }
            context.timeInc(1);
            Request request{top.mem_req_addr, top.mem_req_wdata, static_cast<uint8_t>(top.mem_req_wstrb), bool(top.mem_req_write)};
            if (held && (!top.mem_req_valid || !(request == *held)))
                throw std::runtime_error("request payload/valid changed under backpressure at cycle " + std::to_string(cycle));
            bool accept = top.mem_req_valid && top.mem_req_ready;
            bool respond = top.mem_rsp_valid && top.mem_rsp_ready;
            bool exit_accept = accept && request.address == EXIT_ADDRESS;
            held = top.mem_req_valid && !top.mem_req_ready ? std::optional<Request>(request) : std::nullopt;
            if (exit_accept && !pending.empty())
                throw std::runtime_error("exit accepted before outstanding RAM responses completed");
            if (cooldown) --cooldown;
            top.clk = 1; top.eval(); context.timeInc(1);
            if (respond) {
                pending.complete();
                ++responses;
            }
            if (accept) {
                ++requests;
                cooldown = o.request_wait + random_delay(o.random_wait);
                if (request.address == EXIT_ADDRESS) {
                    if (!request.write || request.strobe != 15) throw std::runtime_error("invalid exit MMIO operation");
                    if (++exit_count != 1) throw std::runtime_error("duplicate exit write");
                    exit_value = request.data;
                    if (!top.halted) throw std::runtime_error("exit acceptance did not halt CPU on the same edge");
                } else {
                    if ((request.address & 3) || request.address > RAM_BYTES - 4)
                        throw std::runtime_error("invalid external RAM request at " + hex(request.address));
                    bool error = o.error_address && request.address == *o.error_address &&
                        (!o.error_write || request.write) && (!o.error_read || !request.write);
                    pending.accept(request, cycle + o.latency + random_delay(o.random_wait), error);
                    writes += request.write;
                }
            }
            memory_pending_cycles += !pending.empty();
            memory_transaction_cycles += pending.size();
            memory_peak_outstanding = std::max<uint64_t>(memory_peak_outstanding, pending.size());
            const unsigned retired_mask = top.retire_valid;
            if (retired_mask >> RETIRE_LANES) throw std::runtime_error("retirement valid exceeds packed port width");
            if (retired_mask & (retired_mask + 1)) throw std::runtime_error("retirement lanes are not a continuous prefix");
            unsigned retire_count = 0;
            for (unsigned lane = 0; lane < RETIRE_LANES; ++lane) retire_count += (retired_mask >> lane) & 1;
            ++retire_cycles[retire_count];
            bool retired_exit = false;
            for (unsigned lane = 0; lane < RETIRE_LANES; ++lane) {
                if (!((top.retire_valid >> lane) & 1)) continue;
                uint32_t pc = word(top.retire_pc, lane), inst = word(top.retire_inst, lane);
                uint32_t value = word(top.retire_value, lane), address = word(top.retire_addr, lane);
                uint32_t data = word(top.retire_wdata, lane);
                unsigned rd = (top.retire_rd >> (5*lane)) & 31;
                unsigned strobe = (top.retire_wstrb >> (4*lane)) & 15, store = (top.retire_store >> lane) & 1;
                if (retired_exit) throw std::runtime_error("retired a younger instruction after exit");
                if (store && address == EXIT_ADDRESS) {
                    if (!exit_accept || data != exit_value || strobe != 15)
                        throw std::runtime_error("exit retirement does not match bus acceptance");
                    retired_exit = true;
                }
                ++observed_retired;
                if (trace.is_open()) trace << std::hex << pc << ',' << inst << ',' << rd << ',' << value << ','
                    << store << ',' << address << ',' << data << ',' << strobe << '\n';
            }
            if (exit_accept && !retired_exit) throw std::runtime_error("exit bus acceptance missing final retirement");
            if (top.retired_count != observed_retired)
                throw std::runtime_error("retirement counter mismatch at cycle " + std::to_string(cycle));
            if (top.halted || top.faulted) {
                if (top.halted && top.faulted) throw std::runtime_error("CPU both halted and faulted");
                if (top.faulted) {
                    if (!o.expect_fault) throw std::runtime_error("CPU fault cause=" + std::to_string(top.fault_cause) +
                        " pc=" + hex(top.fault_pc) + " inst=" + hex(top.fault_inst) + " address=" + hex(top.fault_addr));
                    if (exit_count) throw std::runtime_error("faulting program issued exit");
                    if (o.fault_pc && top.fault_pc != *o.fault_pc) throw std::runtime_error("fault PC mismatch: " + hex(top.fault_pc));
                    if (o.fault_cause && top.fault_cause != *o.fault_cause) throw std::runtime_error("fault cause mismatch: " + std::to_string(top.fault_cause));
                    if (o.fault_address && top.fault_addr != *o.fault_address) throw std::runtime_error("fault address mismatch: " + hex(top.fault_addr));
                    if (o.fault_inst && (!top.fault_inst_valid || top.fault_inst != *o.fault_inst)) throw std::runtime_error("fault instruction mismatch");
                    if (o.fault_inst_valid && bool(top.fault_inst_valid) != bool(*o.fault_inst_valid)) throw std::runtime_error("fault instruction validity mismatch");
                } else {
                    if (o.expect_fault) throw std::runtime_error("expected fault but CPU exited");
                    if (exit_count != 1) throw std::runtime_error("halt without one exit write");
                    if (!pending.empty() || held || requests != responses + 1) throw std::runtime_error("exit with unfinished memory work");
                    if (expected_value && exit_value != *expected_value)
                        throw std::runtime_error("exit value mismatch: actual=" + hex(exit_value) + " expected=" + hex(*expected_value));
                    if (expected_memory) {
                        for (size_t a = 0; a < RAM_BYTES; ++a)
                            if (memory[a] != (*expected_memory)[a]) throw std::runtime_error("final RAM mismatch at " + hex(a) +
                                ": actual=" + hex(memory[a]) + " expected=" + hex((*expected_memory)[a]));
                    }
                }
                if (o.instructions && observed_retired != *o.instructions)
                    throw std::runtime_error("instruction count mismatch: actual=" + std::to_string(observed_retired) + " expected=" + std::to_string(*o.instructions));
                const double wall_seconds = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - simulation_start).count();
                struct rusage usage {};
                if (getrusage(RUSAGE_SELF, &usage)) throw std::runtime_error("getrusage failed");
                if (top.halted) {
                    const uint64_t final_cycles = top.cycle_count;
                    for (unsigned guard = 0; guard < 4; ++guard) {
                        top.clk = 0; top.mem_req_ready = 1; top.mem_rsp_valid = 0;
                        top.mem_rsp_error = 0; top.mem_rsp_rdata = 0; top.eval(); context.timeInc(1);
                        if (top.mem_req_valid) throw std::runtime_error("memory request after halt");
                        top.clk = 1; top.eval(); context.timeInc(1);
                        if (!top.halted || top.faulted || top.retire_valid ||
                            top.retired_count != observed_retired || top.cycle_count != final_cycles)
                            throw std::runtime_error("CPU state/retirement counters changed after halt");
                    }
                }
                if (!o.dump_memory.empty()) dump_image(memory, o.dump_memory);
                std::cout << "{\"status\":\"" << (top.faulted ? "expected_fault" : "pass")
                    << "\",\"cycles\":" << top.cycle_count << ",\"instructions\":" << observed_retired
                    << ",\"ipc\":" << std::setprecision(10) << (top.cycle_count ? double(observed_retired) / top.cycle_count : 0)
                    << ",\"exit_value\":" << exit_value << ",\"latency\":" << o.latency
                    << ",\"seed\":" << o.seed << ",\"memory_requests\":" << requests
                    << ",\"memory_writes\":" << writes << ",\"memory_pending_cycles\":" << memory_pending_cycles
                    << ",\"memory_transaction_cycles\":" << memory_transaction_cycles
                    << ",\"memory_peak_outstanding\":" << memory_peak_outstanding
                    << ",\"max_outstanding\":" << o.max_outstanding
                    << ",\"retire_cycles_0\":" << retire_cycles[0] << ",\"retire_cycles_1\":" << retire_cycles[1]
                    << ",\"retire_cycles_2\":" << retire_cycles[2] << ",\"retire_cycles_3\":" << retire_cycles[3]
                    << ",\"retire_cycles_4\":" << retire_cycles[4] << ",\"wall_seconds\":" << wall_seconds
                    << ",\"peak_rss_kib\":" << usage.ru_maxrss << ",\"branch_misses\":" << top.branch_miss_count
                    << ",\"icache_misses\":" << top.icache_miss_count << ",\"dcache_misses\":" << top.dcache_miss_count
                    << ",\"load_replay_count\":" << top.load_replay_count
                    << ",\"fault_pc\":" << top.fault_pc << ",\"fault_cause\":" << unsigned(top.fault_cause) << "}\n";
                finished = true; break;
            }
            if (context.gotFinish()) throw std::runtime_error("RTL called $finish before exit/fault");
        }
        top.final();
        if (!finished) throw std::runtime_error("cycle limit exceeded (" + std::to_string(o.max_cycles) + ")");
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << '\n'; return 1;
    }
}
