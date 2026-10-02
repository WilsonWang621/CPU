#include "Vmemory_controller.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <string>
#ifndef MAX_MEM_OUTSTANDING
#define MAX_MEM_OUTSTANDING 64
#endif

static void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
struct Request {
    unsigned owner;
    std::array<uint64_t,4> payload;
    uint64_t due;
};

static void exercise(unsigned latency) {
    Vmemory_controller d;
    d.rst=1; d.clk=0; d.eval(); d.clk=1; d.eval(); d.clk=0; d.eval(); d.rst=0;
    std::array<unsigned,2> sent{},received{};
    const std::array<unsigned,2> total{263,247};
    std::deque<Request> skid, external;
    unsigned last_owner=1, peak=0, longest_burst=0, burst=0;
    bool req_held=false, rsp_held=false;
    std::array<uint64_t,4> held_request{},held_response{};
    for(uint64_t cycle=0;cycle<80000;++cycle) {
        d.s_req_valid=0; d.s_req_write=0; d.s_req_addr=0; d.s_req_wdata=0; d.s_req_wstrb=0;
        for(int c=0;c<2;++c) {
            if(sent[c]<total[c]) d.s_req_valid|=1<<c;
            d.s_req_write|=(sent[c]&1)<<c;
            d.s_req_addr|=uint64_t(0x1000+c*0x1000+4*sent[c])<<(32*c);
            d.s_req_wdata|=uint64_t(0x11110000u*c+sent[c])<<(32*c);
            d.s_req_wstrb|=((sent[c]+c)&0xf)<<(4*c);
        }
        d.s_rsp_ready=((cycle%19>=5)?1:0)|((cycle%23>=7)?2:0);
        d.mem_rsp_valid=!external.empty() && cycle>=external.front().due;
        d.mem_rsp_rdata=external.empty()?0:uint32_t(external.front().payload[0]^external.front().payload[1]^0x12345678u);
        d.mem_rsp_error=!external.empty() && ((external.front().payload[0]>>2)%7)==0;
        const bool can_pop=d.mem_rsp_valid && ((d.s_rsp_ready>>external.front().owner)&1);
        d.mem_req_ready=cycle>12 && cycle%31<27 &&
            (external.size()<MAX_MEM_OUTSTANDING || can_pop);
        d.clk=0; d.eval();
        require(!d.idle || (skid.empty() && external.empty() && !d.s_req_valid),"false idle");
        require(d.s_req_ready!=3 && d.s_rsp_valid!=3,"two clients selected simultaneously");
        const std::array<uint64_t,4> req{d.mem_req_addr,d.mem_req_wdata,d.mem_req_wstrb,d.mem_req_write};
        if(req_held) require(d.mem_req_valid && req==held_request,"request changed before acceptance");
        req_held=d.mem_req_valid && !d.mem_req_ready; held_request=req;
        const std::array<uint64_t,4> rsp{d.s_rsp_valid,d.s_rsp_rdata,d.s_rsp_error,d.mem_rsp_ready};
        if(rsp_held) require(rsp[0]==held_response[0] && rsp[1]==held_response[1] && rsp[2]==held_response[2],
                            "response changed under backpressure");
        rsp_held=d.mem_rsp_valid && !d.mem_rsp_ready; held_response=rsp;

        if(d.mem_rsp_valid) {
            const auto owner=external.front().owner;
            require(d.s_rsp_valid==(1u<<owner),"response owner mismatch");
            require(d.mem_rsp_ready==((d.s_rsp_ready>>owner)&1),"response backpressure misrouted");
            require(uint32_t(d.s_rsp_rdata>>(32*owner))==d.mem_rsp_rdata &&
                ((d.s_rsp_error>>owner)&1)==d.mem_rsp_error,"response payload mismatch");
            if(d.mem_rsp_ready) { ++received[owner]; external.pop_front(); }
        }
        if(d.mem_req_valid && d.mem_req_ready) {
            require(!skid.empty(),"external request has no client owner");
            auto request=skid.front(); skid.pop_front();
            require(req==request.payload,"skid payload mismatch");
            request.due=cycle+latency; external.push_back(request);
            require(external.size()<=MAX_MEM_OUTSTANDING,"owner FIFO exceeded capacity");
            peak=std::max<unsigned>(peak,external.size());
            longest_burst=std::max(longest_burst,++burst);
        } else burst=0;
        for(unsigned c=0;c<2;++c) if((d.s_req_valid & d.s_req_ready)&(1u<<c)) {
            if(d.s_req_valid==3) require(c!=last_owner,"round robin starvation");
            last_owner=c;
            skid.push_back({c,{uint32_t(d.s_req_addr>>(32*c)),uint32_t(d.s_req_wdata>>(32*c)),
                uint64_t((d.s_req_wstrb>>(4*c))&0xf),uint64_t((d.s_req_write>>c)&1)},0});
            require(skid.size()<=1,"skid register accepted too many requests");
            ++sent[c];
        }
        d.clk=1; d.eval(); d.clk=0; d.eval();
        if(received==total) {
            d.s_req_valid=0; d.mem_rsp_valid=0; d.eval();
            require(d.idle && external.empty() && skid.empty(),"controller did not drain");
            require(peak>=std::min<unsigned>(MAX_MEM_OUTSTANDING,latency),"requests did not overlap");
            require(longest_burst>=std::min<unsigned>(MAX_MEM_OUTSTANDING,16),"mandatory request bubbles");
            std::cout<<"memory_controller passed: latency="<<latency<<" peak="<<peak
                     <<" longest_burst="<<longest_burst<<'\n';
            return;
        }
    }
    throw std::runtime_error("controller watchdog");
}

int main(int argc,char** argv) {
    Verilated::commandArgs(argc,argv);
    try { exercise(3); exercise(20); exercise(97); return 0; }
    catch(const std::exception& e) { std::cerr<<"controller test failed: "<<e.what()<<'\n'; return 1; }
}
