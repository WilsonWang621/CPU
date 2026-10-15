// Keep mutually exclusive source masks and byte-local controls together.
(* keep_hierarchy=1 *)
module v2_priority_mux #(
  parameter integer WORD_BITS=32,PORTS=3,GROUP_BITS=8,
  parameter integer GROUPS=(WORD_BITS+GROUP_BITS-1)/GROUP_BITS
)(
  input wire [PORTS-1:0] enable,
  input wire [WORD_BITS-1:0] old_value,
  input wire [PORTS*WORD_BITS-1:0] data,
  output logic [WORD_BITS-1:0] value
);
  wire [PORTS-1:0] chosen;
  wire [(PORTS+1)*GROUPS-1:0] controls;
  for(genvar p=0;p<PORTS;p=p+1) begin: priority_decode
    if(p==PORTS-1) begin: last_port
      assign chosen[p]=enable[p];
    end else begin: lower_port
      assign chosen[p]=enable[p] && !(|enable[PORTS-1:p+1]);
    end
  end
  v2_distribution #(.WIDTH(PORTS+1),.LEAVES(GROUPS)) tree (
    .data_in({!(|enable),chosen}),.data_out(controls));
  for(genvar bit_id=0;bit_id<WORD_BITS;bit_id=bit_id+1) begin: bit_mux
    wire [PORTS:0] local_control=controls[(bit_id/GROUP_BITS)*(PORTS+1)+:PORTS+1];
    integer p;
    logic result_bit;
    always_comb begin
      result_bit=old_value[bit_id] && local_control[PORTS];
      for(p=0;p<PORTS;p=p+1)
        result_bit=result_bit | (data[p*WORD_BITS+bit_id] && local_control[p]);
    end
    assign value[bit_id]=result_bit;
  end
endmodule
