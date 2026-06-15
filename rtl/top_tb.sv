`timescale 1ns/1ps
import axi_pcie_pkg::*;
module top_tb;

logic clk;
logic rst_n;

// ── AXI写通道（Slave侧）──────────────────────────
logic [3:0]  s_axi_awid;
logic [63:0] s_axi_awaddr;
logic [7:0]  s_axi_awlen;
logic [2:0]  s_axi_awsize;
logic [1:0]  s_axi_awburst;
logic        s_axi_awvalid;
logic        s_axi_awready;

logic [63:0] s_axi_wdata;
logic [7:0]  s_axi_wstrb;
logic        s_axi_wlast;
logic        s_axi_wvalid;
logic        s_axi_wready;

logic [3:0]  s_axi_bid;
logic [1:0]  s_axi_bresp;
logic        s_axi_bvalid;
logic        s_axi_bready;

// ── AXI读接口（预留，暂时悬空）────────────────────
logic [3:0]  s_axi_arid;
logic [63:0] s_axi_araddr;
logic [7:0]  s_axi_arlen;
logic [2:0]  s_axi_arsize;
logic [1:0]  s_axi_arburst;
logic        s_axi_arvalid;
logic        s_axi_arready;
logic [3:0]  s_axi_rid;
logic [63:0] s_axi_rdata;
logic [1:0]  s_axi_rresp;
logic        s_axi_rlast;
logic        s_axi_rvalid;
logic        s_axi_rready;

// ── PCIe TX AXI-Stream ────────────────────────────
logic [127:0] m_axis_tdata;
logic [15:0]  m_axis_tkeep;
logic         m_axis_tlast;
logic         m_axis_tvalid;
logic         m_axis_tready;

// ── PCIe RX（预留）────────────────────────────────
logic [127:0] s_axis_tdata;
logic [15:0]  s_axis_tkeep;
logic         s_axis_tlast;
logic         s_axis_tvalid;
logic         s_axis_tready;

// ── 错误上报 ──────────────────────────────────────
logic         err_unexpected_cpl; // Tag不存在
logic         err_cpl_abort;       // Status=CA
// ── 超时上报 ──────────────────────────────────────
logic [32-1:0]  timeout_vec;  // tag 处理超时

// ── 配置接口 ──────────────────────────────────────
logic [15:0]  cfg_requester_id;
logic         fc_init_done;
logic [9:0]   mrrs_bytes;    // 运行时可配

// ── Credit DLLP更新（来自PHY IP）─────────────────
logic         fc_update_valid;
logic [1:0]   fc_update_type;
logic [11:0]  fc_update_val;


axi_pcie_bridge_top u_top(
    .clk(clk),
    .rst_n(rst_n),

    // ── AXI4 Slave接口 ────────────────────────────────
    .s_axi_awid(s_axi_awid),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awlen(s_axi_awlen),
    .s_axi_awsize(s_axi_awsize),
    .s_axi_awburst(s_axi_awburst),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),

    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wlast(s_axi_wlast),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),

    .s_axi_bid(s_axi_bid),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),

    // ── AXI读接口（预留，暂时悬空）────────────────────
    .s_axi_arid(s_axi_arid),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arlen(s_axi_arlen),
    .s_axi_arsize(s_axi_arsize),
    .s_axi_arburst(s_axi_arburst),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),

    .s_axi_rid(s_axi_rid),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rlast(s_axi_rlast),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),

    // ── PCIe TX AXI-Stream ────────────────────────────
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tlast(m_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),

    // ── PCIe RX（预留）────────────────────────────────
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),

    // ── 错误上报 ──────────────────────────────────────
    .err_unexpected_cpl(err_unexpected_cpl), // Tag不存在
    .err_cpl_abort(err_cpl_abort),       // Status=CA

    // ── 超时上报 ──────────────────────────────────────
    .timeout_vec(timeout_vec),  // tag 处理超时

    // ── 配置接口 ──────────────────────────────────────
    .cfg_requester_id(cfg_requester_id),
    .fc_init_done(fc_init_done),
    .mrrs_bytes(mrrs_bytes),

    // ── Credit DLLP更新（来自PHY IP）─────────────────
    .fc_update_valid(fc_update_valid),
    .fc_update_type(fc_update_type),
    .fc_update_val(fc_update_val)
);

initial begin
    clk = 0;
    forever #5 clk = ~clk; // 半周期为5，时钟周期为10
end
initial begin
    rst_n = 0;
    // 初始时将所有驱动的 AXI valid 信号清零，避免不定态
    
    s_axi_awvalid = 0;
    s_axi_wvalid  = 0;
    s_axi_awid    = 0;
    s_axi_awaddr  = 0;
    s_axi_awlen   = 0;
    s_axi_awsize  = 0;
    s_axi_awburst = 0;
    s_axi_wdata   = 0;
    s_axi_wstrb   = 0;
    s_axi_wlast   = 0;

    s_axi_bready = 1'b1; // 允许接收 B 响应

    // ── 读路径 ────────────────────────────────
    s_axi_arid = 0;
    s_axi_araddr = 0;
    s_axi_arlen = 0;
    s_axi_arsize = 0;
    s_axi_arburst = 0;
    s_axi_arvalid = 0;

    s_axi_rready = 1;


    m_axis_tready = 1;  // PCIe侧永远ready

    
    cfg_requester_id  = 16'h0100; // 身份证号焊死
    mrrs_bytes = 256;   // 设置MRD为256
    fc_init_done  = 1'b1;     // 默认初始化充值
    fc_update_valid = 0;
    fc_update_type = 0;         // 00=PH, 01=PD, 10=NPH, 11=NPD
    fc_update_val = 0;

    #50;               // 等待 50ns
    @(posedge clk);    // 对齐到时钟沿
    rst_n <= 1;        // 释放复位

    // 充值 MPS Header 额度
    @(posedge clk);
    fc_update_valid <= 1;
    fc_update_type <= 2'b0;
    fc_update_val <= 12'd50;

    // 充值 MPS Data 额度
    @(posedge clk);
    fc_update_valid <= 1;
    fc_update_type <= 2'b01;
    fc_update_val <= 20'd1024;

    // 充值 MRD Header 额度
    @(posedge clk);
    fc_update_valid <= 1;
    fc_update_type <= 2'b10;
    fc_update_val <= 12'd50;

    @(posedge clk);
    fc_update_valid <= 0;
end

localparam int AXI_LEN = 12;
logic [7:0] my_test_data [256];  // 待发送的 256 字节测试数据
logic [7:0] my_test_data2 [256]; 
initial begin
    // 1. 等待复位释放
    @(posedge rst_n);
    repeat(3) @(posedge clk);

    // 2. 并发启动地址通道和数据通道
    fork
        // 线程 A: 发送写地址
        begin
            s_axi_awid    <= 4'b0001;
            s_axi_awaddr  <= 64'h12;
            s_axi_awlen   <= AXI_LEN-1;      // 突发长度 = len + 1 
            s_axi_awsize  <= 3'd3;   // 8 字节 (64位) 传输
            s_axi_awburst <= 2'b01;  // INCR 模式
            s_axi_awvalid <= 1;      // 主动拉高 valid！
            
            
            // 只要没握手成功，就一直维持 valid；一旦握手成功，下个周期立刻拉低
            forever begin
                @(posedge clk);
                if (s_axi_awvalid && s_axi_awready) begin
                    s_axi_awvalid <= 1'b0;
                    break; // 跳出当前线程
                end
            end

            s_axi_awid    <= 4'b0010;          // 换个 ID
            s_axi_awaddr  <= 64'h80;          // 换个地址
            s_axi_awlen   <= AXI_LEN-1;      
            s_axi_awsize  <= 3'd3;   
            s_axi_awburst <= 2'b01;  
            s_axi_awvalid <= 1;               // 再次拉高 valid！
            
            // 等待第二次握手
            while (1) begin
                @(posedge clk);
                if (s_axi_awvalid && s_axi_awready) begin
                    s_axi_awvalid <= 1'b0; 
                    break;
                end
            end
        end

        // 线程 B: 发送写数据（完全独立）
        begin
            for(int i=0; i<AXI_LEN; i++) begin
                @(posedge clk);
                if(i==0) s_axi_wdata  <= 64'h1111_1111_1111_1111;
                else s_axi_wdata  <= {8{8'(i)}};
                
                if(i==AXI_LEN-1) begin 
                    s_axi_wlast  <= 1'b1;
                    //s_axi_wstrb  <= 8'h7f;
                end
                else begin 
                    s_axi_wlast  <= 1'b0;
                   // s_axi_wstrb  <= 8'hff;
                end
                s_axi_wstrb  <= 8'hff;
                s_axi_wvalid <= 1'b1;
            end
            forever begin
                @(posedge clk);
                if (s_axi_wvalid && s_axi_wready) begin
                    s_axi_wvalid <= 1'b0;
                    s_axi_wlast  <= 1'b0;
                    break; // 跳出当前线程
                end
            end

            for(int i=0; i<AXI_LEN; i++) begin
                @(posedge clk);
                if(i==0) s_axi_wdata  <= 64'h1111_1111_1111_1111;
                else s_axi_wdata  <= {8{8'(i)}};
                
                if(i==AXI_LEN-1) begin 
                    s_axi_wlast  <= 1'b1;
                    //s_axi_wstrb  <= 8'h7f;
                end
                else begin 
                    s_axi_wlast  <= 1'b0;
                    //s_axi_wstrb  <= 8'hff;
                end
                s_axi_wstrb  <= 8'hff;
                s_axi_wvalid <= 1'b1;
            end
            forever begin
                @(posedge clk);
                if (s_axi_wvalid && s_axi_wready) begin
                    s_axi_wvalid <= 1'b0;
                    s_axi_wlast  <= 1'b0;
                    break; // 跳出当前线程
                end
            end

        end
        begin
            // 读数据
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
        end
    join // 两个通道都握手成功后，才继续往下走
    
    $display("AXI Write Transaction Completed!");

    
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

    #800;
    $finish; // 结束仿真
end

initial begin
    $fsdbDumpfile("tb_wave.fsdb"); // 指定波形文件名字
    $fsdbDumpvars(0, top_tb,"+all"); // 倾倒tb_wave_tb下所有层级的信号
end

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
    // DW2: RequesterID=16'h0100, Tag=target_tag, LowerAddr=7'b000_0000
    dw2 = {16'h0100, target_tag, 1'b0, 7'b000_0000};

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