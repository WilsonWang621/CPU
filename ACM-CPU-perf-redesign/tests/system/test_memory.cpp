#include "../../sim/memory_model.h"
#include <iostream>
#include <stdexcept>

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
int main() {
    try {
        std::vector<uint8_t> ram(4096, 0);
        for (unsigned n=0;n<100;++n) ram[4*n]=n;
        OrderedMemory stream(ram, 64);
        unsigned accepted=0, completed=0;
        for (uint64_t cycle=0;cycle<120;++cycle) {
            const auto response=stream.response(cycle);
            require(bool(response)==(cycle>=20),"fixed-latency response missing or early");
            if (response) {
                require(response->data==completed && !response->error,"responses reordered");
                stream.complete();++completed;
            }
            if (cycle<100) {
                require(stream.can_accept(),"II1 request stream stalled");
                stream.accept(BusRequest{4*accepted,0,0,false},cycle+20,false);++accepted;
            }
        }
        require(completed==100 && stream.empty(),"pipeline failed to drain");

        ram.assign(4096,0);
        OrderedMemory mixed(ram,8);
        mixed.accept({0,0x11223344,15,true},20,false);
        mixed.accept({0,0,0,false},21,false);
        mixed.accept({0,0x0000ab00,2,true},22,false);
        mixed.accept({0,0,0,false},23,false);
        mixed.accept({0,0xffffffff,15,true},24,true);
        mixed.accept({0,0,0,false},25,false);
        require(!mixed.response(19) && ram[0]==0,"write visible before completion");
        require(bool(mixed.response(20)),"write response missing");mixed.complete();
        require(mixed.response(21)->data==0x11223344,"read bypassed older write");mixed.complete();
        mixed.response(22);mixed.complete();
        for(unsigned cycle=23;cycle<=30;++cycle)
            require(mixed.response(cycle)->data==0x1122ab44,"held read changed or younger write passed it");
        mixed.complete();
        require(mixed.response(31)->error,"write error lost");mixed.complete();
        require(mixed.response(32)->data==0x1122ab44,"failed write modified RAM");mixed.complete();
        require(mixed.empty(),"mixed transactions failed to drain");

        OrderedMemory reordered_due(ram,2);
        reordered_due.accept({0,0,0,false},30,false);
        reordered_due.accept({4,0,0,false},1,false);
        require(!reordered_due.response(29),"younger request bypassed older delayed response");
        bool rejected=false;
        try {reordered_due.accept({8,0,0,false},2,false);} catch(const std::runtime_error &) {rejected=true;}
        require(rejected,"outstanding capacity not enforced");
        reordered_due.response(30);reordered_due.complete();
        require(bool(reordered_due.response(31)),"younger ready response did not follow");
        reordered_due.complete();

        OrderedMemory one(ram,1);
        one.accept({0,0,0,false},1,false);
        for(unsigned cycle=1;cycle<10;++cycle) {
            require(bool(one.response(cycle)),"capacity-one response missing");
            one.complete();
            one.accept({0,0,0,false},cycle+1,false);
        }
        std::cout<<"PASS ordered pipelined RAM: II1, exact latency20, RAW, byte writes, held responses, errors, capacity\n";
        return 0;
    } catch(const std::exception &error) {
        std::cerr<<"FAIL memory model: "<<error.what()<<'\n';return 1;
    }
}
