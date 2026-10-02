// Keep the per-word mask separate so the default ABC pass cannot turn the
// decoded read back into a bit-level mux with a shared high-fanout selector.
(* keep_hierarchy=1 *)
module v2_read_mask #(parameter integer WORD_BITS=32)(
  input wire selected,
  input wire [WORD_BITS-1:0] word,
  output wire [WORD_BITS-1:0] value
);
  assign value=word & {WORD_BITS{selected}};
endmodule
