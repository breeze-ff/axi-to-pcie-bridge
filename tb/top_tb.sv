// tb_top.sv
`include "uvm_macros.svh"
import uvm_pkg::*;
import axi_pcie_pkg::*;

module top_tb;

    // ── 时钟复位 ──────────────────────────────────────
    logic clk;
    logic rst_n;
    // ── Interface例化 ─────────────────────────────────
    axi_if      u_axi_if    (.clk(clk), .rst_n(rst_n));
    pcie_tx_if  u_pcie_tx_if(.clk(clk), .rst_n(rst_n));
    pcie_rx_if  u_pcie_rx_if(.clk(clk), .rst_n(rst_n));
    cfg_if      u_cfg_if    (.clk(clk), .rst_n(rst_n));

    initial clk = 0;
    always #5 clk = ~clk;   // 100MHz

    initial begin
        rst_n = 0;
        repeat(10) @(posedge clk);
        rst_n <= 1;
        // 在test里面做
        // u_cfg_if.init_cfg(16'd1000,10'd256);  // 配置bridge的id号码，设置MPS报文长度最大为256
        // u_cfg_if.inject_credit(2'b00,12'd50);  // 充值额度PH
        // u_cfg_if.inject_credit(2'b01,12'd1024);  // 充值额度PD
        // u_cfg_if.inject_credit(2'b10,12'd50);  // 充值额度NPH
    end

    

    // 初始化
    initial begin
        // 0时刻绝对初始化，防止 X 态污染
        // AW
        u_axi_if.awid    = 0;
        u_axi_if.awaddr  = 0;
        u_axi_if.awlen   = 0;
        u_axi_if.awsize  = 0;
        u_axi_if.awburst = 0;
        u_axi_if.awvalid = 0; 
        // W
        u_axi_if.wdata   = 0;
        u_axi_if.wstrb   = 0;
        u_axi_if.wlast   = 0;
        u_axi_if.wvalid  = 0;
        // B
        u_axi_if.bready  = 0;   // B接收通道也拉低，driver会驱动
        // AR
        u_axi_if.arid    = 0;
        u_axi_if.araddr  = 0;
        u_axi_if.arlen   = 0;
        u_axi_if.arsize  = 0;
        u_axi_if.arburst = 0;
        u_axi_if.arvalid = 0; 
        // R
        u_axi_if.rready  = 0;   // R接收通道也拉低，driver会驱动

        u_pcie_tx_if.tready = 1;  // 一直拉高，随时接收tlp

        
    end

    // ── DUT例化 ───────────────────────────────────────
    axi_pcie_bridge_top #(
        .MPS_BYTES     (128),
        .AXI_DATA_W    (64),
        .AW_FIFO_DEPTH (32),
        .AR_FIFO_DEPTH (32),
        .W_FIFO_DEPTH  (256),
        .MRRS_BYTES    (512),   // 是最大容量，并非MRRS,MRRS要手动设置
        .TAG_NUM       (128),
        .TAG_WIDTH     (7),
        .ARID_NUM      (16),
        .ARID_WIDTH    (4)
    ) u_dut (
        .clk                (clk),
        .rst_n              (rst_n),

        // AXI写
        .s_axi_awid         (u_axi_if.awid),
        .s_axi_awaddr       (u_axi_if.awaddr),
        .s_axi_awlen        (u_axi_if.awlen),
        .s_axi_awsize       (u_axi_if.awsize),
        .s_axi_awburst      (u_axi_if.awburst),
        .s_axi_awvalid      (u_axi_if.awvalid),
        .s_axi_awready      (u_axi_if.awready),

        .s_axi_wdata        (u_axi_if.wdata),
        .s_axi_wstrb        (u_axi_if.wstrb),
        .s_axi_wlast        (u_axi_if.wlast),
        .s_axi_wvalid       (u_axi_if.wvalid),
        .s_axi_wready       (u_axi_if.wready),

        .s_axi_bid          (u_axi_if.bid),
        .s_axi_bresp        (u_axi_if.bresp),
        .s_axi_bvalid       (u_axi_if.bvalid),
        .s_axi_bready       (u_axi_if.bready),

        // AXI读
        .s_axi_arid         (u_axi_if.arid),
        .s_axi_araddr       (u_axi_if.araddr),
        .s_axi_arlen        (u_axi_if.arlen),
        .s_axi_arsize       (u_axi_if.arsize),
        .s_axi_arburst      (u_axi_if.arburst),
        .s_axi_arvalid      (u_axi_if.arvalid),
        .s_axi_arready      (u_axi_if.arready),

        .s_axi_rid          (u_axi_if.rid),
        .s_axi_rdata        (u_axi_if.rdata),
        .s_axi_rresp        (u_axi_if.rresp),
        .s_axi_rlast        (u_axi_if.rlast),
        .s_axi_rvalid       (u_axi_if.rvalid),
        .s_axi_rready       (u_axi_if.rready),

        // PCIe TX
        .m_axis_tdata       (u_pcie_tx_if.tdata),
        .m_axis_tkeep       (u_pcie_tx_if.tkeep),
        .m_axis_tlast       (u_pcie_tx_if.tlast),
        .m_axis_tvalid      (u_pcie_tx_if.tvalid),
        .m_axis_tready      (u_pcie_tx_if.tready),

        // PCIe RX
        .s_axis_tdata       (u_pcie_rx_if.tdata),
        .s_axis_tkeep       (u_pcie_rx_if.tkeep),
        .s_axis_tlast       (u_pcie_rx_if.tlast),
        .s_axis_tvalid      (u_pcie_rx_if.tvalid),
        .s_axis_tready      (u_pcie_rx_if.tready),

        // 配置
        .cfg_requester_id   (u_cfg_if.cfg_requester_id),
        .fc_init_done       (u_cfg_if.fc_init_done),
        .mrrs_bytes         (u_cfg_if.mrrs_bytes),
        .fc_update_valid    (u_cfg_if.fc_update_valid),
        .fc_update_type     (u_cfg_if.fc_update_type),
        .fc_update_val      (u_cfg_if.fc_update_val),
        .ph_credit          (u_cfg_if.ph_credit),     
        .pd_credit          (u_cfg_if.pd_credit),  
        .nph_credit         (u_cfg_if.nph_credit),

        // 错误和超时
        .err_unexpected_cpl (u_cfg_if.err_unexpected_cpl),
        .err_cpl_abort      (u_cfg_if.err_cpl_abort),
        .timeout_vec        (u_cfg_if.timeout_vec)
    );

    // ── UVM配置和启动 ─────────────────────────────────
    initial begin
        // 把interface传入UVM配置数据库
        // uvm_test_top*是传递到所有组件下，包括test
        // uvm_test_top.*,不包括test
        uvm_config_db #(virtual axi_if)::set(null, "uvm_test_top*", "axi_vif", u_axi_if);      
        uvm_config_db #(virtual pcie_tx_if)::set(null, "uvm_test_top*", "pcie_tx_vif", u_pcie_tx_if);  
        uvm_config_db #(virtual pcie_rx_if)::set(null, "uvm_test_top*", "pcie_rx_vif", u_pcie_rx_if);
        uvm_config_db #(virtual cfg_if)::set(null, "uvm_test_top*", "cfg_vif", u_cfg_if);

        run_test();
    end

    initial begin
        $fsdbDumpfile("novas.fsdb"); // 指定波形文件名字
        $fsdbDumpvars(0, top_tb,"+all"); // 倾倒tb_wave_tb下所有层级的信号
    end

    // ── 超时保护 ──────────────────────────────────────
    initial begin
        #1_000_000;
        `uvm_fatal("TIMEOUT", "Simulation timeout")
    end

endmodule