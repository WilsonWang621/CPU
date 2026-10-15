from pathlib import Path
import argparse,importlib.util,re,json,hashlib
p=argparse.ArgumentParser();p.add_argument('name');p.add_argument('--wb-tree',action='store_true');p.add_argument('--operand',action='store_true');p.add_argument('--wake-qualified',action='store_true');p.add_argument('--wake-tree',action='store_true');p.add_argument('--forward-priority',action='store_true');p.add_argument('--prefix-div',action='store_true');p.add_argument('--dispatch-wake',action='store_true');p.add_argument('--parallel-issue',action='store_true');p.add_argument('--forward-onehot',action='store_true');p.add_argument('--memory-grants',action='store_true');p.add_argument('--parallel-forward-mask',action='store_true');p.add_argument('--cache-lookup',action='store_true');p.add_argument('--split-address',action='store_true');p.add_argument('--parallel-dispatch',action='store_true');p.add_argument('--parallel-return',action='store_true');p.add_argument('--store-grants',action='store_true');p.add_argument('--load-value-tree',action='store_true');p.add_argument('--store-priority',action='store_true');p.add_argument('--split-load-address',action='store_true');p.add_argument('--return-lookahead',action='store_true');p.add_argument('--dc-index-bits',type=int);p.add_argument('--rob-bits',type=int);p.add_argument('--address-register',action='store_true');a=p.parse_args()
out=Path('build/frequency-stage8')/a.name/'rtl';out.mkdir(parents=True,exist_ok=True)
BASE=Path('reports/data/2026-10-15/timing-stage8/baseline433/structured')
changed={}
if a.operand:
 changed['v2_operand.sv']='''// Parallel, mutually exclusive operand source selection.
(* keep_hierarchy=1 *)
module v2_operand #(parameter integer SLOT_BITS=5)(
  input wire live,prepare,old_ready,initial_ready,
  input wire [SLOT_BITS-1:0] source,
  input wire [31:0] old_value,initial_value,
  input wire [2:0] wb_good,
  input wire [3*SLOT_BITS-1:0] wb_slots,
  input wire [95:0] wb_values,
  output wire next_ready,
  output wire [31:0] next_value
);
  wire [2:0] hit,chosen;
  for(genvar w=0;w<3;w=w+1) begin: matching
    assign hit[w]=live && !old_ready && wb_good[w] && source==wb_slots[w*SLOT_BITS+:SLOT_BITS];
  end
  assign chosen[2]=hit[2];
  assign chosen[1]=hit[1] && !hit[2];
  assign chosen[0]=hit[0] && !(hit[1] || hit[2]);
  wire initializing=!live && prepare;
  wire holding=!(initializing || |chosen);
  assign next_ready=live ? (old_ready || |hit):(prepare ? initial_ready:old_ready);
  assign next_value=(old_value & {32{holding}}) | (initial_value & {32{initializing}}) |
                    (wb_values[31:0] & {32{chosen[0]}}) |
                    (wb_values[63:32] & {32{chosen[1]}}) |
                    (wb_values[95:64] & {32{chosen[2]}});
endmodule
'''
if a.wb_tree or a.wake_qualified or a.wake_tree or a.forward_priority or a.dispatch_wake or a.parallel_issue or a.forward_onehot or a.memory_grants or a.parallel_forward_mask or a.split_address or a.parallel_dispatch:
 core=(BASE/'cpu_top.sv').read_text()
if a.wb_tree:
 needle='  wire [95:0] wb_values;'
 assert core.count(needle)==1
 core=core.replace(needle,needle+'''
  wire [6*96-1:0] wb_value_copies;
  v2_distribution #(.WIDTH(96),.LEAVES(6)) distribute_wb_values (
    .data_in(wb_values),.data_out(wb_value_copies));
''')
 assert core.count('.wb_good,.wb_slots,.wb_values,.next_ready(')==2
 core=core.replace('.wb_good,.wb_slots,.wb_values,.next_ready(','.wb_good,.wb_slots,.wb_values(wb_value_copies[(2+bank)*96+:96]),.next_ready(')
 core=core.replace('source_value=wb_value[w];','source_value=wb_value_copies[5*96+w*32+:32];')
 core=core.replace('values[r]<=wb_value[w];','values[r]<=wb_value_copies[(2*r/ROB_ENTRIES)*96+w*32+:32];')
 core=core.replace('values[r][bit_id]<=wb_value[w][bit_id];','values[r][bit_id]<=wb_value_copies[(2*r/ROB_ENTRIES)*96+w*32+bit_id];')
if a.wake_qualified:
 old='assign wb_good[w]=wb_valid[w] && wb_fault[w]==0 && rob[wb_rid[w]].rd!=0;'
 assert core.count(old)==1
 core=core.replace(old,'''// Only JAL/JALR among branches have a register consumer. Compute their
    // alignment directly so conditional-branch comparisons do not gate wakeup.
    assign wb_good[w]=wb_valid[w] && rob[wb_rid[w]].rd!=0 &&
      (w!=0 ? wb_fault[w]==0 :
       (mdu_result_valid || is_alu(executing[0].op) ||
        (executing[0].op==OP_JAL && executing[0].imm[1:0]==0) ||
        (executing[0].op==OP_JALR &&
         !(executing[0].a[1]^executing[0].imm[1]^(executing[0].a[0]&executing[0].imm[0])))));''')
 core=core.replace('`ifndef SYNTHESIS','''`ifndef SYNTHESIS
  // Verify exact equivalence of wakeup eligibility in reachable CPU states.
  always_ff @(posedge clk) if(!rst)
    assert(wb_good[0] === (wb_valid[0] && wb_fault[0]==0 && rob[wb_rid[0]].rd!=0))
      else $fatal(1,"specialized integer wakeup qualification differs");
''',1)
if a.wake_tree:
 needle='  wire [95:0] wb_values;'
 assert core.count(needle)==1
 core=core.replace(needle,needle+'''
  localparam integer WAKE_BITS=3+3*RW;
  wire [6*WAKE_BITS-1:0] wake_copies;
  v2_distribution #(.WIDTH(WAKE_BITS),.LEAVES(6)) distribute_wakeup (
    .data_in({wb_good,wb_slots}),.data_out(wake_copies));
''')
 assert core.count('.wb_good,.wb_slots,')==2
 core=core.replace('.wb_good,.wb_slots,',
   '.wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),'
   '.wb_slots(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+:3*RW]),')
if a.wb_tree or a.wake_qualified or a.wake_tree or a.forward_priority or a.dispatch_wake or a.parallel_issue or a.forward_onehot or a.memory_grants or a.parallel_forward_mask or a.split_address or a.parallel_dispatch:
 changed['cpu_top.sv']=core
if a.dispatch_wake:
 old='pending && wb_valid[w] && wb_rid[w]==source_id && wb_fault[w]==0'
 assert core.count(old)==1
 core=core.replace(old,'pending && wb_good[w] && wb_rid[w]==source_id')
 core=core.replace('`ifndef SYNTHESIS',"""`ifndef SYNTHESIS
  // A pending RAT tag must identify a real register-writing producer.
  always_ff @(posedge clk) if(!rst) begin
    for(integer src=0;src<4;src=src+1)
      for(integer port=0;port<3;port=port+1)
        if(source_pending[src] && source_register[src*5+:5]!=0 &&
           wb_rid[port]==source_slot[src*RW+:RW])
          assert(wb_good[port] === (wb_valid[port] && wb_fault[port]==0))
            else $fatal(1,"dispatch wakeup predicate differs for a pending source");
  end
""",1)
 changed['cpu_top.sv']=core
if a.forward_priority:
 old="""v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST),.YOUNGEST(1)) choose_forward (
    .ready(store_forward_candidates),.owner(store_owners),.rob_head(store_head),.valid(forward_match),.index(forward_slot));"""
 assert core.count(old)==1
 core=core.replace(old,"""v2_circular_priority #(.ENTRIES(STORE_SLOTS),.INDEX_BITS(ST)) choose_forward (
    .ready(store_forward_candidates),.head(store_head),.valid(forward_match),.index(forward_slot));""")
 changed['cpu_top.sv']=core
 changed['v2_circular_priority.sv']=Path('build/frequency-stage8/v2_circular_priority.sv').read_text()
if a.parallel_issue:
 old="""    wire [ISSUE_BITS-1:0] selected_payload;"""
 assert core.count(old)==1
 core=core.replace(old,old+"""
    wire [IQ_ENTRIES-1:0] direct_grant;
    wire [IQ_ENTRIES*((ISSUE_BITS+31)/32)-1:0] payload_grants;
    if(bank==2) begin: unused_direct_grant
      assign direct_grant=0;assign payload_grants=0;
    end else begin: distribute_grants
      v2_distribution #(.WIDTH(IQ_ENTRIES),.LEAVES((ISSUE_BITS+31)/32)) tree (
        .data_in(direct_grant),.data_out(payload_grants));
    end
""")
 old="""      v2_select #(.ENTRIES(IQ_ENTRIES),.SLOT_BITS(RW+1),.EXTENDED_ORDER(1)) choose (
        .ready(select_ready[bank]),.owner(select_owner[bank]),.rob_head({(RW+1){1'b0}}),.valid(selected_valid[bank]),.index(selected[bank]));"""
 assert core.count(old)==1
 core=core.replace(old,"""      v2_parallel_select #(.ENTRIES(IQ_ENTRIES),.SLOT_BITS(RW+1)) choose (
        .ready(select_ready[bank]),.owner(select_owner[bank]),.rob_head({(RW+1){1'b0}}),
        .valid(selected_valid[bank]),.index(selected[bank]),.grant(direct_grant));""")
 old="""      v2_iq_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)) read_slice (
        .index(selected[bank]),.words(slice_words),.value(selected_payload[first+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)]));"""
 assert core.count(old)==1
 core=core.replace(old,"""      if(bank!=2) begin: direct_payload
        v2_grant_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)) read_slice (
          .grant(payload_grants[(first/32)*IQ_ENTRIES+:IQ_ENTRIES]),.words(slice_words),
          .value(selected_payload[first+:(ISSUE_BITS-first<32 ? ISSUE_BITS-first:32)]));
      end else begin: indexed_payload
"""+old+"""
      end""")
 changed['cpu_top.sv']=core
 for name in ('v2_order_compare.sv','v2_parallel_select.sv','v2_grant_read.sv'):
  changed[name]=(Path('build/frequency-stage8')/name).read_text()
if a.forward_onehot:
 assert a.forward_priority
 core=core.replace('v2_circular_priority #(.ENTRIES(STORE_SLOTS),.INDEX_BITS(ST)) choose_forward (',
   'v2_circular_grant #(.ENTRIES(STORE_SLOTS),.INDEX_BITS(ST)) choose_forward (')
 old='.ready(store_forward_candidates),.head(store_head),.valid(forward_match),.index(forward_slot));'
 assert core.count(old)==1
 core=core.replace(old,'.ready(store_forward_candidates),.head(store_head),.valid(forward_match),.index(forward_slot),.grant(forward_grant));')
 core=core.replace('  logic [ST-1:0] forward_slot;',"""  logic [ST-1:0] forward_slot;
  wire [STORE_SLOTS-1:0] forward_grant;
  wire [STORE_SLOTS*36-1:0] forwarding_words;
  wire [35:0] forwarding_payload;
  for(genvar s=0;s<STORE_SLOTS;s=s+1) begin: forward_payloads
    assign forwarding_words[s*36+:36]={stores[s].mask,stores[s].data};
  end
  v2_grant_read #(.ENTRIES(STORE_SLOTS),.WORD_BITS(36)) read_forward_payload (
    .grant(forward_grant),.words(forwarding_words),.value(forwarding_payload));
""")
 core=core.replace('(stores[forward_slot].mask & memory_mask)', '(forwarding_payload[35:32] & memory_mask)')
 core=core.replace('forward_full ? stores[forward_slot].data:cache_load_data', 'forward_full ? forwarding_payload[31:0]:cache_load_data')
 changed['cpu_top.sv']=core
 for name in ('v2_circular_grant.sv','v2_grant_read.sv'):
  changed[name]=(Path('build/frequency-stage8')/name).read_text()
if a.memory_grants:
 assert a.parallel_issue
 core=core.replace('  wire [IQ_ENTRIES*32-1:0] prepared_address_words;',
   '  wire [IQ_ENTRIES*32-1:0] prepared_address_words;\n  wire [IQ_ENTRIES-1:0] memory_address_grant;')
 old="""    if(bank==2) begin: unused_direct_grant
      assign direct_grant=0;assign payload_grants=0;"""
 assert core.count(old)==1
 core=core.replace(old,"""    if(bank==2) begin: unused_direct_grant
      assign direct_grant=0;
      wire [(QW+1)*((ISSUE_BITS+31)/32+1)-1:0] next_controls;
      v2_distribution #(.WIDTH(QW+1),.LEAVES((ISSUE_BITS+31)/32+1)) controls (
        .data_in({prepared_selection.next_valid,prepared_selection.next_index}),.data_out(next_controls));
      for(genvar group=0;group<(ISSUE_BITS+31)/32;group=group+1) begin: payload_copy
        v2_registered_grant #(.ENTRIES(IQ_ENTRIES),.INDEX_BITS(QW)) local_grant (
          .clk,.rst,.valid(next_controls[group*(QW+1)+QW]),.index(next_controls[group*(QW+1)+:QW]),
          .grant(payload_grants[group*IQ_ENTRIES+:IQ_ENTRIES]));
`ifndef SYNTHESIS
        always_ff @(posedge clk) if(!rst)
          assert(payload_grants[group*IQ_ENTRIES+:IQ_ENTRIES]===
                 (selected_valid[bank] ? ({{(IQ_ENTRIES-1){1'b0}},1'b1}<<selected[bank]):{IQ_ENTRIES{1'b0}}))
            else $fatal(1,"registered memory payload grant differs");
`endif
      end
      v2_registered_grant #(.ENTRIES(IQ_ENTRIES),.INDEX_BITS(QW)) address_copy (
        .clk,.rst,.valid(next_controls[((ISSUE_BITS+31)/32)*(QW+1)+QW]),
        .index(next_controls[((ISSUE_BITS+31)/32)*(QW+1)+:QW]),.grant(memory_address_grant));
""")
 start=core.index('      if(bank!=2) begin: direct_payload')
 middle=core.index('      end else begin: indexed_payload',start)
 stop=core.index('\n      end',middle)+len('\n      end')
 direct=core[start:middle].replace('      if(bank!=2) begin: direct_payload\n','')
 core=core[:start]+direct+core[stop:]
 old="""  v2_iq_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(32)) read_memory_address (
    .index(selected[2]),.words(prepared_address_words),.value(memory_address));"""
 assert core.count(old)==1
 core=core.replace(old,"""  v2_grant_read #(.ENTRIES(IQ_ENTRIES),.WORD_BITS(32)) read_memory_address (
    .grant(memory_address_grant),.words(prepared_address_words),.value(memory_address));""")
 changed['cpu_top.sv']=core
 changed['v2_registered_grant.sv']=Path('build/frequency-stage8/v2_registered_grant.sv').read_text()
if a.parallel_forward_mask:
 assert a.forward_onehot
 core=core.replace('  wire [35:0] forwarding_payload;',"""  wire [35:0] forwarding_payload;
  wire [STORE_SLOTS-1:0] forwarding_full_grants;
  for(genvar s=0;s<STORE_SLOTS;s=s+1) begin: forwarding_coverage
    assign forwarding_full_grants[s]=forward_grant[s] &&
      (stores[s].mask & memory_mask)==memory_mask;
  end
""")
 old='    if(forward_match) forward_full=(forwarding_payload[35:32] & memory_mask)==memory_mask;'
 assert core.count(old)==1
 core=core.replace(old,'')
 assert core.count('forward_full=0;squashed_stores=0;')==1
 core=core.replace('forward_full=0;squashed_stores=0;','forward_full=|forwarding_full_grants;squashed_stores=0;')
 core=core.replace('`ifndef SYNTHESIS',"""`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst && select_valid[2])
    assert(forward_full === (forward_match &&
           ((forwarding_payload[35:32] & memory_mask)==memory_mask)))
      else $fatal(1,"parallel store coverage differs");
""",1)
 changed['cpu_top.sv']=core
if a.split_address:
 core=core.replace('  issue_t queue [3][IQ_ENTRIES],dispatch_payload[2];',"""  issue_t queue [3][IQ_ENTRIES],dispatch_payload[2];
  wire [31:0] dispatch_address [0:1];
  for(genvar address_lane=0;address_lane<2;address_lane=address_lane+1) begin: prepare_dispatch_address
    v2_prefix_adder #(.WIDTH(32)) add (
      .a(dispatch_payload[address_lane].a),.b(dispatch_payload[address_lane].imm),
      .carry_in(1'b0),.sum(dispatch_address[address_lane]),.carry_out());
  end
""")
 old="""        wire [31:0] address_immediate=queue[bank][q].valid ? queue[bank][q].imm:
          (prepare_lane[1] ? dispatch_payload[1].imm:dispatch_payload[0].imm);
        wire [31:0] address_sum;
        v2_prefix_adder #(.WIDTH(32)) effective_address_add (.a(next_value_a),.b(address_immediate),.carry_in(1'b0),.sum(address_sum),.carry_out());"""
 assert core.count(old)==1
 core=core.replace(old,"""        wire [31:0] live_value,live_sum;
        v2_operand #(.SLOT_BITS(RW)) address_operand (
          .live(1'b1),.prepare(1'b0),.old_ready(queue[bank][q].ready_a),
          .old_value(queue[bank][q].a),.source(queue[bank][q].source_a),
          .initial_ready(1'b0),.initial_value(32'b0),
          .wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),
          .wb_slots(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+:3*RW]),
          .wb_values,.next_ready(),.next_value(live_value));
        v2_prefix_adder #(.WIDTH(32)) effective_address_add (
          .a(live_value),.b(queue[bank][q].imm),.carry_in(1'b0),.sum(live_sum),.carry_out());
        wire [31:0] address_sum=queue[bank][q].valid ? live_sum:
          (prepare_lane[1] ? dispatch_address[1]:dispatch_address[0]);
""")
 changed['cpu_top.sv']=core
if a.parallel_dispatch:
 assert a.dispatch_wake
 old='    logic pending,ready_value;'
 assert core.count(old)==1
 core=core.replace(old,old+'\n    logic [2:0] bypass_matches,bypass_chosen;')
 core=core.replace('source_id=0;register_id=0;pending=0;ready_value=0;source_value=0;',
   'source_id=0;register_id=0;pending=0;ready_value=0;source_value=0;bypass_matches=0;bypass_chosen=0;')
 old="""        for(integer w=0;w<3;w=w+1)
          if(pending && wb_good[w] && wb_rid[w]==source_id) begin ready_value=1;source_value=wb_value[w];end"""
 assert core.count(old)==1
 core=core.replace(old,"""        for(integer w=0;w<3;w=w+1)
          bypass_matches[w]=pending && wb_good[w] && wb_rid[w]==source_id;
        bypass_chosen[2]=bypass_matches[2];
        bypass_chosen[1]=bypass_matches[1] && !bypass_matches[2];
        bypass_chosen[0]=bypass_matches[0] && !(bypass_matches[1] || bypass_matches[2]);
        ready_value=ready_value || |bypass_matches;
        source_value=(source_value & {32{!(|bypass_matches)}}) |
          (wb_value[0] & {32{bypass_chosen[0]}}) |
          (wb_value[1] & {32{bypass_chosen[1]}}) |
          (wb_value[2] & {32{bypass_chosen[2]}});""")
 changed['cpu_top.sv']=core
if a.store_priority:
 assert not a.store_grants
 old="""  v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST)) choose_store (
    .ready(store_send_candidates),.owner(store_owners),.rob_head(store_head),.valid(store_send_valid),.index(store_send_slot));"""
 assert core.count(old)==1
 core=core.replace(old,"""  v2_oldest_store #(.ENTRIES(STORE_SLOTS),.INDEX_BITS(ST)) choose_store (
    .ready(store_send_candidates),.head(store_head),.valid(store_send_valid),.index(store_send_slot),.grant());""")
 changed['cpu_top.sv']=core
 changed['v2_oldest_store.sv']=Path('build/frequency-stage8/v2_oldest_store.sv').read_text()
if a.split_load_address:
 assert a.split_address
 start=core.index('      if(bank==2) begin: address_prepare')
 stop=core.index('      always_ff @(posedge clk) begin',start)
 part=core[start:stop]
 part=part.replace('wire [31:0] live_value,live_sum;','wire [31:0] live_value,live_sum,non_load_sum,load_sum;')
 part=part.replace('.wb_good(wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:3]),',
   ".wb_good({1'b0,wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+:2]}),")
 part=part.replace('.sum(live_sum),.carry_out());',""".sum(non_load_sum),.carry_out());
        v2_prefix_adder #(.WIDTH(32)) load_address_add (
          .a(wb_value[2]),.b(queue[bank][q].imm),.carry_in(1'b0),.sum(load_sum),.carry_out());
        wire load_matches=!queue[bank][q].ready_a &&
          wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+3*RW+2] &&
          queue[bank][q].source_a==wake_copies[(bank*2+2*q/IQ_ENTRIES)*WAKE_BITS+2*RW+:RW];
        assign live_sum=load_matches ? load_sum:non_load_sum;""")
 part=part.replace('''        always_ff @(posedge clk)
          if(address_update) prepared_address[q]<=address_sum;''',"""        always_ff @(posedge clk)
          if(address_update) prepared_address[q]<=address_sum;
`ifndef SYNTHESIS
        wire [31:0] reference_immediate=queue[bank][q].valid ? queue[bank][q].imm:
          (prepare_lane[1] ? dispatch_payload[1].imm:dispatch_payload[0].imm);
        wire [31:0] reference_address=next_value_a+reference_immediate;
        always_ff @(posedge clk) if(!rst && address_update && next_ready_a)
          assert(address_sum === reference_address)
            else $fatal(1,"prepared effective address differs");
`endif""")
 core=core[:start]+part+core[stop:];changed['cpu_top.sv']=core
if a.store_grants:
 assert a.parallel_issue
 old="""  v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST)) choose_store (
    .ready(store_send_candidates),.owner(store_owners),.rob_head(store_head),.valid(store_send_valid),.index(store_send_slot));"""
 assert core.count(old)==1
 core=core.replace(old,"""  wire [STORE_SLOTS-1:0] store_send_grant;
  wire [3*STORE_SLOTS-1:0] store_send_copies;
  wire [STORE_SLOTS*32-1:0] send_addresses,send_values;
  wire [STORE_SLOTS*4-1:0] send_masks;
  v2_oldest_store #(.ENTRIES(STORE_SLOTS),.INDEX_BITS(ST)) choose_store (
    .ready(store_send_candidates),.head(store_head),.valid(store_send_valid),.index(store_send_slot),.grant(store_send_grant));
  v2_distribution #(.WIDTH(STORE_SLOTS),.LEAVES(3)) distribute_store_send (
    .data_in(store_send_grant),.data_out(store_send_copies));
  for(genvar slot=0;slot<STORE_SLOTS;slot=slot+1) begin: send_payloads
    assign send_addresses[slot*32+:32]={stores[slot].address[31:2],2'b0};
    assign send_values[slot*32+:32]=stores[slot].data;
    assign send_masks[slot*4+:4]=stores[slot].mask;
  end
  v2_grant_read #(.ENTRIES(STORE_SLOTS),.WORD_BITS(32)) send_address_read (
    .grant(store_send_copies[0*STORE_SLOTS+:STORE_SLOTS]),.words(send_addresses),.value(cache_store_address));
  v2_grant_read #(.ENTRIES(STORE_SLOTS),.WORD_BITS(32)) send_value_read (
    .grant(store_send_copies[1*STORE_SLOTS+:STORE_SLOTS]),.words(send_values),.value(cache_store_data));
  v2_grant_read #(.ENTRIES(STORE_SLOTS),.WORD_BITS(4)) send_mask_read (
    .grant(store_send_copies[2*STORE_SLOTS+:STORE_SLOTS]),.words(send_masks),.value(cache_store_mask));
""")
 for assignment in ["  assign cache_store_address={stores[store_send_slot].address[31:2],2'b0};",'  assign cache_store_data=stores[store_send_slot].data;','  assign cache_store_mask=stores[store_send_slot].mask;']:
  assert core.count(assignment)==1
  core=core.replace(assignment,'')
 core=core.replace('`ifndef SYNTHESIS',"""`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst && store_send_valid) begin
    assert(cache_store_address === {stores[store_send_slot].address[31:2],2'b0});
    assert(cache_store_data === stores[store_send_slot].data);
    assert(cache_store_mask === stores[store_send_slot].mask);
  end
""",1)
 changed['cpu_top.sv']=core
 changed['v2_oldest_store.sv']=Path('build/frequency-stage8/v2_oldest_store.sv').read_text()
if a.load_value_tree:
 assert not a.wb_tree and a.split_address and a.parallel_dispatch
 needle='  wire [95:0] wb_values;'
 assert core.count(needle)==1
 core=core.replace(needle,needle+"""
  wire [6*32-1:0] load_value_copies;
  v2_distribution #(.WIDTH(32),.LEAVES(6)) distribute_load_result (
    .data_in(wb_value[2]),.data_out(load_value_copies));
""")
 assert core.count('.wb_values,')==3
 core=core.replace('.wb_values,','.wb_values({load_value_copies[(2+bank)*32+:32],wb_values[63:0]}),')
 old='(wb_value[2] & {32{bypass_chosen[2]}})'
 assert core.count(old)==1
 core=core.replace(old,'(load_value_copies[5*32+:32] & {32{bypass_chosen[2]}})')
 core=core.replace('values[r]<=wb_value[w];','values[r]<=(w==2 ? load_value_copies[(2*r/ROB_ENTRIES)*32+:32]:wb_value[w]);')
 core=core.replace('values[r][bit_id]<=wb_value[w][bit_id];','values[r][bit_id]<=(w==2 ? load_value_copies[(2*r/ROB_ENTRIES)*32+bit_id]:wb_value[w][bit_id]);')
 changed['cpu_top.sv']=core
if a.address_register:
 assert a.split_address
 old="""        always_ff @(posedge clk)
          if(address_update) prepared_address[q]<=address_sum;"""
 assert core.count(old)==1
 core=core.replace(old,"""        wire [31:0] address_next;
        v2_priority_mux #(.WORD_BITS(32),.PORTS(3)) capture_address (
          .enable({queue[bank][q].valid && !queue[bank][q].ready_a,
                   !queue[bank][q].valid && prepare_lane[1],
                   !queue[bank][q].valid && prepare_lane[0]}),
          .old_value(prepared_address[q]),
          .data({live_sum,dispatch_address[1],dispatch_address[0]}),.value(address_next));
        always_ff @(posedge clk) prepared_address[q]<=address_next;""")
 changed['cpu_top.sv']=core
 changed['v2_priority_mux.sv']=Path('build/frequency-stage8/v2_priority_mux.sv').read_text()
if a.prefix_div:
 source=(BASE/'muldiv.sv').read_text()
 old="""  always_comb begin
    quotient_next=quotient_q;
    remainder_next=remainder_q;
    shifted=0;
    if(div_live) for(integer bit_step=0;bit_step<DIV_STEP_BITS;bit_step=bit_step+1) begin
      shifted={remainder_next[31:0],quotient_next[31]};
      quotient_next={quotient_next[30:0],1'b0};
      if(shifted>={1'b0,divisor_q}) begin
        remainder_next=shifted-{1'b0,divisor_q};
        quotient_next[0]=1'b1;
      end else remainder_next=shifted;
    end
  end"""
 assert source.count(old)==1
 source=source.replace(old,"""  for(genvar step=0;step<DIV_STEP_BITS;step=step+1) begin: restoring
    wire [31:0] input_quotient,output_quotient;
    wire [32:0] input_remainder,output_remainder;
    if(step==0) begin: first_step
      assign input_quotient=quotient_q;assign input_remainder=remainder_q;
    end else begin: later_step
      assign input_quotient=restoring[step-1].output_quotient;
      assign input_remainder=restoring[step-1].output_remainder;
    end
    v2_div_step arithmetic (.quotient(input_quotient),.remainder(input_remainder),.divisor(divisor_q),
      .next_quotient(output_quotient),.next_remainder(output_remainder));
  end
  always_comb begin
    shifted=0;
    quotient_next=div_live ? restoring[DIV_STEP_BITS-1].output_quotient:quotient_q;
    remainder_next=div_live ? restoring[DIV_STEP_BITS-1].output_remainder:remainder_q;
  end""")
 changed['muldiv.sv']=source
 changed['v2_div_step.sv']=Path('build/frequency-stage8/v2_div_step.sv').read_text()
if a.cache_lookup:
 cache=(BASE/'v2_dcache.sv').read_text()
 old="    assign load_matches[way]=tag_valid[{load_set,1'(way)}] && tags[{load_set,1'(way)}]==load_address[RB-1:SB+OFFSET];"
 assert cache.count(old)==1
 cache=cache.replace(old,'')
 old='  assign load_hit=load_tag_hit && word_valid[load_line][load_address[OFFSET-1:2]];'
 assert cache.count(old)==1
 cache=cache.replace(old,"""  wire [LINES*TB-1:0] lookup_tags;
  wire [LINES*WORDS-1:0] lookup_words;
  for(genvar line=0;line<LINES;line=line+1) begin: lookup_payload
    assign lookup_tags[line*TB+:TB]=tags[line];
    assign lookup_words[line*WORDS+:WORDS]=word_valid[line];
  end
  v2_cache_lookup #(.SETS(SETS),.TAG_BITS(TB),.WORDS(WORDS)) lookup (
    .address(load_address[RB-1:2]),.tags(lookup_tags),.valid(tag_valid),.word_valid(lookup_words),
    .match_bits(load_matches),.hit(load_hit));
""")
 changed['v2_dcache.sv']=cache
 for name in ('v2_cache_lookup.sv','v2_cache_tag_match.sv'):
  changed[name]=(Path('build/frequency-stage8')/name).read_text()
if a.return_lookahead:
 assert not a.parallel_return
 cache=changed.get('v2_dcache.sv',(BASE/'v2_dcache.sv').read_text())
 old='(waiter_next[w].error || word_valid_next[waiter_next[w].physical][waiter_next[w].word_index])'
 assert cache.count(old)==1
 cache=cache.replace(old,'return_candidates[w]')
 needle='  always_comb begin: returning_load'
 assert cache.count(needle)==1
 cache=cache.replace(needle,"""  wire [LOAD_SLOTS-1:0] return_candidates;
  logic incoming_word_ready;
  wire incoming_error=(merge_valid && misses[merge_slot].failed[load_address[OFFSET-1:2]]) ||
    (fill_fire && mem_rsp_error && response_line==selected_line && response_word==load_address[OFFSET-1:2]);
  always_comb begin
    incoming_word_ready=word_valid[selected_line][load_address[OFFSET-1:2]];
    if(allocate && !load_tag_hit) incoming_word_ready=0;
    if(fill_fire && response_line==selected_line && response_word==load_address[OFFSET-1:2])
      incoming_word_ready=!mem_rsp_error;
    if(store_accept && store_tag_hit && store_line==selected_line && store_mask==15 &&
        store_address[OFFSET-1:2]==load_address[OFFSET-1:2]) incoming_word_ready=1;
  end
  for(genvar waiter=0;waiter<LOAD_SLOTS;waiter=waiter+1) begin: return_lookahead
    logic resident_word_ready;
    wire publish=load_accept && !load_hit && load_tag==LT'(waiter);
    wire consumed=result_valid && result_ready && result_tag==LT'(waiter);
    wire resident_error=waiters[waiter].error ||
      (fill_fire && mem_rsp_error && waiters[waiter].valid &&
       waiters[waiter].physical==response_line && waiters[waiter].word_index==response_word);
    always_comb begin
      resident_word_ready=word_valid[waiters[waiter].physical][waiters[waiter].word_index];
      if(allocate && !load_tag_hit && selected_line==waiters[waiter].physical) resident_word_ready=0;
      if(fill_fire && response_line==waiters[waiter].physical && response_word==waiters[waiter].word_index)
        resident_word_ready=!mem_rsp_error;
      if(store_accept && store_tag_hit && store_line==waiters[waiter].physical && store_mask==15 &&
          store_address[OFFSET-1:2]==waiters[waiter].word_index) resident_word_ready=1;
    end
    assign return_candidates[waiter]=publish ? (incoming_error || incoming_word_ready):
      (waiters[waiter].valid && !consumed && (resident_error || resident_word_ready));
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst)
      assert((waiter_next[waiter].valid && return_candidates[waiter]) ===
        (waiter_next[waiter].valid && (waiter_next[waiter].error ||
          word_valid_next[waiter_next[waiter].physical][waiter_next[waiter].word_index])))
        else $fatal(1,"cache return eligibility differs");
`endif
  end
"""+needle)
 changed['v2_dcache.sv']=cache
if a.parallel_return:
 assert a.parallel_issue
 cache=changed.get('v2_dcache.sv',(BASE/'v2_dcache.sv').read_text())
 start=cache.index('  always_comb begin: returning_load')
 stop=cache.index('  always_ff @(posedge clk)',start)
 cache=cache[:start]+"""  localparam integer RETURN_BITS=1+LT+LB+WW;
  wire [LOAD_SLOTS-1:0] return_candidates,return_grants;
  wire [LOAD_SLOTS*RETURN_BITS-1:0] return_words;
  wire [RETURN_BITS-1:0] return_payload;
  for(genvar waiter=0;waiter<LOAD_SLOTS;waiter=waiter+1) begin: choose_return
    assign return_candidates[waiter]=waiter_next[waiter].valid &&
      (waiter_next[waiter].error || word_valid_next[waiter_next[waiter].physical][waiter_next[waiter].word_index]);
    assign return_grants[waiter]=return_candidates[waiter] &&
      !(|(return_candidates & (({LOAD_SLOTS{1'b1}}) >> (LOAD_SLOTS-waiter))));
    assign return_words[waiter*RETURN_BITS+:RETURN_BITS]=
      {waiter_next[waiter].error,LT'(waiter),waiter_next[waiter].physical,waiter_next[waiter].word_index};
  end
  v2_grant_read #(.ENTRIES(LOAD_SLOTS),.WORD_BITS(RETURN_BITS)) choose_return_payload (
    .grant(return_grants),.words(return_words),.value(return_payload));
  assign return_valid_next=|return_candidates;
  assign {return_error_next,return_tag_next,return_address_next}=return_payload;
"""+cache[stop:]
 changed['v2_dcache.sv']=cache
spec=importlib.util.spec_from_file_location('export_plain','scripts/area_v2/export_plain.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
package=(BASE/'cpu_pkg.sv').read_text();result='// Frozen stage8 experiment.\n'
for source in sorted(BASE.glob('*.sv')):
 if source.name=='cpu_pkg.sv':continue
 data=changed.get(source.name,source.read_text())
 result+=m.lower(data,package)+'\n'
 if source.name in changed:(out/source.name).write_text(data)
for name,data in changed.items():
 if not (BASE/name).exists():
  result+=m.lower(data,package)+'\n'
  (out/name).write_text(data)
(out/'area_v2_core.v').write_text(result)
for name in ('student_top.sv','pararisc_axi_adapter.sv'):(out/name).write_bytes((BASE.parent/name).read_bytes())
if a.rob_bits is not None:
 top=(out/'student_top.sv').read_text();assert top.count('ROB_BITS=5')==1;top=top.replace('ROB_BITS=5',f'ROB_BITS={a.rob_bits}');(out/'student_top.sv').write_text(top)
if a.dc_index_bits is not None:
 top=(out/'student_top.sv').read_text();assert top.count('DC_INDEX_BITS=4')==1;top=top.replace('DC_INDEX_BITS=4',f'DC_INDEX_BITS={a.dc_index_bits}');(out/'student_top.sv').write_text(top)
(out/'filelist.f').write_text('area_v2_core.v\npararisc_axi_adapter.sv\nstudent_top.sv\n')
(out/'source-hashes.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.suffix in ('.v','.sv')},indent=2)+'\n')
(out/'trial-options.json').write_text(json.dumps(vars(a),indent=2)+'\n')
print(out/'filelist.f')
