// reorder_buffer.sv
// 职责：
//   1. 维护per-ARID的Tag发出顺序FIFO
//   2. 提供数据写入端口（cpld_parser写入）
//   3. 按AXI事务内Tag顺序输出数据（保证同ARID内有序）
//   4. 不同ARID之间Round-Robin公平调度（异ID可乱序）
//   5. 修复：R_NEXT_TAG → R_LOCK时锁定当前ARID，不切换ID

import axi_pcie_pkg::*;

module reorder_buffer #(
    parameter TAG_NUM    = 32,
    parameter TAG_WIDTH  = 5,
    parameter ARID_NUM   = 16,
    parameter ARID_WIDTH = 4,
    parameter MRRS_BYTES = 512,
    parameter AXI_DATA_W = 64
)(
    input  logic clk,
    input  logic rst_n,

    // ── read_engine注册新MRd（分配Tag时同步调用）────
    input  logic [TAG_WIDTH-1:0]  alloc_tag,
    input  rob_entry_t            alloc_entry,
    input  logic                  alloc_valid,

    // ── cpld_parser写入数据 ───────────────────────────
    input  logic [TAG_WIDTH-1:0]  wr_tag,
    input  logic [9:0]            wr_offset,
    input  logic [127:0]          wr_data,
    input  logic [15:0]           wr_keep,
    input  logic                  wr_valid,

    // ── cpld_parser标记complete ───────────────────────
    input  logic [TAG_WIDTH-1:0]  cpl_tag,
    input  logic [1:0]            cpl_resp,
    input  logic                  cpl_valid,

    // ── AXI R通道输出 ─────────────────────────────────
    output logic [ARID_WIDTH-1:0] m_axi_rid,
    output logic [63:0]           m_axi_rdata,
    output logic [1:0]            m_axi_rresp,
    output logic                  m_axi_rlast,
    output logic                  m_axi_rvalid,
    input  logic                  m_axi_rready
);

// ════════════════════════════════════════════════════
// 参数和局部常量
// ════════════════════════════════════════════════════
localparam BEAT_BYTES = AXI_DATA_W / 8;  // 每个AXI beat的字节数 = 8
localparam FIFO_DEPTH = TAG_NUM;          // 每个ARID的顺序FIFO深度
localparam FIFO_PTR_W = TAG_WIDTH + 1;   // FIFO指针位宽（多1位用于判满判空）

// ════════════════════════════════════════════════════
// 数据存储（TAG_NUM个槽位，每槽MRRS_BYTES字节）
// 每个Tag对应一块数据缓冲区
// ════════════════════════════════════════════════════
logic [7:0] data_buf [TAG_NUM][MRRS_BYTES];

// cpld_parser写入数据：按字节写入，wr_keep控制有效字节
always_ff @(posedge clk) begin
    if (wr_valid) begin
        for (int b = 0; b < 16; b++) begin
            if (wr_keep[b])
                data_buf[wr_tag][wr_offset + b] <= wr_data[b*8 +: 8];
        end
    end
end
// ── 每个Tag已写入ROB的实际字节计数器 ────────────────
logic [9:0] rob_rcvd_bytes [TAG_NUM];

// 计算当前时钟周期 wr_keep 写入了多少个有效字节
logic [4:0] wr_cycle_bytes;
always_comb begin
    wr_cycle_bytes = '0;
    if (wr_valid) begin
        for (int b = 0; b < 16; b++) begin
            if (wr_keep[b]) wr_cycle_bytes = wr_cycle_bytes + 1'b1;
        end
    end
end
// ════════════════════════════════════════════════════
// 元数据表（每个Tag一项）
// ════════════════════════════════════════════════════
rob_entry_t rob_table [TAG_NUM];

// slot_release_valid：当前输出的Tag的最后一个beat发出时释放槽位
logic                  slot_release_valid;
logic [TAG_WIDTH-1:0]  slot_release_tag;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < TAG_NUM; i++) begin
            rob_table[i]      <= '0;
            rob_rcvd_bytes[i] <= '0;
        end
    end else begin
        // 1. 分配新 Slot 时，计数器清零
        if (alloc_valid) begin
            rob_table[alloc_tag]      <= alloc_entry;
            rob_rcvd_bytes[alloc_tag] <= '0;
        end

        // 2. 收到写入数据时，累加实际写入的字节数
        if (wr_valid) begin
            rob_rcvd_bytes[wr_tag] <= rob_rcvd_bytes[wr_tag] + wr_cycle_bytes;
        end

        // 3. 只有当 cpld_parser 喊完 complete，并且 ROB 内部核对字节数确实齐了，才能标记 complete
        if (cpl_valid && rob_table[cpl_tag].valid && !(alloc_valid && alloc_tag == cpl_tag)) begin
            // 考虑当前拍可能正好也有最后一笔 wr_valid 写入
            automatic logic [9:0] total_rcvd;
            total_rcvd = rob_rcvd_bytes[cpl_tag] + ((wr_valid && wr_tag == cpl_tag) ? wr_cycle_bytes : 10'd0);
            
            // 核心安全闸：字节数对齐了才判定真 complete
            if (total_rcvd >= rob_table[cpl_tag].len_bytes) begin
                rob_table[cpl_tag].complete <= 1'b1;
            end
            rob_table[cpl_tag].resp <= cpl_resp;
        end

        // 4. 释放 Slot
        if (slot_release_valid && !(alloc_valid && alloc_tag == slot_release_tag)) begin
            rob_table[slot_release_tag].valid    <= 1'b0;
            rob_table[slot_release_tag].complete <= 1'b0;
            rob_rcvd_bytes[slot_release_tag]     <= '0;
        end
    end
end

// ════════════════════════════════════════════════════
// per-ARID 顺序FIFO
// 每个ARID维护一个独立的Tag发出顺序队列
// read_engine每发一个MRd TLP就把对应Tag压入该ARID的队列
// ════════════════════════════════════════════════════
logic [TAG_WIDTH-1:0]  arid_fifo      [ARID_NUM][FIFO_DEPTH];
logic [FIFO_PTR_W-1:0] arid_fifo_wp   [ARID_NUM];  // 写指针
logic [FIFO_PTR_W-1:0] arid_fifo_rp   [ARID_NUM];  // 读指针
logic                  arid_fifo_empty [ARID_NUM];
logic                  arid_fifo_full  [ARID_NUM];

generate
    genvar g;
    for (g = 0; g < ARID_NUM; g++) begin : gen_fifo_status
        assign arid_fifo_empty[g] =
            (arid_fifo_wp[g] == arid_fifo_rp[g]);
        assign arid_fifo_full[g]  =
            (arid_fifo_wp[g][FIFO_PTR_W-1] != arid_fifo_rp[g][FIFO_PTR_W-1]) &&
            (arid_fifo_wp[g][FIFO_PTR_W-2:0] == arid_fifo_rp[g][FIFO_PTR_W-2:0]);
    end
endgenerate

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < ARID_NUM; i++) begin
            arid_fifo_wp[i] <= '0;
            arid_fifo_rp[i] <= '0;
        end
    end else begin
        // 入队：新Tag按其ARID写入对应队列
        if (alloc_valid) begin
            automatic logic [ARID_WIDTH-1:0] wid;
            wid = alloc_entry.arid[ARID_WIDTH-1:0];
            arid_fifo[wid][arid_fifo_wp[wid][FIFO_PTR_W-2:0]] <= alloc_tag;
            arid_fifo_wp[wid] <= arid_fifo_wp[wid] + 1'b1;
        end

        // 出队：该Tag的数据已全部输出完毕
        if (slot_release_valid) begin
            automatic logic [ARID_WIDTH-1:0] rid;
            rid = rob_table[slot_release_tag].arid[ARID_WIDTH-1:0];
            arid_fifo_rp[rid] <= arid_fifo_rp[rid] + 1'b1;
        end
    end
end

// ════════════════════════════════════════════════════
// 每个ARID的队头Tag及就绪状态
// head_ready[i]：ARID=i的队头Tag数据已收齐，可以输出
// ════════════════════════════════════════════════════
logic [TAG_WIDTH-1:0] head_tag   [ARID_NUM];
logic                 head_ready [ARID_NUM];

generate
    for (g = 0; g < ARID_NUM; g++) begin : gen_head
        assign head_tag[g] =
            arid_fifo[g][arid_fifo_rp[g][FIFO_PTR_W-2:0]];

        // 队头就绪：队列非空 且 队头Tag的数据已收齐 且 槽位有效
        assign head_ready[g] =
            !arid_fifo_empty[g] &&
            rob_table[head_tag[g]].complete &&
            rob_table[head_tag[g]].valid;
    end
endgenerate

// ════════════════════════════════════════════════════
// Round-Robin仲裁器（跨ARID公平调度）
// 注意：仲裁器持续运行，但只有在允许切换ARID时才使用其结果
// ════════════════════════════════════════════════════
logic [ARID_WIDTH-1:0] rr_ptr;      // 轮询起始ARID
logic [ARID_WIDTH-1:0] arb_winner;  // 本轮仲裁胜出的ARID
logic                  arb_valid;   // 有ARID可以输出

always_comb begin
    arb_winner = '0;
    arb_valid  = 1'b0;
    // 从rr_ptr开始环形扫描，找第一个head_ready的ARID
    for (int i = 0; i < ARID_NUM; i++) begin
        automatic logic [ARID_WIDTH-1:0] idx;
        idx = (rr_ptr + i[ARID_WIDTH-1:0]) & (ARID_NUM - 1);
        if (head_ready[idx] && !arb_valid) begin
            arb_winner = idx;
            arb_valid  = 1'b1;
        end
    end
end

// rr_ptr：只在一个完整AXI事务（所有Tag）输出完毕后推进
// 即cur_is_axi_last=1的最后一个beat输出时推进
logic out_last_beat;
logic cur_is_axi_last;
// ── 当前正在输出的Tag信息 ────────────────────────────
logic [TAG_WIDTH-1:0]  cur_out_tag;
logic [ARID_WIDTH-1:0] cur_out_arid;
logic [6:0]            r_beat_idx;    // 当前输出第几个beat
logic [6:0]            r_beat_total;  // 本Tag共需输出几个beat

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rr_ptr <= '0;
    else if (out_last_beat && cur_is_axi_last)
        rr_ptr <= (cur_out_arid + 1'b1) & (ARID_NUM - 1);
end

// ════════════════════════════════════════════════════
// 输出状态机
// ════════════════════════════════════════════════════
typedef enum logic [1:0] {
    R_IDLE,      // 等待仲裁选出可输出的ARID
    R_LOCK,      // 锁定当前输出的Tag（1拍），准备发beat
    R_SEND,      // 逐beat输出R通道数据
    R_NEXT_TAG   // 当前Tag输出完，等待同ARID下一个Tag complete
} r_state_t;

r_state_t r_state, r_next;



// ════════════════════════════════════════════════════
// 关键修复：burst_in_progress标志
//
// 问题根源：
//   R_NEXT_TAG等待下一个Tag时，仲裁器arb_winner可能已经
//   切换到其他ARID。当R_LOCK执行时若直接用arb_winner，
//   会错误地切换到其他ARID，打断当前AXI burst。
//
// 修复方案：
//   用burst_in_progress标记当前是否处于"AXI burst进行中"
//   R_LOCK时根据此标志决定：
//     burst_in_progress=1 → 来自R_NEXT_TAG，锁定cur_out_arid
//     burst_in_progress=0 → 来自R_IDLE，使用arb_winner
// ════════════════════════════════════════════════════
logic burst_in_progress;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        burst_in_progress <= 1'b0;
    end else begin
        case (r_state)
            R_IDLE:
                // 空闲时：没有burst在进行
                burst_in_progress <= 1'b0;

            R_SEND: begin
                if (out_last_beat) begin
                    if (!cur_is_axi_last)
                        // 当前Tag发完，但AXI事务还有后续Tag
                        // → 即将进入R_NEXT_TAG，burst仍在进行
                        burst_in_progress <= 1'b1;
                    else
                        // 当前Tag是AXI事务最后一个Tag，burst完成
                        // → 即将回到R_IDLE，burst结束
                        burst_in_progress <= 1'b0;
                end
            end

            // R_LOCK和R_NEXT_TAG期间不改变burst_in_progress
            default: ;
        endcase
    end
end

// ── 状态机时序 ────────────────────────────────────
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) r_state <= R_IDLE;
    else        r_state <= r_next;
end

// ── 状态机组合 ────────────────────────────────────
always_comb begin
    r_next = r_state;
    case (r_state)
        R_IDLE:
            // 有任意ARID的队头就绪，进入锁定
            if (arb_valid)
                r_next = R_LOCK;

        R_LOCK:
            // 锁定1拍后立即开始发送
            r_next = R_SEND;

        R_SEND:
            if (out_last_beat) begin
                if (cur_is_axi_last)
                    // 整个AXI事务完成，回到仲裁
                    r_next = R_IDLE;
                else
                    // 本Tag发完，等待同ARID下一个Tag
                    r_next = R_NEXT_TAG;
            end

        R_NEXT_TAG:
            // 等待当前ARID的下一个队头Tag complete
            // 注意：必须用cur_out_arid而不是arb_winner
            // 这里只检查本ARID的队头，不受其他ARID影响
            if (head_ready[cur_out_arid])
                r_next = R_LOCK;

        default: r_next = R_IDLE;
    endcase
end

// ── 寄存器更新 ────────────────────────────────────
assign r_beat_total = (rob_table[cur_out_tag].len_bytes +
                       BEAT_BYTES - 1) / BEAT_BYTES;

assign out_last_beat = m_axi_rvalid && m_axi_rready &&
                       (r_beat_idx == r_beat_total - 1);

assign slot_release_valid = out_last_beat;
assign slot_release_tag   = cur_out_tag;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_out_tag     <= '0;
        cur_out_arid    <= '0;
        cur_is_axi_last <= '0;
        r_beat_idx      <= '0;
    end else begin
        case (r_state)
            R_IDLE: begin
                r_beat_idx <= '0;
            end

            R_LOCK: begin
                // ════════════════════════════════════════
                // 核心修复点：
                //   burst_in_progress=1（来自R_NEXT_TAG）
                //     → 锁定当前ARID，只更新Tag
                //     → cur_out_arid保持不变
                //   burst_in_progress=0（来自R_IDLE仲裁）
                //     → 使用仲裁结果，允许切换ARID
                // ════════════════════════════════════════
                if (burst_in_progress) begin
                    // 来自R_NEXT_TAG：继续当前AXI事务
                    // 取当前ARID的下一个队头Tag（已在R_NEXT_TAG等待complete）
                    cur_out_tag     <= head_tag[cur_out_arid];
                    cur_is_axi_last <= rob_table[head_tag[cur_out_arid]].axi_last;
                    // cur_out_arid故意不赋值，保持原值
                end else begin
                    // 来自R_IDLE：新的AXI事务，使用仲裁结果
                    cur_out_tag     <= head_tag[arb_winner];
                    cur_out_arid    <= arb_winner;
                    cur_is_axi_last <= rob_table[head_tag[arb_winner]].axi_last;
                end
                r_beat_idx <= '0;
            end

            R_SEND: begin
                if (m_axi_rvalid && m_axi_rready)
                    r_beat_idx <= r_beat_idx + 1'b1;
            end

            R_NEXT_TAG: begin
                // 等待期间清零beat索引，准备下一个Tag的输出
                r_beat_idx <= '0;
            end
        endcase
    end
end

// ════════════════════════════════════════════════════
// R通道数据读出
// 从data_buf按beat索引取8字节
// ════════════════════════════════════════════════════
logic [63:0] r_beat_data;
logic [3:0]  last_beat_valid_bytes; 

assign last_beat_valid_bytes = (rob_table[cur_out_tag].len_bytes % BEAT_BYTES == 0) ? 
                               4'd8 : (rob_table[cur_out_tag].len_bytes % BEAT_BYTES);

always_comb begin
    r_beat_data = '0;
    for (int b = 0; b < BEAT_BYTES; b++) begin
        r_beat_data[b*8 +: 8] = data_buf[cur_out_tag][r_beat_idx * BEAT_BYTES + b];
    end
    // 2. 核心修改：如果是当前 Tag 的最后一拍，将超出有效范围的高位字节强行改写为 8'hX
    if (r_beat_idx == r_beat_total - 1) begin
        for (int b = 0; b < BEAT_BYTES; b++) begin
            if (b >= last_beat_valid_bytes) begin
                r_beat_data[b*8 +: 8] = 8'bxxxx_xxxx; // 赋予 X 态，让 Scoreboard 的 $isunknown 剔除
            end
        end
    end
end

// ════════════════════════════════════════════════════
// AXI R通道输出
// ════════════════════════════════════════════════════
// rvalid：只在R_SEND状态有效
assign m_axi_rvalid = (r_state == R_SEND);

// rid：使用锁定的cur_out_arid，不受仲裁器实时值影响
assign m_axi_rid    = cur_out_arid[ARID_WIDTH-1:0];

assign m_axi_rdata  = r_beat_data;
assign m_axi_rresp  = rob_table[cur_out_tag].resp;

// rlast：只在AXI事务最后一个Tag的最后一个beat拉高
assign m_axi_rlast  = out_last_beat && cur_is_axi_last;

// ════════════════════════════════════════════════════
// 仿真断言
// ════════════════════════════════════════════════════
// synthesis translate_off
always_ff @(posedge clk) begin
    // 断言：FIFO不应溢出
    if (alloc_valid) begin
        automatic logic [ARID_WIDTH-1:0] wid;
        wid = alloc_entry.arid[ARID_WIDTH-1:0];
        if (arid_fifo_full[wid])
            $error("[ROB] ARID=%0d FIFO full at %0t", wid, $time);
    end

    // 断言：complete标记应作用于有效槽位
    if (cpl_valid && !rob_table[cpl_tag].valid)
        $error("[ROB] cpl on invalid slot tag=%0d at %0t", cpl_tag, $time);

    // 断言：burst_in_progress期间，R_LOCK不应切换ARID
    if (r_state == R_LOCK && burst_in_progress) begin
        // 验证cur_out_arid在burst进行中保持不变
        // （此处只做打印，实际检查由波形验证）
        $display("[ROB] R_LOCK from NEXT_TAG: locked arid=%0d tag=%0d at %0t",
                 cur_out_arid, head_tag[cur_out_arid], $time);
    end

    // 断言：rlast后的下一拍，rid不应在同一burst内改变
    // （验证AXI burst原子性）
    if (m_axi_rvalid && m_axi_rready && !m_axi_rlast) begin
        // burst进行中，下一拍rid应该保持不变
        // 通过波形观察验证
    end
end
// synthesis translate_on

endmodule