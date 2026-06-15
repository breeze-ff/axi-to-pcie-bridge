// pcie_tx_if.sv
// DUT发出TLP（MWr/MRd），Monitor监听
// tready由Driver控制，模拟PHY背压

interface pcie_tx_if (input logic clk, input logic rst_n);

logic [127:0] tdata;
logic [15:0]  tkeep;
logic         tlast;
logic         tvalid;
logic         tready;   // Driver驱动，控制背压

// ── Monitor视角（采样DUT发出的TLP）──────────────
clocking monitor_cb @(posedge clk);
    default input #1step;
    input tdata, tkeep, tlast, tvalid, tready;
endclocking

// ── Driver视角（控制tready背压）──────────────────
clocking driver_cb @(posedge clk);
    default input #1step output #1;
    input  tdata, tkeep, tlast, tvalid;
    output tready;
endclocking

modport mon_mp (clocking monitor_cb, input clk, rst_n);
modport drv_mp (clocking driver_cb,  input clk, rst_n);

endinterface : pcie_tx_if