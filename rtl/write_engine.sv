// write_engine.sv
// 职责：
//   1. 从AW_FIFO取地址，从W_FIFO取数据
//   2. 计算TLP切割（MPS + 4KB双重限制）
//   3. 拼装MWr TLP Header + Payload
//   4. 检查PCIe Credit后送TX Arbiter
//   5. 最后一个TLP发完后发B响应

import axi_pcie_pkg::*;

module write_engine #(
    parameter MPS_BYTES     = 128,   // MaxPayloadSize字节数
    parameter AXI_DATA_W    = 64,    // AXI数据位宽（字节数=8）
    parameter AXI_DATA_BYTES= AXI_DATA_W / 8  // = 8
)(
    input  logic clk,
    input  logic rst_n,

    // ── 来自axi_wr_if ─────────────────────────────────
    input  aw_info_t aw_info,
    input  logic     aw_info_valid,
    output logic     aw_info_ready,  // 脉冲：取走AW信息

    input  w_beat_t  w_beat,
    input  logic     w_beat_valid,
    output logic     w_beat_ready,   // 脉冲：消费一个beat

    // ── B响应输出 ──────────────────────────────────────
    output logic [3:0] b_id,
    output logic [1:0] b_resp,
    output logic       b_valid,
    input  logic       b_ready,

    // ── PCIe Credit（来自Credit Manager）──────────────
    input  logic [11:0] ph_credit,
    input  logic [19:0] pd_credit,

    // ── Credit消耗通知 ─────────────────────────────────
    output logic         ph_consume,
    output logic [9:0]   pd_consume_dw,

    // ── 向TX Arbiter输出TLP ───────────────────────────
    output tlp_hdr_t     wr_tlp_hdr,
    output logic [MPS_BYTES*8-1:0]  wr_tlp_data,
    output logic        wr_tlp_valid,
    input  logic        wr_tlp_ready,

    // ── 配置 ──────────────────────────────────────────
    input  logic [15:0] requester_id
);

// ════════════════════════════════════════════════════
// 状态机定义
// ════════════════════════════════════════════════════
typedef enum logic [2:0] {
    S_IDLE,        // 等待AW_FIFO有数据
    S_LOAD_AW,     // 取出AW信息，初始化计数器
    S_CALC,        // 计算本TLP的切割长度（1拍）
    S_COLLECT,     // 从W_FIFO逐beat收集本TLP的Payload
    S_CHK_CREDIT,  // 检查PCIe Credit
    S_SEND,        // 向TX Arbiter发送TLP
    S_BRESP        // 发B响应（最后一个TLP之后）
} state_t;

state_t state, next_state;

// ════════════════════════════════════════════════════
// 内部寄存器
// ════════════════════════════════════════════════════
logic [63:0] cur_addr;         // 当前TLP起始地址
logic [15:0] remain_bytes;     // 整个Burst还剩多少字节未发
logic [3:0]  cur_awid;         // 保存AWID用于B响应
logic [7:0]  cur_awlen;        // 保存AWLEN
logic [2:0]  cur_awsize;       // 保存AWSIZE

// 本TLP相关
logic [9:0]  this_tlp_bytes;   // 本TLP数据字节数
logic [9:0]  this_tlp_dw;      // 本TLP数据DW数（向上取整）
logic        this_is_last;     // 本TLP是最后一个
logic        use_64bit;        // 是否用4DW Header

// Payload收集缓冲（最大MPS=128B=32DW，每DW 4字节）
logic [7:0]  payload_buf [MPS_BYTES];   // 字节数组

// 🔑 【修复引入】字节级流控核心指针
logic [2:0]  beat_byte_idx;    // 当前 AXI Beat 内待处理的字节指针 (0~7)
logic [9:0]  collect_byte_cnt; // 当前 TLP 已成功收集到的有效字节数

// ════════════════════════════════════════════════════
// 切割参数计算（组合逻辑）
// ════════════════════════════════════════════════════
logic [12:0] bytes_to_4k; 
logic [9:0]  calc_bytes;

// 到4KB边界的距离
assign bytes_to_4k = 13'h1000 - {1'b0, cur_addr[11:0]};

// 到下一个MPS自然对齐边界的距离
logic [12:0] bytes_to_mps;
logic [9:0] mps_offset;
assign mps_offset  = cur_addr[9:0] & (MPS_BYTES - 10'd1);

assign bytes_to_mps = (mps_offset == '0) ?
                       {3'b0, MPS_BYTES} : 
                       {3'b0, MPS_BYTES} - {3'b0, mps_offset};

always_comb begin
    logic [12:0] a, b;
    a = (bytes_to_mps < bytes_to_4k) ? bytes_to_mps : bytes_to_4k;
    b = ({3'b0, MPS_BYTES} < a) ? {3'b0, MPS_BYTES} : a;
    calc_bytes = ({3'b0, remain_bytes[9:0]} < b) ? remain_bytes[9:0] : b[9:0];
end

assign this_tlp_dw   = (calc_bytes + 10'd3) >> 2;
assign this_tlp_bytes= calc_bytes;
assign this_is_last  = (calc_bytes == remain_bytes[9:0]);
assign use_64bit     = (cur_addr[63:32] != 32'h0);


// ════════════════════════════════════════════════════
// 🔑 W_FIFO beat消费 & Payload收集 (字节级精准流控)
// ════════════════════════════════════════════════════
logic [2:0] next_beat_byte_idx;
logic [9:0] next_collect_byte_cnt;
logic       beat_consumed;

always_comb begin
    next_beat_byte_idx    = beat_byte_idx;
    next_collect_byte_cnt   = collect_byte_cnt;
    beat_consumed           = 1'b0;
    w_beat_ready            = 1'b0;

    if (state == S_COLLECT && w_beat_valid) begin
        // 单拍内最多尝试吞掉 8 个字节
        for (int i = 0; i < 8; i++) begin
            if (next_collect_byte_cnt < this_tlp_bytes && !beat_consumed) begin
                // 指针无条件向后滑动
                if (next_beat_byte_idx == 3'd7) begin
                    beat_consumed      = 1'b1; // 这拍 8 字节彻底吃完了
                    next_beat_byte_idx = 3'd0;
                end else begin
                    next_beat_byte_idx = next_beat_byte_idx + 1'b1;
                end
                next_collect_byte_cnt  = next_collect_byte_cnt + 1'b1;
            end
        end
        
        // 🔑 只有当当前拍的 8 字节全部被消耗完时，才允许对 W_FIFO 握手（弹出该拍）
        if (beat_consumed) begin
            w_beat_ready = 1'b1;
        end
    end
end

// 时序逻辑：精准移位抓取
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        beat_byte_idx    <= '0;
        collect_byte_cnt <= '0;
        payload_buf      <= '{default: 8'h00};
    end else begin
        if (state == S_LOAD_AW) begin
            beat_byte_idx    <= '0; // 整个大 Burst 开始，总字节指针归零
            collect_byte_cnt <= '0;
        end else if (state == S_CALC) begin
            payload_buf      <= '{default: 8'h00}; // 清空当前 TLP 的 buffer
            collect_byte_cnt <= '0;                // 当前 TLP 已抓取字节复位
            // 🔑 注意：绝对不能在这里重置 beat_byte_idx！
            // 因为上一包没用完的残余半包数据（如第 11 拍的第 2 个 DW）还在物理总线上等待读取。
        end else if (state == S_COLLECT && w_beat_valid) begin
            // 动态还原组合逻辑的推演，精准捕获有效字节
            automatic logic [2:0] t_beat_idx    = beat_byte_idx;
            automatic logic [9:0] t_collect_cnt = collect_byte_cnt;
            automatic logic       t_consumed    = 1'b0;

            for (int i = 0; i < 8; i++) begin
                if (t_collect_cnt < this_tlp_bytes && !t_consumed) begin
                    // 仅当 wstrb 为高时才写入 buffer，实现自动压紧或对齐
                    if (w_beat.wstrb[t_beat_idx]) begin
                        payload_buf[t_collect_cnt] <= w_beat.wdata[t_beat_idx*8 +: 8];
                    end
                    
                    if (t_beat_idx == 3'd7) begin
                        t_consumed = 1'b1;
                        t_beat_idx = 3'd0;
                    end else begin
                        t_beat_idx = t_beat_idx + 1'b1;
                    end
                    t_collect_cnt  = t_collect_cnt + 1'b1;
                end
            end

            beat_byte_idx    <= t_beat_idx;
            collect_byte_cnt <= t_collect_cnt;
        end
    end
end

// 🔑 收集完成判定：当前 TLP 收集到的字节数满足切割预期
logic collect_done;
assign collect_done = (collect_byte_cnt >= this_tlp_bytes);


// ════════════════════════════════════════════════════
// 状态机时序与组合逻辑
// ════════════════════════════════════════════════════
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= S_IDLE;
    else        state <= next_state;
end

always_comb begin
    next_state = state;
    case (state)
        S_IDLE:
            if (aw_info_valid)   next_state = S_LOAD_AW;
        S_LOAD_AW:
            next_state = S_CALC;
        S_CALC:
            next_state = S_COLLECT;
        S_COLLECT:
            if (collect_done)    next_state = S_CHK_CREDIT;
        S_CHK_CREDIT:
            if (ph_credit >= 12'd1 && pd_credit >= {10'b0, this_tlp_dw})
                next_state = S_SEND;
        S_SEND:
            if (wr_tlp_ready) begin
                if (this_is_last) next_state = S_BRESP;
                else              next_state = S_CALC;
            end
        S_BRESP:
            if (b_ready)         next_state = S_IDLE;
        default:                 next_state = S_IDLE;
    endcase
end

// ════════════════════════════════════════════════════
// 寄存器更新
// ════════════════════════════════════════════════════
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_addr     <= '0;
        remain_bytes <= '0;
        cur_awid     <= '0;
        cur_awlen    <= '0;
        cur_awsize   <= '0;
    end else if (state == S_LOAD_AW) begin
        cur_addr     <= aw_info.awaddr;
        remain_bytes <= ({8'b0, aw_info.awlen} + 16'd1) << aw_info.awsize;
        cur_awid     <= aw_info.awid;
        cur_awlen    <= aw_info.awlen;
        cur_awsize   <= aw_info.awsize;
    end else if (state == S_SEND && wr_tlp_ready) begin
        cur_addr     <= cur_addr + {54'b0, this_tlp_bytes};
        remain_bytes <= remain_bytes - {6'b0, this_tlp_bytes};
    end
end

assign aw_info_ready = (state == S_LOAD_AW);

// ════════════════════════════════════════════════════
// TLP Header拼装与输出连接
// ════════════════════════════════════════════════════
logic [127:0] hdr_3dw, hdr_4dw;

// 3DW Header
always_comb begin
    hdr_3dw = '0;
    hdr_3dw[31:29] = 3'b100;          // Fmt: 3DW w/ Data
    hdr_3dw[28:24] = 5'b00000;        // Type: Memory
    hdr_3dw[9:0]   = this_tlp_dw;     // Length (DW)
    hdr_3dw[63:48] = requester_id;
    hdr_3dw[39:36] = last_dw_be(cur_addr[1:0], this_tlp_bytes);
    hdr_3dw[35:32] = first_dw_be(cur_addr[1:0], this_tlp_bytes);
    hdr_3dw[95:66] = cur_addr[31:2];
end

// 4DW Header
always_comb begin
    hdr_4dw = '0;
    hdr_4dw[31:0]  = hdr_3dw[31:0];
    hdr_4dw[31:29] = 3'b110;          // Fmt: 4DW w/ Data
    hdr_4dw[63:32] = hdr_3dw[63:32];
    hdr_4dw[95:64] = cur_addr[63:32];
    hdr_4dw[127:98]= cur_addr[31:2];
end

always_comb begin
    wr_tlp_hdr   = '0;
    wr_tlp_valid = (state == S_SEND);

    if (use_64bit) begin
        wr_tlp_hdr.hdr        = hdr_4dw;
        wr_tlp_hdr.hdr_dw_num = 4'd4;
    end else begin
        wr_tlp_hdr.hdr        = hdr_3dw;
        wr_tlp_hdr.hdr_dw_num = 4'd3;
    end

    for (int i = 0; i < MPS_BYTES; i++)
        wr_tlp_data[i*8 +: 8] = payload_buf[i];

    wr_tlp_hdr.data_dw_num = this_tlp_dw;
    wr_tlp_hdr.has_data    = 1'b1;
end

assign ph_consume    = wr_tlp_valid && wr_tlp_ready;
assign pd_consume_dw = (wr_tlp_valid && wr_tlp_ready) ? this_tlp_dw : '0;

assign b_id    = cur_awid;
assign b_resp  = 2'b00; // OKAY
assign b_valid = (state == S_BRESP);

endmodule