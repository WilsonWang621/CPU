// Two-wide Tomasulo backend. ROB entries also hold reservation-station operands.
// Architectural registers change only at the ROB head; stores leave at commit.
module pararisc_backend #(parameter integer ROB_BITS = 4) (
  input wire clock, reset, bus_fault,
  input wire fetch_valid, fetch_two,
  output wire fetch_ready,
  input wire [31:0] fetch_pc, fetch_i0, fetch_i1, fetch_pred0, fetch_pred1,
  output wire redirect,
  output wire [31:0] redirect_pc,
  output wire frontend_redirect,
  output wire [31:0] frontend_redirect_pc,
  output wire train_valid,
  output wire [31:0] train_pc, train_target,
  output wire train_taken, train_conditional, train_indirect,
  output wire store_valid,
  input wire store_ready,
  output wire [31:0] store_addr, store_data,
  output wire [3:0] store_mask,
  output wire load_valid,
  input wire load_ready,
  output wire [31:0] load_addr,
  output wire [4:0] load_word,
  input wire load_resp_valid,
  output wire load_resp_ready,
  input wire [31:0] load_resp_data
);
  localparam integer N = 1 << ROB_BITS;
  reg [N-1:0] live, issued, done, exceptional, wrong_path, address_done;
  reg [N-1:0] a_ready, b_ready;
  reg [31:0] inst [0:N-1], pcs [0:N-1], predicted [0:N-1];
  reg [31:0] result [0:N-1], actual [0:N-1];
  reg [31:0] aval [0:N-1], bval [0:N-1];
  reg [ROB_BITS-1:0] atag [0:N-1], btag [0:N-1];
  reg [4:0] dest [0:N-1];
  reg [ROB_BITS-1:0] head, tail;
  reg [ROB_BITS:0] count;
  reg [31:0] rf [0:31];
  reg [31:0] mapped;
  reg [ROB_BITS-1:0] rat [0:31];
  reg halted;
  reg early_valid;
  reg [ROB_BITS-1:0] early_tag;

  reg ex0_valid, ex1_valid;
  reg [ROB_BITS-1:0] ex0_tag, ex1_tag;
  reg [31:0] ex0_inst, ex0_pc, ex0_pred, ex0_a, ex0_b;
  reg [31:0] ex1_inst, ex1_pc, ex1_pred, ex1_a, ex1_b;
  wire [31:0] ex0_value, ex0_target, ex1_value, ex1_target;
  wire ex0_branch, ex0_taken, ex0_fault, ex1_branch, ex1_taken, ex1_fault;
  pararisc_alu alu0 (.insn(ex0_inst), .pc(ex0_pc), .a(ex0_a), .b(ex0_b),
    .value(ex0_value), .target(ex0_target), .branch(ex0_branch), .taken(ex0_taken), .illegal(ex0_fault));
  pararisc_alu alu1 (.insn(ex1_inst), .pc(ex1_pc), .a(ex1_a), .b(ex1_b),
    .value(ex1_value), .target(ex1_target), .branch(ex1_branch), .taken(ex1_taken), .illegal(ex1_fault));

  reg [3:0] lq_live, lq_sent;
  reg [1:0] lq_head, lq_tail, lq_send;
  reg [2:0] lq_count;
  reg [31:0] lq_address [0:3];
  reg [2:0] lq_funct [0:3];
  reg [ROB_BITS-1:0] lq_tag [0:3];
  reg ld_killed;
  wire ld_active = lq_count != 0;
  wire ld_sent = lq_sent[lq_head];
  wire [31:0] ld_address = lq_address[lq_head];
  wire [2:0] ld_funct = lq_funct[lq_head];
  wire [ROB_BITS-1:0] ld_tag = lq_tag[lq_head];
  assign load_valid = lq_live[lq_send] && !lq_sent[lq_send] && !redirect && !halted;
  assign load_addr = lq_address[lq_send];
  assign load_word = ld_address[6:2];
  wire [31:0] shifted_load = load_resp_data >> {ld_address[1:0], 3'b0};
  reg [31:0] load_value;
  always @* case (ld_funct)
    0: load_value = {{24{shifted_load[7]}},shifted_load[7:0]};
    1: load_value = {{16{shifted_load[15]}},shifted_load[15:0]};
    2: load_value = shifted_load;
    4: load_value = {24'b0,shifted_load[7:0]};
    5: load_value = {16'b0,shifted_load[15:0]};
    default: load_value = 0;
  endcase
  wire mdu_ready, mdu_valid, mdu_accept;
  wire [31:0] mdu_value;
  wire [ROB_BITS-1:0] mdu_tag;
  reg issue_mdu;
  reg [ROB_BITS-1:0] pick_mdu;
  reg [31:0] mdu_a, mdu_b;
  pararisc_mdu #(.TAG_BITS(ROB_BITS)) mdu (
    .clock(clock), .reset(reset), .flush(redirect), .req_valid(issue_mdu), .req_ready(mdu_ready),
    .req_a(mdu_a), .req_b(mdu_b), .req_op(inst[pick_mdu][14:12]), .req_tag(pick_mdu),
    .resp_valid(mdu_valid), .resp_ready(mdu_accept), .resp_value(mdu_value), .resp_tag(mdu_tag)
  );

  wire wb0 = ex0_valid && !redirect && !halted;
  wire wb_load = load_resp_valid && ld_active && !ld_killed;
  wire wb_mdu = !wb_load && mdu_valid;
  wire wb_ex1 = !wb_load && !mdu_valid && ex1_valid;
  wire wb1 = (wb_load || wb_mdu || wb_ex1) && !redirect && !halted;
  wire [ROB_BITS-1:0] wb1_tag = wb_load ? ld_tag : (wb_mdu ? mdu_tag : ex1_tag);
  wire [31:0] wb1_value = wb_load ? load_value : (wb_mdu ? mdu_value : ex1_value);
  assign load_resp_ready = ld_killed || redirect || (wb1 && wb_load);
  assign mdu_accept = wb1 && wb_mdu;

  wire [ROB_BITS-1:0] head1 = head + 1'b1;
  wire head_store = inst[head][6:0] == 7'h23;
  wire next_store = inst[head1][6:0] == 7'h23;
  wire retire0 = count != 0 && done[head] && !exceptional[head] && !halted &&
    (!head_store || store_ready);
  wire retire1 = count > 1 && retire0 && !wrong_path[head] && done[head1] &&
    !exceptional[head1] && (!next_store || (!head_store && store_ready));
  assign redirect = (retire0 && wrong_path[head]) || (retire1 && wrong_path[head1]);
  assign redirect_pc = wrong_path[head] ? actual[head] : actual[head1];
  wire [ROB_BITS-1:0] redirect_tag = wrong_path[head] ? head : head1;
  wire [ROB_BITS-1:0] age0 = ex0_tag-head, age1 = ex1_tag-head, early_age=early_tag-head;
  wire early0 = wb0 && ex0_branch && ex0_target != ex0_pred && (!early_valid || age0 < early_age);
  wire early1 = wb1 && wb_ex1 && ex1_branch && ex1_target != ex1_pred && (!early_valid || age1 < early_age);
  wire select_early1 = early1 && (!early0 || age1 < age0);
  wire new_early = early0 || early1;
  assign frontend_redirect = new_early || (redirect && (!early_valid || early_tag != redirect_tag));
  assign frontend_redirect_pc = new_early ? (select_early1 ? ex1_target : ex0_target) : redirect_pc;
  wire [ROB_BITS-1:0] store_head = head_store ? head : head1;
  assign store_valid = !halted && count != 0 && done[head] && !exceptional[head] &&
    (head_store || (count > 1 && !wrong_path[head] && done[head1] && !exceptional[head1] && next_store));
  assign store_addr = {result[store_head][31:2], 2'b0};
  assign store_data = bval[store_head] << {result[store_head][1:0], 3'b0};
  assign store_mask = inst[store_head][14:12] == 0 ? 4'b1 << result[store_head][1:0] :
    (inst[store_head][14:12] == 1 ? 4'b11 << result[store_head][1:0] : 4'hf);
  function automatic is_control(input [31:0] insn);
    is_control = insn[6:0] == 7'h63 || insn[6:0] == 7'h6f || insn[6:0] == 7'h67;
  endfunction
  wire train_second = retire1 && is_control(inst[head1]);
  wire [ROB_BITS-1:0] train_head = train_second ? head1 : head;
  assign train_valid = (retire0 && is_control(inst[head])) || train_second;
  assign train_pc = pcs[train_head];
  assign train_target = actual[train_head];
  assign train_taken = actual[train_head] != pcs[train_head] + 4;
  assign train_conditional = inst[train_head][6:0] == 7'h63;
  assign train_indirect = inst[train_head][6:0] == 7'h67;

  function automatic [4:0] destination(input [31:0] insn);
    case (insn[6:0])
      7'h37,7'h17,7'h13,7'h33,7'h03,7'h6f,7'h67: destination = insn[11:7];
      default: destination = 0;
    endcase
  endfunction
  function automatic [4:0] source_a(input [31:0] insn);
    case (insn[6:0])
      7'h13,7'h33,7'h03,7'h23,7'h63,7'h67: source_a = insn[19:15];
      default: source_a = 0;
    endcase
  endfunction
  function automatic [4:0] source_b(input [31:0] insn);
    case (insn[6:0])
      7'h33,7'h23,7'h63: source_b = insn[24:20];
      default: source_b = 0;
    endcase
  endfunction
  // {ready, producer tag, value}; explicit completion bypass covers dispatch on writeback.
  function automatic [ROB_BITS+32:0] read_source(input [4:0] arch);
    reg r;
    reg [ROB_BITS-1:0] t;
    reg [31:0] v;
    begin
      t = rat[arch]; r = 1; v = arch == 0 ? 0 : rf[arch];
      if (arch != 0 && mapped[arch]) begin
        r = done[t]; v = result[t];
        if (wb0 && ex0_tag == t) begin r = 1; v = ex0_value; end
        if (wb1 && wb1_tag == t) begin r = 1; v = wb1_value; end
      end
      read_source = {r,t,v};
    end
  endfunction
  wire [ROB_BITS-1:0] tail1 = tail + 1'b1;
  wire [4:0] dst0 = destination(fetch_i0), dst1 = destination(fetch_i1);
  wire [ROB_BITS+32:0] src0a = read_source(source_a(fetch_i0));
  wire [ROB_BITS+32:0] src0b = read_source(source_b(fetch_i0));
  wire [ROB_BITS+32:0] src1a = dst0 != 0 && dst0 == source_a(fetch_i1) ?
    {1'b0,tail,32'b0} : read_source(source_a(fetch_i1));
  wire [ROB_BITS+32:0] src1b = dst0 != 0 && dst0 == source_b(fetch_i1) ?
    {1'b0,tail,32'b0} : read_source(source_b(fetch_i1));
  assign fetch_ready = count <= N-2 && !redirect && !halted && !early_valid && !new_early;
  wire dispatch = fetch_valid && fetch_ready;

  reg issue0, issue1, issue_load;
  reg [ROB_BITS-1:0] pick0, pick1, pick_load;
  reg [31:0] issue0_a, issue0_b, issue1_a, issue1_b, load_a;
  reg [N-1:0] ready_bits;
  reg [31:0] effective_a [0:N-1], effective_b [0:N-1];
  integer chosen;
  reg ra, rb, older_store;
  reg [ROB_BITS-1:0] age_i, age_j;
  reg [31:0] candidate_address;
  always @* begin
    for (integer k=0; k<N; k=k+1) begin
      effective_a[k] = aval[k]; effective_b[k] = bval[k];
      ra = a_ready[k]; rb = b_ready[k];
      if (!a_ready[k] && wb0 && atag[k] == ex0_tag) begin ra = 1; effective_a[k] = ex0_value; end
      if (!a_ready[k] && wb1 && atag[k] == wb1_tag) begin ra = 1; effective_a[k] = wb1_value; end
      if (!b_ready[k] && wb0 && btag[k] == ex0_tag) begin rb = 1; effective_b[k] = ex0_value; end
      if (!b_ready[k] && wb1 && btag[k] == wb1_tag) begin rb = 1; effective_b[k] = wb1_value; end
      ready_bits[k] = live[k] && !issued[k] && ra && (rb || inst[k][6:0] == 7'h23);
    end
    issue0 = 0; issue1 = 0; issue_mdu = 0; issue_load = 0; chosen = 0;
    pick0 = 0; pick1 = 0; pick_mdu = 0; pick_load = 0;
    issue0_a = 0; issue0_b = 0; issue1_a = 0; issue1_b = 0; mdu_a = 0; mdu_b = 0; load_a = 0;
    older_store = 0; age_i = 0; age_j = 0; candidate_address = 0;
    for (integer k=0; k<N; k=k+1) begin
      if (ready_bits[k] && chosen < 2 && !redirect && !halted &&
          (!early_valid || (ROB_BITS'(k)-head) <= early_age)) begin
        if (inst[k][6:0] == 7'h03) begin
          older_store = 0; age_i = ROB_BITS'(k) - head;
          candidate_address = effective_a[k] + {{20{inst[k][31]}},inst[k][31:20]};
          for (integer j=0; j<N; j=j+1) begin
            age_j = ROB_BITS'(j) - head;
            if (live[j] && inst[j][6:0] == 7'h23 && age_j < age_i &&
                (!address_done[j] || result[j][31:2] == candidate_address[31:2])) older_store = 1;
          end
          if (!issue_load && lq_count < 4 && !older_store) begin
            issue_load = 1; pick_load = ROB_BITS'(k); load_a = effective_a[k]; chosen = chosen+1;
          end
        end else if (inst[k][6:0] == 7'h33 && inst[k][31:25] == 1) begin
          if (!issue_mdu && mdu_ready) begin
            issue_mdu = 1; pick_mdu = ROB_BITS'(k);
            mdu_a = effective_a[k]; mdu_b = effective_b[k]; chosen = chosen+1;
          end
        end else if (!issue0) begin
          issue0 = 1; pick0 = ROB_BITS'(k); issue0_a = effective_a[k]; issue0_b = effective_b[k]; chosen = chosen+1;
        end else if (!issue1 && (!ex1_valid || wb_ex1)) begin
          issue1 = 1; pick1 = ROB_BITS'(k); issue1_a = effective_a[k]; issue1_b = effective_b[k]; chosen = chosen+1;
        end
      end
    end
  end
  wire [31:0] issued_load_addr = load_a + {{20{inst[pick_load][31]}},inst[pick_load][31:20]};
  wire [2:0] issued_load_f3 = inst[pick_load][14:12];
  wire bad_load = !(issued_load_f3 == 0 || issued_load_f3 == 1 || issued_load_f3 == 2 ||
    issued_load_f3 == 4 || issued_load_f3 == 5) ||
    ((issued_load_f3 == 1 || issued_load_f3 == 5) && issued_load_addr[0]) ||
    (issued_load_f3 == 2 && issued_load_addr[1:0] != 0);

  integer i;
  always @(posedge clock) begin
    if (reset) begin
      head <= 0; tail <= 0; count <= 0; live <= 0; issued <= 0; done <= 0;
      exceptional <= 0; wrong_path <= 0; address_done <= 0; a_ready <= 0; b_ready <= 0; mapped <= 0; halted <= 0;
      early_valid <= 0; early_tag <= 0;
      ex0_valid <= 0; ex1_valid <= 0;
      lq_live <= 0; lq_sent <= 0; lq_head <= 0; lq_tail <= 0; lq_send <= 0; lq_count <= 0; ld_killed <= 0;
      for (i=0; i<32; i=i+1) begin rf[i] <= 0; rat[i] <= 0; end
    end else begin
      if (bus_fault || (count != 0 && done[head] && exceptional[head])) halted <= 1;
      if (new_early) begin early_valid <= 1; early_tag <= select_early1 ? ex1_tag : ex0_tag; end
      ex0_valid <= issue0;
      if (issue0) begin
        ex0_tag <= pick0; ex0_inst <= inst[pick0]; ex0_pc <= pcs[pick0]; ex0_pred <= predicted[pick0];
        ex0_a <= issue0_a; ex0_b <= issue0_b; issued[pick0] <= 1;
      end
      if (wb_ex1) ex1_valid <= 0;
      if (issue1) begin
        ex1_valid <= 1; ex1_tag <= pick1; ex1_inst <= inst[pick1]; ex1_pc <= pcs[pick1]; ex1_pred <= predicted[pick1];
        ex1_a <= issue1_a; ex1_b <= issue1_b; issued[pick1] <= 1;
      end
      if (issue_mdu) issued[pick_mdu] <= 1;
      if (load_valid && load_ready) begin lq_sent[lq_send] <= 1; lq_send <= lq_send+1; end
      if (load_resp_valid && load_resp_ready) begin
        lq_live[lq_head] <= 0; lq_head <= lq_head+1; ld_killed <= 0;
      end
      lq_count <= lq_count + 3'(issue_load && !bad_load) - 3'(load_resp_valid && load_resp_ready);
      if (issue_load) begin
        issued[pick_load] <= 1;
        if (bad_load) begin exceptional[pick_load] <= 1; done[pick_load] <= 1; end
        else begin
          lq_live[lq_tail] <= 1; lq_sent[lq_tail] <= 0; lq_address[lq_tail] <= issued_load_addr;
          lq_funct[lq_tail] <= issued_load_f3; lq_tag[lq_tail] <= pick_load; lq_tail <= lq_tail+1;
        end
      end
      if (wb0) begin
        result[ex0_tag] <= ex0_value; actual[ex0_tag] <= ex0_target;
        done[ex0_tag] <= ex0_inst[6:0] != 7'h23 || b_ready[ex0_tag];
        if (ex0_inst[6:0] == 7'h23) address_done[ex0_tag] <= 1;
        exceptional[ex0_tag] <= ex0_fault; wrong_path[ex0_tag] <= ex0_branch && ex0_target != ex0_pred;
      end
      if (wb1) begin
        result[wb1_tag] <= wb1_value; done[wb1_tag] <= 1;
        if (wb_ex1) begin
          actual[wb1_tag] <= ex1_target;
          if (ex1_inst[6:0] == 7'h23) begin address_done[wb1_tag] <= 1; done[wb1_tag] <= b_ready[wb1_tag]; end
          exceptional[wb1_tag] <= ex1_fault; wrong_path[wb1_tag] <= ex1_branch && ex1_target != ex1_pred;
        end
      end
      for (i=0; i<N; i=i+1) begin
        if (live[i]) begin
          if (address_done[i] && b_ready[i]) done[i] <= 1;
          if (!a_ready[i] && ((wb0 && atag[i] == ex0_tag) || (wb1 && atag[i] == wb1_tag))) begin
            a_ready[i] <= 1; aval[i] <= wb1 && atag[i] == wb1_tag ? wb1_value : ex0_value;
          end
          if (!b_ready[i] && ((wb0 && btag[i] == ex0_tag) || (wb1 && btag[i] == wb1_tag))) begin
            b_ready[i] <= 1; bval[i] <= wb1 && btag[i] == wb1_tag ? wb1_value : ex0_value;
          end
        end
      end
      if (retire0) begin
        live[head] <= 0;
        if (dest[head] != 0) begin
          rf[dest[head]] <= result[head];
          if (mapped[dest[head]] && rat[dest[head]] == head) mapped[dest[head]] <= 0;
        end
      end
      if (retire1) begin
        live[head1] <= 0;
        if (dest[head1] != 0) begin
          rf[dest[head1]] <= result[head1];
          if (mapped[dest[head1]] && rat[dest[head1]] == head1) mapped[dest[head1]] <= 0;
        end
      end
      head <= head + {{(ROB_BITS-1){1'b0}},retire0} + {{(ROB_BITS-1){1'b0}},retire1};
      count <= count + (dispatch ? (fetch_two ? 2 : 1) : 0) - {{ROB_BITS{1'b0}},retire0} - {{ROB_BITS{1'b0}},retire1};
      if (dispatch) begin
        live[tail] <= 1; issued[tail] <= 0; done[tail] <= 0; exceptional[tail] <= 0; wrong_path[tail] <= 0; address_done[tail] <= 0;
        inst[tail] <= fetch_i0; pcs[tail] <= fetch_pc; predicted[tail] <= fetch_pred0; dest[tail] <= dst0;
        {a_ready[tail],atag[tail],aval[tail]} <= src0a;
        {b_ready[tail],btag[tail],bval[tail]} <= src0b;
        if (dst0 != 0) begin mapped[dst0] <= 1; rat[dst0] <= tail; end
        if (fetch_two) begin
          live[tail1] <= 1; issued[tail1] <= 0; done[tail1] <= 0; exceptional[tail1] <= 0; wrong_path[tail1] <= 0; address_done[tail1] <= 0;
          inst[tail1] <= fetch_i1; pcs[tail1] <= fetch_pc+4; predicted[tail1] <= fetch_pred1; dest[tail1] <= dst1;
          {a_ready[tail1],atag[tail1],aval[tail1]} <= src1a;
          {b_ready[tail1],btag[tail1],bval[tail1]} <= src1b;
          if (dst1 != 0) begin mapped[dst1] <= 1; rat[dst1] <= tail1; end
        end
        tail <= tail + (fetch_two ? 2 : 1);
      end
      if (redirect) begin
        early_valid <= 0;
        head <= 0; tail <= 0; count <= 0; live <= 0; issued <= 0; done <= 0;
        mapped <= 0; exceptional <= 0; wrong_path <= 0; address_done <= 0; ex0_valid <= 0; ex1_valid <= 0;
        if (ld_active && ld_sent && !(load_resp_valid && load_resp_ready)) begin
          ld_killed <= 1; lq_count <= 1; lq_live <= 4'b1 << lq_head; lq_sent <= 4'b1 << lq_head;
          lq_tail <= lq_head+1; lq_send <= lq_head+1;
        end else begin
          lq_live <= 0; lq_sent <= 0; lq_head <= 0; lq_tail <= 0; lq_send <= 0; lq_count <= 0; ld_killed <= 0;
        end
      end
    end
  end
`ifdef PARARISC_TRACE
  always @(posedge clock) if (!reset) begin
    if (retire0) $display("RET %08x %08x x%0d=%08x",pcs[head],inst[head],dest[head],result[head]);
    if (retire1) $display("RET %08x %08x x%0d=%08x",pcs[head1],inst[head1],dest[head1],result[head1]);
    if (redirect) $display("REDIRECT %08x",redirect_pc);
    if (halted) $display("HALT head=%0d pc=%08x insn=%08x",head,pcs[head],inst[head]);
  end
`endif
endmodule
