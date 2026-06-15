// cpld_seq_item.sv
// CplD Driver注入时使用
// Reactive模式下由pcie_tx_monitor触发生成

class cpld_seq_item extends uvm_sequence_item;
    `uvm_object_utils_begin(cpld_seq_item)
        `uvm_field_int(tag,          UVM_ALL_ON)
        `uvm_field_int(cpl_status,   UVM_ALL_ON)
        `uvm_field_int(byte_count,   UVM_ALL_ON)
        `uvm_field_int(lower_addr,   UVM_ALL_ON)
        `uvm_field_int(requester_id, UVM_ALL_ON)
        `uvm_field_int(completer_id, UVM_ALL_ON)
        `uvm_field_array_int(data,   UVM_ALL_ON)
        `uvm_field_int(delay_cycles, UVM_ALL_ON)
        `uvm_field_int(split_cpl,    UVM_ALL_ON)
    `uvm_object_utils_end

    // ── 必须字段（由MRd信息推导）─────────────────────
    logic [7:0]  tag;           // 必须和对应MRd一致
    logic [2:0]  cpl_status;    // 000=SC, 001=UR, 100=CA
    logic [11:0] byte_count;    // 本次CplD携带字节数
    logic [6:0]  lower_addr;    // 第一个字节地址低7位
    logic [15:0] requester_id;  // 复制MRd的requester_id
    logic [15:0] completer_id;  // 来自cfg_requester_id，为了方便可以假设PCIE设备和桥的ID相同,也可以自定义

    // ── 回注数据 ──────────────────────────────────────
    // 按DW存储，length_dw = ceil(byte_count/4)
    rand logic [31:0] data[];

    // ── 随机延迟（模拟PCIe往返时延）─────────────────
    rand logic [7:0] delay_cycles;
    int prev_delay = -1;
    // ── 是否拆分成多个CplD（模拟RCB边界拆分）────────
    rand logic split_cpl;

    // ════════════════════════════════════════════════
    // 约束
    // ════════════════════════════════════════════════

    // 默认状态成功
    constraint c_status {
        cpl_status == 3'b000;
    }

    // 延迟范围：1~20拍
    constraint c_delay {
        delay_cycles inside {[1:60]};
        // 如果 prev_delay 有效，则启动“相差至少 8”的约束
        if (prev_delay != -1) {
            delay_cycles >= (prev_delay + 8) || delay_cycles <= (prev_delay - 8);
        }
    }

    // 默认不拆分
    constraint c_split {
        split_cpl == 1'b0;
    }

    function new(string name = "cpld_seq_item");
        super.new(name);
    endfunction

    // ── 从MRd TLP推导CplD内容 ─────────────────────
    // Reactive Driver调用此函数自动填字段
    function void build_from_mrd(pcie_tlp_item mrd);
        tag          = mrd.tag;
        requester_id = mrd.requester_id;
        // byte_count = length_dw * 4（简化，忽略BE边界）
        byte_count   = {mrd.length_dw, 2'b00};
        // lower_addr来自原始MRd地址低7位
        lower_addr   = mrd.address[6:0];
        // data数组大小与length_dw一致
        data         = new[mrd.length_dw];
        // 默认成功
        cpl_status   = 3'b000;
    endfunction

    function string convert2string();
        string s;
        s = $sformatf(
            "[CplD] tag=%0d status=%3b byte_count=%0d delay=%0d split=%0b",
            tag, cpl_status, byte_count,
            delay_cycles, split_cpl);
        return s;
    endfunction

endclass