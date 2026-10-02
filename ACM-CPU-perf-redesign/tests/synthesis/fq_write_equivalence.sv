module fq_write_equivalence #(parameter integer WIDTH=669)(
 input logic rst,
 input logic [3:0] enabled,
 input logic [WIDTH-1:0] old_data,mask,
 input logic [4*WIDTH-1:0] lane_data,
 output logic equivalent
);
 logic [WIDTH-1:0] conditional_writes,single_write,selected;
 logic write_enable;
 always_comb begin
   conditional_writes=old_data;single_write=old_data;selected=0;write_enable=0;
   for(integer lane=0;lane<4;lane=lane+1) begin
     if(!rst && enabled[lane]) conditional_writes=lane_data[lane*WIDTH+:WIDTH] & mask;
     if(enabled[lane]) begin selected=lane_data[lane*WIDTH+:WIDTH];write_enable=1;end
   end
   if(!rst && write_enable) single_write=selected & mask;
   equivalent=conditional_writes==single_write;
 end
endmodule
