// Complete projected-state induction: all request/core snapshots are bounded;
// only valid FQ payloads need be bounded because the FQ is intentionally unreset.
// Independently selected source/destination entries represent arbitrary indices,
// bank sizes and alias patterns. Other record fields are unchanged by masks.
module ras_storage_induction #(parameter integer RAS_DEPTH=4)(
 input logic rst,advance,redirect_valid,request_write,fq_write,fq_invalidate,core_write,
 input logic fq_destination_valid,fq_source_valid,
 input logic [511:0] predictor_state,request_state,request_source,fq_state,fq_source,core_state,
 input logic [511:0] redirect_stack,
 input logic [4:0] stack_count,redirect_count,
 input logic [3:0] update_enable,pop,push,
 input logic [127:0] pcs,
 input logic [31:0] redirect_pc,
 input logic redirect_pop,redirect_push,
 output logic equivalent
);
 localparam logic [511:0] RAS_MASK={512{1'b1}} >> (512-32*RAS_DEPTH);
 logic [511:0] walk,pnext,rnext,fnext,cnext,pmasked,rmasked,fmasked,cmasked;
 logic [4:0] count;
 logic [516:0] updated;
 logic fvalid_next,hypothesis,next_invariant,unchanged,legal_checkpoint_source;
 function automatic logic bounded(input logic [511:0] value);
   return (value & ~RAS_MASK)==0;
 endfunction
  function automatic logic [516:0] update_ras(input logic [511:0] stack,
    input logic [4:0] count,input logic [31:0] pc,input logic pop,input logic push);
    logic [511:0] value;
    logic [4:0] depth;
    begin
      value=stack;depth=count;
      if(RAS_DEPTH>0) begin
        if(pop && depth!=0) begin value=value>>32;depth=depth-5'd1;end
        if(push) begin
          value={value[479:0],pc+32'd4};
          if(int'(depth)<RAS_DEPTH) depth=depth+5'd1;
        end
        for(integer k=RAS_DEPTH;k<16;k=k+1) value[k*32+:32]=32'b0;
      end else begin value=0;depth=0;end
      return {depth,value};
    end
  endfunction
 always_comb begin
   walk=predictor_state;count=stack_count;updated=0;
   for(integer lane=0;lane<4;lane=lane+1) if(update_enable[lane]) begin
     updated=update_ras(walk,count,pcs[lane*32+:32],pop[lane],push[lane]);
     walk=updated[511:0];count=updated[516:512];
   end
   if(redirect_valid) begin
     updated=update_ras(redirect_stack,redirect_count,redirect_pc,redirect_pop,redirect_push);
     walk=updated[511:0];
   end
   pnext=predictor_state;pmasked=predictor_state;
   rnext=request_write ? predictor_state:request_state;rmasked=rnext & RAS_MASK;
   fnext=fq_state;fmasked=fq_state;fvalid_next=fq_destination_valid;
   cnext=core_write ? fq_source:core_state;cmasked=cnext & RAS_MASK;
   if(rst) begin
     pnext=0;pmasked=0;rnext=0;rmasked=0;cnext=0;cmasked=0;fvalid_next=0;
   end else begin
     if(advance || redirect_valid) begin pnext=walk;pmasked=walk & RAS_MASK;end
     if(fq_invalidate) fvalid_next=0;
     if(fq_write) begin fnext=request_source;fmasked=request_source & RAS_MASK;fvalid_next=1;end
   end
   hypothesis=bounded(predictor_state) && bounded(request_state) &&
     bounded(request_source) && bounded(core_state) &&
     (!fq_destination_valid || bounded(fq_state)) && (!fq_source_valid || bounded(fq_source));
   // Follows directly from core's fetch_valid guard on rename/checkpoint writes.
   legal_checkpoint_source=!core_write || fq_source_valid;
   next_invariant=bounded(pnext) && bounded(rnext) && bounded(cnext) && (!fvalid_next || bounded(fnext));
   unchanged=pnext==pmasked && rnext==rmasked && cnext==cmasked && fnext==fmasked;
   equivalent=1;
   if(rst || (hypothesis && legal_checkpoint_source)) equivalent=next_invariant && unchanged;
 end
endmodule
