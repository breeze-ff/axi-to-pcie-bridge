// axi_wr_if.sv
// 职责：
//   1. 接收AXI AW通道，存入AW_FIFO
//   2. 接收AXI W通道，存入W_FIFO（每个beat一项）
//   3. 向Write Engine提供AW信息和W数据
//   4. 接收Write Engine的B响应，转发给AXI B通道

import axi_pcie_pkg::*;

module axi_wr_if #(
    parameter AW_FIFO_DEPTH = 8,   // 支持8个outstanding写地址
    parameter W_FIFO_DEPTH  = 64   // 缓存64个beat（足够大防止背压）
)(
    input  logic clk,
    input  logic rst_n,

    // ── AXI写通道（Slave侧）──────────────────────────
    input  logic [3:0]  s_axi_awid,
    input  logic [63:0] s_axi_awaddr,
    input  logic [7:0]  s_axi_awlen,
    input  logic [2:0]  s_axi_awsize,
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [63:0] s_axi_wdata,
    input  logic [7:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [3:0]  s_axi_bid,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // ── 向Write Engine输出 ────────────────────────────
    output aw_info_t    aw_info,        // AW通道信息
    output logic        aw_info_valid,  // AW_FIFO非空
    input  logic        aw_info_ready,  // Write Engine消费AW（只取一次）

    output w_beat_t     w_beat,         // W通道当前beat
    output logic        w_beat_valid,   // W_FIFO非空
    input  logic        w_beat_ready,   // Write Engine消费一个beat

    // ── 来自Write Engine的B响应 ───────────────────────
    input  logic [3:0]  b_id,
    input  logic [1:0]  b_resp,
    input  logic        b_valid_in,
    output logic        b_ready_out     // 告知Write Engine B通道是否空闲
);

// ════════════════════════════════════════════════════
// AW_FIFO：存放写地址信息
// ════════════════════════════════════════════════════
// 使用标准同步FIFO实现
localparam AW_PTR_W = $clog2(AW_FIFO_DEPTH);

aw_info_t  aw_fifo_mem [AW_FIFO_DEPTH];
logic [AW_PTR_W:0] aw_wptr, aw_rptr;   // 多一位判满判空
logic aw_full, aw_empty;

assign aw_full  = (aw_wptr[AW_PTR_W] != aw_rptr[AW_PTR_W]) &&
                  (aw_wptr[AW_PTR_W-1:0] == aw_rptr[AW_PTR_W-1:0]);
assign aw_empty = (aw_wptr == aw_rptr);

// AW写入
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aw_wptr <= '0;
    end else if (s_axi_awvalid && s_axi_awready) begin
        aw_fifo_mem[aw_wptr[AW_PTR_W-1:0]] <= '{
            awid    : s_axi_awid,
            awaddr  : s_axi_awaddr,
            awlen   : s_axi_awlen,
            awsize  : s_axi_awsize,
            awburst : s_axi_awburst
        };
        aw_wptr <= aw_wptr + 1'b1;
    end
end

// AW读出
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) aw_rptr <= '0;
    else if (aw_info_valid && aw_info_ready)
        aw_rptr <= aw_rptr + 1'b1;
end

assign s_axi_awready = !aw_full;
assign aw_info_valid = !aw_empty;
assign aw_info       = aw_fifo_mem[aw_rptr[AW_PTR_W-1:0]];

// ════════════════════════════════════════════════════
// W_FIFO：存放每个写数据beat
// ════════════════════════════════════════════════════
localparam W_PTR_W = $clog2(W_FIFO_DEPTH);

w_beat_t   w_fifo_mem [W_FIFO_DEPTH];
logic [W_PTR_W:0] w_wptr, w_rptr;
logic w_full, w_empty;

assign w_full  = (w_wptr[W_PTR_W] != w_rptr[W_PTR_W]) &&
                 (w_wptr[W_PTR_W-1:0] == w_rptr[W_PTR_W-1:0]);
assign w_empty = (w_wptr == w_rptr);

// W写入（每个有效beat都存入）
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        w_wptr <= '0;
    end else if (s_axi_wvalid && s_axi_wready) begin
        w_fifo_mem[w_wptr[W_PTR_W-1:0]] <= '{
            wdata : s_axi_wdata,
            wstrb : s_axi_wstrb,
            wlast : s_axi_wlast
        };
        w_wptr <= w_wptr + 1'b1;
    end
end

// W读出
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) w_rptr <= '0;
    else if (w_beat_valid && w_beat_ready)
        w_rptr <= w_rptr + 1'b1;
end

assign s_axi_wready = !w_full;
assign w_beat_valid = !w_empty;
assign w_beat       = w_fifo_mem[w_rptr[W_PTR_W-1:0]];

// ════════════════════════════════════════════════════
// B通道：透传Write Engine的响应给AXI Master
// ════════════════════════════════════════════════════
// Write Engine在最后一个TLP发出后通知这里
// 用一级寄存器打拍，解耦时序

logic        b_buf_valid;
logic [3:0]  b_buf_id;
logic [1:0]  b_buf_resp;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        b_buf_valid <= 1'b0;
    end else if (b_valid_in && b_ready_out) begin
        // 接收Write Engine的响应
        b_buf_valid <= 1'b1;
        b_buf_id    <= b_id;
        b_buf_resp  <= b_resp;
    end else if (s_axi_bvalid && s_axi_bready) begin
        // 发给AXI Master后清空
        b_buf_valid <= 1'b0;
    end
end

assign s_axi_bvalid = b_buf_valid;
assign s_axi_bid    = b_buf_id;
assign s_axi_bresp  = b_buf_resp;
// Write Engine可以发新响应的条件：B缓冲空闲
assign b_ready_out  = !b_buf_valid;

endmodule