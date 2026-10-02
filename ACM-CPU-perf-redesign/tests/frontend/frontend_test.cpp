#include "Vfrontend_test_top.h"
#include "verilated.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <functional>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>
#ifndef FETCH_WIDTH
#define FETCH_WIDTH 4
#endif
#ifndef FETCH_REQUESTS
#define FETCH_REQUESTS 16
#endif
#ifndef LINE_BYTES
#define LINE_BYTES 32
#endif
#ifndef PREDICTOR_MODE
#define PREDICTOR_MODE 2
#endif
static uint64_t checks=0;
static void require(bool condition,const std::string& reason) {
 ++checks;if(!condition)throw std::runtime_error(reason);
}
static uint32_t jal(unsigned rd,int offset) {
 uint32_t x=offset;return ((x>>20)&1)<<31|((x>>1)&1023)<<21|((x>>11)&1)<<20|((x>>12)&255)<<12|rd<<7|0x6f;
}
static uint32_t jump_target(uint32_t pc,uint32_t word) {
 uint32_t offset=((word>>31)<<20)|(word&0xff000)|(((word>>20)&1)<<11)|(((word>>21)&1023)<<1);
 return pc+((offset^0x100000)-0x100000);
}
struct Request {uint32_t pc;unsigned count,tag,due;uint8_t error_mask;};
struct Test {
 Vfrontend_test_top d;
 std::mt19937 rng{0x260921};
 std::vector<Request> pending;
 std::array<bool,256> active{};
 std::function<uint32_t(uint32_t)> memory=[](uint32_t pc){return (((pc>>2)&4095)<<20)|(10<<7)|0x13;};
 std::function<unsigned(uint32_t)> delay=[](uint32_t){return 1;};
 std::function<bool(uint32_t)> error=[](uint32_t){return false;};
 std::function<uint8_t(uint32_t,unsigned)> error_mask=[](uint32_t,unsigned){return 0;};
 std::function<void(const Request&)> accepted=[](const Request&){};
 std::function<void(unsigned)> consumed;
 unsigned cycle=0,requests=0,responses=0,instructions=0,max_inflight=0;
 unsigned history_expected=0,ras_depth_expected=0,ras_top_expected=0;
 uint32_t next=0;
 bool check_snapshots=true,held=false;
 uint32_t held_pc=0;unsigned held_count=0,held_tag=0;
 Test(){
  d.rst=1;edge();d.rst=0;d.eval();
  consumed=[this](unsigned lane){
   uint32_t pc=d.out_pc[lane],word=d.out_inst[lane];
   require(pc==next,"ordered current-path PC got="+std::to_string(pc)+" want="+std::to_string(next));
   require((d.out_inst_valid&(1u<<lane))&&!(d.out_fault>>(4*lane)&15),"unexpected instruction fault");
   require(word==memory(pc),"tagged response instruction matches address");
   if(check_snapshots){
    require((d.out_history>>(16*lane)&65535)==history_expected,"saved pre-instruction history");
    require((d.out_ras_count>>(5*lane)&31)==ras_depth_expected,"saved pre-instruction RAS depth");
    if(ras_depth_expected)require(d.out_ras[16*lane]==ras_top_expected,"saved pre-instruction RAS top");
   }
   next=word%128==0x6f?jump_target(pc,word):pc+4;
   require(d.out_prediction[lane]==next,"packet prediction and cold JAL repair");
   if(word%128==0x6f&&(((word>>7)&31)==1||((word>>7)&31)==5)){
    ras_depth_expected=std::min(16u,ras_depth_expected+1);ras_top_expected=pc+4;
   }
   ++instructions;
  };
 }
 void edge(){d.clk=0;d.eval();d.clk=1;d.eval();d.clk=0;d.eval();}
 unsigned step(bool request_ready=true,unsigned pop_limit=4,bool unordered=false){
  d.req_ready=request_ready;d.rsp_valid=0;d.rsp_error=0;d.rsp_error_mask=0;d.pop_count=0;
  std::vector<unsigned> eligible;
  for(unsigned n=0;n<pending.size();n++)if(pending[n].due<=cycle)eligible.push_back(n);
  int response=-1;
  if(!eligible.empty()){
   response=eligible[unordered?rng()%eligible.size():0];const auto&p=pending[response];
   d.rsp_valid=1;d.rsp_tag=p.tag;d.rsp_error=p.error_mask!=0;d.rsp_error_mask=p.error_mask;
   for(unsigned n=0;n<4;n++)d.rsp_data[n]=memory(p.pc+4*n);
  }
  d.eval();
  if(held)require(d.req_valid&&d.req_addr==held_pc&&d.req_count==held_count&&d.req_tag==held_tag,"request stable through backpressure/redirect");
  unsigned popped=0;
  if(!d.stop&&!d.redirect_valid){
   while(popped<pop_limit&&(d.out_valid&(1u<<popped))){consumed(popped);++popped;}
   d.pop_count=popped;
  }
  bool request=d.req_valid&&d.req_ready,response_transfer=d.rsp_valid&&d.rsp_ready;
  Request accepted_request{};
  if(request){
   accepted_request={d.req_addr,d.req_count,d.req_tag,cycle+delay(d.req_addr),
     uint8_t(error_mask(d.req_addr,d.req_count)|(error(d.req_addr)?1:0))};
   require(d.req_count>=1&&d.req_count<=FETCH_WIDTH,"legal fetch word count");
   require(!(d.req_addr&3)&&d.req_addr+4*d.req_count<=262144,"legal RAM fetch address");
   require((d.req_addr%LINE_BYTES)+4*d.req_count<=LINE_BYTES,"packet stays inside cache line");
   require(!active[d.req_tag],"tag not reused before response drains");
  }
  held=d.req_valid&&!d.req_ready;held_pc=d.req_addr;held_count=d.req_count;held_tag=d.req_tag;
  edge();
  if(response_transfer){active[pending[response].tag]=false;pending.erase(pending.begin()+response);++responses;}
  if(request){pending.push_back(accepted_request);active[accepted_request.tag]=true;++requests;accepted(accepted_request);}
  max_inflight=std::max(max_inflight,unsigned(pending.size()));++cycle;
  return popped;
 }
 void redirect(uint32_t pc,unsigned history=0,unsigned depth=0,uint32_t top=0,bool ready=true){
  d.redirect_valid=1;d.redirect_pc=pc;d.redirect_inst=0;d.redirect_history=history;
  d.redirect_ras_count=depth;
  for(unsigned n=0;n<16;n++)d.redirect_ras_snapshot[n]=0;
  d.redirect_ras_snapshot[0]=top;
  next=pc;history_expected=history;ras_depth_expected=depth;ras_top_expected=top;
  step(ready);d.redirect_valid=0;d.eval();
 }
 void drain(){
  d.stop=1;
  for(unsigned n=0;n<1000;n++){step(true,0,true);if(d.idle&&pending.empty()){require(requests==responses,"request response conservation");return;}}
  throw std::runtime_error("frontend failed to drain canceled requests");
 }
};
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{
  {
   Test t;
   for(unsigned n=0;n<150;n++){
    unsigned count=t.step();
    if(n>10)require(count==FETCH_WIDTH,"warm stream sustains fetch width every cycle");
   }
   t.drain();
  }
  {
   // Capture B=Taken/G=NotTaken in a delayed fetch, then reverse the table
   // counters before the response. Packet metadata must retain the old votes.
   Test t;t.memory=[](uint32_t pc){return pc==0?0x04000063:0x13;};
   t.delay=[](uint32_t){return 12;};t.d.stop=1;
   t.d.train_valid=1;t.d.train_pc[0]=0;t.d.train_inst[0]=0x04000063;
   t.d.train_next_pc[0]=64;t.d.train_taken=1;t.d.train_history=0;
   for(unsigned n=0;n<3;n++)t.step();
   t.d.train_valid=0;t.d.stop=0;t.redirect(0,1);
   bool fetched=false,observed=false;
   t.accepted=[&](const Request&request){if(request.pc==0)fetched=true;};
   auto normal=t.consumed;
   t.consumed=[&](unsigned lane){
    if(t.d.out_pc[lane]==0){
     require(!observed&&t.d.out_inst[lane]==0x04000063,"delayed conditional fetch");
     require(bool(t.d.out_bimodal_taken&(1u<<lane))&&!bool(t.d.out_gshare_taken&(1u<<lane)),"saved fetch-time component votes survive table changes");
     bool direction=PREDICTOR_MODE!=1;
     require(bool(t.d.out_taken&(1u<<lane))==direction,"recorded tournament direction");
     require((t.d.out_history>>(16*lane)&65535)==1,"recorded pre-branch history");
     t.next=direction?64:4;t.history_expected=direction?3:2;++t.instructions;observed=true;
    }else normal(lane);
   };
   for(unsigned n=0;n<20&&!fetched;n++)t.step();
   require(fetched,"conditional request captured before training changes");
   t.d.train_valid=1;t.d.train_taken=0;t.d.train_history=1;
   t.d.train_bimodal_taken=1;t.d.train_gshare_taken=0;
   for(unsigned n=0;n<3;n++)t.step();
   t.d.train_valid=0;
   for(unsigned n=0;n<100;n++)t.step();
   require(observed,"captured component metadata delivered");t.drain();
  }
  {
   Test t;t.delay=[&](uint32_t){return 1+t.rng()%23;};
   for(unsigned n=0;n<6000;n++){
    if(n%61==0)t.redirect(4*(t.rng()%60000),t.rng()&65535,1+t.rng()%16,t.rng(),t.rng()%4!=0);
    t.step(t.rng()%4!=0,t.rng()%5,true);
   }
   require(t.instructions>(FETCH_REQUESTS>=4?1000u:200u)&&t.max_inflight>=2,
           "random backpressure and multiple outstanding coverage");
   t.drain();
  }
  {
   Test t;t.delay=[](uint32_t pc){return pc==0?100:2;};
   t.error_mask=[](uint32_t pc,unsigned count){return uint8_t(pc==0?1u<<std::min(count-1,2u):0);};
   bool new_path_before_old_response=false;
   t.accepted=[&](const Request&r){if(r.pc>=128&&t.cycle<100)new_path_before_old_response=true;};
   t.step();t.step(false,0);t.redirect(128,0x1357,2,0x1234,false);
   for(unsigned n=0;n<180;n++)t.step(true,4,true);
   require(new_path_before_old_response,"new path issues before canceled old error response");
   t.drain();
  }
  {
   Test t;t.memory=[](uint32_t pc){return pc==8?jal(1,56):pc==68?jal(5,60):0x13;};
   t.delay=[&](uint32_t){return 1+t.rng()%12;};
   for(unsigned n=0;n<300;n++)t.step(true,4,true);
   require(t.ras_depth_expected==2,"two cold direct calls update speculative RAS");t.drain();
  }
  {
   Test t;t.error=[](uint32_t pc){return pc==16;};unsigned faults=0;
   auto normal=t.consumed;
   t.consumed=[&](unsigned lane){
    if(t.d.out_fault>>(4*lane)&15){
     require(t.next==16&&t.d.out_pc[lane]==16&&!(t.d.out_inst_valid&(1u<<lane)),"ordered bus fault record");
     require((t.d.out_fault>>(4*lane)&15)==4,"fetch bus fault cause");++faults;
    }else normal(lane);
   };
   for(unsigned n=0;n<180;n++)t.step(true,4,true);
   require(faults==1&&t.d.idle,"one bus fault blocks younger fetch");
   t.consumed=normal;t.redirect(256);for(unsigned n=0;n<30;n++)t.step();t.drain();
  }
  for(uint32_t bad_pc:{4u,8u}){
   Test t;unsigned words=0,faults=0;
   t.error_mask=[bad_pc](uint32_t pc,unsigned count){
    return uint8_t(bad_pc>=pc&&bad_pc<pc+4*count?1u<<((bad_pc-pc)/4):0);
   };
   t.consumed=[&](unsigned lane){
    if(t.d.out_inst_valid&(1u<<lane)){
     require(t.d.out_pc[lane]==4*words&&t.d.out_pc[lane]<bad_pc,"valid prefix before failed word");
     require(t.d.out_inst[lane]==t.memory(4*words),"valid prefix instruction preserved");++words;
    }else{
     require(words==bad_pc/4&&t.d.out_pc[lane]==bad_pc,"fault attributed to first failed instruction");
     require((t.d.out_fault>>(4*lane)&15)==4&&t.d.out_fault_addr[lane]==bad_pc,"per-word bus fault metadata");++faults;
    }
   };
   for(unsigned n=0;n<100;n++)t.step();
   require(words==bad_pc/4&&faults==1,"valid prefix then exactly one masked fault");t.drain();
  }
  {
   Test t;t.memory=[](uint32_t pc){return pc==0?jal(1,64):0x13;};
   t.error_mask=[](uint32_t pc,unsigned count){return uint8_t(pc<=4&&4<pc+4*count?1u<<((4-pc)/4):0);};
   for(unsigned n=0;n<100;n++)t.step();
   require(t.instructions>50&&t.ras_depth_expected==1,"cold JAL skips failed second word");t.drain();
  }
  {
   Test t;t.memory=[](uint32_t pc){return pc==0?0x04000063:0x13;};
   t.error_mask=[](uint32_t pc,unsigned count){return uint8_t(pc<=4&&4<pc+4*count?1u<<((4-pc)/4):0);};
   for(unsigned n=0;n<20&&t.instructions==0;n++)t.step(true,1);
   require(t.instructions==1&&t.next==4,"conditional branch delivered before later word fault");
   t.d.redirect_valid=1;t.d.redirect_pc=64;t.d.redirect_branch_pc=0;t.d.redirect_inst=0x04000063;
   t.d.redirect_history=0;t.d.redirect_taken=1;t.next=64;t.history_expected=1;
   t.step();t.d.redirect_valid=0;t.d.eval();
   for(unsigned n=0;n<100;n++)t.step();
   require(t.instructions>50,"resolved taken branch cancels younger masked fault");t.drain();
  }
  {
   Test t;unsigned faults=0,words=0;t.delay=[](uint32_t){return 30;};
   t.consumed=[&](unsigned lane){
    if(t.d.out_inst_valid&(1u<<lane)){require(t.d.out_pc[lane]==262140&&!words,"last RAM word before range fault");++words;}
    else{require(words==1&&t.d.out_pc[lane]==262144&&(t.d.out_fault>>(4*lane)&15)==3,"ordered local fetch range fault");++faults;}
   };
   t.redirect(262140);for(unsigned n=0;n<100;n++)t.step();
   require(words==1&&faults==1,"last RAM word and one fault");t.drain();
  }
  {
   Test t;unsigned faults=0;t.consumed=[&](unsigned lane){
    require(t.d.out_pc[lane]==2&&!(t.d.out_inst_valid&(1u<<lane))&&(t.d.out_fault>>(4*lane)&15)==2,"fetch alignment fault");++faults;
   };
   t.redirect(2);for(unsigned n=0;n<20;n++)t.step();
   require(t.requests==0&&faults==1,"misaligned PC never sends cache request");t.drain();
  }
  std::cout<<"FRONTEND PASS width="<<FETCH_WIDTH<<": full-rate fetch, ordered tagged responses, cancellation, snapshots, cold JAL, precise faults ("<<checks<<" checks)\n";
 }catch(const std::exception&e){std::cerr<<"FRONTEND FAIL width="<<FETCH_WIDTH<<": "<<e.what()<<"\n";return 1;}
}
