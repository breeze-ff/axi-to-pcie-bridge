// tx_arbiter.sv
// 职责：
//   接收写引擎的MWr TLP（读引擎接口预留）
//   检查Credit后决定能否发送
//   按优先级仲裁，流式输出到PCIe PHY接口
//
// TLP发送格式（AXI-Stream）：
//   每个transfer = 128bit = 4DW
//   先发Header（3DW或4DW），再发Payload
//   tlast在最后一个transfer拉高

import axi_pcie_pkg::*;

module tx_arbiter #(
    parameter MPS_BYTES = 128
)(
    input  logic clk,
    input  logic rst_n,

    // ── 来自Write Engine ──────────────────────────────
    input  tlp_hdr_t                  wr_tlp_hdr,
    input  logic [MPS_BYTES*8-1:0]    wr_tlp_data,
    input  logic                      wr_tlp_valid,
    output logic                      wr_tlp_ready,

    // ── 来自Read Engine  ──────────────────────────────
    input  tlp_hdr_t                  rd_tlp_hdr,
    input  logic                      rd_tlp_valid,
    output logic                      rd_tlp_ready,

    // ── Credit查询 ────────────────────────────────────
    input  logic [11:0]               ph_credit,
    input  logic [19:0]               pd_credit,
    input  logic [11:0]               nph_credit,

    // ── Credit消耗通知→Credit Manager ─────────────────
    output logic                      ph_consume,
    output logic [9:0]                pd_consume_dw,
    output logic                      nph_consume,

    // ── PCIe TX AXI-Stream接口 ────────────────────────
    output logic [127:0]              m_axis_tdata,
    output logic [15:0]               m_axis_tkeep,  // 对应位的字节有效
    output logic                      m_axis_tlast,
    output logic                      m_axis_tvalid,
    input  logic                      m_axis_tready
);

// ════════════════════════════════════════════════════
// 内部状态
// ════════════════════════════════════════════════════
typedef enum logic [1:0] {
    S_IDLE,      // 等待TLP
    S_ARB,       // 仲裁（检查Credit，选择发哪个）
    S_SEND_HDR,  // 发送Header
    S_SEND_DATA  // 发送Payload（分多个transfer）
} arb_state_t;

arb_state_t state, next_state;

// 锁存当前正在发送的TLP信息
tlp_hdr_t               cur_hdr;
logic [MPS_BYTES*8-1:0] cur_data;
logic                   cur_is_wr;     // 1=MWr，0=MRd

// Payload发送进度
// 每个transfer发128bit=16字节=4DW
// 最大MPS=128字节=8个transfer
logic [3:0] data_xfer_idx;    // 当前第几个transfer
logic [3:0] data_xfer_total;  // 本TLP共需几个transfer

// Header是否发完
logic hdr_sent;

// ════════════════════════════════════════════════════
// Credit检查
// ════════════════════════════════════════════════════
logic can_send_wr, can_send_rd;

assign can_send_wr = wr_tlp_valid &&
                     (ph_credit >= 12'd1) &&
                     (pd_credit >= {10'b0, wr_tlp_hdr.data_dw_num});

assign can_send_rd = rd_tlp_valid &&
                     (nph_credit >= 12'd1);

// ════════════════════════════════════════════════════
// 发送transfer数计算
// 4DW Header + Payload，每个transfer = 4DW = 128bit
// Header占1个transfer（3DW时第4DW填0，tkeep控制）
// Payload每4DW一个transfer
// ════════════════════════════════════════════════════
// 总transfer数 = 1（Header） + ceil(data_dw_num / 4)
logic [3:0] payload_xfer_num;
assign payload_xfer_num = (cur_hdr.data_dw_num[9:2]) +
                          (|cur_hdr.data_dw_num[1:0]); // 有余数则+1

// ════════════════════════════════════════════════════
// 状态机时序
// ════════════════════════════════════════════════════
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S_IDLE;
    else        state <= next_state;
end

always_comb begin
    next_state = state;
    case (state)
        S_IDLE:
            if (can_send_wr || can_send_rd)
                next_state = S_ARB;

        S_ARB:
            // 仲裁完成，锁存TLP，下一拍发Header
            next_state = S_SEND_HDR;

        S_SEND_HDR:
            if (m_axis_tready) begin
                if (cur_hdr.has_data)
                    next_state = S_SEND_DATA;
                else
                    next_state = S_IDLE;  // MRd无Payload，发完即结束
            end

        S_SEND_DATA:
            // 最后一个Payload transfer发完
            if (m_axis_tready &&
                data_xfer_idx == payload_xfer_num - 1)
                next_state = S_IDLE;

        default: next_state = S_IDLE;
    endcase
end

// ════════════════════════════════════════════════════
// 仲裁与TLP锁存
// ════════════════════════════════════════════════════
// 简单优先级：MWr > MRd（写优先，防止写饥饿）
// 后续可升级为WRR

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_hdr        <= '0;
        cur_data       <= '0;
        cur_is_wr      <= '0;
        data_xfer_idx  <= '0;
    end else begin
        case (state)
            S_ARB: begin
                // 锁存选中的TLP
                if (can_send_wr) begin
                    cur_hdr   <= wr_tlp_hdr;
                    cur_data  <= wr_tlp_data;
                    cur_is_wr <= 1'b1;
                end else begin
                    cur_hdr   <= rd_tlp_hdr;
                    cur_data  <= '0;         // MRd无Payload
                    cur_is_wr <= 1'b0;
                end
                data_xfer_idx <= '0;
            end

            S_SEND_DATA: begin
                if (m_axis_tready)
                    data_xfer_idx <= data_xfer_idx + 1'b1;
            end

            S_IDLE: begin
                data_xfer_idx <= '0;
            end
        endcase
    end
end

// ════════════════════════════════════════════════════
// AXI-Stream输出
// ════════════════════════════════════════════════════
logic [1:0] last_dw_rem;
always_comb begin
    m_axis_tvalid = 1'b0;
    m_axis_tdata  = '0;
    m_axis_tkeep  = '0;
    m_axis_tlast  = '0;

    case (state)
        S_SEND_HDR: begin
            m_axis_tvalid = 1'b1;
            m_axis_tdata  = cur_hdr.hdr;  // 128bit Header

            // tkeep：3DW Header有效12字节，4DW有效16字节
            m_axis_tkeep  = (cur_hdr.hdr_dw_num == 4'd3) ?
                             16'h0FFF :   // 低12字节有效
                             16'hFFFF;   // 全16字节有效

            // 无Payload时Header就是最后一个transfer
            m_axis_tlast  = !cur_hdr.has_data;
        end

        S_SEND_DATA: begin
            m_axis_tvalid = 1'b1;

            // 从cur_data中取当前transfer的128bit
            // data_xfer_idx决定取哪段
            m_axis_tdata = cur_data[data_xfer_idx*128 +: 128];

            // 最后一个transfer的tkeep
            // 最后一段可能不满128bit（DW数不是4的倍数时）
            
            last_dw_rem = cur_hdr.data_dw_num[1:0]; // 余数DW数

            if (data_xfer_idx == payload_xfer_num - 1) begin
                // 最后一个transfer
                m_axis_tlast = 1'b1;
                case (last_dw_rem)
                    2'b00: m_axis_tkeep = 16'hFFFF; // 4DW满
                    2'b01: m_axis_tkeep = 16'h000F; // 1DW有效
                    2'b10: m_axis_tkeep = 16'h00FF; // 2DW有效
                    2'b11: m_axis_tkeep = 16'h0FFF; // 3DW有效
                endcase
            end else begin
                m_axis_tkeep = 16'hFFFF; // 中间transfer全有效
                m_axis_tlast = 1'b0;
            end
        end

        default: begin
            m_axis_tvalid = 1'b0;
        end
    endcase
end

// ════════════════════════════════════════════════════
// 反压信号：告知Write/Read Engine可以发下一个TLP
// ════════════════════════════════════════════════════
// 只在S_ARB状态接收TLP（锁存的那一拍）
// 写优先
assign wr_tlp_ready = (state == S_ARB) && can_send_wr;
assign rd_tlp_ready = (state == S_ARB) && !can_send_wr && can_send_rd;

// ════════════════════════════════════════════════════
// Credit消耗：在S_ARB锁存TLP的同拍扣减
// ════════════════════════════════════════════════════
assign ph_consume    = (state == S_ARB) && can_send_wr;
assign pd_consume_dw = (state == S_ARB) && can_send_wr ?
                        wr_tlp_hdr.data_dw_num : '0;
assign nph_consume   = (state == S_ARB) && !can_send_wr && can_send_rd;

endmodule