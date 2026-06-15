// tag_allocator.sv
// 职责：
//   1. 为每个MRd TLP分配一个唯一Tag（5bit，32个Tag）
//   2. 记录Tag → (arid, addr, len_bytes) 的映射
//   3. CplD到来时提供反查接口
//   4. CplD收齐后释放Tag
//   5. Tag耗尽时通知read_engine背压

import axi_pcie_pkg::*;

module tag_allocator #(
    parameter TAG_NUM       = 32,
    parameter TAG_WIDTH     = 5,      // log2(TAG_NUM)
    parameter TIMEOUT_CYC   = 100_000
)(
    input  logic clk,
    input  logic rst_n,

    // ── 分配接口（来自read_engine）───────────────────
    input  logic                alloc_req,
    input  tag_alloc_req_t      alloc_info,
    output logic [TAG_WIDTH-1:0]alloc_tag,
    output logic                alloc_ack,    // 分配成功脉冲
    output logic                alloc_stall,  // Tag耗尽，read_engine需等待

    // ── 释放接口（来自cpld_parser）───────────────────
    input  logic [TAG_WIDTH-1:0]free_tag,
    input  logic                free_valid,

    // ── 查询接口（来自cpld_parser，CplD到来时反查）───
    input  logic [TAG_WIDTH-1:0]query_tag,
    output tag_entry_t          query_entry,
    output logic                query_hit,

    // ── 已收字节更新（来自cpld_parser）───────────────
    // 每收到一个CplD，更新对应Tag已收字节数
    input  logic [TAG_WIDTH-1:0]update_tag,
    input  logic [9:0]          update_bytes,
    input  logic                update_valid,

    // ── 超时上报 ──────────────────────────────────────
    output logic [TAG_NUM-1:0]  timeout_vec
);

// ════════════════════════════════════════════════════
// Tag存储表
// ════════════════════════════════════════════════════
tag_entry_t tag_table [TAG_NUM];
logic [31:0] tag_timer [TAG_NUM];   // 超时计数器

// ════════════════════════════════════════════════════
// 空闲Tag查找：Round-Robin避免饥饿
// ════════════════════════════════════════════════════
logic [TAG_WIDTH-1:0] rr_ptr;       // 轮询起始位置
logic [TAG_WIDTH-1:0] free_idx;     // 找到的空闲Tag
logic                 found_free;   // 是否找到空闲Tag

// 从rr_ptr开始找第一个valid=0的Tag
logic [TAG_WIDTH-1:0] idx;
// idx是为了从rr_ptr环形查找，& (TAG_NUM - 1)只取低5位
// 释放tag时，下一拍才能重新分配
// 当前实现：free_valid那一拍tag_table[free_tag].valid=0
// 同一拍alloc可能分配同一个tag

// 修改：alloc时跳过刚刚释放的tag
always_comb begin
    free_idx   = '0;
    found_free = 1'b0;
    for (int i = 0; i < TAG_NUM; i++) begin
        logic [TAG_WIDTH-1:0] idx;
        idx = (rr_ptr + i[TAG_WIDTH-1:0]) & (TAG_NUM - 1);
        // 排除刚释放的tag（free_valid同拍不能立即复用）
        if (!tag_table[idx].valid && !(free_valid && free_tag == idx) && !found_free) begin
            free_idx   = idx;
            found_free = 1'b1;
        end
    end
end

assign alloc_stall = !found_free;
assign alloc_ack   = alloc_req && found_free;
assign alloc_tag   = free_idx;

// ════════════════════════════════════════════════════
// 分配/释放/更新操作
// ════════════════════════════════════════════════════
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < TAG_NUM; i++) begin
            tag_table[i] <= '0;
            tag_timer[i] <= '0;
        end
        rr_ptr <= '0;
    end else begin

        // ── 分配 ─────────────────────────────────────
        if (alloc_ack) begin
            tag_table[free_idx].valid      <= 1'b1;
            tag_table[free_idx].arid       <= alloc_info.arid;
            tag_table[free_idx].addr       <= alloc_info.addr;
            tag_table[free_idx].len_bytes  <= alloc_info.len_bytes;
            tag_table[free_idx].rcvd_bytes <= '0;
            tag_timer[free_idx]            <= '0;
            // 更新轮询指针到下一个位置
            rr_ptr <= (free_idx + 1'b1) & (TAG_NUM - 1);
        end

        // ── 已收字节累加（CplD部分到达）──────────────
        if (update_valid && tag_table[update_tag].valid) begin
            tag_table[update_tag].rcvd_bytes <=
                tag_table[update_tag].rcvd_bytes + update_bytes;
        end

        // ── 释放（CplD全部收齐，由cpld_parser触发）───
        if (free_valid) begin
            tag_table[free_tag].valid <= 1'b0;
            tag_timer[free_tag]       <= '0;
        end

        // ── 超时计数（valid的Tag才计时）──────────────
        for (int i = 0; i < TAG_NUM; i++) begin
            if (tag_table[i].valid) begin
                // 分配和超时同Tag不会同拍（分配时timer已清零）
                if (!(free_valid && free_tag == i[TAG_WIDTH-1:0]))
                    tag_timer[i] <= tag_timer[i] + 1'b1;
            end else begin
                tag_timer[i] <= '0;
            end
        end
    end
end

// ════════════════════════════════════════════════════
// 查询接口（组合逻辑，CplD解析时立即反查）
// ════════════════════════════════════════════════════
assign query_hit   = tag_table[query_tag].valid;
assign query_entry = tag_table[query_tag];

// ════════════════════════════════════════════════════
// 超时检测
// ════════════════════════════════════════════════════
generate
    genvar i;
    for (i = 0; i < TAG_NUM; i++) begin : gen_timeout
        assign timeout_vec[i] = tag_table[i].valid && (tag_timer[i] >= TIMEOUT_CYC);
    end
endgenerate

// ════════════════════════════════════════════════════
// 仿真断言
// ════════════════════════════════════════════════════
// synthesis translate_off
always_ff @(posedge clk) begin
    // 释放一个未分配的Tag
    if (free_valid && !tag_table[free_tag].valid)
        $error("[tag_alloc] freeing invalid tag=%0d at %0t", free_tag, $time);
    // 超时告警
    for (int i = 0; i < TAG_NUM; i++) begin
        if (timeout_vec[i])
            $warning("[tag_alloc] tag=%0d timeout at %0t", i, $time);
    end
end
// synthesis translate_on

endmodule