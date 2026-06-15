// pcie_rx_if.sv
// 外部注入CplD，Driver驱动，Monitor监听tready

interface pcie_rx_if (input logic clk, input logic rst_n);

logic [127:0] tdata;
logic [15:0]  tkeep;
logic         tlast;
logic         tvalid;
logic         tready;   // DUT驱动，Driver采样

// ── Driver视角（注入CplD）────────────────────────
clocking driver_cb @(posedge clk);
    default input #1step output #1;
    output tdata, tkeep, tlast, tvalid;
    input  tready;
endclocking

// ── Monitor视角（监听注入的CplD和tready）─────────
clocking monitor_cb @(posedge clk);
    default input #1step;
    input tdata, tkeep, tlast, tvalid, tready;
endclocking

modport drv_mp (clocking driver_cb,  input clk, rst_n);
modport mon_mp (clocking monitor_cb, input clk, rst_n);

endinterface : pcie_rx_if