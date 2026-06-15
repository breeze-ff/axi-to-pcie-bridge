// credit_manager.sv
// 职责：
//   追踪三类PCIe Credit的当前可用量
//   Posted:     PH（Header）、PD（Data，单位DW）
//   Non-Posted: NPH、NPD（读路径用，本阶段先留接口）
//   对端通过DLLP补充Credit，发送TLP时消耗Credit

import axi_pcie_pkg::*;

module credit_manager (
    input  logic clk,
    input  logic rst_n,

    // ── DLLP补充（来自PCIe链路层IP）─────────────────
    // 实际项目中由PHY IP的FC Update接口驱动
    // 仿真中可以初始化为固定值模拟对端通告
    input  logic        fc_update_valid,
    input  logic [1:0]  fc_update_type,
    // 00=PH, 01=PD, 10=NPH, 11=NPD
    input  logic [11:0] fc_update_val,

    // ── 消耗接口（来自TX Arbiter）────────────────────
    input  logic        ph_consume,       // 消耗1个PH
    input  logic [9:0]  pd_consume_dw,    // 消耗N个PD
    input  logic        nph_consume,      // 消耗1个NPH（读路径预留）

    // ── 当前Credit量输出（给TX Arbiter查询）──────────
    output logic [11:0] ph_credit,
    output logic [19:0] pd_credit,        // PD单位是DW，范围更大
    output logic [11:0] nph_credit,

    // ── 初始化完成标志 ────────────────────────────────
    // PCIe规范要求FC Init完成后才能发TLP
    // 仿真中拉高即可，真实项目由PHY IP驱动
    input  logic        fc_init_done
);

// ════════════════════════════════════════════════════
// Credit寄存器
// ════════════════════════════════════════════════════
logic [11:0] ph_cred_r;
logic [19:0] pd_cred_r;
logic [11:0] nph_cred_r;

// ── 更新逻辑（补充和消耗可能同拍，合并计算）──────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ph_cred_r  <= '0;
        pd_cred_r  <= '0;
        nph_cred_r <= '0;
    end else begin
        // PH
        case ({fc_update_valid && fc_update_type==2'b00, ph_consume})
            2'b10: ph_cred_r <= ph_cred_r + fc_update_val;
            2'b01: ph_cred_r <= ph_cred_r - 12'd1;
            2'b11: ph_cred_r <= ph_cred_r + fc_update_val - 12'd1;
            default: ; // 不变
        endcase

        // PD
        // |pd_consume_d表示判断pd_consume_dw是否为0，这样写省资源
        case ({fc_update_valid && fc_update_type==2'b01,
               |pd_consume_dw})
            2'b10: pd_cred_r <= pd_cred_r + {10'b0, fc_update_val};
            2'b01: pd_cred_r <= pd_cred_r - {10'b0, pd_consume_dw};
            2'b11: pd_cred_r <= pd_cred_r + {10'b0, fc_update_val}
                                           - {10'b0, pd_consume_dw};
            default: ;
        endcase

        // NPH（读路径）
        case ({fc_update_valid && fc_update_type==2'b10, nph_consume})
            2'b10: nph_cred_r <= nph_cred_r + fc_update_val;
            2'b01: nph_cred_r <= nph_cred_r - 12'd1;
            2'b11: nph_cred_r <= nph_cred_r + fc_update_val - 12'd1;
            default: ;
        endcase
    end
end

// ── 输出（fc_init_done前强制为0，阻止TLP发送）────────
assign ph_credit  = fc_init_done ? ph_cred_r  : '0;
assign pd_credit  = fc_init_done ? pd_cred_r  : '0;
assign nph_credit = fc_init_done ? nph_cred_r : '0;

// ── 防溢出断言（仿真用）──────────────────────────────
// synthesis translate_off
always_ff @(posedge clk) begin
    if (ph_consume && ph_cred_r == '0)
        $error("[credit_manager] PH underflow at time %0t", $time);
    if (|pd_consume_dw && pd_cred_r < {10'b0, pd_consume_dw})
        $error("[credit_manager] PD underflow at time %0t", $time);
    if (nph_consume && nph_cred_r == '0)
        $error("[credit_manager] NPH underflow at time %0t", $time);
end
// synthesis translate_on

endmodule