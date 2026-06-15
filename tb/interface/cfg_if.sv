// cfg_if.sv
// 管理DUT的配置输入和状态输出
// 不需要clocking block，直接由test在复位后配置

interface cfg_if (input logic clk, input logic rst_n);

// ── 配置输入 ──────────────────────────────────────
logic [15:0] cfg_requester_id;
logic        fc_init_done;
logic [9:0]  mrrs_bytes;

// ── Credit更新 ────────────────────────────────────
logic        fc_update_valid;
logic [1:0]  fc_update_type;
logic [11:0] fc_update_val;

// ── 状态输出（监听）──────────────────────────────
logic        err_unexpected_cpl;
logic        err_cpl_abort;
logic [31:0] timeout_vec;

// ── credit 消耗通知 output logic ──

logic [11:0] ph_credit;
logic [19:0] pd_credit;        // PD单位是DW，范围更大
logic [11:0] nph_credit;

// ── 快速配置task（Test直接调用）──────────────────
task automatic init_cfg(
    input logic [15:0] req_id,
    input logic [9:0]  mrrs
);
    cfg_requester_id = req_id;
    mrrs_bytes       = mrrs;
    fc_init_done     = 1'b0;
    fc_update_valid  = 1'b0;
    fc_update_type   = 2'b00;
    fc_update_val    = 12'h0;
    @(posedge clk);
    #1;
    fc_init_done = 1'b1;
endtask

// ── Credit注入task（Test或Sequence调用）──────────
task automatic inject_credit(
    input logic [1:0]  ctype,  // 00=PH,01=PD,10=NPH
    input logic [11:0] val
);
    @(posedge clk); #1;
    fc_update_valid = 1'b1;
    fc_update_type  = ctype;
    fc_update_val   = val;
    @(posedge clk); #1;
    fc_update_valid = 1'b0;
endtask

endinterface : cfg_if