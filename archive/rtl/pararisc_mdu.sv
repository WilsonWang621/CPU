module pararisc_mdu #(parameter integer TAG_BITS = 4) (
  input wire clock, reset, flush,
  input wire req_valid,
  output wire req_ready,
  input wire [31:0] req_a, req_b,
  input wire [2:0] req_op,
  input wire [TAG_BITS-1:0] req_tag,
  output reg resp_valid,
  input wire resp_ready,
  output reg [31:0] resp_value,
  output reg [TAG_BITS-1:0] resp_tag
);
  localparam [3:0] IDLE=0, MUL1=1, MUL2=2, MUL3=3, MUL4=4, DIV0=5, DIV1=6;
  reg [3:0] state;
  reg [31:0] a, b;
  reg [2:0] op;
  reg [31:0] pp00, pp01, pp10, pp11;
  reg [33:0] middle;
  reg [15:0] low16;
  reg [31:0] product_low, product_high;
  reg [31:0] dividend, divisor, quotient;
  reg [32:0] remainder;
  reg [5:0] count;
  reg neg_q, neg_r, rem_op;
  function automatic [5:0] length(input [31:0] x);
    integer i;
    begin
      length = 0;
      for (i=0; i<32; i=i+1) if (x[i]) length = 6'(i+1);
    end
  endfunction
  wire [5:0] shift = length(dividend) - length(divisor);
  wire subtract = remainder >= {1'b0, divisor};
  wire [32:0] next_rem = subtract ? remainder - {1'b0, divisor} : remainder;
  wire [31:0] next_q = quotient | (subtract ? 32'b1 << (count-1) : 0);
  wire [31:0] div_result = rem_op ? next_rem[31:0] : next_q;
  wire signed_div = req_op == 4 || req_op == 6;
  assign req_ready = state == IDLE && (!resp_valid || resp_ready);
  always @(posedge clock) begin
    if (reset || flush) begin
      state <= IDLE; resp_valid <= 0; resp_value <= 0; resp_tag <= 0;
      a <= 0; b <= 0; op <= 0; pp00 <= 0; pp01 <= 0; pp10 <= 0; pp11 <= 0;
      middle <= 0; low16 <= 0; product_low <= 0; product_high <= 0;
      dividend <= 0; divisor <= 0; quotient <= 0; remainder <= 0; count <= 0;
      neg_q <= 0; neg_r <= 0; rem_op <= 0;
    end else begin
      if (resp_valid && resp_ready) resp_valid <= 0;
      if (req_valid && req_ready) begin
        a <= req_a; b <= req_b; op <= req_op; resp_tag <= req_tag;
        if (req_op < 4) state <= MUL1;
        else if (req_b == 0) begin
          resp_value <= req_op[1] ? req_a : 32'hffff_ffff; resp_valid <= 1;
        end else if (signed_div && req_a == 32'h8000_0000 && req_b == 32'hffff_ffff) begin
          resp_value <= req_op[1] ? 0 : req_a; resp_valid <= 1;
        end else begin
          dividend <= signed_div && req_a[31] ? -req_a : req_a;
          divisor <= signed_div && req_b[31] ? -req_b : req_b;
          neg_q <= signed_div && (req_a[31] ^ req_b[31]);
          neg_r <= signed_div && req_a[31]; rem_op <= req_op[1];
          quotient <= 0; state <= DIV0;
        end
      end
      case (state)
        MUL1: begin
          pp00 <= a[15:0] * b[15:0]; pp01 <= a[15:0] * b[31:16];
          pp10 <= a[31:16] * b[15:0]; pp11 <= a[31:16] * b[31:16]; state <= MUL2;
        end
        MUL2: begin
          middle <= {2'b0, pp01} + {2'b0, pp10} + {18'b0, pp00[31:16]};
          low16 <= pp00[15:0]; state <= MUL3;
        end
        MUL3: begin
          product_low <= {middle[15:0], low16};
          product_high <= pp11 + {14'b0, middle[33:16]}; state <= MUL4;
        end
        MUL4: begin
          resp_value <= op == 0 ? product_low : product_high -
            (((op == 1 || op == 2) && a[31]) ? b : 0) - ((op == 1 && b[31]) ? a : 0);
          resp_valid <= 1; state <= IDLE;
        end
        DIV0: begin
          if (length(dividend) < length(divisor)) begin
            resp_value <= rem_op ? (neg_r ? -dividend : dividend) : 0;
            resp_valid <= 1; state <= IDLE;
          end else begin
            divisor <= divisor << shift; count <= shift + 1;
            remainder <= {1'b0, dividend}; state <= DIV1;
          end
        end
        DIV1: begin
          divisor <= divisor >> 1; quotient <= next_q; remainder <= next_rem; count <= count-1;
          if (count == 1) begin
            resp_value <= (rem_op ? neg_r : neg_q) ? -div_result : div_result;
            resp_valid <= 1; state <= IDLE;
          end
        end
        default: begin end
      endcase
    end
  end
endmodule
