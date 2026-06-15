// read_engine.sv
// 职责：
//   1. 从AR_FIFO取读请求
//   2. 按MRRS和4KB切割成多个MRd段
//   3. 每段向tag_allocator申请Tag
//   4. 拿到Tag后组装MRd TLP发给tx_arbiter
//   5. Tag耗尽时对AR通道产生背压

import axi_pcie_pkg::*;

module read_engine #(
    parameter AXI_DATA_W     = 64,
    parameter AXI_DATA_BYTES = AXI_DATA_W / 8,
    parameter TAG_WIDTH      = 5
)(
    input  logic clk,
    input  logic rst_n,

    // ── 来自axi_rd_if ─────────────────────────────────
    input  ar_info_t  ar_info,
    input  logic      ar_info_valid,
    output logic      ar_info_ready,  // 消费AR请求

    // ── Tag分配接口 ────────────────────────────────────
    output logic                 alloc_req,
    output tag_alloc_req_t       alloc_info,
    input  logic [TAG_WIDTH-1:0] alloc_tag,
    input  logic                 alloc_ack,
    input  logic                 alloc_stall,

    // ── 向ROB注册本段信息 ─────────────────────────────
    // read_engine分配到Tag后，同步通知ROB建立槽位
    output logic [TAG_WIDTH-1:0] rob_alloc_tag,
    output rob_entry_t           rob_alloc_entry,
    output logic                 rob_alloc_valid,

    // ── 向TX Arbiter输出MRd TLP ───────────────────────
    output tlp_hdr_t             rd_tlp_hdr,
    output logic                 rd_tlp_valid,
    input  logic                 rd_tlp_ready,

    // ── PCIe配置 ──────────────────────────────────────
    input  logic [15:0]          requester_id,
    input  logic [9:0]           mrrs_bytes    // 运行时可配
);

// ════════════════════════════════════════════════════
// 状态机
// ════════════════════════════════════════════════════
typedef enum logic [2:0] {
    S_IDLE,       // 等待AR_FIFO有数据
    S_LOAD_AR,    // 取出AR信息，初始化计数器
    S_CALC,       // 计算本段切割长度
    S_ALLOC_TAG,  // 向tag_allocator申请Tag，等ack
    S_SEND_TLP,   // 发MRd TLP给tx_arbiter
    S_DONE        // 整个AR事务切割完毕
} rd_state_t;

rd_state_t state, next_state;

// ════════════════════════════════════════════════════
// 内部寄存器
// ════════════════════════════════════════════════════
logic [63:0] cur_addr;
logic [15:0] remain_bytes;
logic [3:0]  cur_arid;
logic [7:0]  cur_arlen;
logic [2:0]  cur_arsize;

// 本段切割结果
logic [9:0]  this_seg_bytes;
logic [9:0]  this_seg_dw;
logic        this_is_last;
logic        use_64bit;

// 锁存分配到的Tag（等TLP发出前保持）
logic [TAG_WIDTH-1:0] locked_tag;

// ════════════════════════════════════════════════════
// 切割参数计算（组合逻辑，同write_engine逻辑）
// ════════════════════════════════════════════════════
logic [12:0] bytes_to_4k;
logic [9:0]  calc_bytes;

logic [9:0] mrrs_offset;   // 地址不对齐时候，到下一个tlp要对齐，0x00
logic [12:0] bytes_to_mrrs;

assign bytes_to_4k = 13'h1000 - {1'b0, cur_addr[11:0]};
assign use_64bit   = (cur_addr[63:32] != '0);
assign mrrs_offset   = cur_addr[9:0] & (mrrs_bytes - 10'd1);  // mrrs_bytes设置为256，取低8位

assign bytes_to_mrrs = (mrrs_offset == '0) ?
                        {3'b0, mrrs_bytes} :            // 已对齐，整块可用
                        {3'b0, mrrs_bytes} - {3'b0, mrrs_offset};     // 到下一个MRD边界的距离

always_comb begin
    logic [12:0] a, b;
    // MRD边界 和 4KB边界 取小
    a = (bytes_to_mrrs < bytes_to_4k) ? bytes_to_mrrs : bytes_to_4k;
    // 再和MRD限制取小（保证单TLP不超MRD）
    b = ({3'b0, mrrs_bytes} < a) ? {3'b0, mrrs_bytes} : a;
    // 最后和remain取小
    calc_bytes = ({3'b0, remain_bytes[9:0]} < b) ? remain_bytes[9:0] : b[9:0];
end

assign this_seg_bytes = calc_bytes;
assign this_seg_dw    = (calc_bytes + 10'd3) >> 2;
assign this_is_last   = (calc_bytes == remain_bytes[9:0]);


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
            if (ar_info_valid)
                next_state = S_LOAD_AR;

        S_LOAD_AR:
            next_state = S_CALC;

        S_CALC:
            next_state = S_ALLOC_TAG;

        S_ALLOC_TAG:
            // alloc_stall=1说明Tag耗尽，原地等待
            // alloc_ack=1说明分配成功，进发送
            if (alloc_ack)
                next_state = S_SEND_TLP;

        S_SEND_TLP:
            // TLP被tx_arbiter接受
            if (rd_tlp_ready) begin
                if (this_is_last)
                    next_state = S_DONE;
                else
                    next_state = S_CALC;  // 还有剩余，切下一段
            end

        S_DONE:
            // 整个AR事务处理完，回到IDLE等下一个
            next_state = S_IDLE;

        default: next_state = S_IDLE;
    endcase
end

// ════════════════════════════════════════════════════
// 寄存器更新
// ════════════════════════════════════════════════════
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cur_addr     <= '0;
        remain_bytes <= '0;
        cur_arid     <= '0;
        cur_arlen    <= '0;
        cur_arsize   <= '0;
        locked_tag   <= '0;
    end else begin
        case (state)
            S_LOAD_AR: begin
                cur_addr     <= ar_info.araddr;
                remain_bytes <= ({8'b0, ar_info.arlen} + 16'd1)
                                 << ar_info.arsize;
                cur_arid     <= ar_info.arid;
                cur_arlen    <= ar_info.arlen;
                cur_arsize   <= ar_info.arsize;
            end

            S_ALLOC_TAG: begin
                // 锁存分配到的Tag
                if (alloc_ack)
                    locked_tag <= alloc_tag;
            end

            S_SEND_TLP: begin
                // TLP发出后更新地址和剩余字节
                if (rd_tlp_ready) begin
                    cur_addr     <= cur_addr + {54'b0, this_seg_bytes};
                    remain_bytes <= remain_bytes - {6'b0, this_seg_bytes};
                end
            end
        endcase
    end
end

// ════════════════════════════════════════════════════
// tag_allocator分配请求
// ════════════════════════════════════════════════════
assign alloc_req        = (state == S_ALLOC_TAG) && !alloc_stall;
assign alloc_info.arid      = cur_arid;
assign alloc_info.addr      = cur_addr;
assign alloc_info.len_bytes = this_seg_bytes;

// ════════════════════════════════════════════════════
// ROB槽位注册
// 分配到Tag的同拍通知ROB建立对应槽位
// ════════════════════════════════════════════════════
assign rob_alloc_valid            = alloc_ack;
assign rob_alloc_tag              = alloc_tag;
assign rob_alloc_entry.valid      = 1'b1;
assign rob_alloc_entry.complete   = 1'b0;
assign rob_alloc_entry.arid       = cur_arid;
assign rob_alloc_entry.len_bytes  = this_seg_bytes;
assign rob_alloc_entry.rcvd_bytes = '0;
assign rob_alloc_entry.resp       = 2'b00;
// 只有最后一段TLP才标记axi_last=1
assign rob_alloc_entry.axi_last     = this_is_last;

// ════════════════════════════════════════════════════
// MRd TLP Header拼装
// ════════════════════════════════════════════════════
logic [127:0] hdr_3dw, hdr_4dw;

always_comb begin
    hdr_3dw = '0;
    // DW0
    hdr_3dw[31:29] = 3'b000;           // Fmt: 3DW无数据
    hdr_3dw[28:24] = 5'b00000;         // Type: Memory
    hdr_3dw[23:20] = 4'b0000;          // TC=0
    hdr_3dw[15]    = 1'b0;             // TD
    hdr_3dw[14]    = 1'b0;             // EP
    hdr_3dw[13:12] = 2'b00;            // Attr
    hdr_3dw[11:10] = 2'b00;            // AT
    hdr_3dw[9:0]   = this_seg_dw;      // Length
    // DW1
    hdr_3dw[63:48] = requester_id;
    hdr_3dw[47:40] = {3'b0, locked_tag}; // Tag
    hdr_3dw[39:36] = last_dw_be(cur_addr[1:0], this_seg_bytes);
    hdr_3dw[35:32] = first_dw_be(cur_addr[1:0], this_seg_bytes);
    // DW2
    hdr_3dw[95:66] = cur_addr[31:2];
    hdr_3dw[65:64] = 2'b00;            // PH
end

always_comb begin
    hdr_4dw        = '0;
    hdr_4dw[31:0]  = hdr_3dw[31:0];
    hdr_4dw[31:29] = 3'b010;           // Fmt: 4DW无数据
    hdr_4dw[63:32] = hdr_3dw[63:32];
    hdr_4dw[95:64] = cur_addr[63:32];
    hdr_4dw[127:98]= cur_addr[31:2];
    hdr_4dw[97:96] = 2'b00;
end

// ════════════════════════════════════════════════════
// 输出连接
// ════════════════════════════════════════════════════
always_comb begin
    rd_tlp_hdr          = '0;
    rd_tlp_hdr.has_data = 1'b0;        // MRd无Payload

    if (use_64bit) begin
        rd_tlp_hdr.hdr        = hdr_4dw;
        rd_tlp_hdr.hdr_dw_num = 4'd4;
    end else begin
        rd_tlp_hdr.hdr        = hdr_3dw;
        rd_tlp_hdr.hdr_dw_num = 4'd3;
    end

    rd_tlp_hdr.data_dw_num = '0;       // MRd无Payload
end

assign rd_tlp_valid  = (state == S_SEND_TLP);
assign ar_info_ready = (state == S_LOAD_AR);

endmodule