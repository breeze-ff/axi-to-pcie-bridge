// axi_seq_item.sv
class axi_seq_item extends uvm_sequence_item;
    `uvm_object_utils_begin(axi_seq_item)
        `uvm_field_int(id,      UVM_ALL_ON)
        `uvm_field_int(addr,    UVM_ALL_ON)
        `uvm_field_int(len,     UVM_ALL_ON)
        `uvm_field_int(size,    UVM_ALL_ON)
        `uvm_field_int(burst,   UVM_ALL_ON)
        `uvm_field_int(is_write,UVM_ALL_ON)
        `uvm_field_array_int(wdata, UVM_ALL_ON)
        `uvm_field_array_int(wstrb, UVM_ALL_ON)
        `uvm_field_array_int(rdata, UVM_ALL_ON)
        `uvm_field_int(resp,    UVM_ALL_ON)
    `uvm_object_utils_end

    // ── 基本字段 ──────────────────────────────────────
    rand logic [3:0]  id;
    rand logic [63:0] addr;
    rand logic [7:0]  len;       // burst长度-1
    rand logic [2:0]  size;      // 固定3（8字节/beat，64bit AXI）
    rand logic [1:0]  burst;     // 固定01（INCR）
    rand logic        is_write;  // 1=写，0=读

    // ── 写数据（len+1个beat）─────────────────────────
    rand logic [63:0] wdata[];
    rand logic [7:0]  wstrb[];

    // ── 读响应数据（Monitor填入）─────────────────────
    logic [63:0] rdata[];

    // ── 响应状态 ──────────────────────────────────────
    logic [1:0] resp;  // 00=OKAY, 10=SLVERR

    // ════════════════════════════════════════════════
    // 约束
    // ════════════════════════════════════════════════

    // size固定为3（64bit总线，每beat8字节）
    constraint c_size {
        size == 3'b011;
    }

    // burst固定INCR
    constraint c_burst {
        burst == 2'b01;
    }

    // len范围：0~63（最多64拍，512字节，不超过MRRS）
    constraint c_len {
        len inside {[0:63]};
    }

    // 地址DW对齐（低2位为0）
    // 约束地址：必须 8 字节（2 DW / 64-bit）对齐
    constraint c_addr_64bit_align {
        // 直接低 3 位清零
        // addr[2:0] == 3'b000; 
        addr[1:0] == 2'b00;
        // 或者用模运算表达（等价）
        // addr % 8 == 0;
    }

    // 地址范围（64位地址空间的低4GB，便于测试）
    // constraint c_addr_range {
    //     addr[63:32] == 32'h0;
    //     addr[31:0]  inside {[32'h0000_1000 : 32'hFFFF_0000]};
    // }

    // wdata/wstrb数组大小与len一致
    constraint c_data_size {
        wdata.size() == len + 1;
        wstrb.size() == len + 1;
    }

    // wstrb全有效（对齐传输）
    constraint c_wstrb {
        foreach(wstrb[i]) wstrb[i] == 8'hFF;
    }


    function new(string name = "axi_seq_item");
        super.new(name);
    endfunction

    // ── 便捷打印 ──────────────────────────────────────
    function string convert2string();
        string s;
        s = $sformatf(
            "[AXI] %s id=%0d addr=0x%016h len=%0d size=%0d",
            is_write ? "WRITE" : "READ",
            id, addr, len, size);
        return s;
    endfunction

endclass