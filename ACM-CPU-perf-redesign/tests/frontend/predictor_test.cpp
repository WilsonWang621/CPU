#include "Vpredictor_test_top.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <array>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#ifndef PREDICTOR_MODE
#define PREDICTOR_MODE 2
#endif
#ifndef HISTORY_BITS
#define HISTORY_BITS 8
#endif
#ifndef BHT_ENTRIES
#define BHT_ENTRIES 64
#endif
static unsigned checks=0;
static void require(bool condition,const std::string& reason) {
 ++checks;if(!condition) throw std::runtime_error(reason);
}
static uint32_t jal(unsigned rd,int offset) {
 uint32_t x=offset;return ((x>>20)&1)<<31|((x>>1)&1023)<<21|((x>>11)&1)<<20|((x>>12)&255)<<12|rd<<7|0x6f;
}
static uint32_t branch(int offset) {
 uint32_t x=offset;return ((x>>12)&1)<<31|((x>>5)&63)<<25|((x>>1)&15)<<8|((x>>11)&1)<<7|0x63;
}
static uint32_t jalr(unsigned rd,unsigned rs,int offset=0) {
 return (uint32_t(offset)&4095)<<20|rs<<15|rd<<7|0x67;
}
struct Test {
 Vpredictor_test_top d;
 Test(){d.rst=1;tick();d.rst=0;d.query_count=4;d.eval();}
 void tick(){d.clk=0;d.eval();d.clk=1;d.eval();d.clk=0;d.eval();}
 void query(uint32_t pc,unsigned count=4){d.query_pc=pc;d.query_count=count;d.eval();}
 void advance(){d.advance=1;tick();d.advance=0;d.eval();}
 void train(uint32_t pc,uint32_t inst,uint32_t target,bool taken=true,uint16_t history=0,bool bimodal=false,bool gshare=false){
  d.train_valid=1;d.train_pc[0]=pc;d.train_inst[0]=inst;d.train_next_pc[0]=target;
  d.train_taken=taken;d.train_history=history;d.train_bimodal_taken=bimodal;d.train_gshare_taken=gshare;
  tick();d.train_valid=0;d.eval();
 }
 unsigned count(unsigned lane=0){return (d.ras_count>>(5*lane))&31;}
 uint16_t history(unsigned lane=0){return d.history>>(16*lane);}
 void replay(uint16_t h,unsigned count,uint32_t top,uint32_t older=0){
  d.redirect_valid=1;d.redirect_inst=0;d.redirect_history=h;d.redirect_ras_count=count;
  for(unsigned n=0;n<16;n++)d.redirect_ras_snapshot[n]=0;
  d.redirect_ras_snapshot[0]=top;d.redirect_ras_snapshot[1]=older;
  tick();d.redirect_valid=0;d.eval();
 }
};
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);
 try {
  {
   Test t;t.query(12);
   require(t.d.predicted_count==4&&t.d.next_pc==28,"cold sequential packet");
   for(unsigned n=0;n<4;n++)require(t.d.prediction[n]==16+4*n&&t.history(n)==0&&t.count(n)==0,"cold snapshots");
   t.advance();t.query(64);require(t.history()==0,"commit-free sequential history");
  }
  {
   Test t;
   // Four simultaneous taken branches alias both direction counters.
   t.d.train_valid=15;t.d.train_taken=15;t.d.train_history=0;
   for(unsigned n=0;n<4;n++){
    t.d.train_pc[n]=0;t.d.train_inst[n]=branch(64);t.d.train_next_pc[n]=64;
   }
   t.tick();t.d.train_valid=0;t.query(0);
   require(t.d.predicted_count==1&&t.d.prediction[0]==64,"aliased training target");
   t.train(0,branch(64),4,false,0);t.query(0);
   require(t.d.predicted_taken==1,"four increments folded before one decrement");
   t.train(0,branch(64),4,false,0);t.query(0);
   require(!(t.d.predicted_taken&1),"saturating counter decrements");
   for(unsigned n=0;n<4;n++)t.train(4*n,branch(64),4*n+4,false,0);
   // Restore arbitrary speculative history; each known conditional folds the
   // previous lane's not-taken result into the next lane's saved history.
   t.replay(1,0,0);t.query(0);
   require(t.d.predicted_count==4,"four not-taken conditional predictions");
   for(unsigned n=0;n<4;n++)require(t.history(n)==(1u<<n),"per-lane pre-branch history");
   t.advance();t.query(128);require(t.history()==16,"speculative history advances at request");
  }
  {
   Test t;
   for(unsigned n=0;n<3;n++)t.train(0,branch(64),64,true,0);
   t.replay(1,0,0);t.query(0,1);
   require(t.d.bimodal_taken==1&&t.d.gshare_taken==0,"fetch-time component disagreement");
   require(bool(t.d.predicted_taken)==(PREDICTOR_MODE!=1),"chooser resets strongly bimodal");
   // Intervening updates make both current components agree. Retirement must
   // still train from the earlier captured disagreement supplied below.
   for(unsigned n=0;n<2;n++)t.train(0,branch(64),64,true,1);
   t.query(0,1);require(t.d.bimodal_taken==1&&t.d.gshare_taken==1,"tables changed after original fetch");
   t.d.train_valid=15;t.d.train_taken=0;t.d.train_bimodal_taken=15;t.d.train_gshare_taken=0;
   t.d.train_history=0;
   for(unsigned n=0;n<4;n++){
    t.d.train_pc[n]=0;t.d.train_inst[n]=branch(64);t.d.train_next_pc[n]=4;
    t.d.train_history|=uint64_t(1)<<(16*n);
   }
   t.tick();t.d.train_valid=0;
   for(unsigned n=0;n<3;n++)t.train(0,branch(64),64,true,0);
   t.query(0,1);
   require(t.d.bimodal_taken==1&&t.d.gshare_taken==0,"recreate component disagreement");
   require(bool(t.d.predicted_taken)==(PREDICTOR_MODE==0),"four aliased chooser updates use saved votes");
   t.d.train_valid=15;t.d.train_taken=0;t.d.train_bimodal_taken=0;t.d.train_gshare_taken=15;
   t.tick();t.d.train_valid=0;
   for(unsigned n=0;n<3;n++)t.train(0,branch(64),64,true,0);
   t.query(0,1);
   require(bool(t.d.predicted_taken)==(PREDICTOR_MODE!=1),"four aliased chooser updates switch back to bimodal");
  }
  {
   Test t;t.train(0,jal(1,64),64);t.train(64,jal(5,64),128);t.train(128,jalr(0,5),0x9990);
   t.train(68,jalr(0,1),0x8880);
   t.query(0);require(t.d.prediction[0]==64&&t.count()==0,"call pre-snapshot");t.advance();
   t.query(64);require(t.count()==1&&t.d.ras[0]==4,"speculative call pushes before commit");t.advance();
   t.query(128);require(t.count()==2&&t.d.ras[0]==68&&t.d.ras[1]==4,"nested speculative calls");
   require(t.d.prediction[0]==68,"return prediction uses speculative RAS");t.advance();
   t.query(68);require(t.count()==1&&t.d.prediction[0]==4,"nested return pops");t.advance();
   t.query(256);require(t.count()==0,"return stack empty after two returns");
  }
  {
   Test t;
   for(unsigned n=0;n<5;n++){t.train(4*n,jal(1,4),4*n+4);t.query(4*n,1);t.advance();}
   t.query(128);require(t.count()==4,"RAS saturates depth");
   for(unsigned n=0;n<4;n++)require(t.d.ras[n]==20-4*n,"RAS overflow discards oldest");
   t.train(128,jalr(5,1),0x7770);t.query(128,1);
   require(t.d.prediction[0]==20,"coroutine predicts old top before pop/push");t.advance();
   t.query(192);require(t.count()==4&&t.d.ras[0]==132&&t.d.ras[1]==16,"coroutine replaces top");
   t.replay(0x1234,2,0x100,0x200);t.query(192);
   require(t.history()==0x1234&&t.count()==2&&t.d.ras[0]==0x100&&t.d.ras[1]==0x200,"load replay restores exact snapshot");
   t.d.redirect_valid=1;t.d.redirect_inst=branch(16);t.d.redirect_taken=1;t.tick();t.d.redirect_valid=0;t.query(192);
   require(t.history()==0x2469&&t.count()==2,"redirect applies actual branch history once");
   t.d.redirect_valid=1;t.d.redirect_inst=jal(1,64);t.d.redirect_branch_pc=256;t.tick();t.d.redirect_valid=0;t.query(192);
   require(t.history()==0x1234&&t.count()==3&&t.d.ras[0]==260&&t.d.ras[1]==0x100,"redirect restores then applies actual call");
   t.d.redirect_valid=1;t.d.redirect_inst=jalr(5,1,-1);t.d.redirect_branch_pc=512;t.tick();t.d.redirect_valid=0;t.query(192);
   require(t.history()==0x1234&&t.count()==2&&t.d.ras[0]==516&&t.d.ras[1]==0x200,"redirect restores then applies actual coroutine hints");
  }
  {
   Test t;
   t.train(0,jalr(0,2),0x87654321);t.query(0,1);
   require(t.d.predicted_taken==1&&t.d.next_pc==0x87654321,"BTB preserves all target bits");
   for(uint32_t pc:{1u,2u,3u}){
    t.query(pc,1);require(t.d.predicted_taken==0&&t.d.next_pc==pc+4,"unaligned query cannot alias omitted PC bits");
   }
   t.train(256,jalr(0,2),0x12345679);t.query(0,1);
   require(t.d.predicted_taken==0&&t.d.next_pc==4,"same-index different high tag misses");
   t.query(256,1);require(t.d.predicted_taken==1&&t.d.next_pc==0x12345679,"replacement high tag hits");
   t.train(0x80000100,jalr(0,2),0x11111111);t.query(256,1);
   require(t.d.predicted_taken==0,"high address bit participates in compact tag");
   t.query(0x80000100,1);require(t.d.predicted_taken==1&&t.d.next_pc==0x11111111,"full high-address tag match");
  }
  {
   Test t;
   // All register-hint combinations, signed immediate edges, and empty/nonempty
   // stacks check the 15-bit BTB metadata against instruction-level semantics.
   for(unsigned rd=0;rd<32;rd++)for(unsigned rs=0;rs<32;rs++)
    for(int offset:{-2048,-1,0,1,2047})for(unsigned depth:{0u,2u}){
     const bool rd_link=rd==1||rd==5,rs_link=rs==1||rs==5;
     const bool pop=rs_link&&(!rd_link||rd!=rs),push=rd_link;
     const uint32_t top=depth?0x80000801:0,older=depth?0x01020304:0;
     t.train(64,jalr(rd,rs,offset),0x87654321);
     t.replay(0x5a5a,depth,top,older);t.query(64,1);
     const uint32_t target=pop&&depth?(top+uint32_t(offset))&~1u:0x87654321;
     require(t.d.predicted_taken==1&&t.d.next_pc==target,"JALR metadata target and signed return offset");
     require(t.count()==depth&&t.d.ras[0]==top,"JALR snapshot precedes hint effects");
     t.advance();t.query(256,1);
     unsigned expected_depth=depth-(pop&&depth?1:0)+(push?1:0);
     uint32_t expected_top=push?68:pop&&depth?older:top;
     require(t.count()==expected_depth&&t.d.ras[0]==expected_top,"JALR pop/push/coroutine metadata effects");
     require(t.history()==0x5a5a,"JALR does not alter conditional history");
    }
  }
  {
   Test t;std::mt19937 random(0x260925);
   std::array<unsigned,BHT_ENTRIES> bimodal{},gshare{},chooser{};
   bimodal.fill(1);gshare.fill(1);chooser.fill(0);
   std::array<bool,64> valid{};std::array<uint32_t,64> tags{};
   const unsigned history_mask=(1u<<HISTORY_BITS)-1;
   auto update=[](unsigned counter,bool taken){return taken?std::min(3u,counter+1):(counter?counter-1:0);};
   for(unsigned step=0;step<5000;step++){
    t.d.train_valid=random()&15;t.d.train_taken=random()&15;
    t.d.train_bimodal_taken=random()&15;t.d.train_gshare_taken=random()&15;t.d.train_history=0;
    for(unsigned lane=0;lane<4;lane++){
     uint32_t pc=4*(random()%128);unsigned history=random()&65535;
     t.d.train_pc[lane]=pc;t.d.train_inst[lane]=branch(64);
     t.d.train_next_pc[lane]=(t.d.train_taken&(1u<<lane))?pc+64:pc+4;
     t.d.train_history|=uint64_t(history)<<(16*lane);
     if(t.d.train_valid&(1u<<lane)){
      unsigned bi=(pc>>2)&(BHT_ENTRIES-1),gi=((pc>>2)^(history&history_mask))&(BHT_ENTRIES-1);
      bool outcome=t.d.train_taken&(1u<<lane),old_b=t.d.train_bimodal_taken&(1u<<lane),old_g=t.d.train_gshare_taken&(1u<<lane);
      if(old_b!=old_g)chooser[bi]=update(chooser[bi],old_g==outcome);
      bimodal[bi]=update(bimodal[bi],outcome);gshare[gi]=update(gshare[gi],outcome);
      valid[(pc>>2)&63]=true;tags[(pc>>2)&63]=pc;
     }
    }
    t.tick();t.d.train_valid=0;
    unsigned history=random()&65535;uint32_t pc=4*(random()%128);
    t.replay(history,0,0);t.query(pc,1);
    unsigned bi=(pc>>2)&(BHT_ENTRIES-1),gi=((pc>>2)^(history&history_mask))&(BHT_ENTRIES-1);
    bool b=bimodal[bi]>=2,g=gshare[gi]>=2;
    bool vote=PREDICTOR_MODE==0?b:PREDICTOR_MODE==1?g:chooser[bi]>=2?g:b;
    bool taken=valid[(pc>>2)&63]&&tags[(pc>>2)&63]==pc&&vote;
    require(t.d.bimodal_taken==unsigned(b),"random bimodal folding/reference");
    require(t.d.gshare_taken==unsigned(g),"random masked gshare folding/reference");
    require(t.d.predicted_taken==unsigned(taken)&&t.d.next_pc==(taken?pc+64:pc+4),"random chooser captured-vote/reference");
   }
  }

  {
   Test t;
   for(unsigned round=0;round<2;round++){
    for(unsigned entry=0;entry<BHT_ENTRIES;entry++)
     for(unsigned n=0;n<3;n++)t.train(4*entry,branch(64),4*entry+64,true,0,false,true);
    t.d.train_valid=15;t.d.train_taken=15;t.d.advance=1;t.d.redirect_valid=1;
    t.d.redirect_inst=branch(64);t.d.redirect_taken=1;t.d.rst=1;
    for(unsigned n=0;n<3;n++)t.tick();
    t.d.rst=0;t.d.advance=0;t.d.redirect_valid=0;t.d.train_valid=0;
    for(unsigned entry=0;entry<BHT_ENTRIES;entry++){
     t.query(4*entry,1);
     require(t.d.bimodal_taken==0&&t.d.gshare_taken==0,"reset masks stale direction words");
     require(t.d.predicted_taken==0&&t.d.next_pc==4*entry+4,"reset invalidates BTB words");
     require(t.history()==0&&t.count()==0,"reset dominates redirect and advance");
     t.tick();
    }
    t.train(4,branch(64),8,false,0);t.query(4,1);
    require(t.d.bimodal_taken==0&&t.d.gshare_taken==0,"first post-reset fold starts from 01");
    t.train(0,branch(64),64,true,1,false,false);t.train(0,branch(64),64,true,1,false,false);
    t.query(0,1);
    require(t.d.bimodal_taken==1&&t.d.gshare_taken==0,"post-reset component disagreement");
    require(bool(t.d.predicted_taken)==(PREDICTOR_MODE!=1),"first post-reset chooser fold starts from 00");
    t.d.train_valid=15;t.d.train_taken=15;t.d.train_history=0;
    t.d.train_bimodal_taken=0;t.d.train_gshare_taken=0;
    for(unsigned lane=0;lane<4;lane++){
     t.d.train_pc[lane]=8;t.d.train_inst[lane]=branch(64);t.d.train_next_pc[lane]=72;
    }
    t.tick();t.d.train_valid=0;t.train(8,branch(64),12,false,0);t.query(8,1);
    require(t.d.bimodal_taken==1&&t.d.gshare_taken==1,"post-reset four-lane aliases saturate in order");
   }
  }
  std::cout<<"PREDICTOR PASS mode="<<PREDICTOR_MODE<<" history="<<HISTORY_BITS<<" entries="<<BHT_ENTRIES
           <<": aliased four-lane updates, captured votes, snapshots, speculative RAS ("<<checks<<" checks)\n";
 }catch(const std::exception&e){std::cerr<<"PREDICTOR FAIL: "<<e.what()<<"\n";return 1;}
}
