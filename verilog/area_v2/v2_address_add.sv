// Four-bit sums run in parallel. A balanced prefix supplies the inter-block
// carries, keeping a forwarded memory operand off a 32-bit ripple chain.
module v2_address_add(
  input wire [31:0] a,b,
  output wire [31:0] value
);
  wire [7:0] p,g;
  wire [31:0] zero_sum,one_sum;
  for(genvar block_id=0;block_id<8;block_id=block_id+1) begin: blocks
    v2_address_chunk chunk (
      .a(a[block_id*4+:4]),.b(b[block_id*4+:4]),
      .propagate(p[block_id]),.generate_carry(g[block_id]),
      .zero_sum(zero_sum[block_id*4+:4]),.one_sum(one_sum[block_id*4+:4]));
  end
  for(genvar level=0;level<4;level=level+1) begin: prefix
    wire [7:0] propagate,generate_carry;
    for(genvar block_id=0;block_id<8;block_id=block_id+1) begin: blocks
      if(level==0) begin: initial_group
        assign propagate[block_id]=p[block_id];
        assign generate_carry[block_id]=g[block_id];
      end else if(block_id >= (1<<(level-1))) begin: combine
        assign propagate[block_id]=prefix[level-1].propagate[block_id] &
          prefix[level-1].propagate[block_id-(1<<(level-1))];
        assign generate_carry[block_id]=prefix[level-1].generate_carry[block_id] |
          (prefix[level-1].propagate[block_id] & prefix[level-1].generate_carry[block_id-(1<<(level-1))]);
      end else begin: pass_group
        assign propagate[block_id]=prefix[level-1].propagate[block_id];
        assign generate_carry[block_id]=prefix[level-1].generate_carry[block_id];
      end
    end
  end
  for(genvar block_id=0;block_id<8;block_id=block_id+1) begin: result_blocks
    if(block_id==0) begin: low
      assign value[block_id*4+:4]=zero_sum[block_id*4+:4];
    end else begin: high
      assign value[block_id*4+:4]=prefix[3].generate_carry[block_id-1] ?
        one_sum[block_id*4+:4]:zero_sum[block_id*4+:4];
    end
  end
endmodule
