// axi_pcie_bridge_top.sv
// 当前阶段：只接写路径，读路径接口预留

import axi_pcie_pkg::*;

module axi_pcie_bridge_top #(
    parameter MPS_BYTES     = 128,
    parameter AXI_DATA_W    = 64,
    parameter AW_FIFO_DEPTH = 8,
    parameter AR_FIFO_DEPTH = 8,
    parameter W_FIFO_DEPTH  = 256,
    parameter MRRS_BYTES     = 512, // 最大支持512，运行时候需要通过mrrs_bytes配置
    parameter AXI_DATA_BYTES = AXI_DATA_W / 8,
    parameter TAG_NUM       = 32,
    parameter TAG_WIDTH     = 5,      // log2(TAG_NUM)
    parameter TIMEOUT_CYC   = 1000_000,
    parameter ARID_NUM   = 16,         // 支持的ARID数量
    parameter ARID_WIDTH = 4          // log2(ARID_NUM)
)(
    input  logic clk,
    input  logic rst_n,

    // ── AXI4 Slave接口 ────────────────────────────────
    // AW
    input  logic [3:0]  s_axi_awid,
    input  logic [63:0] s_axi_awaddr,
    input  logic [7:0]  s_axi_awlen,
    input  logic [2:0]  s_axi_awsize,
    input  logic [1:0]  s_axi_awburst,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    // W
    input  logic [63:0] s_axi_wdata,
    input  logic [7:0]  s_axi_wstrb,
    input  logic        s_axi_wlast,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    // B
    output logic [3:0]  s_axi_bid,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    // ── AXI读接口（预留，暂时悬空）────────────────────
    // AR
    input  logic [3:0]  s_axi_arid,
    input  logic [63:0] s_axi_araddr,
    input  logic [7:0]  s_axi_arlen,
    input  logic [2:0]  s_axi_arsize,
    input  logic [1:0]  s_axi_arburst,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    // R
    output logic [3:0]  s_axi_rid,
    output logic [63:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rlast,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    // ── PCIe TX AXI-Stream 发送 MPS MRD────────────────────────────
    output logic [127:0] m_axis_tdata,
    output logic [15:0]  m_axis_tkeep,
    output logic         m_axis_tlast,
    output logic         m_axis_tvalid,
    input  logic         m_axis_tready,

    // ── PCIe RX AXI-Stream 接收CPLD ────────────────────────────────
    input  logic [127:0] s_axis_tdata,
    input  logic [15:0]  s_axis_tkeep,
    input  logic         s_axis_tlast,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,

    // ── 错误上报 ──────────────────────────────────────
    output logic         err_unexpected_cpl, // Tag不存在
    output logic         err_cpl_abort,       // Status=CA
    // ── 超时上报 ──────────────────────────────────────
    output logic [TAG_NUM-1:0]  timeout_vec,  // tag 处理超时

    // ── credit 消耗通知 output logic ──
    output logic [11:0] ph_credit,
    output logic [19:0] pd_credit,        // PD单位是DW，范围更大
    output logic [11:0] nph_credit,


    // ── 配置接口 ──────────────────────────────────────
    input  logic [15:0]  cfg_requester_id,
    input  logic         fc_init_done,
    input  logic [9:0]   mrrs_bytes,    // 运行时可配

    // ── Credit DLLP更新（来自PHY IP）─────────────────
    input  logic         fc_update_valid,
    input  logic [1:0]   fc_update_type,
    input  logic [11:0]  fc_update_val
);

// ════════════════════════════════════════════════════
// 内部连线
// ════════════════════════════════════════════════════

// AXI写接口 <→ Write Engine
aw_info_t   aw_info;
logic       aw_info_valid, aw_info_ready;
w_beat_t    w_beat;
logic       w_beat_valid,  w_beat_ready;
logic [3:0] b_id_we;
logic [1:0] b_resp_we;
logic       b_valid_we,    b_ready_we;

// Write Engine <→ TX Arbiter
tlp_hdr_t              wr_tlp_hdr;
logic [MPS_BYTES*8-1:0]wr_tlp_data;
logic                  wr_tlp_valid, wr_tlp_ready;

// Credit Manager <→ TX Arbiter
// logic [11:0] ph_credit;
// logic [19:0] pd_credit;
// logic [11:0] nph_credit;
logic        ph_consume;
logic [9:0]  pd_consume_dw;
logic        nph_consume;

// AXI读接口── 向read_engine输出 ─────────────────────────────
ar_info_t    ar_info;
logic        ar_info_valid;
logic        ar_info_ready;

// ─────────── read_engine <-> TX Arbiter ───────────
// ── 向TX Arbiter输出MRd TLP ───────────────────────
tlp_hdr_t             rd_tlp_hdr;
logic                 rd_tlp_valid;
logic                 rd_tlp_ready;

// ─────────── read_engine <-> tag_allocator ───────────
// ── Tag分配接口 ── 
logic                 alloc_req;
tag_alloc_req_t       alloc_info;
logic [TAG_WIDTH-1:0] alloc_tag;
logic                 alloc_ack;
logic                 alloc_stall;

// ─────────── read_engine <-> reorder_buffer ───────────
// ── read_engine注册新MRd ──────────────────────────
logic [TAG_WIDTH-1:0]  rob_alloc_tag;
rob_entry_t            rob_alloc_entry;
logic                  rob_alloc_valid;

// ─────────── cpld_parser <-> tag_allocator ───────────
// ── 查询tag_allocator ─────────────────────────────
logic [TAG_WIDTH-1:0] query_tag;
tag_entry_t           query_entry;
logic                 query_hit;
// ── 更新tag_allocator已收字节 ─────────────────────
logic [TAG_WIDTH-1:0] update_tag;
logic [9:0]           update_bytes;
logic                 update_valid;
// ── 释放tag_allocator ─────────────────────────────
logic [TAG_WIDTH-1:0] free_tag;
logic                 free_valid;

// ─────────── cpld_parser <-> reorder_buffer ───────────
// ── cpld_parser写入数据 ───────────────────────────
logic [TAG_WIDTH-1:0]  wr_tag;
logic [9:0]            wr_offset;
logic [127:0]          wr_data;
logic [15:0]           wr_keep;
logic                  wr_valid;
// ── cpld_parser标记complete ───────────────────────
logic [TAG_WIDTH-1:0]  cpl_tag;
logic [1:0]            cpl_resp;
logic                  cpl_valid;

// ════════════════════════════════════════════════════
// 模块例化
// ════════════════════════════════════════════════════

// ── AXI写接口 ─────────────────────────────────────
axi_wr_if #(
    .AW_FIFO_DEPTH (AW_FIFO_DEPTH),
    .W_FIFO_DEPTH  (W_FIFO_DEPTH)
) u_axi_wr_if (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_axi_awid     (s_axi_awid),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awlen    (s_axi_awlen),
    .s_axi_awsize   (s_axi_awsize),
    .s_axi_awburst  (s_axi_awburst),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wlast    (s_axi_wlast),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bid      (s_axi_bid),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .aw_info        (aw_info),
    .aw_info_valid  (aw_info_valid),
    .aw_info_ready  (aw_info_ready),
    .w_beat         (w_beat),
    .w_beat_valid   (w_beat_valid),
    .w_beat_ready   (w_beat_ready),
    .b_id           (b_id_we),
    .b_resp         (b_resp_we),
    .b_valid_in     (b_valid_we),
    .b_ready_out    (b_ready_we)
);

// ── Write Engine ──────────────────────────────────
write_engine #(
    .MPS_BYTES   (MPS_BYTES),
    .AXI_DATA_W  (AXI_DATA_W)
) u_write_engine (
    .clk            (clk),
    .rst_n          (rst_n),
    .aw_info        (aw_info),
    .aw_info_valid  (aw_info_valid),
    .aw_info_ready  (aw_info_ready),
    .w_beat         (w_beat),
    .w_beat_valid   (w_beat_valid),
    .w_beat_ready   (w_beat_ready),
    .b_id           (b_id_we),
    .b_resp         (b_resp_we),
    .b_valid        (b_valid_we),
    .b_ready        (b_ready_we),
    .ph_credit      (ph_credit),
    .pd_credit      (pd_credit),
    .ph_consume     (),       // 属于遗留，真实计算在tx_arb里面
    .pd_consume_dw  (),        // 属于遗留，真实计算在tx_arb里面
    .wr_tlp_hdr     (wr_tlp_hdr),
    .wr_tlp_data    (wr_tlp_data),
    .wr_tlp_valid   (wr_tlp_valid),
    .wr_tlp_ready   (wr_tlp_ready),
    .requester_id   (cfg_requester_id)
);

// ── Credit Manager ────────────────────────────────
credit_manager u_credit_mgr (
    .clk             (clk),
    .rst_n           (rst_n),
    .fc_update_valid (fc_update_valid),
    .fc_update_type  (fc_update_type),
    .fc_update_val   (fc_update_val),
    .ph_consume      (ph_consume),
    .pd_consume_dw   (pd_consume_dw),
    .nph_consume     (nph_consume),
    .ph_credit       (ph_credit),
    .pd_credit       (pd_credit),
    .nph_credit      (nph_credit),
    .fc_init_done    (fc_init_done)
);

// ── TX Arbiter ────────────────────────────────────
tx_arbiter #(
    .MPS_BYTES (MPS_BYTES)
) u_tx_arbiter (
    .clk            (clk),
    .rst_n          (rst_n),
    .wr_tlp_hdr     (wr_tlp_hdr),
    .wr_tlp_data    (wr_tlp_data),
    .wr_tlp_valid   (wr_tlp_valid),
    .wr_tlp_ready   (wr_tlp_ready),
    .rd_tlp_hdr     (rd_tlp_hdr),
    .rd_tlp_valid   (rd_tlp_valid),
    .rd_tlp_ready   (rd_tlp_ready),
    .ph_credit      (ph_credit),
    .pd_credit      (pd_credit),
    .nph_credit     (nph_credit),
    .ph_consume     (ph_consume),
    .pd_consume_dw  (pd_consume_dw),
    .nph_consume    (nph_consume),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tkeep   (m_axis_tkeep),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tready  (m_axis_tready)
);

axi_rd_if #(
    .AR_FIFO_DEPTH (AR_FIFO_DEPTH)
) u_axi_rd_if(
    .clk(clk),
    .rst_n(rst_n),

    // ── AXI AR通道 ────────────────────────────────────
    .s_axi_arid(s_axi_arid),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arlen(s_axi_arlen),
    .s_axi_arsize(s_axi_arsize),
    .s_axi_arburst(s_axi_arburst),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),

    // ── 向read_engine输出 ─────────────────────────────
    .ar_info(ar_info),
    .ar_info_valid(ar_info_valid),
    .ar_info_ready(ar_info_ready)
);

read_engine #(
    .AXI_DATA_W     (AXI_DATA_W),
    .AXI_DATA_BYTES (AXI_DATA_BYTES),
    .TAG_WIDTH      (TAG_WIDTH)
) u_read_engine(
    .clk(clk),
    .rst_n(rst_n),

    // ── 来自axi_rd_if ─────────────────────────────────
    .ar_info(ar_info),
    .ar_info_valid(ar_info_valid),
    .ar_info_ready(ar_info_ready),  // 消费AR请求

    // ── Tag分配接口 ────────────────────────────────────
    .alloc_req(alloc_req),
    .alloc_info(alloc_info),
    .alloc_tag(alloc_tag),
    .alloc_ack(alloc_ack),
    .alloc_stall(alloc_stall),

    // ── 向ROB注册本段信息 ─────────────────────────────
    // read_engine分配到Tag后，同步通知ROB建立槽位
    .rob_alloc_tag(rob_alloc_tag),
    .rob_alloc_entry(rob_alloc_entry),
    .rob_alloc_valid(rob_alloc_valid),

    // ── 向TX Arbiter输出MRd TLP ───────────────────────
    .rd_tlp_hdr(rd_tlp_hdr),
    .rd_tlp_valid(rd_tlp_valid),
    .rd_tlp_ready(rd_tlp_ready),

    // ── PCIe配置 ──────────────────────────────────────
    .requester_id(cfg_requester_id),
    .mrrs_bytes(mrrs_bytes)    // 运行时可配
);

tag_allocator #(
    .TAG_NUM       (TAG_NUM),
    .TAG_WIDTH     (TAG_WIDTH), // log2(TAG_NUM)
    .TIMEOUT_CYC   (TIMEOUT_CYC)
) u_tag_allocator (
    .clk          (clk),
    .rst_n        (rst_n),

    // ── 来自 read_engine 的同名信号 ──
    .alloc_req    (alloc_req),
    .alloc_info   (alloc_info),
    .alloc_tag    (alloc_tag),
    .alloc_ack    (alloc_ack),
    .alloc_stall  (alloc_stall),

    .free_tag     (free_tag),
    .free_valid   (free_valid),

    .query_tag    (query_tag),
    .query_entry  (query_entry),
    .query_hit    (query_hit),

    .update_tag   (update_tag),
    .update_bytes (update_bytes),
    .update_valid (update_valid),

    .timeout_vec  (timeout_vec)               
);

cpld_parser #(
    .TAG_WIDTH  (TAG_WIDTH)
) u_cpld_parser (
    .clk(clk),
    .rst_n(rst_n),

    // ── PCIe RX AXI-Stream ────────────────────────────
    // 假设每个transfer = 128bit = 4DW
    // TLP边界对齐，Header在第一个transfer
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),

    // ── 查询tag_allocator ─────────────────────────────
    .query_tag(query_tag),
    .query_entry(query_entry),
    .query_hit(query_hit),

    // ── 更新tag_allocator已收字节 ─────────────────────
    .update_tag(update_tag),
    .update_bytes(update_bytes),
    .update_valid(update_valid),

    // ── 释放tag_allocator ─────────────────────────────
    .free_tag(free_tag),
    .free_valid(free_valid),

    // ── 写入reorder_buffer ────────────────────────────
    .rob_wr_tag(wr_tag),
    .rob_wr_offset(wr_offset), // 写入ROB槽位内的字节偏移
    .rob_wr_data(wr_data),   // 本次写入128bit
    .rob_wr_keep(wr_keep),   // 字节有效掩码
    .rob_wr_valid(wr_valid),

    // ── 标记ROB槽位complete ───────────────────────────
    .rob_cpl_tag(cpl_tag),
    .rob_cpl_resp(cpl_resp),  // OKAY或SLVERR
    .rob_cpl_valid(cpl_valid),

    // ── 错误上报 ──────────────────────────────────────
    .err_unexpected_cpl(err_unexpected_cpl), // Tag不存在
    .err_cpl_abort(err_cpl_abort)       // Status=CA
);

reorder_buffer #(
    .TAG_NUM    (TAG_NUM),
    .TAG_WIDTH  (TAG_WIDTH),
    .ARID_NUM   (ARID_NUM),        // 支持的ARID数量
    .ARID_WIDTH (ARID_WIDTH),        // log2(ARID_NUM)
    .MRRS_BYTES (MRRS_BYTES),
    .AXI_DATA_W (AXI_DATA_W)
) u_reorder_buffer(
    .clk(clk),
    .rst_n(rst_n),

    // ── read_engine注册新MRd ──────────────────────────
    .alloc_tag(rob_alloc_tag),
    .alloc_entry(rob_alloc_entry),
    .alloc_valid(rob_alloc_valid),

    // ── cpld_parser写入数据 ───────────────────────────
    .wr_tag(wr_tag),
    .wr_offset(wr_offset),
    .wr_data(wr_data),
    .wr_keep(wr_keep),
    .wr_valid(wr_valid),

    // ── cpld_parser标记complete ───────────────────────
    .cpl_tag(cpl_tag),
    .cpl_resp(cpl_resp),
    .cpl_valid(cpl_valid),

    // ── AXI R通道输出 ─────────────────────────────────
    .m_axi_rid(s_axi_rid),
    .m_axi_rdata(s_axi_rdata),
    .m_axi_rresp(s_axi_rresp),
    .m_axi_rlast(s_axi_rlast),
    .m_axi_rvalid(s_axi_rvalid),
    .m_axi_rready(s_axi_rready)
); 

endmodule