module forwarding_equivalence #(parameter integer N=4, W=$clog2(N)) (
 input logic [W-1:0] csb_head,rob_head,load_rid,
 input logic [W:0] csb_count,
 input logic [N-1:0] csb_valid,rob_valid,rob_ready,rob_addr_ready,rob_is_store,rob_fault,
 input logic [N*8-1:0] csb_addr,rob_addr,
 input logic [N*32-1:0] csb_data,rob_data,
 input logic [N*4-1:0] csb_mask,rob_mask,
 input logic [7:0] address,input logic [3:0] mask,
 output logic assumptions,equivalent
);
 function automatic integer distance(input integer r,input integer h);
   return r>=h ? r-h:r+N-h;
 endfunction
 logic [3:0] old_fmask,new_fmask,old_block,new_block,old_from,new_from;
 logic [31:0] old_data,new_data;
 logic [4*W-1:0] old_owner,new_owner,old_wait,new_wait;
 integer csb_age[4], rob_age[4];
 logic [3:0] csb_found,rob_found;
 always_comb begin
   integer slot,age;
   old_fmask=0;new_fmask=0;old_block=0;new_block=0;old_from=0;new_from=0;
   old_data=0;new_data=0;old_owner=0;new_owner=0;old_wait=0;new_wait=0;
   csb_found=0;rob_found=0;slot=0;age=0;
   for(integer b=0;b<4;b++) begin csb_age[b]=0;rob_age[b]=0;end
   assumptions=csb_count<=N;
   for(integer n=0;n<N;n++) begin
     age=distance(n,csb_head);
     if(csb_valid[n] != (age<csb_count)) assumptions=0;
   end
   for(integer n=0;n<N;n++) begin
     slot=(csb_head+n)%N;
     if(n<csb_count && csb_addr[slot*8+:8]==address)
       for(integer b=0;b<4;b++) if(csb_mask[slot*4+b]) begin
         old_fmask[b]=1;old_data[b*8+:8]=csb_data[slot*32+b*8+:8];
       end
   end
   for(integer n=0;n<N;n++) begin
     slot=(rob_head+n)%N;
     if(n<distance(load_rid,rob_head) && rob_valid[slot] && rob_is_store[slot] &&
       rob_addr_ready[slot] && !rob_fault[slot] && rob_addr[slot*8+:8]==address)
       for(integer b=0;b<4;b++) if(rob_mask[slot*4+b]) begin
         old_block[b]=!rob_ready[slot];old_wait[b*W+:W]=W'(slot);
         if(rob_ready[slot]) begin
           old_fmask[b]=1;old_data[b*8+:8]=rob_data[slot*32+b*8+:8];
           old_from[b]=1;old_owner[b*W+:W]=W'(slot);
         end
       end
   end
   for(integer n=0;n<N;n++) begin
     age=distance(n,csb_head);
     if(csb_valid[n] && csb_addr[n*8+:8]==address)
       for(integer b=0;b<4;b++) if(csb_mask[n*4+b] && (!csb_found[b] || age>csb_age[b])) begin
         csb_found[b]=1;csb_age[b]=age;
         new_fmask[b]=1;new_data[b*8+:8]=csb_data[n*32+b*8+:8];
       end
   end
   for(integer n=0;n<N;n++) begin
     age=distance(n,rob_head);
     if(age<distance(load_rid,rob_head) && rob_valid[n] && rob_is_store[n] &&
       rob_addr_ready[n] && !rob_fault[n] && rob_addr[n*8+:8]==address)
       for(integer b=0;b<4;b++) if(rob_mask[n*4+b] && (!rob_found[b] || age>rob_age[b])) begin
         rob_found[b]=1;rob_age[b]=age;
         new_block[b]=!rob_ready[n];new_wait[b*W+:W]=W'(n);
         if(rob_ready[n]) begin
           new_fmask[b]=1;new_data[b*8+:8]=rob_data[n*32+b*8+:8];
           new_from[b]=1;new_owner[b*W+:W]=W'(n);
         end
       end
   end
   equivalent=1;
   if(assumptions) begin
     if((old_block & mask)!=(new_block & mask)) equivalent=0;
     for(integer b=0;b<4;b++) if(mask[b]) begin
       if(old_block[b]) begin
         if(old_wait[b*W+:W]!=new_wait[b*W+:W]) equivalent=0;
       end else begin
         if(old_fmask[b]!=new_fmask[b] || old_from[b]!=new_from[b]) equivalent=0;
         if(old_fmask[b] && old_data[b*8+:8]!=new_data[b*8+:8]) equivalent=0;
         if(old_from[b] && old_owner[b*W+:W]!=new_owner[b*W+:W]) equivalent=0;
       end
     end
   end
 end
endmodule
