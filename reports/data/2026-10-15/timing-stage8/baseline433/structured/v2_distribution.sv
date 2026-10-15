// A balanced binary tree of non-inverting branches. A source drives at most
// two inverter banks at each fork. Consumers choose their own leaf, so ABC
// cannot combine the downstream enables into one heavily loaded driver.
module v2_distribution #(
  parameter integer WIDTH=1, LEAVES=2
)(
  input wire [WIDTH-1:0] data_in,
  output wire [WIDTH*LEAVES-1:0] data_out
);
  generate
    if(LEAVES==1) begin: leaf
      assign data_out=data_in;
    end else begin: branch
      localparam integer LEFT=LEAVES/2, RIGHT=LEAVES-LEFT;
      wire [WIDTH-1:0] inverted_left,inverted_right,left_value,right_value;
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) left_first (
        .data_in(data_in),.data_out(inverted_left));
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) left_second (
        .data_in(inverted_left),.data_out(left_value));
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) right_first (
        .data_in(data_in),.data_out(inverted_right));
      (* keep=1 *) v2_distribution_inverter #(.WIDTH(WIDTH)) right_second (
        .data_in(inverted_right),.data_out(right_value));
      v2_distribution #(.WIDTH(WIDTH),.LEAVES(LEFT)) left_tree (
        .data_in(left_value),.data_out(data_out[0+:WIDTH*LEFT]));
      v2_distribution #(.WIDTH(WIDTH),.LEAVES(RIGHT)) right_tree (
        .data_in(right_value),.data_out(data_out[WIDTH*LEFT+:WIDTH*RIGHT]));
    end
  endgenerate
endmodule
