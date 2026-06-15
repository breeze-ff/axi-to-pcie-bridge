// cpld_parser.sv 修正版
// 关键修改：去掉S_PARSE_HDR
// Header在S_IDLE收到tvalid的那一拍直接解析
// 职责：
//   解析PCIe RX侧的CplD TLP
//   数据写入reorder_buffer
//   元数据更新tag_allocator

import axi_pcie_pkg::*;

module cpld_parser #(
    parameter TAG_WIDTH  = 5
)(
    input  logic clk,
    input  logic rst_n,

    // ── PCIe RX AXI-Stream ────────────────────────────
    // 假设每个transfer = 128bit = 4DW
    // TLP边界对齐，Header在第一个transfer
    input  logic [127:0] s_axis_tdata,
    input  logic [15:0]  s_axis_tkeep,
    input  logic         s_axis_tlast,
    input  logic         s_axis_tvalid,
    output logic         s_axis_tready,

    // ── 查询tag_allocator ─────────────────────────────
    output logic [TAG_WIDTH-1:0] query_tag,
    input  tag_entry_t           query_entry,
    input  logic                 query_hit,

    // ── 更新tag_allocator已收字节 ─────────────────────
    output logic [TAG_WIDTH-1:0] update_tag,
    output logic [9:0]           update_bytes,
    output logic                 update_valid,

    // ── 释放tag_allocator ─────────────────────────────
    output logic [TAG_WIDTH-1:0] free_tag,
    output logic                 free_valid,

    // ── 写入reorder_buffer ────────────────────────────
    output logic [TAG_WIDTH-1:0] rob_wr_tag,
    output logic [9:0]           rob_wr_offset, // 写入ROB槽位内的字节偏移
    output logic [127:0]         rob_wr_data,   // 本次写入128bit
    output logic [15:0]          rob_wr_keep,   // 字节有效掩码
    output logic                 rob_wr_valid,

    // ── 标记ROB槽位complete ───────────────────────────
    output logic [TAG_WIDTH-1:0] rob_cpl_tag,
    output logic [1:0]           rob_cpl_resp,  // OKAY或SLVERR
    output logic                 rob_cpl_valid,

    // ── 错误上报 ──────────────────────────────────────
    output logic                 err_unexpected_cpl, // Tag不存在
    output logic                 err_cpl_abort       // Status=CA
);

// ════════════════════════════════════════════════════
// 状态机：只有三个状态
// ════════════════════════════════════════════════════
typedef enum logic [1:0] {
    S_IDLE,      // 等待TLP，同时在tvalid拍直接解析Header
    S_RECV_DATA, // 接收Payload（Header之后的transfer）
    S_ERROR      // 错误TLP，丢弃剩余
} cpl_state_t;

cpl_state_t state, next_state;

// ════════════════════════════════════════════════════
// Header解析（组合逻辑，只在S_IDLE时有意义）
// ════════════════════════════════════════════════════
// Header字段解析（第一个transfer）
// CplD Header固定3DW，格式：
//   DW0[31:30]=Fmt, [29:24]=Type, [9:0]=Length
//   DW1[31:16]=Completer ID, [15:13]=Status,
//      [12]=BCM, [11:0]=ByteCount
//   DW2[31:16]=Requester ID, [15:8]=Tag,
//      [6:0]=LowerAddr
// Payload从第二个DW开始（Header之后紧跟）
// ════════════════════════════════════════════════════
// ════════════════════════════════════════════════════
logic [2:0]           cpl_status;
logic [11:0]          cpl_byte_count;
logic [TAG_WIDTH-1:0] cpl_tag;
logic [6:0]           cpl_lower_addr;
logic [9:0]           cpl_length_dw;
logic                 is_cpld;
logic                 is_cpl;

always_comb begin
    cpl_length_dw  = s_axis_tdata[9:0];
    is_cpld        = (s_axis_tdata[28:24] == 5'b01010) &&
                     (s_axis_tdata[31:30] == 2'b10);
    is_cpl         = (s_axis_tdata[28:24] == 5'b01010) &&
                     (s_axis_tdata[31:30] == 2'b00);
    cpl_status     = s_axis_tdata[47:45];
    cpl_byte_count = s_axis_tdata[43:32];
    cpl_tag        = s_axis_tdata[TAG_WIDTH-1+72:72];
    cpl_lower_addr = s_axis_tdata[70:64];
end

// ════════════════════════════════════════════════════
// Header检查结果（S_IDLE且tvalid时判断）
// 把所有分支条件提前组合出来，状态机里直接用
// ════════════════════════════════════════════════════
logic hdr_is_valid_cpld; // 正常CplD，可以收数据
logic hdr_is_error;      // 需要丢弃

always_comb begin
    hdr_is_valid_cpld = 1'b0;
    hdr_is_error      = 1'b0;

    if (s_axis_tvalid && state == S_IDLE) begin
        if (!is_cpld && !is_cpl) begin
            // 不是Completion TLP
            hdr_is_error = 1'b1;
        end else if (!query_hit) begin
            // Tag不存在
            hdr_is_error = 1'b1;
        end else if (cpl_status != 3'b000) begin
            // 非成功状态
            hdr_is_error = 1'b1;
        end else if (is_cpld) begin
            // 正常CplD
            hdr_is_valid_cpld = 1'b1;
        end
        // is_cpl（无数据）：既不是valid_cpld也不是error
        // 直接回S_IDLE，不做任何操作
    end
end

// ════════════════════════════════════════════════════
// 锁存Header信息
// 在S_IDLE && tvalid的那一拍锁存，后续S_RECV_DATA使用
// ════════════════════════════════════════════════════
logic [TAG_WIDTH-1:0] cur_tag;
logic [9:0]           cur_length_dw;
logic [2:0]           cur_status;
logic [9:0]           cur_payload_bytes;  // 本CplD携带字节数
logic [9:0]           wr_base_offset;     // 本CplD在ROB内的起始偏移
logic [9:0]           data_xfer_cnt;      // S_RECV_DATA已收transfer数

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_tag          <= '0;
        cur_length_dw    <= '0;
        cur_status       <= '0;
        cur_payload_bytes<= '0;
        wr_base_offset   <= '0;
        data_xfer_cnt    <= '0;
    end else begin

        // ── S_IDLE收到Header拍：锁存所有信息 ──────────
        // 注意：query_entry.rcvd_bytes此时已经反映了
        //       该Tag之前收到的字节数（组合逻辑直接查表）
        if (state == S_IDLE && s_axis_tvalid && hdr_is_valid_cpld) begin
            cur_tag           <= cpl_tag;
            cur_length_dw     <= cpl_length_dw;
            cur_status        <= cpl_status;
            cur_payload_bytes <= {cpl_length_dw, 2'b00}; // *4
            wr_base_offset    <= query_entry.rcvd_bytes;  // ← 关键：此拍查到的是正确值
            data_xfer_cnt     <= '0;
        end

        // ── S_RECV_DATA：transfer计数递增 ──────────────
        if (state == S_RECV_DATA && s_axis_tvalid) begin
            data_xfer_cnt <= data_xfer_cnt + 1'b1;
        end
    end
end

// ════════════════════════════════════════════════════
// 收齐判断（用锁存的cur值，而不是组合逻辑的cpl值）
// ════════════════════════════════════════════════════
// 注意query_entry在S_RECV_DATA时query_tag=cur_tag
// query_entry.rcvd_bytes是tag表当前值
// 收齐条件：已收 + 本次 >= 总需求
logic this_cpl_done;
assign this_cpl_done = query_hit &&
    (query_entry.rcvd_bytes + cur_payload_bytes
     >= query_entry.len_bytes);

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

        S_IDLE: begin
            if (s_axis_tvalid) begin
                if (hdr_is_valid_cpld) begin
                    // 正常CplD
                    // tlast在Header拍就拉高说明无Payload（不正常，按错误处理）
                    next_state = s_axis_tlast ? S_ERROR : S_RECV_DATA;
                end else if (hdr_is_error) begin
                    // 错误TLP，看是否已经是最后一拍
                    next_state = s_axis_tlast ? S_IDLE : S_ERROR;
                end
                // is_cpl（无数据正常Completion）：保持S_IDLE
                // 其他情况：保持S_IDLE
            end
        end

        S_RECV_DATA: begin
            if (s_axis_tvalid && s_axis_tlast)
                next_state = S_IDLE;
        end

        S_ERROR: begin
            if (s_axis_tvalid && s_axis_tlast)
                next_state = S_IDLE;
        end

        default: next_state = S_IDLE;
    endcase
end

// ════════════════════════════════════════════════════
// tag查询
// S_IDLE时用解析出的cpl_tag查（Header那一拍）
// S_RECV_DATA时用锁存的cur_tag查（收齐判断用）
// ════════════════════════════════════════════════════
assign query_tag = (state == S_IDLE) ? cpl_tag : cur_tag;

// ════════════════════════════════════════════════════
// 输出信号
// ════════════════════════════════════════════════════

// 始终接收
assign s_axis_tready = 1'b1;

// ── 写ROB数据（S_RECV_DATA期间每个transfer）──────────
assign rob_wr_valid  = (state == S_RECV_DATA) && s_axis_tvalid;
assign rob_wr_tag    = cur_tag;
assign rob_wr_data   = s_axis_tdata;
assign rob_wr_keep   = s_axis_tkeep;
assign rob_wr_offset = wr_base_offset + {data_xfer_cnt, 4'b0};
                       // 每个transfer 16字节（128bit）

// ── 更新rcvd_bytes（tlast拍更新）─────────────────────
assign update_valid  = (state == S_RECV_DATA) &&
                        s_axis_tvalid && s_axis_tlast;
assign update_tag    = cur_tag;
assign update_bytes  = cur_payload_bytes;

// ── 释放Tag（收齐的tlast拍）──────────────────────────
assign free_valid    = update_valid && this_cpl_done;
assign free_tag      = cur_tag;

// ── 标记ROB complete（与free同拍）────────────────────
assign rob_cpl_valid = free_valid;
assign rob_cpl_tag   = cur_tag;
assign rob_cpl_resp  = (cur_status == 3'b000) ? 2'b00 : 2'b10;

// ── 错误上报 ──────────────────────────────────────────
assign err_unexpected_cpl = (state == S_IDLE) && s_axis_tvalid && (is_cpld || is_cpl) && !query_hit;
assign err_cpl_abort      = (state == S_IDLE) && s_axis_tvalid && (cpl_status == 3'b100);

endmodule