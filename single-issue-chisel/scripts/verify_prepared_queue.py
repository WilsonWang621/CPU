#!/usr/bin/env python3
"""Check full/partial cached-head queue RTL against legacy RTL and a software FIFO."""
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
#include "VPreparedQueueHarness.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <deque>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

using Word = std::array<uint32_t,4>;
int main(int argc,char** argv) {
  Verilated::commandArgs(argc,argv);
  const unsigned entries=std::stoul(argv[1]);
  const bool flow=std::stoul(argv[2]);
  VPreparedQueueHarness dut;
  std::mt19937_64 rng(0x9416400ULL+entries*2+flow);
  std::deque<Word> fifo;
  std::vector<std::array<bool,4>> transitions(entries+1);
  std::vector<bool> resetAt(entries+1),redirectAt(entries+1);
  Word seenZero{},seenOne{};
  uint64_t cycles=0,pushed=0,popped=0,flowed=0,resets=0,redirects=0,payloadChecks=0;
  auto tick=[&](bool valid,bool ready,bool reset=false,bool redirect=false) {
    Word input;
    for(auto& x:input) x=uint32_t(rng());
    input[3]&=3;
    for(unsigned i=0;i<4;i++) { seenZero[i]|=~input[i]; seenOne[i]|=input[i]; }
    dut.clock=0; dut.reset=reset; dut.redirect=redirect;
    dut.enq_valid=valid; dut.deq_ready=ready;
    for(unsigned i=0;i<4;i++) dut.enq_data[i]=input[i];
    dut.eval();
    const unsigned occupancy=fifo.size();
    if(reset || redirect) {
      if(reset) { resetAt[occupancy]=true; resets++; }
      if(redirect) { redirectAt[occupancy]=true; redirects++; }
      fifo.clear();
    } else {
      const bool expectedReady=occupancy<entries;
      const bool expectedValid=occupancy!=0 || (flow && valid);
      auto fail=[&](const std::string& reason) {
        throw std::runtime_error(reason+" at cycle "+std::to_string(cycles)+
          ", occupancy "+std::to_string(occupancy));
      };
      if(bool(dut.enq_ready)!=expectedReady) fail("software enqueue-ready mismatch");
      if(bool(dut.deq_valid)!=expectedValid) fail("software dequeue-valid mismatch");
      if(expectedValid) {
        const auto& expected=occupancy ? fifo.front() : input;
        for(unsigned i=0;i<4;i++) if(dut.deq_data[i]!=expected[i]) fail("software payload mismatch");
        payloadChecks++;
      }
      const bool push=valid && expectedReady;
      const bool pop=ready && expectedValid;
      const bool bypass=flow && occupancy==0 && push && pop;
      const bool storedPush=push && !bypass;
      const bool storedPop=pop && occupancy!=0;
      transitions[occupancy][unsigned(storedPush)*2+storedPop]=true;
      if(pop) popped++;
      if(push) pushed++;
      if(bypass) flowed++;
      if(storedPop) fifo.pop_front();
      if(storedPush) fifo.push_back(input);
    }
    dut.clock=1; dut.eval();
    dut.clock=0; dut.eval();
    cycles++;
  };
  tick(false,false,true);
  // Force reset and redirect at every occupancy, including a full queue.
  for(unsigned occupancy=0;occupancy<=entries;occupancy++) {
    for(bool redirect:{false,true}) {
      while(!fifo.empty()) tick(false,true);
      for(unsigned i=0;i<occupancy;i++) tick(true,false);
      tick(true,true,!redirect,redirect);
      tick(false,true);
    }
  }
  // Exercise every legal occupancy/enqueue/dequeue transition explicitly.
  for(unsigned occupancy=0;occupancy<=entries;occupancy++) {
    for(unsigned controls=0;controls<4;controls++) {
      tick(false,false,true);
      for(unsigned i=0;i<occupancy;i++) tick(true,false);
      tick(controls&2,controls&1);
    }
  }
  // Fill, hold full, drain, wrap both pointers, and repeat simultaneous traffic.
  tick(false,false,true);
  for(unsigned round=0;round<32;round++) {
    for(unsigned i=0;i<entries*2;i++) tick(true,false);
    for(unsigned i=0;i<entries*4;i++) tick(true,true);
    for(unsigned i=0;i<entries*2;i++) tick(false,true);
    for(unsigned i=0;i<8;i++) tick(true,true);
  }
  for(unsigned i=0;i<200000;i++) {
    const auto bits=rng();
    tick(bits&1,bits&2,(bits%997)==0,(bits%991)==0);
  }
  while(!fifo.empty()) tick(false,true);
  unsigned covered=0;
  for(unsigned occupancy=0;occupancy<=entries;occupancy++) {
    if(!resetAt[occupancy] || !redirectAt[occupancy])
      throw std::runtime_error("reset/redirect occupancy coverage incomplete");
    for(unsigned transaction=0;transaction<4;transaction++) {
      const bool legal=(occupancy!=0 || !(transaction&1)) &&
        (occupancy!=entries || !(transaction&2));
      if(legal && !transitions[occupancy][transaction])
        throw std::runtime_error("transaction coverage incomplete");
      if(transitions[occupancy][transaction]) covered++;
    }
  }
  if(covered!=4*entries || (flow && flowed==0))
    throw std::runtime_error("flow/transaction coverage incomplete");
  for(unsigned i=0;i<4;i++) {
    const uint32_t mask=i==3 ? 3 : UINT32_MAX;
    if((seenZero[i]&seenOne[i]&mask)!=mask)
      throw std::runtime_error("98-bit payload zero/one coverage incomplete");
  }
  dut.final();
  std::cout << "{\"cycles\":" << cycles << ",\"enqueued\":" << pushed
    << ",\"dequeued\":" << popped << ",\"flow_through\":" << flowed
    << ",\"reset_cycles\":" << resets << ",\"redirect_cycles\":" << redirects
    << ",\"occupancy_transaction_combinations\":" << covered
    << ",\"reset_occupancies\":" << entries+1
    << ",\"redirect_occupancies\":" << entries+1
    << ",\"payload_checks\":" << payloadChecks
    << ",\"payload_bits_zero_one_covered\":98}\n";
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
    out = PROJECT / "reports/validation/prepared-queue"
    build = PROJECT / "build/prepared-queue-validation"
    generator = build / "generator"
    scala = generator / "src/main/scala/tier2"
    out.mkdir(parents=True, exist_ok=True)
    (out / "result.json").unlink(missing_ok=True)
    scala.mkdir(parents=True, exist_ok=True)
    for path in scala.glob("*.scala"):
        path.unlink()
    sources = list((PROJECT / "src/main/scala/tier2").glob("*.scala"))
    sources.append(PROJECT / "src/test/scala/tier2/PreparedQueueHarness.scala")
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
    source_hashes["scripts/verify_prepared_queue.py"] = sha(Path(__file__))
    cpp = build / "prepared_queue_test.cpp"
    cpp.write_text(CPP)
    rtl = build / "rtl"
    run([Path.home() / ".local/bin/sbt", "-batch",
         f"runMain tier2.GeneratePreparedQueueHarness {rtl}"],
        out / "generate.log", generator)
    results = []
    for entries in (2, 8):
        for flow in (0, 1):
            for partial in (False, True):
                name = f"entries{entries}-flow{flow}" + ("-partial34x32" if partial else "")
                obj = build / name / "obj"
                # AppImage headers live under a new mount path for each run;
                # old compiler dependency files refer to unmounted headers.
                if obj.exists():
                    shutil.rmtree(obj)
                obj.mkdir(parents=True, exist_ok=True)
                design = rtl / name / "PreparedQueueHarness.sv"
                run([packaged_tool("verilator") or executable("verilator"), "--cc",
                     "--exe", "--build", "--assert", "--top-module", "PreparedQueueHarness",
                     "-Wno-fatal", "-O3", "-j", "1", "--Mdir", obj, design, cpp],
                    out / (name + "-build.log"), PROJECT)
                proc = subprocess.run([str(obj / "VPreparedQueueHarness"), str(entries), str(flow)],
                                      text=True, capture_output=True)
                (out / (name + "-test.log")).write_text(proc.stdout + proc.stderr)
                proc.check_returncode()
                result = {"entries": entries, "flow": bool(flow), "partial_head_cache": partial,
                          "cache_low": 34 if partial else 0, "cache_width": 32 if partial else 98,
                          **json.loads(proc.stdout), "rtl_sha256": sha(design),
                          "simulator_sha256": sha(obj / "VPreparedQueueHarness")}
                results.append(result)
                print(name, result, flush=True)
    (out / "result.json").write_text(json.dumps({"status": "passed", "variants": results,
        "source_sha256": source_hashes, "driver_sha256": sha(cpp)}, indent=2) + "\n")


if __name__ == "__main__":
    main()
