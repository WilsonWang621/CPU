// Pipelined, nonblocking sector cache. Valid/dirty state is per byte; fills
// preserve locally known bytes, and stores never require a read-for-ownership.
// The shared waiter pool is both a per-line operation FIFO and a response buffer.
module cache #(
    parameter integer CACHE_BYTES=16384, WAYS=4, LINE_BYTES=32,
    READ_ONLY=0, MSHRS=8, WAITERS=32, TAG_BITS=8, MAX_MEM_OUTSTANDING=64, MAX_CPU_WORDS=4
) (
    input logic clk, rst,
    input logic cpu_req_valid,
    output logic cpu_req_ready,
    input logic cpu_req_write,
    input logic [31:0] cpu_req_addr, cpu_req_wdata,
    input logic [3:0] cpu_req_wstrb,
    input logic [2:0] cpu_req_count,
    input logic [TAG_BITS-1:0] cpu_req_tag,
    output logic cpu_rsp_valid,
    input logic cpu_rsp_ready,
    output logic [127:0] cpu_rsp_data,
    output logic [TAG_BITS-1:0] cpu_rsp_tag,
    output logic cpu_rsp_error,
    output logic [3:0] cpu_rsp_error_mask,
    input logic flush_valid,
    output logic flush_done, flush_error, idle,
    output logic [63:0] miss_count,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr, mem_req_wdata,
    output logic [3:0] mem_req_wstrb,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input logic [31:0] mem_rsp_rdata,
    input logic mem_rsp_error
);
    localparam integer SETS=CACHE_BYTES/(WAYS*LINE_BYTES), WORDS=LINE_BYTES/4;
    localparam integer LINE_BITS=LINE_BYTES*8;
    localparam integer CPU_BITS=32*MAX_CPU_WORDS;
    localparam integer LINES=SETS*WAYS, OFFSET_BITS=$clog2(LINE_BYTES);
    localparam integer DATA_BITS=(READ_ONLY!=0) ? LINE_BITS:32;
    localparam integer DATA_ROWS=(READ_ONLY!=0) ? LINES:LINES*WORDS;
    localparam integer SB=SETS>1 ? $clog2(SETS):1, YB=WAYS>1 ? $clog2(WAYS):1;
    localparam integer WB=$clog2(WORDS), MB=MSHRS>1 ? $clog2(MSHRS):1;
    localparam integer QB=WAITERS>1 ? $clog2(WAITERS):1, QC=$clog2(WAITERS+1);
    localparam integer FB=MAX_MEM_OUTSTANDING>1 ? $clog2(MAX_MEM_OUTSTANDING):1;
    localparam integer FC=$clog2(MAX_MEM_OUTSTANDING+1), LB=$clog2(LINES+1);

    logic [SETS-1:0][WAYS-1:0] tag_valid;
    logic [SETS-1:0][WAYS-1:0][31:0] line_addr;
    logic [SETS-1:0][WAYS-1:0][LINE_BYTES-1:0] valid_bytes, dirty_bytes;
    // Instruction packets share a line row; data accesses use 32-bit word rows.
    // Ways are part of the row address, never packed together into a wide row.
    // The synthesis flow fully lowers this explicit storage to flip-flops.
    (* ram_style="registers" *) logic [DATA_BITS-1:0] data_array [DATA_ROWS];
    logic [LINE_BITS-1:0] instruction_hit_line,instruction_service_line;

    wire [LINE_BYTES-1:0] valid_line [LINES],dirty_line [LINES];
    wire [3:0] valid_word [LINES*WORDS],dirty_word [LINES*WORDS];
    wire [31:0] address_line [LINES];
    for(genvar row=0;row<LINES;row=row+1) begin: metadata_columns
        assign valid_line[row]=valid_bytes[row/WAYS][row%WAYS];
        assign dirty_line[row]=dirty_bytes[row/WAYS][row%WAYS];
        assign address_line[row]=line_addr[row/WAYS][row%WAYS];
        for(genvar word=0;word<WORDS;word=word+1) begin: word_columns
            assign valid_word[row*WORDS+word]=valid_bytes[row/WAYS][row%WAYS][4*word+:4];
            assign dirty_word[row*WORDS+word]=dirty_bytes[row/WAYS][row%WAYS][4*word+:4];
        end
    end
    logic [SETS-1:0][YB-1:0] replace_way;
    logic locked [SETS][WAYS];

    typedef enum logic [1:0] {M_FREE,M_WB,M_READ,M_ERROR} phase_t;
    typedef struct packed {
        phase_t phase;
        logic [SB-1:0] set_index;
        logic [YB-1:0] way;
        logic [31:0] line, victim;
        logic [WORDS-1:0] attempted, pending;
        logic [WB-1:0] cursor, critical;
        logic prefetch, error;
        logic [QB-1:0] head, tail;
        logic [QC-1:0] count;
    } miss_t;
    typedef struct packed {
        logic valid, done, write, error;
        logic [MB-1:0] slot;
        logic [QB-1:0] next_waiter;
        logic [WB-1:0] word_index;
        logic [2:0] count;
        logic [31:0] wdata;
        logic [3:0] wstrb;
        logic [3:0] error_mask;
        logic [TAG_BITS-1:0] tag;
        logic [LINE_BYTES-1:0] failed_bytes;
        logic [CPU_BITS-1:0] result;
    } waiter_t;
    typedef struct packed {
        logic flush, write;
        logic [MB-1:0] slot;
        logic [SB-1:0] set_index;
        logic [YB-1:0] way;
        logic [WB-1:0] word_index;
        logic [3:0] strobe;
    } metadata_t;
    typedef struct packed {
        logic valid;
        metadata_t meta;
        logic [31:0] address, data;
    } request_t;
    miss_t m_q[MSHRS],m_d[MSHRS];
    waiter_t w_q[WAITERS],w_d[WAITERS];

    // Narrow read columns prevent whole waiter records from entering muxes.
    wire  w_q_col_valid [WAITERS];
    wire  w_q_col_done [WAITERS];
    wire  w_q_col_write [WAITERS];
    wire  w_q_col_error [WAITERS];
    wire [MB-1:0] w_q_col_slot [WAITERS];
    wire [QB-1:0] w_q_col_next_waiter [WAITERS];
    wire [WB-1:0] w_q_col_word_index [WAITERS];
    wire [2:0] w_q_col_count [WAITERS];
    wire [3:0] w_q_col_wstrb [WAITERS];
    wire [3:0] w_q_col_error_mask [WAITERS];
    wire [TAG_BITS-1:0] w_q_col_tag [WAITERS];
    wire [LINE_BYTES-1:0] w_q_col_failed_bytes [WAITERS];
    wire [CPU_BITS-1:0] w_q_col_result [WAITERS];
    for(genvar q=0;q<WAITERS;q=q+1) begin: waiter_columns
        assign w_q_col_valid[q]=w_q[q].valid;
        assign w_q_col_done[q]=w_q[q].done;
        assign w_q_col_write[q]=w_q[q].write;
        assign w_q_col_error[q]=w_q[q].error;
        assign w_q_col_slot[q]=w_q[q].slot;
        assign w_q_col_next_waiter[q]=w_q[q].next_waiter;
        assign w_q_col_word_index[q]=w_q[q].word_index;
        assign w_q_col_count[q]=w_q[q].count;
        assign w_q_col_wstrb[q]=w_q[q].wstrb;
        assign w_q_col_error_mask[q]=w_q[q].error_mask;
        assign w_q_col_tag[q]=w_q[q].tag;
        assign w_q_col_failed_bytes[q]=w_q[q].failed_bytes;
        assign w_q_col_result[q]=w_q[q].result;
    end
    metadata_t response_meta[MAX_MEM_OUTSTANDING];
    metadata_t returning;
    request_t out_q,out_d;
    logic [FB-1:0] response_head,response_tail;
    logic [FC-1:0] response_count;
    logic [MB-1:0] issue_next_q,issue_next_d,service_next_q,service_next_d;
    logic [QB-1:0] result_next_q,result_next_d;
    logic request_fire,response_fire,credit,out_space;

    typedef enum logic [2:0] {F_IDLE,F_SCAN,F_ISSUE,F_DRAIN,F_DONE} flush_state_t;
    flush_state_t f_q,f_d;
    logic [LB-1:0] flush_cursor_q,flush_cursor_d;
    logic [SB-1:0] flush_set_q,flush_set_d;
    logic [YB-1:0] flush_way_q,flush_way_d;
    logic [WORDS-1:0] flush_words_q,flush_words_d;
    logic flush_error_d;
    logic rsp_valid_d,rsp_error_d;
    logic [3:0] rsp_error_mask_d,service_error_mask;
    logic [127:0] rsp_data_d;
    logic [TAG_BITS-1:0] rsp_tag_d;
    logic [63:0] miss_count_d;

    logic [SB-1:0] req_set;
    integer req_word,free_miss,match_miss,hit_way,victim_way,free_waiter,done_waiter;
    integer service_slot,issue_slot,issue_word,scan_line;
    integer chosen_slot,idx,word_pos;
    logic [QB-1:0] service_waiter,pos;
    logic [YB-1:0] chosen_way;
    logic [31:0] req_line;
    logic [LINE_BYTES-1:0] req_mask,service_mask,failed_mask;
    logic [WORDS-1:0] needed_words,dirty_words,remaining_words;
    logic req_bad,victim_busy,hit,rsp_space,any_miss,any_waiter,direct_response;
    logic service_error,service_write,hit_write;
    logic [MSHRS-1:0] install_line;
    logic [CPU_BITS-1:0] hit_result,service_result;
    logic [LINE_BYTES-1:0] service_failed_bytes;

    function automatic integer line_index(input integer set_index,way_index);
        line_index=set_index*WAYS+way_index;
    endfunction
    function automatic integer data_index(input integer set_index,way_index,word_index);
        data_index=(set_index*WAYS+way_index)*WORDS+word_index;
    endfunction
    function automatic [LINE_BYTES-1:0] word_mask(input integer word_index,input integer count);
        word_mask='0;
        for(integer n=0;n<MAX_CPU_WORDS;n=n+1)
            if(n<count && word_index+n<WORDS) word_mask[4*(word_index+n)+:4]=4'hf;
    endfunction
    function automatic [WORDS-1:0] missing_words(input logic [LINE_BYTES-1:0] bytes_valid);
        for(integer n=0;n<WORDS;n=n+1) missing_words[n]=bytes_valid[4*n+:4]!=4'hf;
    endfunction
    function automatic [WORDS-1:0] modified_words(input logic [LINE_BYTES-1:0] bytes_dirty);
        for(integer n=0;n<WORDS;n=n+1) modified_words[n]=|bytes_dirty[4*n+:4];
    endfunction
    function automatic [3:0] requested_error_mask(input integer count);
        for(integer n=0;n<4;n=n+1) requested_error_mask[n]=n<count;
        if(count==0) requested_error_mask=4'b0001;
    endfunction

    // Response readiness never depends on request ready. Keep these separate
    // equations so elastic FIFO credit does not create a false block-level loop.
    assign returning=response_meta[response_head];
    assign mem_rsp_ready=!rst && response_count!=0;
    assign response_fire=mem_rsp_valid && mem_rsp_ready;
    assign credit=int'(response_count)<MAX_MEM_OUTSTANDING || response_fire;
    assign mem_req_valid=!rst && out_q.valid && credit;
    assign mem_req_addr=out_q.address;
    assign mem_req_wdata=out_q.data;
    assign mem_req_write=out_q.meta.write;
    assign mem_req_wstrb=out_q.meta.strobe;
    assign request_fire=mem_req_valid && mem_req_ready;
    assign out_space=!out_q.valid || request_fire;

    always_comb begin
        for(integer m=0;m<MSHRS;m=m+1) m_d[m]=m_q[m];
        for(integer w=0;w<WAITERS;w=w+1) w_d[w]=w_q[w];
        out_d=out_q;
        if(request_fire) out_d.valid=0;
        issue_next_d=issue_next_q;service_next_d=service_next_q;result_next_d=result_next_q;
        f_d=f_q;flush_cursor_d=flush_cursor_q;flush_set_d=flush_set_q;
        flush_way_d=flush_way_q;flush_words_d=flush_words_q;flush_error_d=flush_error;
        rsp_valid_d=cpu_rsp_valid;rsp_data_d=cpu_rsp_data;rsp_tag_d=cpu_rsp_tag;rsp_error_d=cpu_rsp_error;
        rsp_error_mask_d=cpu_rsp_error_mask;
        if(cpu_rsp_valid && cpu_rsp_ready) rsp_valid_d=0;
        rsp_space=!cpu_rsp_valid || cpu_rsp_ready;
        miss_count_d=miss_count;
        install_line='0;service_error=0;service_write=0;hit_write=0;
        service_error_mask='0;
        free_miss=-1;match_miss=-1;hit_way=-1;victim_way=-1;free_waiter=-1;done_waiter=-1;
        service_slot=-1;service_waiter='0;issue_slot=-1;issue_word=-1;scan_line=-1;
        chosen_slot=-1;chosen_way='0;idx=0;pos=0;word_pos=0;
        req_line=(cpu_req_addr >> OFFSET_BITS) << OFFSET_BITS;
        req_set=SB'((cpu_req_addr >> OFFSET_BITS)&(SETS-1));
        req_word=int'((cpu_req_addr >> 2)&(WORDS-1));
        req_mask=word_mask(req_word,int'(cpu_req_count));
        req_bad=cpu_req_addr[1:0]!=0 || cpu_req_count==0 || cpu_req_count>3'(MAX_CPU_WORDS) ||
            req_word+int'(cpu_req_count)>WORDS || (cpu_req_write && (READ_ONLY!=0 || cpu_req_count!=1));
        any_miss=0;any_waiter=0;victim_busy=0;hit=0;direct_response=0;
        service_mask='0;failed_mask='0;needed_words='0;dirty_words='0;remaining_words='0;
        hit_result='0;service_result='0;service_failed_bytes='0;instruction_hit_line='0;instruction_service_line='0;
        for(integer s=0;s<SETS;s=s+1)
            for(integer y=0;y<WAYS;y=y+1) locked[s][y]=0;
        for(integer m=0;m<MSHRS;m=m+1) begin
            if(m_q[m].phase==M_FREE) begin
                if(free_miss<0) free_miss=m;
            end else begin
                any_miss=1;
                locked[m_q[m].set_index][m_q[m].way]=1;
                if(m_q[m].line==req_line) match_miss=m;
                if(m_q[m].line!=req_line && tag_valid[m_q[m].set_index][m_q[m].way] &&
                    address_line[line_index(int'(m_q[m].set_index),int'(m_q[m].way))]==req_line) victim_busy=1;
            end
        end
        for(integer w=0;w<WAITERS;w=w+1) begin
            if(w_q_col_valid[w]) any_waiter=1;
            else if(free_waiter<0) free_waiter=w;
            idx=(int'(result_next_q)+w)%WAITERS;
            if(w_q_col_valid[idx] && w_q_col_done[idx] && done_waiter<0) done_waiter=idx;
        end
        for(integer y=0;y<WAYS;y=y+1) begin
            if(!locked[req_set][y] && tag_valid[req_set][y] && address_line[line_index(int'(req_set),int'(y))]==req_line)
                hit_way=y;
            if(!locked[req_set][y] && !tag_valid[req_set][y] && victim_way<0) victim_way=y;
        end
        for(integer n=0;n<WAYS;n=n+1) begin
            idx=(int'(replace_way[req_set])+n)%WAYS;
            if(!locked[req_set][idx] && victim_way<0) victim_way=idx;
        end
        if(hit_way>=0) begin
            if(READ_ONLY!=0) instruction_hit_line=LINE_BITS'(data_array[line_index(int'(req_set),hit_way)]);
            hit=cpu_req_write || (valid_line[line_index(int'(req_set),int'(hit_way))]&req_mask)==req_mask;
            if(!cpu_req_write)
                for(integer n=0;n<MAX_CPU_WORDS;n=n+1)
                    if(n<int'(cpu_req_count) && req_word+n<WORDS)
                        if(READ_ONLY!=0) hit_result[32*n+:32]=instruction_hit_line[32*(req_word+n)+:32];
                        else hit_result[32*n+:32]=32'(data_array[data_index(int'(req_set),int'(hit_way),int'(req_word+n))]);
        end
        idle=!any_miss && !any_waiter && !cpu_rsp_valid && !out_q.valid && response_count==0 &&
             (f_q==F_IDLE || f_q==F_DONE);
        flush_done=f_q==F_DONE;

        // The response register is elastic. Completed waiters retain their own
        // payloads until they can move into it; stores/fills can still progress.
        if(rsp_space && done_waiter>=0) begin
            rsp_valid_d=1;rsp_data_d=128'(w_q_col_result[done_waiter]);
            rsp_tag_d=w_q_col_tag[done_waiter];rsp_error_d=w_q_col_error[done_waiter];
            rsp_error_mask_d=w_q_col_error_mask[done_waiter];
            w_d[done_waiter].valid=0;
            result_next_d=QB'((done_waiter+1)%WAITERS);
        end

        // Response ownership is recorded at request acceptance. Pending bits
        // include the output skid, so no slot can be reused before it drains.
        if(response_fire) begin
            if(returning.flush) begin
                if(mem_rsp_error) begin
                    flush_error_d=1;f_d=F_DRAIN;flush_words_d='0;
                end
            end else begin
                m_d[returning.slot].pending[returning.word_index]=0;
                if(mem_rsp_error && returning.write) begin
                    m_d[returning.slot].error=1;
                    flush_error_d=1;
                end else if(mem_rsp_error) begin
                    failed_mask=word_mask(int'(returning.word_index),1) &
                        ~valid_line[line_index(int'(returning.set_index),int'(returning.way))];
                    for(integer w=0;w<WAITERS;w=w+1)
                        if(w_q_col_valid[w] && !w_q_col_done[w] && !w_q_col_write[w] && w_q_col_slot[w]==returning.slot)
                            w_d[w].failed_bytes=w_q_col_failed_bytes[w] | failed_mask;
                end
            end
        end

        // A victim stays intact until every issued write has responded. Failed
        // words preserve dirty state; already-issued later words still drain.
        for(integer m=0;m<MSHRS;m=m+1) begin
            if(m_q[m].phase==M_WB) begin
                dirty_words=modified_words(dirty_line[line_index(int'(m_q[m].set_index),int'(m_q[m].way))]);
                if(m_d[m].pending==0 &&
                   (m_d[m].error || (dirty_words & ~m_d[m].attempted)==0)) begin
                    if(m_d[m].error) m_d[m].phase=M_ERROR;
                    else begin
                        m_d[m].phase=M_READ;m_d[m].attempted='0;m_d[m].cursor=m_q[m].critical;
                        install_line[m]=1;
                    end
                end
            end
        end

        // Execute one FIFO head per cycle, independent of response backpressure.
        // A younger store cannot overwrite an older pending read of this line.
        for(integer n=0;n<MSHRS;n=n+1) begin
            idx=(int'(service_next_q)+n)%MSHRS;
            pos=m_q[idx].head;
            service_mask=word_mask(int'(w_q_col_word_index[pos]),int'(w_q_col_count[pos]));
            if(service_slot<0 && m_q[idx].count!=0 &&
               (m_q[idx].phase==M_ERROR || (m_q[idx].phase==M_READ &&
                (w_q_col_write[pos] ||
                 ((valid_line[line_index(int'(m_q[idx].set_index),int'(m_q[idx].way))] | w_d[pos].failed_bytes)&service_mask)==service_mask)))) begin
                service_slot=idx;service_waiter=QB'(pos);
            end
        end
        if(service_slot>=0) begin
            if(READ_ONLY!=0)
                instruction_service_line=LINE_BITS'(data_array[line_index(int'(m_q[service_slot].set_index),int'(m_q[service_slot].way))]);
            service_failed_bytes=w_d[service_waiter].failed_bytes;
            service_mask=word_mask(int'(w_q_col_word_index[service_waiter]),int'(w_q_col_count[service_waiter]));
            if(m_q[service_slot].phase==M_ERROR)
                service_error_mask=requested_error_mask(int'(w_q_col_count[service_waiter]));
            else if(!w_q_col_write[service_waiter])
                for(integer n=0;n<MAX_CPU_WORDS;n=n+1)
                    if(n<int'(w_q_col_count[service_waiter]) && int'(w_q_col_word_index[service_waiter])+n<WORDS)
                        service_error_mask[n]=
                            (service_failed_bytes[4*(int'(w_q_col_word_index[service_waiter])+n)+:4] &
                             ~valid_word[data_index(int'(m_q[service_slot].set_index),int'(m_q[service_slot].way),int'((int'(w_q_col_word_index[service_waiter])+n)))])!=0;
            service_error=|service_error_mask;
            service_write=w_q_col_write[service_waiter] && !service_error;
            if(!w_q_col_write[service_waiter] && m_q[service_slot].phase==M_READ)
                for(integer n=0;n<MAX_CPU_WORDS;n=n+1)
                    if(n<int'(w_q_col_count[service_waiter]) && int'(w_q_col_word_index[service_waiter])+n<WORDS && !service_error_mask[n])
                        if(READ_ONLY!=0)
                            service_result[32*n+:32]=instruction_service_line[32*(int'(w_q_col_word_index[service_waiter])+n)+:32];
                        else service_result[32*n+:32]=32'(data_array[data_index(int'(m_q[service_slot].set_index),int'(m_q[service_slot].way),int'(int'(w_q_col_word_index[service_waiter])+n))]);
            w_d[service_waiter].done=1;w_d[service_waiter].error=service_error;
            w_d[service_waiter].error_mask=service_error_mask;
            w_d[service_waiter].result=service_result;
            m_d[service_slot].head=w_q_col_next_waiter[service_waiter];
            m_d[service_slot].count=m_d[service_slot].count-1'b1;
            service_next_d=MB'((service_slot+1)%MSHRS);
        end

        cpu_req_ready=0;
        if(!rst && !flush_valid && f_q==F_IDLE) begin
            if(req_bad || hit) cpu_req_ready=(rsp_space && done_waiter<0) || free_waiter>=0;
            else if(!victim_busy && free_waiter>=0) begin
                if(match_miss>=0) cpu_req_ready=1;
                else cpu_req_ready=free_miss>=0 && (hit_way>=0 || victim_way>=0);
            end
        end
        if(cpu_req_valid && cpu_req_ready) begin
            if(req_bad || hit) begin
                direct_response=rsp_space && done_waiter<0;
                if(direct_response) begin
                    rsp_valid_d=1;rsp_tag_d=cpu_req_tag;rsp_error_d=req_bad;
                    rsp_error_mask_d=req_bad ? requested_error_mask(int'(cpu_req_count)):4'b0;
                    rsp_data_d=req_bad ? 128'b0:128'(hit_result);
                end else begin
                    w_d[free_waiter]='0;w_d[free_waiter].valid=1;w_d[free_waiter].done=1;
                    w_d[free_waiter].tag=cpu_req_tag;w_d[free_waiter].error=req_bad;
                    w_d[free_waiter].error_mask=req_bad ? requested_error_mask(int'(cpu_req_count)):4'b0;
                    w_d[free_waiter].result=req_bad ? {CPU_BITS{1'b0}}:hit_result;
                end
                hit_write=!req_bad && cpu_req_write;
            end else begin
                chosen_slot=match_miss;
                if(chosen_slot<0) begin
                    chosen_slot=free_miss;
                    chosen_way=YB'(hit_way>=0 ? hit_way:victim_way);
                    m_d[chosen_slot]='0;
                    m_d[chosen_slot].set_index=req_set;m_d[chosen_slot].way=YB'(chosen_way);
                    m_d[chosen_slot].line=req_line;m_d[chosen_slot].victim=address_line[line_index(int'(req_set),int'(chosen_way))];
                    m_d[chosen_slot].cursor=WB'(req_word);
                    if(hit_way<0 && tag_valid[req_set][chosen_way] && dirty_line[line_index(int'(req_set),int'(chosen_way))]!=0)
                        m_d[chosen_slot].phase=M_WB;
                    else begin
                        m_d[chosen_slot].phase=M_READ;
                        if(hit_way<0) install_line[chosen_slot]=1;
                    end
                    miss_count_d=miss_count+64'd1;
                end
                w_d[free_waiter]='0;w_d[free_waiter].valid=1;
                w_d[free_waiter].slot=MB'(chosen_slot);w_d[free_waiter].word_index=WB'(req_word);
                w_d[free_waiter].count=cpu_req_count;w_d[free_waiter].tag=cpu_req_tag;
                w_d[free_waiter].write=cpu_req_write;w_d[free_waiter].wdata=cpu_req_wdata;
                w_d[free_waiter].wstrb=cpu_req_wstrb;
                if(response_fire && !returning.flush && !returning.write && mem_rsp_error &&
                    int'(returning.slot)==chosen_slot) w_d[free_waiter].failed_bytes=failed_mask;
                if(m_d[chosen_slot].count==0) m_d[chosen_slot].head=QB'(free_waiter);
                else w_d[m_d[chosen_slot].tail].next_waiter=QB'(free_waiter);
                m_d[chosen_slot].tail=QB'(free_waiter);
                m_d[chosen_slot].count=m_d[chosen_slot].count+1'b1;
                if(!cpu_req_write) begin
                    if(!m_d[chosen_slot].prefetch) begin
                        m_d[chosen_slot].critical=WB'(req_word);
                        if(m_d[chosen_slot].phase==M_READ) m_d[chosen_slot].cursor=WB'(req_word);
                    end
                    m_d[chosen_slot].prefetch=1;
                    // New requests retry previously failed prefetch sectors;
                    // errors are attached only to requests present at failure.
                    if(match_miss>=0 && m_q[chosen_slot].phase==M_READ)
                        for(integer n=0;n<MAX_CPU_WORDS;n=n+1)
                            if(n<int'(cpu_req_count) && req_word+n<WORDS &&
                               !m_q[chosen_slot].pending[req_word+n] &&
                               valid_word[data_index(int'(req_set),int'(m_q[chosen_slot].way),int'((req_word+n)))]!=4'hf)
                                m_d[chosen_slot].attempted[req_word+n]=0;
                end
            end
        end

        if(f_q==F_IDLE && flush_valid && idle) begin
            f_d=F_SCAN;flush_cursor_d='0;flush_words_d='0;
        end
        if(f_q==F_SCAN && f_d!=F_DRAIN) begin
            for(integer line=0;line<LINES;line=line+1)
                if(line>=int'(flush_cursor_q) && tag_valid[line/WAYS][line%WAYS] &&
                   dirty_line[line_index(int'(line/WAYS),int'(line%WAYS))]!=0 && scan_line<0) scan_line=line;
            if(scan_line<0) f_d=F_DRAIN;
            else begin
                flush_set_d=SB'(scan_line/WAYS);flush_way_d=YB'(scan_line%WAYS);
                flush_words_d=modified_words(dirty_line[line_index(int'(scan_line/WAYS),int'(scan_line%WAYS))]);
                flush_cursor_d=LB'(scan_line+1);f_d=F_ISSUE;
            end
        end

        // One outgoing word every cycle. Round robin across real MSHRs; each
        // read burst starts at the critical word and wraps around the line.
        if(out_space) begin
            if(f_q==F_ISSUE && f_d!=F_DRAIN) begin
                for(integer n=0;n<WORDS;n=n+1)
                    if(flush_words_q[n] && issue_word<0) issue_word=n;
                if(issue_word>=0) begin
                    out_d='0;out_d.valid=1;out_d.meta.flush=1;out_d.meta.write=1;
                    out_d.meta.set_index=flush_set_q;out_d.meta.way=flush_way_q;
                    out_d.meta.word_index=WB'(issue_word);
                    out_d.meta.strobe=dirty_word[data_index(int'(flush_set_q),int'(flush_way_q),int'(issue_word))];
                    out_d.address=address_line[line_index(int'(flush_set_q),int'(flush_way_q))]+32'(4*issue_word);
                    flush_words_d[issue_word]=0;
                    if(flush_words_d==0) f_d=F_SCAN;
                end
            end else if(f_q==F_IDLE) begin
                for(integer n=0;n<MSHRS;n=n+1) begin
                    idx=(int'(issue_next_q)+n)%MSHRS;
                    needed_words='0;
                    if(m_q[idx].phase==M_WB && m_d[idx].phase==M_WB && !m_d[idx].error)
                        needed_words=modified_words(dirty_line[line_index(int'(m_q[idx].set_index),int'(m_q[idx].way))]);
                    else if(m_q[idx].phase==M_READ && m_d[idx].prefetch) begin
                        needed_words=missing_words(valid_line[line_index(int'(m_q[idx].set_index),int'(m_q[idx].way))]);
                        // A store executing at this edge supplies these bytes;
                        // do not issue a redundant read for a now-complete word.
                        if(service_write && idx==service_slot &&
                           (valid_word[data_index(int'(m_q[idx].set_index),int'(m_q[idx].way),int'(int'(w_q_col_word_index[service_waiter])))] |
                            w_q_col_wstrb[service_waiter])==4'hf)
                            needed_words[w_q_col_word_index[service_waiter]]=0;
                    end
                    remaining_words=needed_words & ~m_d[idx].attempted;
                    for(integer k=0;k<WORDS;k=k+1) begin
                        word_pos=(int'(m_d[idx].cursor)+k)%WORDS;
                        if(remaining_words[word_pos] && issue_slot<0) begin issue_slot=idx;issue_word=word_pos;end
                    end
                end
                if(issue_slot>=0) begin
                    out_d='0;out_d.valid=1;out_d.meta.slot=MB'(issue_slot);
                    out_d.meta.set_index=m_q[issue_slot].set_index;out_d.meta.way=m_q[issue_slot].way;
                    out_d.meta.word_index=WB'(issue_word);out_d.meta.write=m_q[issue_slot].phase==M_WB;
                    out_d.address=(out_d.meta.write ? m_q[issue_slot].victim:m_q[issue_slot].line)+32'(4*issue_word);
                    if(out_d.meta.write) begin
                        out_d.meta.strobe=dirty_word[data_index(int'(out_d.meta.set_index),int'(out_d.meta.way),int'(issue_word))];
                    end
                    m_d[issue_slot].attempted[issue_word]=1;m_d[issue_slot].pending[issue_word]=1;
                    m_d[issue_slot].cursor=WB'((issue_word+1)%WORDS);
                    issue_next_d=MB'((issue_slot+1)%MSHRS);
                end
            end
            // Flush and victim writeback share the one outgoing memory port.
            if(READ_ONLY==0 && out_d.valid && out_d.meta.write)
                out_d.data=32'(data_array[data_index(int'(out_d.meta.set_index),int'(out_d.meta.way),int'(out_d.meta.word_index))]);
        end
        for(integer m=0;m<MSHRS;m=m+1) begin
            remaining_words='0;
            if(m_q[m].phase==M_READ && m_d[m].prefetch)
                remaining_words=missing_words(valid_line[line_index(int'(m_q[m].set_index),int'(m_q[m].way))]) & ~m_d[m].attempted;
            if(m_q[m].phase!=M_FREE && m_d[m].phase!=M_WB && !install_line[m] &&
               m_d[m].count==0 && m_d[m].pending==0 && remaining_words==0)
                m_d[m].phase=M_FREE;
        end
        if(f_d==F_DRAIN && response_count==0 && !out_q.valid) f_d=F_DONE;
        if(f_q==F_DONE && !flush_valid) f_d=F_IDLE;
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            for(integer m=0;m<MSHRS;m=m+1) m_q[m]<='0;
            for(integer w=0;w<WAITERS;w=w+1) w_q[w]<='0;
            for(integer f=0;f<MAX_MEM_OUTSTANDING;f=f+1) response_meta[f]<='0;
            out_q<='0;response_head<='0;response_tail<='0;response_count<='0;
            issue_next_q<='0;service_next_q<='0;result_next_q<='0;
            cpu_rsp_valid<=0;cpu_rsp_data<='0;cpu_rsp_tag<='0;cpu_rsp_error<=0;cpu_rsp_error_mask<='0;
            flush_error<=0;miss_count<='0;f_q<=F_IDLE;
            flush_cursor_q<='0;flush_set_q<='0;flush_way_q<='0;flush_words_q<='0;
        end else begin
            for(integer m=0;m<MSHRS;m=m+1) m_q[m]<=m_d[m];
            for(integer w=0;w<WAITERS;w=w+1) w_q[w]<=w_d[w];
            out_q<=out_d;issue_next_q<=issue_next_d;service_next_q<=service_next_d;result_next_q<=result_next_d;
            cpu_rsp_valid<=rsp_valid_d;cpu_rsp_data<=rsp_data_d;cpu_rsp_tag<=rsp_tag_d;cpu_rsp_error<=rsp_error_d;
            cpu_rsp_error_mask<=rsp_error_mask_d;
            flush_error<=flush_error_d;miss_count<=miss_count_d;f_q<=f_d;
            flush_cursor_q<=flush_cursor_d;flush_set_q<=flush_set_d;flush_way_q<=flush_way_d;flush_words_q<=flush_words_d;
            case({request_fire,response_fire})
                2'b10: response_count<=response_count+1'b1;
                2'b01: response_count<=response_count-1'b1;
                default: begin end
            endcase
            if(request_fire) begin
                response_meta[response_tail]<=out_q.meta;
                response_tail<=int'(response_tail)==MAX_MEM_OUTSTANDING-1 ? '0:response_tail+1'b1;
            end
            if(response_fire)
                response_head<=int'(response_head)==MAX_MEM_OUTSTANDING-1 ? '0:response_head+1'b1;

        end
    end

    // Decode write addresses once. Metadata is updated in fixed-size line
    // records, avoiding read/modify/write muxes over every cache line.
    logic [SB-1:0] store_set;
    logic [YB-1:0] store_way;
    logic [WB-1:0] store_word;
    logic [3:0] store_strobe;
    assign store_set=m_q[service_slot].set_index;
    assign store_way=m_q[service_slot].way;
    assign store_word=w_q_col_word_index[service_waiter];
    assign store_strobe=w_q_col_wstrb[service_waiter];
    wire [LINE_BYTES-1:0] returned_word_mask=word_mask(int'(returning.word_index),1);
    wire [LINE_BYTES-1:0] returned_strobe_mask=LINE_BYTES'(returning.strobe) << (4*int'(returning.word_index));
    wire [LINE_BYTES-1:0] store_byte_mask=LINE_BYTES'(store_strobe) << (4*int'(store_word));
    wire [LINE_BYTES-1:0] hit_byte_mask=LINE_BYTES'(cpu_req_wstrb) << (4*req_word);
    // This is the real cache data memory: byte enables and ordered write ports.
    // Synthesis memory_map lowers it fully to FFs; no SRAM macro is assumed.
    generate if(READ_ONLY!=0) begin: instruction_storage
        always_ff @(posedge clk) if(!rst && response_fire && !mem_rsp_error && !returning.flush && !returning.write)
            for(integer b=0;b<4;b=b+1)
                if(!valid_word[data_index(int'(returning.set_index),int'(returning.way),int'(returning.word_index))][b])
                    data_array[line_index(int'(returning.set_index),int'(returning.way))]
                        [8*(4*int'(returning.word_index)+b)+:8]<=mem_rsp_rdata[8*b+:8];
    end else begin: word_storage
    wire [31:0] store_data=w_q[service_waiter].wdata;
    always_ff @(posedge clk) if(!rst) begin
        if(response_fire && !mem_rsp_error && !returning.flush && !returning.write)
            for(integer b=0;b<4;b=b+1)
                if(!valid_word[data_index(int'(returning.set_index),int'(returning.way),int'(returning.word_index))][b])
                    data_array[data_index(int'(returning.set_index),int'(returning.way),int'(returning.word_index))][8*b+:8]<=mem_rsp_rdata[8*b+:8];
        if(READ_ONLY==0 && service_write)
            for(integer b=0;b<4;b=b+1)
                if(store_strobe[b]) data_array[data_index(int'(store_set),int'(store_way),int'(store_word))][8*b+:8]<=store_data[8*b+:8];
        if(READ_ONLY==0 && hit_write)
            for(integer b=0;b<4;b=b+1)
                if(cpu_req_wstrb[b]) data_array[data_index(int'(req_set),int'(hit_way),int'(req_word))][8*b+:8]<=cpu_req_wdata[8*b+:8];
    end
    end endgenerate
    for(genvar s=0;s<SETS;s=s+1) begin:g_set
        always_ff @(posedge clk) begin
            if(rst) replace_way[s]<='0;
            else begin
                for(integer m=0;m<MSHRS;m=m+1)
                    if(install_line[m] && m_d[m].set_index==SB'(s))
                        replace_way[s]<=YB'((int'(m_d[m].way)+1)%WAYS);
                if(cpu_req_valid && cpu_req_ready && hit && !req_bad && req_set==SB'(s))
                    replace_way[s]<=YB'((hit_way+1)%WAYS);
            end
        end
        for(genvar y=0;y<WAYS;y=y+1) begin:g_way
            wire fill_here=response_fire && !mem_rsp_error && !returning.flush && !returning.write &&
                returning.set_index==SB'(s) && returning.way==YB'(y);
            wire flush_here=response_fire && !mem_rsp_error && returning.flush &&
                returning.set_index==SB'(s) && returning.way==YB'(y);
            wire service_here=(READ_ONLY==0) && service_write && store_set==SB'(s) && store_way==YB'(y);
            wire hit_here=(READ_ONLY==0) && hit_write && req_set==SB'(s) && hit_way==y;
            wire [MSHRS-1:0] installing;
            for(genvar m=0;m<MSHRS;m=m+1) begin:g_install
                assign installing[m]=install_line[m] && m_d[m].set_index==SB'(s) && m_d[m].way==YB'(y);
            end
            always_ff @(posedge clk) begin
                if(rst) begin tag_valid[s][y]<=0;line_addr[s][y]<='0;end
                else for(integer m=0;m<MSHRS;m=m+1)
                    if(installing[m]) begin
                        tag_valid[s][y]<=1;line_addr[s][y]<=m_d[m].line;
                    end
            end
            logic [LINE_BYTES-1:0] valid_next,dirty_next;
            always_comb begin
                valid_next=valid_bytes[s][y];dirty_next=dirty_bytes[s][y];
                if(|installing) begin valid_next='0;dirty_next='0;end
                if(flush_here)
                    dirty_next=(dirty_next & ~returned_word_mask) |
                        ((dirty_bytes[s][y] & ~returned_strobe_mask) & returned_word_mask);
                if(fill_here) valid_next=valid_next | (returned_word_mask & ~valid_bytes[s][y]);
                if(service_here) begin valid_next=valid_next | store_byte_mask;dirty_next=dirty_next | store_byte_mask;end
                if(hit_here) begin valid_next=valid_next | hit_byte_mask;dirty_next=dirty_next | hit_byte_mask;end
            end
            always_ff @(posedge clk) begin
                if(rst) begin valid_bytes[s][y]<='0;dirty_bytes[s][y]<='0;end
                else begin valid_bytes[s][y]<=valid_next;dirty_bytes[s][y]<=dirty_next;end
            end
        end
    end
    initial begin
        if(WAYS!=1 && WAYS!=2 && WAYS!=4) $fatal(1,"cache WAYS must be 1/2/4");
        if(LINE_BYTES!=16 && LINE_BYTES!=32 && LINE_BYTES!=64) $fatal(1,"cache line must be 16/32/64 bytes");
        if(SETS<1 || (SETS & (SETS-1))!=0 || CACHE_BYTES!=SETS*WAYS*LINE_BYTES)
            $fatal(1,"invalid cache capacity/set count");
        if(MAX_CPU_WORDS<1 || MAX_CPU_WORDS>4) $fatal(1,"invalid CPU word count limit");
        if(MSHRS<1 || MSHRS>16 || WAITERS<1 || TAG_BITS<1 || MAX_MEM_OUTSTANDING<1)
            $fatal(1,"invalid cache queue capacity");
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst) begin
        assert(int'(response_count)<=MAX_MEM_OUTSTANDING) else $fatal(1,"cache response owner overflow");
        if(response_fire && !returning.flush) begin
            assert(m_q[returning.slot].pending[returning.word_index]) else $fatal(1,"response lost its pending word");
            assert(returning.write ? m_q[returning.slot].phase==M_WB : m_q[returning.slot].phase==M_READ)
                else $fatal(1,"response crossed a miss phase boundary");
        end
        for(integer m=0;m<MSHRS;m=m+1)
            assert(int'(m_q[m].count)<=WAITERS) else $fatal(1,"cache waiter FIFO overflow");
    end
`endif
endmodule
