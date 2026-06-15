`timescale 1ns/1ps
import axi_pcie_pkg::*;
module rd_tb;

logic clk,rst_n;
// ── AXI AR通道 ────────────────────────────────────
logic [3:0]  s_axi_arid;
logic [63:0] s_axi_araddr;
logic [7:0]  s_axi_arlen;
logic [2:0]  s_axi_arsize;
logic [1:0]  s_axi_arburst;
logic        s_axi_arvalid;
logic        s_axi_arready;

// ── 向read_engine输出 ─────────────────────────────
ar_info_t    ar_info;
logic        ar_info_valid;
logic        ar_info_ready;

// ── Tag分配接口 ────────────────────────────────────
logic                 alloc_req;
tag_alloc_req_t       alloc_info;
logic [5-1:0] alloc_tag;
logic                 alloc_ack;
logic                 alloc_stall;

logic rd_tlp_ready;

// ── PCIe配置 ──────────────────────────────────────
logic [15:0]          requester_id;
logic [9:0]           mrrs_bytes;    // 运行时可配

// ── PCIe RX AXI-Stream ────────────────────────────
logic [127:0] s_axis_tdata;
logic [15:0]  s_axis_tkeep;
logic         s_axis_tlast;
logic         s_axis_tvalid;
logic         s_axis_tready;

localparam TAG_WIDTH = 5;
localparam ARID_WIDTH = 4;
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

// ── 错误上报 ──────────────────────────────────────
logic                 err_unexpected_cpl; // Tag不存在
logic                 err_cpl_abort;       // Status=CA

// ── read_engine注册新MRd ──────────────────────────
logic [TAG_WIDTH-1:0]  rob_alloc_tag;
rob_entry_t            rob_alloc_entry;
logic                  rob_alloc_valid;

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

// ── AXI R通道输出 ─────────────────────────────────
logic [ARID_WIDTH-1:0] m_axi_rid;
logic [63:0]           m_axi_rdata;
logic [1:0]            m_axi_rresp;
logic                  m_axi_rlast;
logic                  m_axi_rvalid;
logic                  m_axi_rready;


initial begin
    clk = 0;
    forever #5 clk = ~clk;
end

initial begin
    s_axi_arid = 0;
    s_axi_araddr = 0;
    s_axi_arlen = 0;
    s_axi_arsize = 0;
    s_axi_arburst = 0;  // INCR 模式;
    s_axi_arvalid = 0;

    rd_tlp_ready = 1;
    requester_id = 1;
    mrrs_bytes = 256;

    m_axi_rready = 1;  // R通道永远准备接收数据

    rst_n = 0;

    repeat(5) @(posedge clk);
    rst_n <= 1;

end


logic [7:0] my_test_data [256];  // 待发送的 256 字节测试数据
logic [7:0] my_test_data2 [256]; 
initial begin
    @(posedge rst_n);
    @(posedge clk);

    s_axi_arid <= 4'd2;
    s_axi_araddr <= 64'h2c;
    s_axi_arlen <= 63;
    s_axi_arsize <= 3'd3;
    s_axi_arburst <= 2'b01;  // INCR 模式;
    s_axi_arvalid <= 1;

    forever begin
        @(posedge clk);
        if (s_axi_arvalid && s_axi_arready) begin
            s_axi_arvalid <= 1'b0;
            break; // 跳出当前线程
        end
    end

    // s_axi_arid <= 4'd2;
    // s_axi_araddr <= 64'h6c;
    // s_axi_arlen <= 39;
    // s_axi_arsize <= 3'd3;
    // s_axi_arburst <= 2'b01;  // INCR 模式;
    // s_axi_arvalid <= 1;

    // forever begin
    //     @(posedge clk);
    //     if (s_axi_arvalid && s_axi_arready) begin
    //         s_axi_arvalid <= 1'b0;
    //         break; // 跳出当前线程
    //     end
    // end

    $display("AXI read Transaction Completed!");

    #300;

    
    foreach (my_test_data[i]) begin
        my_test_data[i] = 8'(i); // 标准的 SystemVerilog 类型强制转换语法 (Static Cast)
    end

    foreach (my_test_data2[i]) begin
        my_test_data2[i] = 8'(i+1); // 标准的 SystemVerilog 类型强制转换语法 (Static Cast)
    end
    
    send_cpld_256b_aligned(
        .target_tag  (1),   // 直接把例化的连线信号传进去
        .target_arid (4'd2),        // 假设当前测试的 ARID 是 0
        .send_pattern(my_test_data2)
    );
    send_cpld_256b_aligned(
        .target_tag  (0),   // 直接把例化的连线信号传进去
        .target_arid (4'd2),        // 假设当前测试的 ARID 是 0
        .send_pattern(my_test_data)
    );

    #700;
    $finish; // 结束仿真
end

initial begin
    $fsdbDumpfile("tb_wave.fsdb"); // 指定波形文件名字
    $fsdbDumpvars(0, rd_tb,"+all"); // 倾倒tb_wave_tb下所有层级的信号
end

axi_rd_if dut1(
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

read_engine dut2(
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
    .rd_tlp_hdr(),
    .rd_tlp_valid(),
    .rd_tlp_ready(rd_tlp_ready),

    // ── PCIe配置 ──────────────────────────────────────
    .requester_id(requester_id),
    .mrrs_bytes(mrrs_bytes)    // 运行时可配
);

tag_allocator dut3 (
    .clk          (clk),
    .rst_n        (rst_n),

    // ── 来自 read_engine 的同名信号 ──
    .alloc_req    (alloc_req),
    .alloc_info   (alloc_info),
    .alloc_tag    (alloc_tag),
    .alloc_ack    (alloc_ack),
    .alloc_stall  (alloc_stall),

    // ──  快捷操作：直接在括号里给死常数初值 ──
    .free_tag     (free_tag),          //  必须带上 [位宽'进制] 声明！
    .free_valid   (free_valid),          //  同理，不能单写一个 0

    .query_tag    (query_tag),
    // query_entry 是 output，如果不关心，可以直接留空！
    .query_entry  (query_entry),              //  悬空不接，代表 TB 里不观测它
    .query_hit    (query_hit),              //  悬空不接

    .update_tag   (update_tag),
    .update_bytes (update_bytes),
    .update_valid (update_valid),

    .timeout_vec  ()               //  悬空不接
);

cpld_parser dut4 (
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

reorder_buffer dut5(
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
    .m_axi_rid(m_axi_rid),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready)
); 

/**
 * Task: send_cpld_256b_aligned
 * 假设: Header 独占第一个 transfer，Payload 从第二个 transfer 开始整齐对齐
 */
 task automatic send_cpld_256b_aligned (
    input logic [4:0]  target_tag,        // 需要销账的 Tag 号
    input logic [3:0]  target_arid,       // 对应的 AXI ID 
    input logic [7:0]  send_pattern [256] // 待发送的 256 字节测试数据
);
    logic [31:0] dw0, dw1, dw2;
    int byte_ptr;

    // ── 步骤 1: 组装 3DW Header ──
    // DW0: Fmt=2'b10 (带数据3DW), Type=5'b01010 (CplD), Length = 64 DW (256字节)
    dw0 = {2'b10, 1'b0, 5'b01010, 2'b00, 3'b000, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 2'b00, 2'b00, 10'd64};
    // DW1: CompleterID=16'h0000, Status=3'b000 (SC), ByteCount=12'd256
    dw1 = {16'h0000, 3'b000, 1'b0, 12'd256};
    // DW2: RequesterID=16'h0001, Tag=target_tag, LowerAddr=7'b000_0000
    dw2 = {16'h0001, target_tag, 1'b0, 7'b000_0000};

    // ── 步骤 2: AXI-Stream 发送链路 ──
    @(posedge clk);
    #1;
    
    // ===== 【第 1 拍：Header 独占】 =====
    s_axis_tvalid = 1'b1;
    s_axis_tlast  = 1'b0;
    s_axis_tdata[31:0]   = dw0;
    s_axis_tdata[63:32]  = dw1;
    s_axis_tdata[95:64]  = dw2;
    s_axis_tdata[127:96] = 32'h0;     // 💡 简化核心：第 4 个 DW 彻底留空，不带数据！
    s_axis_tkeep         = 16'h0FFF;  // 🔑 只有低 12 字节（3DW）有效

    // 等待大桥 RX 侧 ready 握手
    do begin
        @(posedge clk);
        #1;
    end while (!s_axis_tready);

    // ===== 【第 2~17 拍：纯数据满载，完美对齐传输（共 16 拍）】 =====
    byte_ptr = 0; // 从 256 字节数据的第 0 字节开始发
    
    for (int i = 0; i < 16; i++) begin
        // 这一拍的数据全部由纯数据 Payload 填满
        s_axis_tdata[31:0]   = {send_pattern[byte_ptr+3], send_pattern[byte_ptr+2], send_pattern[byte_ptr+1], send_pattern[byte_ptr+0]};
        s_axis_tdata[63:32]  = {send_pattern[byte_ptr+7], send_pattern[byte_ptr+6], send_pattern[byte_ptr+5], send_pattern[byte_ptr+4]};
        s_axis_tdata[95:64]  = {send_pattern[byte_ptr+11],send_pattern[byte_ptr+10],send_pattern[byte_ptr+9], send_pattern[byte_ptr+8]};
        s_axis_tdata[127:96] = {send_pattern[byte_ptr+15],send_pattern[byte_ptr+14],send_pattern[byte_ptr+13],send_pattern[byte_ptr+12]};
        
        s_axis_tkeep        = 16'hFFFF; // 纯数据拍，16字节全满有效
        
        // 最后一拍（第 16 轮循环，也就是总体第 17 拍）拉高 tlast
        if (i == 15) begin
            s_axis_tlast = 1'b1;
        end else begin
            s_axis_tlast = 1'b0;
        end

        byte_ptr += 16; // 推进指针

        do begin
            @(posedge clk);
            #1;
        end while (!s_axis_tready);
    end

    // 撤销总线信号
    s_axis_tvalid = 1'b0;
    s_axis_tkeep  = '0;
    s_axis_tlast  = 1'b0;
    s_axis_tdata  = '0;
endtask

endmodule