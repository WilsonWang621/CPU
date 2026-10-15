// Retain a data word's enable decode locally. Split its control loads into
// byte-sized groups using preserved ordinary RTL inverters.
(* keep_hierarchy=1 *)
module v2_priority_register #(
  parameter integer WORD_BITS=32, PORTS=2, GROUP_BITS=8,
  parameter integer GROUPS=(WORD_BITS+GROUP_BITS-1)/GROUP_BITS
)(
  input wire clk,clear,
  input wire [PORTS-1:0] enable,
  input wire [PORTS*WORD_BITS-1:0] data,
  output logic [WORD_BITS-1:0] value
);
  wire [(PORTS+1)*GROUPS-1:0] controls;
  v2_distribution #(.WIDTH(PORTS+1),.LEAVES(GROUPS)) control_tree (
    .data_in({clear,enable}),.data_out(controls));
  for(genvar bit_id=0;bit_id<WORD_BITS;bit_id=bit_id+1) begin: bit_register
    wire [PORTS:0] local_control=controls[(bit_id/GROUP_BITS)*(PORTS+1)+:PORTS+1];
    always_ff @(posedge clk) begin
      if(local_control[PORTS]) value[bit_id]<=0;
      else begin
        // Higher numbered ports have priority, matching procedural writes.
        for(integer port_id=0;port_id<PORTS;port_id=port_id+1)
          if(local_control[port_id]) value[bit_id]<=data[port_id*WORD_BITS+bit_id];
      end
    end
  end
endmodule
