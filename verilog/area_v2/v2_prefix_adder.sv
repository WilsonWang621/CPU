(* keep_hierarchy=1 *)
module v2_prefix_adder #(parameter integer WIDTH=32)(
  input wire [WIDTH-1:0] a,b,
  input wire carry_in,
  output wire [WIDTH-1:0] sum,
  output wire carry_out
);
  localparam integer LEVELS=$clog2(WIDTH);
  wire [WIDTH-1:0] initial_g;
  wire [WIDTH-1:0] bit_propagates=a^b;
  for(genvar bit_id=0;bit_id<WIDTH;bit_id=bit_id+1) begin: initial_bit
    if(bit_id==0) begin: first
      assign initial_g[bit_id]=(a[bit_id]&b[bit_id]) | (bit_propagates[bit_id]&carry_in);
    end else begin: later
      assign initial_g[bit_id]=a[bit_id]&b[bit_id];
    end
  end
  for(genvar level=0;level<LEVELS;level=level+1) begin: prefix_level
    wire [WIDTH-1:0] input_g,input_p,group_g,group_p;
    if(level==0) begin: first_level
      assign input_g=initial_g;
      assign input_p=bit_propagates;
    end else begin: later_level
      assign input_g=prefix_level[level-1].group_g;
      assign input_p=prefix_level[level-1].group_p;
    end
    for(genvar bit_id=0;bit_id<WIDTH;bit_id=bit_id+1) begin: prefix_bit
      if(bit_id>=(1<<level)) begin: composed
        v2_prefix_node compose (
          .high_g(input_g[bit_id]),.high_p(input_p[bit_id]),
          .low_g(input_g[bit_id-(1<<level)]),.low_p(input_p[bit_id-(1<<level)]),
          .group_g(group_g[bit_id]),.group_p(group_p[bit_id]));
      end else begin: pass
        assign group_g[bit_id]=input_g[bit_id];
        assign group_p[bit_id]=input_p[bit_id];
      end
    end
  end
  for(genvar bit_id=0;bit_id<WIDTH;bit_id=bit_id+1) begin: result_bit
    if(bit_id==0) begin: first
      assign sum[bit_id]=bit_propagates[bit_id]^carry_in;
    end else begin: later
      assign sum[bit_id]=bit_propagates[bit_id]^prefix_level[LEVELS-1].group_g[bit_id-1];
    end
  end
  generate if(LEVELS==0) begin: single_bit
    assign carry_out=initial_g[WIDTH-1];
  end else begin: multi_bit
    assign carry_out=prefix_level[LEVELS-1].group_g[WIDTH-1];
  end endgenerate
endmodule
