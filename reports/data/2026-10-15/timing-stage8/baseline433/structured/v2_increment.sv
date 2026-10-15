// Parallel prefixes bound carry depth and fanout for fixed-stride PC updates.
module v2_increment #(parameter integer BITS=30)(
  input wire [BITS-1:0] value,
  output wire [BITS-1:0] result
);
  localparam integer LEVELS=$clog2(BITS);
  for(genvar level=0;level<=LEVELS;level=level+1) begin: stage
    wire [BITS-1:0] prefix;
    if(level==0) begin: input_bits
      assign prefix=value;
    end else begin: merge
      for(genvar bit_id=0;bit_id<BITS;bit_id=bit_id+1) begin: bits
        if(bit_id>=2**(level-1)) begin: joined
          v2_inc_join combine (
            .a(stage[level-1].prefix[bit_id]),
            .b(stage[level-1].prefix[bit_id-2**(level-1)]),.value(prefix[bit_id]));
        end else begin: unchanged
          assign prefix[bit_id]=stage[level-1].prefix[bit_id];
        end
      end
    end
  end
  assign result[0]=!value[0];
  for(genvar bit_id=1;bit_id<BITS;bit_id=bit_id+1) begin: sum_bits
    assign result[bit_id]=value[bit_id] ^ stage[LEVELS].prefix[bit_id-1];
  end
endmodule

(* keep_hierarchy=1 *)
module v2_inc_join(input wire a,b,output wire value);
  assign value=a & b;
endmodule
