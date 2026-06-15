// pcie_tlp_item.sv
// Monitor从PCIe TX侧捕获TLP后填入此结构
// 也是Scoreboard比对的基准

typedef enum logic [2:0] {
    TLP_MWR,    // Memory Write
    TLP_MRD,    // Memory Read
    TLP_CPLD,   // Completion with Data
    TLP_CPL,    // Completion without Data
    TLP_UNKNOWN // 其他
} tlp_type_e;

class pcie_tlp_item extends uvm_sequence_item;
    `uvm_object_utils_begin(pcie_tlp_item)
        `uvm_field_enum(tlp_type_e, tlp_type,     UVM_ALL_ON)
        `uvm_field_int(fmt,         UVM_ALL_ON)
        `uvm_field_int(length_dw,   UVM_ALL_ON)
        `uvm_field_int(requester_id,UVM_ALL_ON)
        `uvm_field_int(tag,         UVM_ALL_ON)
        `uvm_field_int(address,     UVM_ALL_ON)
        `uvm_field_int(first_dw_be, UVM_ALL_ON)
        `uvm_field_int(last_dw_be,  UVM_ALL_ON)
        `uvm_field_array_int(payload, UVM_ALL_ON)
        // CplD专用字段
        `uvm_field_int(cpl_status,  UVM_ALL_ON)
        `uvm_field_int(byte_count,  UVM_ALL_ON)
        `uvm_field_int(lower_addr,  UVM_ALL_ON)
    `uvm_object_utils_end

    // ── 通用字段 ──────────────────────────────────────
    tlp_type_e   tlp_type;
    logic [2:0]  fmt;
    logic [9:0]  length_dw;
    logic [15:0] requester_id;
    logic [7:0]  tag;
    logic [63:0] address;       // 32或64位地址统一存64位
    logic [3:0]  first_dw_be;
    logic [3:0]  last_dw_be;
    logic [31:0] payload[];     // MWr的Payload，按DW存储

    // ── CplD专用字段 ──────────────────────────────────
    logic [2:0]  cpl_status;
    logic [11:0] byte_count;
    logic [6:0]  lower_addr;

    // ── 原始Header（调试用）──────────────────────────
    logic [127:0] raw_hdr;

    function new(string name = "pcie_tlp_item");
        super.new(name);
    endfunction

    function string convert2string();
        string s;
        s = $sformatf(
            "[TLP] type=%s tag=%0d addr=0x%016h len=%0d dw first_be=%4b last_be=%4b",
            tlp_type.name(), tag, address,
            length_dw, first_dw_be, last_dw_be);
        return s;
    endfunction

endclass