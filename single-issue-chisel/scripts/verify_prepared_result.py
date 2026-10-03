#!/usr/bin/env python3
"""Validate prepared ROB results against legacy RTL and an independent oracle."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT.parent / "scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool, executable

CPP = r'''
#include "VPreparedResultHarness.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

constexpr unsigned Rows=32,Banks=4;
constexpr unsigned Free=0,Exec=1,Mdu=2,Load=3;
struct Owner { bool valid=false,dead=false,prefetch=false; unsigned tag=0; };
struct Stim {
  uint32_t allocate=0,squashMask=0;
  bool exe=false,md=false,squash=false,reset=false;
  unsigned exeTag=0,mdTag=0,offer=0,prefetch=0,respond=0,consume=0;
  std::array<unsigned,Banks> tags{};
  std::array<unsigned,Rows> kind{};
};
int main(int argc,char** argv) {
  Verilated::commandArgs(argc,argv);
  const unsigned slice=std::stoul(argv[1]);
  VPreparedResultHarness dut;
  std::mt19937_64 rng(0x4009416ULL+slice);
  std::array<Owner,Banks> owners{};
  std::array<bool,Rows> done{};
  std::array<uint32_t,Rows> score{};
  std::array<unsigned,Rows> kind{};
  std::array<unsigned,Rows> loadCoverage{},exeCoverage{},mdCoverage{},reuseCoverage{};
  uint64_t cycles=0,checked=0,loads=0,executions=0,mdu=0,pendingGarbage=0;
  uint64_t multiProducer=0,deadDrain=0,prefetchDrain=0,squashes=0,reuses=0,retainedFreeze=0;
  auto pending=[&](unsigned b) { return owners[b].valid && !owners[b].dead && !owners[b].prefetch; };
  auto fail=[&](const std::string& reason) {
    throw std::runtime_error(reason+" at cycle "+std::to_string(cycles)+", slice "+std::to_string(slice));
  };
  auto checkOwners=[&]() {
    unsigned valid=0,dead=0,pend=0;
    for(unsigned b=0;b<Banks;b++) {
      valid|=unsigned(owners[b].valid)<<b; dead|=unsigned(owners[b].dead)<<b;
      pend|=unsigned(pending(b))<<b;
    }
    if(dut.owner_valid!=valid || dut.owner_dead!=dead || dut.owner_pending!=pend)
      fail("independent CacheOwner state mismatch");
  };
  auto checkWords=[&]() {
    uint32_t mask=0;
    for(unsigned i=0;i<Rows;i++) {
      if(done[i]) {
        mask|=uint32_t(1)<<i;
        if(dut.values[i]!=score[i]) fail("published word mismatch at ROB row "+std::to_string(i));
        checked++;
      }
    }
    if(dut.finalized!=mask) fail("independent finalized mask mismatch");
  };
  auto tick=[&](const Stim& s=Stim{}) {
    const uint32_t exeData=uint32_t(rng()),mdData=uint32_t(rng()),loadData=uint32_t(rng());
    dut.clock=0; dut.reset=s.reset; dut.allocate=s.allocate;
    dut.exe_valid=s.exe; dut.exe_tag=s.exeTag; dut.exe_data=exeData;
    dut.md_valid=s.md; dut.md_tag=s.mdTag; dut.md_data=mdData; dut.load_data=loadData;
    dut.offer=s.offer; dut.offer_prefetch=s.prefetch; dut.offer_tags=0;
    for(unsigned b=0;b<Banks;b++) dut.offer_tags|=s.tags[b]<<(5*b);
    dut.respond=s.respond; dut.consume=s.consume;
    dut.squash=s.squash; dut.squash_mask=s.squashMask;
    dut.eval();
    uint32_t completions=0;
    std::array<bool,Rows> newDone=done;
    std::array<uint32_t,Rows> newScore=score;
    std::array<unsigned,Rows> newKind=kind;
    auto complete=[&](unsigned tag,uint32_t value,unsigned producer) {
      if(s.squash && (s.squashMask&(uint32_t(1)<<tag))) return;
      if(done[tag]) fail("driver completed an already finalized row");
      if(completions&(uint32_t(1)<<tag)) fail("driver supplied two actual producers for a row");
      completions|=uint32_t(1)<<tag; newDone[tag]=true; newScore[tag]=value; newKind[tag]=Free;
      if(producer==Load) { loads++; loadCoverage[tag]++; }
      if(producer==Exec) { executions++; exeCoverage[tag]++; }
      if(producer==Mdu) { mdu++; mdCoverage[tag]++; }
    };
    if(!s.reset) {
      checkOwners(); checkWords();
      if(s.exe) complete(s.exeTag,exeData,Exec);
      if(s.md) complete(s.mdTag,mdData,Mdu);
      for(unsigned b=0;b<Banks;b++) {
        if(pending(b) && !done[owners[b].tag] && !(s.respond&(1<<b))) pendingGarbage++;
        if(pending(b) && done[owners[b].tag]) retainedFreeze++;
        if(s.respond&(1<<b)) {
          if(pending(b)) complete(owners[b].tag,loadData,Load);
          if(owners[b].valid && owners[b].dead) deadDrain++;
          if(owners[b].valid && owners[b].prefetch) prefetchDrain++;
        }
      }
      if(dut.completed!=completions) fail("independent completion mask mismatch");
      if(__builtin_popcount(completions)>1) multiProducer++;
      if(s.allocate&completions) fail("driver reused a completing row");
      for(unsigned i=0;i<Rows;i++) {
        const uint32_t bit=uint32_t(1)<<i;
        if(s.allocate&bit) {
          if(done[i]) { reuses++; reuseCoverage[i]++; }
          newDone[i]=false; newKind[i]=s.kind[i];
        }
        if(s.squash && (s.squashMask&bit)) { newDone[i]=false; newKind[i]=Free; }
      }
      if(s.squash) squashes++;
    }
    dut.clock=1; dut.eval();
    dut.clock=0; dut.eval();
    if(s.reset) {
      owners={}; done={}; score={}; kind={};
    } else {
      for(unsigned b=0;b<Banks;b++) {
        auto& owner=owners[b];
        if(s.squash && owner.valid && !owner.prefetch && (s.squashMask&(uint32_t(1)<<owner.tag))) owner.dead=true;
        if((s.consume&(1<<b)) || ((s.respond&(1<<b)) && owner.valid)) owner.valid=false;
        if(s.offer&(1<<b)) {
          owner.valid=true; owner.dead=false; owner.prefetch=s.prefetch&(1<<b); owner.tag=s.tags[b];
        }
      }
      done=newDone; score=newScore; kind=newKind;
    }
    checkOwners(); checkWords(); cycles++;
  };
  auto alloc=[&](Stim& s,unsigned row,unsigned producer) { s.allocate|=uint32_t(1)<<row; s.kind[row]=producer; };
  Stim reset; reset.reset=true; tick(reset);
  for(unsigned row=0;row<Rows;row++) {
    const unsigned bank=row%Banks,other=(bank+1)%Banks;
    const unsigned distract=(row+1)%Rows,exe=(row+2)%Rows,md=(row+3)%Rows;
    Stim start;
    alloc(start,row,Load); alloc(start,distract,Load); alloc(start,exe,Exec); alloc(start,md,Mdu);
    start.offer=(1<<bank)|(1<<other); start.tags[bank]=row; start.tags[other]=distract;
    tick(start);
    for(unsigned i=0;i<7;i++) tick();
    // A selected load's global data is garbage for the other pending row.
    // ALU and MDU simultaneously publish two independent rows.
    Stim finish; finish.respond=1<<bank; finish.exe=true; finish.exeTag=exe; finish.md=true; finish.mdTag=md;
    tick(finish);
    for(unsigned i=0;i<5;i++) tick();
    Stim distractDone; distractDone.respond=1<<other; tick(distractDone);
    // Retain an owner for a completed row with no selected response. This
    // deliberately stresses the finalized guard beyond normal core turnover.
    Stim retained; retained.offer=1<<bank; retained.tags[bank]=row; tick(retained);
    for(unsigned i=0;i<9;i++) tick();
    Stim drain; drain.consume=1<<bank; tick(drain);
    // Kill a pending owner, reuse its tag while the dead owner still drains,
    // and publish an ALU result that stale load data must never overwrite.
    Stim again; alloc(again,row,Load); again.offer=1<<bank; again.tags[bank]=row; tick(again);
    tick();
    Stim kill; kill.squash=true; kill.squashMask=uint32_t(1)<<row; tick(kill);
    Stim reuse; alloc(reuse,row,Exec); tick(reuse);
    Stim exeDone; exeDone.exe=true; exeDone.exeTag=row; tick(exeDone);
    for(unsigned i=0;i<7;i++) tick();
    Stim dead; dead.respond=1<<bank; tick(dead);
    // A prefetch owner with the same tag also cannot prepare/publish data.
    Stim pref; pref.offer=1<<bank; pref.prefetch=1<<bank; pref.tags[bank]=row; tick(pref);
    for(unsigned i=0;i<3;i++) tick();
    Stim prefDone; prefDone.respond=1<<bank; tick(prefDone);
    Stim mduAlloc; alloc(mduAlloc,row,Mdu); tick(mduAlloc);
    Stim mduDone; mduDone.md=true; mduDone.mdTag=row; tick(mduDone);
  }
  auto pick=[&](const std::vector<unsigned>& candidates) { return candidates[unsigned(rng()%candidates.size())]; };
  for(unsigned cycle=0;cycle<60000;cycle++) {
    Stim s;
    // Random demand/refill/dead/prefetch returns; a simultaneous offer can
    // replace a consumed bank owner at this same edge.
    std::vector<unsigned> occupied;
    for(unsigned b=0;b<Banks;b++) if(owners[b].valid) occupied.push_back(b);
    if(!occupied.empty() && rng()%3!=0) s.respond=1<<pick(occupied);
    uint32_t completing=0;
    for(unsigned b=0;b<Banks;b++) if((s.respond&(1<<b)) && pending(b)) completing|=uint32_t(1)<<owners[b].tag;
    for(unsigned producer:{Exec,Mdu}) {
      std::vector<unsigned> ready;
      for(unsigned i=0;i<Rows;i++) if(kind[i]==producer) ready.push_back(i);
      if(!ready.empty() && rng()%3!=0) {
        unsigned i=pick(ready); completing|=uint32_t(1)<<i;
        if(producer==Exec) { s.exe=true; s.exeTag=i; } else { s.md=true; s.mdTag=i; }
      }
    }
    if(rng()%17==0) {
      s.squash=true;
      for(unsigned i=0;i<Rows;i++) if(kind[i]!=Free && rng()%3==0) s.squashMask|=uint32_t(1)<<i;
    }
    std::vector<unsigned> freeRows;
    for(unsigned i=0;i<Rows;i++) if(kind[i]==Free && !(completing&(uint32_t(1)<<i))) freeRows.push_back(i);
    auto takeRow=[&]() {
      const unsigned pos=unsigned(rng()%freeRows.size());
      const unsigned i=freeRows[pos]; freeRows.erase(freeRows.begin()+pos); return i;
    };
    for(unsigned b=0;b<Banks;b++) {
      if(owners[b].valid && !(s.respond&(1<<b))) continue;
      if(rng()%3==0 || freeRows.empty()) continue;
      s.offer|=1<<b;
      if(rng()%7==0) { s.prefetch|=1<<b; s.tags[b]=unsigned(rng()%Rows); }
      else { const unsigned i=takeRow(); s.tags[b]=i; alloc(s,i,Load); }
    }
    for(unsigned producer:{Exec,Mdu}) {
      if(!freeRows.empty() && rng()%3!=0) alloc(s,takeRow(),producer);
    }
    tick(s);
  }
  // Drain the random stream while checking every final publication.
  for(unsigned cycle=0;cycle<Rows+Banks;cycle++) {
    Stim s;
    for(unsigned b=0;b<Banks;b++) if(owners[b].valid) { s.respond=1<<b; break; }
    for(unsigned i=0;i<Rows;i++) {
      if(kind[i]==Exec && !s.exe) { s.exe=true; s.exeTag=i; }
      if(kind[i]==Mdu && !s.md) { s.md=true; s.mdTag=i; }
    }
    tick(s);
  }
  for(unsigned i=0;i<Rows;i++) {
    if(!loadCoverage[i] || !exeCoverage[i] || !mdCoverage[i] || !reuseCoverage[i]) fail("per-row producer/reuse coverage incomplete");
    if(kind[i]!=Free) fail("random instructions did not drain");
  }
  for(const auto& owner:owners) if(owner.valid) fail("random bank owners did not drain");
  if(!pendingGarbage || !multiProducer || !deadDrain || !prefetchDrain || !retainedFreeze || !squashes || !reuses)
    fail("directed protocol coverage incomplete");
  dut.final();
  std::cout << "{\"cycles\":" << cycles << ",\"published_word_checks\":" << checked
    << ",\"load_completions\":" << loads << ",\"alu_completions\":" << executions
    << ",\"mdu_completions\":" << mdu << ",\"pending_garbage_cycles\":" << pendingGarbage
    << ",\"simultaneous_producer_cycles\":" << multiProducer << ",\"dead_owner_drains\":" << deadDrain
    << ",\"prefetch_drains\":" << prefetchDrain << ",\"squash_cycles\":" << squashes
    << ",\"tag_reuses\":" << reuses << ",\"finalized_with_pending_checks\":" << retainedFreeze
    << ",\"rows_covered\":" << Rows << "}\n";
}
'''


def run(command, log, cwd):
    with log.open("w") as stream:
        subprocess.run([str(x) for x in command], cwd=cwd, stdout=stream,
                       stderr=subprocess.STDOUT, check=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    enter_appimage(DEFAULT_APPIMAGE)
    out = PROJECT / "reports/validation/prepared-result"
    build = PROJECT / "build/prepared-result-validation"
    generator = build / "generator"
    scala = generator / "src/main/scala/tier2"
    out.mkdir(parents=True, exist_ok=True)
    scala.mkdir(parents=True, exist_ok=True)
    for path in scala.glob("*.scala"):
        path.unlink()
    sources = list((PROJECT / "src/main/scala/tier2").glob("*.scala"))
    sources.append(PROJECT / "src/test/scala/tier2/PreparedResultHarness.scala")
    source_hashes = {}
    for path in sources:
        snapshot = scala / path.name
        shutil.copy2(path, snapshot)
        source_hashes[str(path.relative_to(PROJECT))] = sha(snapshot)
    for relative in ("build.sbt", "project/build.properties"):
        destination = generator / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(PROJECT / relative, destination)
        source_hashes[relative] = sha(destination)
    source_hashes["scripts/verify_prepared_result.py"] = sha(Path(__file__))
    cpp = build / "prepared_result_test.cpp"
    cpp.write_text(CPP)
    rtl = build / "rtl"
    run([Path.home() / ".local/bin/sbt", "-batch",
         f"runMain tier2.GeneratePreparedResultHarness {rtl}"],
        out / "generate.log", generator)
    results = []
    for bits in (8, 16, 32):
        name = f"slice{bits}"
        obj = build / name / "obj"
        obj.mkdir(parents=True, exist_ok=True)
        design = rtl / name / "PreparedResultHarness.sv"
        run([packaged_tool("verilator") or executable("verilator"), "--cc",
             "--exe", "--build", "--assert", "--top-module", "PreparedResultHarness",
             "-Wno-fatal", "-O3", "-j", "1", "--Mdir", obj, design, cpp],
            out / (name + "-build.log"), PROJECT)
        proc = subprocess.run([str(obj / "VPreparedResultHarness"), str(bits)],
                              text=True, capture_output=True)
        (out / (name + "-test.log")).write_text(proc.stdout + proc.stderr)
        proc.check_returncode()
        result = {"result_slice_bits": bits, **json.loads(proc.stdout),
                  "rtl_sha256": sha(design),
                  "simulator_sha256": sha(obj / "VPreparedResultHarness")}
        results.append(result)
        print(name, result, flush=True)
    (out / "result.json").write_text(json.dumps({"status": "passed", "variants": results,
        "scope": "Actual LocalResultWord/LocalResultSlice and CacheOwner RTL; independent software owner, completion, finalized and published-data oracle. Raw response arbitration and globally formatted load data are driver inputs; cache SRAM, load formatting, whole-core execution are outside this unit test.",
        "source_sha256": source_hashes, "driver_sha256": sha(cpp)}, indent=2) + "\n")


if __name__ == "__main__":
    main()
