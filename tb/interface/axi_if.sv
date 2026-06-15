// axi_if.sv
interface axi_if (input logic clk, input logic rst_n);

// ── AW通道 ────────────────────────────────────────
logic [3:0]  awid;
logic [63:0] awaddr;
logic [7:0]  awlen;
logic [2:0]  awsize;
logic [1:0]  awburst;
logic        awvalid;
logic        awready;

// ── W通道 ─────────────────────────────────────────
logic [63:0] wdata;
logic [7:0]  wstrb;
logic        wlast;
logic        wvalid;
logic        wready;

// ── B通道 ─────────────────────────────────────────
logic [3:0]  bid;
logic [1:0]  bresp;
logic        bvalid;
logic        bready;

// ── AR通道 ────────────────────────────────────────
logic [3:0]  arid;
logic [63:0] araddr;
logic [7:0]  arlen;
logic [2:0]  arsize;
logic [1:0]  arburst;
logic        arvalid;
logic        arready;

// ── R通道 ─────────────────────────────────────────
logic [3:0]  rid;
logic [63:0] rdata;
logic [1:0]  rresp;
logic        rlast;
logic        rvalid;
logic        rready;

// ════════════════════════════════════════════════
// Clocking Block：Driver视角（驱动AW/W/AR，采样B/R）
// ════════════════════════════════════════════════
clocking driver_cb @(posedge clk);
    default input #1step output #1;

    // AW：驱动
    output awid, awaddr, awlen, awsize, awburst, awvalid;
    input  awready;

    // W：驱动
    output wdata, wstrb, wlast, wvalid;
    input  wready;

    // B：采样
    input  bid, bresp, bvalid;
    output bready;

    // AR：驱动
    output arid, araddr, arlen, arsize, arburst, arvalid;
    input  arready;

    // R：采样
    input  rid, rdata, rresp, rlast, rvalid;
    output rready;
endclocking

// ════════════════════════════════════════════════
// Clocking Block：Monitor视角（全部采样）
// ════════════════════════════════════════════════
clocking monitor_cb @(posedge clk);
    default input #1step;

    input awid, awaddr, awlen, awsize, awburst;
    input awvalid, awready;

    input wdata, wstrb, wlast;
    input wvalid, wready;

    input bid, bresp, bvalid, bready;

    input arid, araddr, arlen, arsize, arburst;
    input arvalid, arready;

    input rid, rdata, rresp, rlast;
    input rvalid, rready;
endclocking

// ════════════════════════════════════════════════
// Modport
// ════════════════════════════════════════════════
modport drv_mp  (clocking driver_cb,  input clk, rst_n);
modport mon_mp  (clocking monitor_cb, input clk, rst_n);

endinterface : axi_if