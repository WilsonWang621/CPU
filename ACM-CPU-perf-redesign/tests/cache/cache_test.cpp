#include "Vcache.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
#ifndef MAX_CPU_WORDS
#define MAX_CPU_WORDS 4
#endif
#ifndef LINE_BYTES
#define LINE_BYTES 32
#endif
#ifndef WAYS
#define WAYS 4
#endif
#ifndef MSHRS
#define MSHRS 8
#endif
#ifndef READ_ONLY
#define READ_ONLY 0
#endif
#ifndef WAITERS
#define WAITERS 32
#endif
#ifndef MAX_MEM_OUTSTANDING
#define MAX_MEM_OUTSTANDING 64
#endif

static void require(bool ok,const std::string& message) {
    if(!ok) throw std::runtime_error(message);
}
using Data=std::array<uint32_t,4>;
class Bench {
    struct Expected { Data data; bool error,write; uint8_t error_mask; };
    struct Pending {
        uint64_t due; uint32_t addr,wdata; uint8_t mask; bool write,error,presented=false;
        uint32_t data=0;
    };
    std::map<int,Expected> expected;
    std::deque<Pending> pending;
    uint8_t next_tag=1;
    bool expected_error=false,held_req=false,held_rsp=false;
    uint8_t expected_error_mask=0,last_error_mask=0;
    std::array<uint64_t,4> last_req{};
    Data last_rsp{};
    uint8_t last_tag=0;
    bool last_error=false;
public:
    Vcache dut;
    std::vector<uint32_t> ram=std::vector<uint32_t>(16384),golden=ram;
    uint64_t cycle=0,reads=0,writes=0,responses=0;
    uint64_t trace_hash=1469598103934665603ull,trace_cycles=0;
    unsigned peak=0,burst=0,longest_burst=0;
    bool accept_memory=true,accept_cpu=true,random_wait=true;
    int latency=20;
    int64_t fail_read=-1,fail_write=-1;
    std::vector<int> response_order;
    std::vector<uint32_t> read_addresses;
    Bench() { reset(); }
    void reset() {
        dut.cpu_req_valid=0;dut.cpu_req_count=1;dut.flush_valid=0;
        dut.mem_req_ready=0;dut.mem_rsp_valid=0;dut.cpu_rsp_ready=0;
        dut.rst=1;dut.clk=0;dut.eval();dut.clk=1;dut.eval();dut.clk=0;dut.eval();dut.rst=0;
        for(size_t i=0;i<ram.size();++i) ram[i]=golden[i]=0x5a123456u^uint32_t(i*0x01030907u);
        expected.clear();pending.clear();response_order.clear();read_addresses.clear();held_req=held_rsp=false;
        cycle=reads=writes=responses=peak=burst=longest_burst=0;
        accept_memory=accept_cpu=random_wait=true;latency=20;fail_read=fail_write=-1;
        expected_error=false;expected_error_mask=0;tick();
    }
    bool tick() {
        ++trace_cycles;
        require(cycle<800000,"cache watchdog");
        dut.clk=0;
        dut.mem_req_ready=accept_memory && pending.size()<MAX_MEM_OUTSTANDING &&
            (!random_wait || (cycle%7!=0 && cycle%11!=0));
        dut.mem_rsp_valid=!pending.empty() && cycle>=pending.front().due;
        if(dut.mem_rsp_valid) {
            auto& p=pending.front();
            if(!p.presented) { p.data=ram.at(p.addr/4);p.presented=true; }
            dut.mem_rsp_rdata=p.data;dut.mem_rsp_error=p.error;
        } else { dut.mem_rsp_rdata=0;dut.mem_rsp_error=0; }
        dut.cpu_rsp_ready=accept_cpu;dut.eval();
        const std::array<uint64_t,4> request{dut.mem_req_addr,dut.mem_req_wdata,dut.mem_req_wstrb,dut.mem_req_write};
        if(held_req) require(dut.mem_req_valid && request==last_req,"request changed before acceptance");
        held_req=dut.mem_req_valid && !dut.mem_req_ready;last_req=request;
        const Data response{dut.cpu_rsp_data[0],dut.cpu_rsp_data[1],dut.cpu_rsp_data[2],dut.cpu_rsp_data[3]};
        if(held_rsp) require(dut.cpu_rsp_valid && response==last_rsp && dut.cpu_rsp_tag==last_tag &&
                            bool(dut.cpu_rsp_error)==last_error && dut.cpu_rsp_error_mask==last_error_mask,
                            "response changed under backpressure");
        held_rsp=dut.cpu_rsp_valid && !dut.cpu_rsp_ready;
        last_rsp=response;last_tag=dut.cpu_rsp_tag;last_error=dut.cpu_rsp_error;last_error_mask=dut.cpu_rsp_error_mask;
        if(dut.cpu_rsp_valid && dut.cpu_rsp_ready) {
            auto it=expected.find(dut.cpu_rsp_tag);
            require(it!=expected.end(),"unexpected/duplicate response tag");
            require(bool(dut.cpu_rsp_error)==it->second.error,"incorrect error tag="+std::to_string(dut.cpu_rsp_tag));
            require(dut.cpu_rsp_error_mask==it->second.error_mask,"incorrect per-word error mask tag="+std::to_string(dut.cpu_rsp_tag));
            trace(1);trace(trace_cycles);trace(dut.cpu_rsp_tag);trace(dut.cpu_rsp_error_mask);
            if(!it->second.write)
                for(unsigned word=0;word<4;++word)
                    if(!(it->second.error_mask&(1u<<word))) {
                        require(response[word]==it->second.data[word],"incorrect successful response word tag="+
                                std::to_string(dut.cpu_rsp_tag)+" word="+std::to_string(word)+" cycle="+std::to_string(cycle));
                        trace(response[word]);
                    }
            response_order.push_back(dut.cpu_rsp_tag);expected.erase(it);++responses;
        }
        const bool accepted=dut.cpu_req_valid && dut.cpu_req_ready;
        if(accepted) {
            const uint32_t addr=dut.cpu_req_addr;
            trace(2);trace(trace_cycles);trace(addr);trace(dut.cpu_req_tag);trace(dut.cpu_req_count);
            trace(dut.cpu_req_write);
            if(dut.cpu_req_write) { trace(dut.cpu_req_wdata);trace(dut.cpu_req_wstrb); }
            const bool invalid=(addr&3) || !dut.cpu_req_count || dut.cpu_req_count>MAX_CPU_WORDS ||
                (addr%LINE_BYTES)+4*dut.cpu_req_count>LINE_BYTES ||
                (dut.cpu_req_write && (READ_ONLY || dut.cpu_req_count!=1));
            const bool bad=expected_error || invalid;
            const uint8_t wanted_mask=dut.cpu_req_count ? uint8_t((1u<<std::min<unsigned>(dut.cpu_req_count,4))-1):1;
            const uint8_t error_mask=invalid ? wanted_mask :
                (expected_error ? (expected_error_mask ? expected_error_mask:wanted_mask):0);
            if(dut.cpu_req_write && !bad)
                for(unsigned b=0;b<4;++b) if(dut.cpu_req_wstrb&(1u<<b))
                    golden.at(addr/4)=(golden.at(addr/4)&~(0xffu<<(8*b)))|(dut.cpu_req_wdata&(0xffu<<(8*b)));
            Data data{};
            if(!invalid && !dut.cpu_req_write)
                for(unsigned n=0;n<dut.cpu_req_count;++n) data[n]=golden.at(addr/4+n);
            require(!expected.count(dut.cpu_req_tag),"tag reused before response");
            expected[dut.cpu_req_tag]={data,bad,bool(dut.cpu_req_write),error_mask};
        }
        if(dut.mem_rsp_valid && dut.mem_rsp_ready) {
            auto p=pending.front();pending.pop_front();
            if(p.write && !p.error)
                for(unsigned b=0;b<4;++b) if(p.mask&(1u<<b))
                    ram.at(p.addr/4)=(ram.at(p.addr/4)&~(0xffu<<(8*b)))|(p.wdata&(0xffu<<(8*b)));
        }
        if(dut.mem_req_valid && dut.mem_req_ready) {
            require(pending.size()<MAX_MEM_OUTSTANDING,"memory queue overflow");
            require((dut.mem_req_addr&3)==0,"unaligned RAM request");
            trace(3);trace(trace_cycles);trace(dut.mem_req_addr);trace(dut.mem_req_write);
            if(dut.mem_req_write) { trace(dut.mem_req_wdata);trace(dut.mem_req_wstrb); }
            const bool error=dut.mem_req_write ? int64_t(dut.mem_req_addr)==fail_write : int64_t(dut.mem_req_addr)==fail_read;
            pending.push_back({cycle+latency+(random_wait?cycle%3:0),dut.mem_req_addr,dut.mem_req_wdata,
                uint8_t(dut.mem_req_wstrb),bool(dut.mem_req_write),error});
            if(dut.mem_req_write) ++writes;else { ++reads;read_addresses.push_back(dut.mem_req_addr); }
            peak=std::max<unsigned>(peak,pending.size());longest_burst=std::max(longest_burst,++burst);
        } else burst=0;
        dut.clk=1;dut.eval();dut.clk=0;dut.eval();++cycle;
        return accepted;
    }
    void offer(uint32_t address,bool write,uint32_t value,uint8_t mask,uint8_t tag,bool error=false,unsigned count=1,uint8_t error_mask=0) {
        dut.cpu_req_valid=1;dut.cpu_req_write=write;dut.cpu_req_addr=address;dut.cpu_req_wdata=value;
        dut.cpu_req_wstrb=mask;dut.cpu_req_tag=tag;dut.cpu_req_count=count;expected_error=error;expected_error_mask=error_mask;
    }
    void send(uint32_t address,bool write,uint32_t value,uint8_t mask,uint8_t tag,bool error=false,unsigned count=1,uint8_t error_mask=0) {
        offer(address,write,value,mask,tag,error,count,error_mask);
        int limit=20000;while(!tick()) require(--limit>0,"CPU request stuck");
        dut.cpu_req_valid=0;expected_error=false;expected_error_mask=0;
    }
    void drain() {
        int limit=20000;
        do { tick();require(--limit>0,"cache drain stuck"); } while(!expected.empty() || !dut.idle);
        require(pending.empty(),"idle while RAM responses pending");
    }
    void access(uint32_t address,bool write=false,uint32_t value=0,uint8_t mask=0xf,bool error=false,unsigned count=1) {
        send(address,write,value,mask,next_tag++,error,count);drain();
    }
    void flush(bool error=false) {
        dut.flush_valid=1;int limit=20000;
        do { tick();require(--limit>0,"flush stuck"); } while(!dut.flush_done);
        require(bool(dut.flush_error)==error,"incorrect sticky flush error");
        require(pending.empty(),"flush done before write responses");
        for(int n=0;n<5;++n) { tick();require(dut.flush_done && !dut.mem_req_valid && !dut.cpu_req_ready,"flush_done not held"); }
        dut.flush_valid=0;tick();
        if(!error) require(ram==golden,"full RAM mismatch after flush");
    }
    bool waiting(int tag) const { return expected.count(tag); }
    void trace(uint64_t value) { trace_hash^=value;trace_hash*=1099511628211ull; }
    size_t outstanding() const { return expected.size(); }
    size_t memory_pending() const { return pending.size(); }
};

static void sectors_and_hits(Bench& b) {
    b.latency=3;
    if(!READ_ONLY) {
        b.access(0,true,0x11223344);
        b.access(4,true,0xfedcba98,5);
        require(b.reads==0 && b.writes==0,"store sector allocation accessed RAM");
        b.access(0);require(b.reads==0,"fully written word needed a fill");
        b.access(4);require(b.reads==LINE_BYTES/4-1,"partial sector fill did not skip valid word");
    } else {
        b.access(0);require(b.reads==LINE_BYTES/4,"instruction prefetch did not fill line");
        b.access(0,true,0x1234,0xf,true);
    }
    b.access(0,false,0,0,false,MAX_CPU_WORDS);b.access(LINE_BYTES-8,false,0,0,false,std::min(2,MAX_CPU_WORDS));
    const auto before=b.cycle;
    for(unsigned n=0;n<32;++n) b.send(0,false,0,0,uint8_t(160+n),false,MAX_CPU_WORDS);
    require(b.cycle-before==32,"cache hit port inserted bubbles");b.drain();
    b.access(1,false,0,0,true);b.access(LINE_BYTES-4,false,0,0,true,2);
    b.flush();const auto writes=b.writes;b.flush();require(b.writes==writes,"clean words written twice");
}

static void merged_waiters(Bench& b) {
    b.reset();b.accept_memory=false;
    b.send(0,false,0,0,10);
    if(!READ_ONLY) {
        b.send(0,true,0x12345678,0xf,11);
        b.send(0,false,0,0,12);
        b.send(0,true,0x00ab0000,4,13);
    }
    b.send(0,false,0,0,14,false,MAX_CPU_WORDS);
    require(b.dut.miss_count==1,"same-line waiters allocated duplicate MSHRs");
    b.accept_cpu=false;b.accept_memory=true;
    for(int n=0;n<250;++n) b.tick();
    require(b.memory_pending()==0 && !b.dut.idle,"CPU backpressure blocked fill draining or lost responses");
    b.accept_cpu=true;b.drain();b.flush();
}

static void waiter_capacity(Bench& b) {
    b.reset();b.accept_memory=false;
    for(unsigned n=0;n<WAITERS;++n) b.send(0,false,0,0,uint8_t(n));
    require(b.dut.miss_count==1,"waiter pool did not merge same line");
    b.dut.cpu_req_addr=0;b.dut.eval();require(!b.dut.cpu_req_ready,"waiter pool overflow accepted");
    b.accept_cpu=false;b.accept_memory=true;
    for(int n=0;n<250;++n) b.tick();
    b.accept_cpu=true;b.drain();require(b.responses==WAITERS,"waiter response dropped");
}

static void overlapping_misses(Bench& b) {
    b.reset();b.access(15*LINE_BYTES);b.latency=97;
    b.accept_memory=false;
    for(unsigned n=0;n<MSHRS;++n) b.send((32+n)*LINE_BYTES,false,0,0,uint8_t(n+1));
    const auto misses=b.dut.miss_count;
    b.send(15*LINE_BYTES,false,0,0,80);
    for(int n=0;n<5;++n) b.tick();
    require(!b.waiting(80),"hit blocked behind unrelated misses");
    b.send(32*LINE_BYTES,false,0,0,81);
    require(b.dut.miss_count==misses,"same-line merge used a new MSHR");
    b.dut.cpu_req_addr=128*LINE_BYTES;b.dut.eval();require(!b.dut.cpu_req_ready,"miss accepted without MSHR");
    b.accept_memory=true;b.random_wait=false;b.drain();
    require(b.peak>=std::min<unsigned>(MSHRS*LINE_BYTES/4,20),"line requests did not pipeline");
    require(b.longest_burst>=std::min<unsigned>(MSHRS*LINE_BYTES/4,16),"burst requests inserted bubbles");
    b.flush();
}

static void early_restart_and_errors(Bench& b) {
    b.reset();b.random_wait=false;
    b.access(LINE_BYTES-4);
    require(b.read_addresses.front()==LINE_BYTES-4,"burst did not start at nonzero critical word");
    b.reset();b.random_wait=false;b.fail_read=LINE_BYTES-4;b.accept_memory=false;
    b.send(0,false,0,0,90);b.send(LINE_BYTES-4,false,0,0,91,true);
    b.accept_memory=true;
    while(b.waiting(90)) b.tick();
    if(LINE_BYTES>=32) require(b.memory_pending()>0,"critical word waited for full line");
    b.drain();require(!b.dut.flush_error,"prefetch read error became global write error");
    const auto reads=b.reads;b.access(0);require(b.reads==reads,"failed prefetch discarded a successful sector");
    b.fail_read=-1;b.access(LINE_BYTES-4);require(b.reads==reads+1,"failed word was not retried alone");
    b.flush();
    if(!READ_ONLY) {
        b.reset();b.accept_memory=false;b.fail_read=LINE_BYTES-4;
        b.send(0,false,0,0,100);
        b.send(LINE_BYTES-4,true,0x76543210,0xf,101);
        b.send(LINE_BYTES-4,false,0,0,102);
        b.accept_memory=true;b.drain();b.flush();
    }
}

static void packet_error_masks(Bench& b) {
    if(MAX_CPU_WORDS<4) {
        b.reset();b.accept_cpu=false;
        b.send(0,false,0,0,130,true,0);
        for(unsigned count=MAX_CPU_WORDS+1;count<=4;++count)
            b.send(0,false,0,0,uint8_t(130+count),true,count);
        for(unsigned n=0;n<100;++n) b.tick();
        require(b.reads==0,"unsupported count allocated/fetched cache storage");
        b.accept_cpu=true;b.drain();
    }
    for(unsigned failed_word=0;failed_word<MAX_CPU_WORDS;++failed_word) {
        b.reset();b.random_wait=false;b.fail_read=4*failed_word;b.accept_cpu=false;
        b.send(0,false,0,0,130,true,MAX_CPU_WORDS,uint8_t(1u<<failed_word));
        for(unsigned n=0;n<100;++n) b.tick();
        require(b.dut.cpu_rsp_valid,"multiword failed request did not complete");
        require(b.dut.cpu_rsp_error_mask==(1u<<failed_word),"wrong held packet error mask");
        // Success words must be present even when an earlier word failed.
        for(unsigned word=0;word<MAX_CPU_WORDS;++word)
            if(word!=failed_word) require(b.dut.cpu_rsp_data[word]==b.golden[word],"packet lost a successful word");
        for(unsigned n=0;n<17;++n) b.tick();
        b.accept_cpu=true;b.drain();
        b.fail_read=-1;const auto reads=b.reads;
        b.access(0,false,0,0,false,MAX_CPU_WORDS);
        require(b.reads==reads+1,"packet retry reread successful words");
        b.flush();
    }
}

static void writeback_and_flush(Bench& b) {
    if(READ_ONLY) return;
    constexpr unsigned stride=16*LINE_BYTES;
    b.reset();
    for(unsigned n=0;n<WAYS;++n) b.access(n*stride,true,0x65430000+n);
    b.access(WAYS*stride+LINE_BYTES-4);
    require(b.read_addresses.front()==WAYS*stride+LINE_BYTES-4,"writeback lost the critical fill word");
    b.access(0);b.flush();
    require(b.writes>=WAYS,"successful eviction/flush dropped a dirty word");
    b.reset();
    for(unsigned n=0;n<WAYS;++n) { b.access(n*stride,true,0x98760000+n);b.access(n*stride+4,true,0x99887766+n); }
    b.accept_memory=false;b.send(WAYS*stride,false,0,0,110,true);b.fail_write=4;
    b.dut.cpu_req_addr=0;b.dut.eval();require(!b.dut.cpu_req_ready,"dirty victim accessible before writeback");
    b.accept_memory=true;b.drain();require(b.dut.flush_error,"victim write failure not sticky");
    b.access(0);b.fail_write=-1;b.flush(true);require(b.ram==b.golden,"failed victim lost dirty bytes");

    b.reset();b.access(0,true,0xaabbccdd);b.access(LINE_BYTES-4,true,0x12345678,5);
    b.fail_write=LINE_BYTES-4;b.flush(true);const auto before=b.writes;
    b.fail_write=-1;b.flush(true);
    require(b.writes==before+1,"flush retry did not retain exactly the failed dirty word");
    require(b.ram==b.golden,"partial-byte flush corrupted untouched RAM bytes");

    b.reset();b.accept_memory=false;
    b.send(0,false,0,0,111);b.send(0,true,0xdeadbeef,0xf,112);
    b.dut.flush_valid=1;for(int n=0;n<5;++n) { b.tick();require(!b.dut.flush_done,"flush skipped accepted operations"); }
    b.accept_memory=true;b.flush();require(!b.waiting(111) && !b.waiting(112),"flush dropped pending responses");
}

static void randomized(Bench& b) {
    for(int latency:{3,20}) {
        b.reset();b.latency=latency;uint32_t random=0xa519c823;
        for(unsigned n=0;n<1800;++n) {
            random^=random<<13;random^=random>>17;random^=random<<5;
            const uint32_t addr=((random>>8)%(64*LINE_BYTES/4))*4;
            const bool write=!READ_ONLY && (random&1);
            const unsigned count=write?1:std::min<unsigned>(MAX_CPU_WORDS,std::min<unsigned>(1+((random>>3)&3),(LINE_BYTES-addr%LINE_BYTES)/4));
            b.offer(addr,write,random^0x91ab753e,uint8_t(random>>20)&0xf,uint8_t(n),false,count);
            bool accepted=false;
            while(!accepted) { b.accept_cpu=b.cycle%17>=7;accepted=b.tick(); }
            b.dut.cpu_req_valid=0;
        }
        b.accept_cpu=true;b.drain();b.flush();
    }
}

// Model the frontend's finite request table: canceled requests also retain a
// slot until their response arrives. Compare this trace across waiter sizes.
static void bounded_window_trace(Bench& b,unsigned window) {
    require(window>0 && window<=WAITERS,"window exceeds waiter capacity");
    b.reset();b.latency=20;
    for(unsigned n=0;n<160;++n) {
        while(b.outstanding()>=window) { b.accept_cpu=b.cycle%17>=7;b.tick(); }
        b.offer(((n*13)%96)*LINE_BYTES,false,0,0,uint8_t(n),false,MAX_CPU_WORDS);
        bool accepted=false;
        while(!accepted) { b.accept_cpu=b.cycle%17>=7;accepted=b.tick(); }
        b.dut.cpu_req_valid=0;
    }
    b.accept_cpu=true;b.drain();
    uint64_t hash=1469598103934665603ull;
    for(auto address:b.read_addresses) { hash^=address;hash*=1099511628211ull; }
    for(auto tag:b.response_order) { hash^=unsigned(tag);hash*=1099511628211ull; }
    std::cout<<"window trace: window="<<window<<" cycles="<<b.cycle<<" reads="<<b.reads
             <<" responses="<<b.responses<<" hash="<<hash<<'\n';
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    const char* stage="reset";
    try {
        if(argc==3 && std::string(argv[1])=="--window-trace") {
            Bench b;bounded_window_trace(b,unsigned(std::stoul(argv[2])));return 0;
        }
        Bench b;stage="sectors and hits";sectors_and_hits(b);
        stage="merged waiters";merged_waiters(b);stage="waiter capacity";waiter_capacity(b);
        stage="overlapping misses";overlapping_misses(b);
        stage="early restart and errors";early_restart_and_errors(b);
        stage="per-word packet errors";packet_error_masks(b);
        stage="writeback and flush";writeback_and_flush(b);stage="randomized";randomized(b);
        std::cout<<"cache passed: ways="<<WAYS<<" line="<<LINE_BYTES<<" mshrs="<<MSHRS<<" readonly="<<READ_ONLY
                 <<" words="<<MAX_CPU_WORDS<<" waiters="<<WAITERS<<'\n';
        if(argc==2 && std::string(argv[1])=="--exact-trace")
            std::cout<<"exact trace: cycles="<<b.trace_cycles<<" hash="<<b.trace_hash<<'\n';
        return 0;
    } catch(const std::exception& e) { std::cerr<<"cache test failed ("<<stage<<"): "<<e.what()<<'\n';return 1; }
}
