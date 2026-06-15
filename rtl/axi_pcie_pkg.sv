// axi_pcie_pkg.sv
package axi_pcie_pkg;

// ── TLP Header 部分 ───────────────────────────────────────
typedef struct packed {
    logic [127:0] hdr;          // 最长4DW Header
    logic [3:0]   hdr_dw_num;   // Header实际DW数（3或4）
    logic [9:0]   data_dw_num;  // Payload DW数
    logic         has_data;     // 是否有Payload
} tlp_hdr_t;

// ── AW通道信息结构体 ──────────────────────────────────
typedef struct packed {
    logic [3:0]  awid;
    logic [63:0] awaddr;
    logic [7:0]  awlen;     // Burst长度-1（AXI4定义）
    logic [2:0]  awsize;    // 每beat字节数的log2
    logic [1:0]  awburst;   // 00=FIXED,01=INCR,10=WRAP
} aw_info_t;

// ── W通道beat结构体 ───────────────────────────────────
typedef struct packed {
    logic [63:0] wdata;
    logic [7:0]  wstrb;
    logic        wlast;
} w_beat_t;

// AR通道信息
typedef struct packed {
    logic [3:0]  arid;
    logic [63:0] araddr;
    logic [7:0]  arlen;
    logic [2:0]  arsize;
    logic [1:0]  arburst;
} ar_info_t;

// Tag管理结构体
// ══════════════════════════════════════

// read_engine向tag_allocator发起分配请求时携带的信息
typedef struct packed {
    logic [3:0]  arid;       // 原始AXI读事务ID
    logic [63:0] addr;       // 本段MRd起始地址
    logic [9:0]  len_bytes;  // 本段MRd字节数
} tag_alloc_req_t;

// tag_allocator内部存储的表项
typedef struct packed {
    logic        valid;
    logic [3:0]  arid;
    logic [63:0] addr;
    logic [9:0]  len_bytes;   // 本MRd请求字节数
    logic [9:0]  rcvd_bytes;  // 已收到字节数（CplD累计）
} tag_entry_t;

// ROB相关结构体
// ══════════════════════════════════════

// reorder_buffer每个槽位的元数据
// 数据本体存在ROB内部的SRAM里，按Tag索引
typedef struct packed {
    logic        valid;     // 槽位在使用
    logic        complete;  // 数据已全部收到，可以输出
    logic        axi_last;  // 是否是该ARID最后一个TLP
    logic [3:0]  arid;      // 对应的AXI读事务ID
    logic [9:0]  len_bytes; // 本MRd期望总字节数
    logic [9:0]  rcvd_bytes;// 已收到字节数
    logic [1:0]  resp;      // OKAY或SLVERR
} rob_entry_t;

// ════════════════════════════════════════════════════
// Byte Enable计算函数
// 用于write_engine和read_engine
// ════════════════════════════════════════════════════
function automatic logic [3:0] first_dw_be(
    input logic [1:0] addr_low2,   // 地址低2位
    input logic [9:0] len_bytes
);
    if (len_bytes == 0) return 4'b0000;
    case (addr_low2)
        2'b00: return 4'b1111;
        2'b01: return 4'b1110;
        2'b10: return 4'b1100;
        2'b11: return 4'b1000;
    endcase
endfunction

function automatic logic [3:0] last_dw_be(
    input logic [1:0] addr_low2,
    input logic [9:0] len_bytes
);
    logic [1:0] end_byte_offset;
    // 只有1个DW时，LastBE=0（PCIe规范要求）
    // 正确的1DW判断：起始偏移+长度不超过4字节边界
    if (({2'b00, addr_low2} + len_bytes) <= 10'd4) return 4'b0000;
    // 最后一个有效字节在其所在DW内的偏移
    end_byte_offset = (addr_low2 + len_bytes[1:0] - 2'b01) & 2'b11;
    case (end_byte_offset)
        2'b00: return 4'b0001;
        2'b01: return 4'b0011;
        2'b10: return 4'b0111;
        2'b11: return 4'b1111;
    endcase
endfunction


endpackage