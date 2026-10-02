// Pipelined two-client arbiter. RAM accepts one request per cycle and returns
// responses in acceptance order; the owner FIFO routes each response correctly.
module memory_controller #(
    parameter integer MAX_MEM_OUTSTANDING = 64
) (
    input  logic clk, rst,
    input  logic [1:0] s_req_valid,
    output logic [1:0] s_req_ready,
    input  logic [1:0] s_req_write,
    input  logic [63:0] s_req_addr, s_req_wdata,
    input  logic [7:0] s_req_wstrb,
    output logic [1:0] s_rsp_valid,
    input  logic [1:0] s_rsp_ready,
    output logic [63:0] s_rsp_rdata,
    output logic [1:0] s_rsp_error,
    output logic mem_req_valid,
    input  logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr, mem_req_wdata,
    output logic [3:0] mem_req_wstrb,
    input  logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input  logic [31:0] mem_rsp_rdata,
    input  logic mem_rsp_error,
    output logic idle
);
    localparam integer PW = MAX_MEM_OUTSTANDING > 1 ? $clog2(MAX_MEM_OUTSTANDING) : 1;
    localparam integer CW = $clog2(MAX_MEM_OUTSTANDING+1);
    logic owners [MAX_MEM_OUTSTANDING];
    logic [PW-1:0] head, tail;
    logic [CW-1:0] count;
    logic request_valid, request_owner, next_owner, selected;
    logic request_fire, response_fire, input_fire, space;

    always_comb begin
        s_rsp_valid = 2'b00;
        s_rsp_rdata = 64'b0;
        s_rsp_error = 2'b00;
        mem_rsp_ready = 1'b0;
        if (!rst && count != 0) begin
            s_rsp_valid[owners[head]] = mem_rsp_valid;
            s_rsp_rdata[32*owners[head] +: 32] = mem_rsp_rdata;
            s_rsp_error[owners[head]] = mem_rsp_error;
            mem_rsp_ready = s_rsp_ready[owners[head]];
        end
    end
    assign response_fire = mem_rsp_valid && mem_rsp_ready;
    assign space = int'(count) < MAX_MEM_OUTSTANDING || response_fire;
    assign mem_req_valid = !rst && request_valid && space;
    assign request_fire = mem_req_valid && mem_req_ready;
    assign selected = s_req_valid[next_owner] ? next_owner : !next_owner;
    assign input_fire = s_req_valid[selected] && s_req_ready[selected];
    assign idle = count == 0 && !request_valid && !(|s_req_valid);
    always_comb begin
        s_req_ready = 2'b00;
        if (!rst && (!request_valid || request_fire) && s_req_valid[selected])
            s_req_ready[selected] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head <= '0;
            tail <= '0;
            count <= '0;
            request_valid <= 1'b0;
            request_owner <= 1'b0;
            next_owner <= 1'b0;
            mem_req_write <= 1'b0;
            mem_req_addr <= '0;
            mem_req_wdata <= '0;
            mem_req_wstrb <= '0;
            for (integer n = 0; n < MAX_MEM_OUTSTANDING; n = n+1) owners[n] <= 1'b0;
        end else begin
            case ({request_fire, response_fire})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: begin end
            endcase
            if (request_fire) begin
                owners[tail] <= request_owner;
                tail <= int'(tail) == MAX_MEM_OUTSTANDING-1 ? '0 : tail + 1'b1;
                request_valid <= 1'b0;
            end
            if (response_fire)
                head <= int'(head) == MAX_MEM_OUTSTANDING-1 ? '0 : head + 1'b1;
            if (input_fire) begin
                request_valid <= 1'b1;
                request_owner <= selected;
                next_owner <= !selected;
                mem_req_write <= s_req_write[selected];
                mem_req_addr <= s_req_addr[32*selected +: 32];
                mem_req_wdata <= s_req_wdata[32*selected +: 32];
                mem_req_wstrb <= s_req_wstrb[4*selected +: 4];
            end
        end
    end
    initial if (MAX_MEM_OUTSTANDING < 1) $fatal(1, "invalid memory owner FIFO capacity");
endmodule
