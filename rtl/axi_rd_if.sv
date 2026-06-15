// axi_rd_if.sv
// 职责：
//   缓存AXI AR通道请求，向read_engine提供ar_info
//   （结构与axi_wr_if的AW_FIFO部分完全对称）

import axi_pcie_pkg::*;

module axi_rd_if #(
    parameter AR_FIFO_DEPTH = 8
)(
    input  logic clk,
    input  logic rst_n,

    // ── AXI AR通道 ────────────────────────────────────
    input  logic [3:0]  s_axi_arid,
    input  logic [63:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,
    input  logic [2:0]  s_axi_arsize,
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    // ── 向read_engine输出 ─────────────────────────────
    output ar_info_t    ar_info,
    output logic        ar_info_valid,
    input  logic        ar_info_ready
);

localparam AR_PTR_W = $clog2(AR_FIFO_DEPTH);

ar_info_t ar_fifo_mem [AR_FIFO_DEPTH];
logic [AR_PTR_W:0] ar_wptr, ar_rptr;
logic ar_full, ar_empty;

assign ar_full  = (ar_wptr[AR_PTR_W] != ar_rptr[AR_PTR_W]) &&
                  (ar_wptr[AR_PTR_W-1:0] == ar_rptr[AR_PTR_W-1:0]);
assign ar_empty = (ar_wptr == ar_rptr);

// 写入
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ar_wptr <= '0;
    end else if (s_axi_arvalid && s_axi_arready) begin
        ar_fifo_mem[ar_wptr[AR_PTR_W-1:0]] <= '{
            arid    : s_axi_arid,
            araddr  : s_axi_araddr,
            arlen   : s_axi_arlen,
            arsize  : s_axi_arsize,
            arburst : s_axi_arburst
        };
        ar_wptr <= ar_wptr + 1'b1;
    end
end

// 读出
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ar_rptr <= '0;
    else if (ar_info_valid && ar_info_ready)
        ar_rptr <= ar_rptr + 1'b1;
end

assign s_axi_arready = !ar_full;
assign ar_info_valid = !ar_empty;
assign ar_info       = ar_fifo_mem[ar_rptr[AR_PTR_W-1:0]];

endmodule