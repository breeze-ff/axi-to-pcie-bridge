// wr_sequence.sv
// ════════════════════════════════════════════════════
// WR_SINGLE_ALIGN：单次对齐写
// ════════════════════════════════════════════════════
class wr_single_align_seq extends axi_base_seq;
    `uvm_object_utils(wr_single_align_seq)

    function new(string name = "wr_single_align_seq");
        super.new(name);
    endfunction

    virtual task body();
        // DW对齐地址，单beat写
        send_write(64'h0000_0000_1000_0000, 8'd0);
    endtask
endclass

// ════════════════════════════════════════════════════
// WR_BURST_NO_SPLIT：小Burst，不触发切割
// 总字节 < MPS且不跨边界
// ════════════════════════════════════════════════════
class wr_burst_no_split_seq extends axi_base_seq;
    `uvm_object_utils(wr_burst_no_split_seq)

    function new(string name = "wr_burst_no_split_seq");
        super.new(name);
    endfunction

    virtual task body();
        // 8拍×8字节=64字节 < MPS=128字节，对齐地址不跨边界
        send_write(64'h0000_0000_1000_0000, 8'd7);
    endtask
endclass

// ════════════════════════════════════════════════════
// WR_BURST_MPS_SPLIT：大Burst，触发MPS切割
// ════════════════════════════════════════════════════
class wr_burst_mps_split_seq extends axi_base_seq;
    `uvm_object_utils(wr_burst_mps_split_seq)

    // 可配置参数
    logic [63:0] start_addr;
    int          burst_len;  // AXI len值

    function new(string name = "wr_burst_mps_split_seq");
        super.new(name);
        // 默认值：非对齐地址，大Burst，触发多次切割
        start_addr = 64'h0000_0000_1000_0040; // 64字节偏移
        burst_len  = 55; // 56拍×8字节=448字节 → 需要4个TLP
    endfunction

    virtual task body();
        `uvm_info(get_type_name(),$sformatf("[SEQ] WR_BURST_MPS_SPLIT start"),UVM_LOW)

        // ── 场景1：对齐地址大Burst ────────────────────
        // addr=0x1000_0000（128B对齐），56拍=448字节
        // 切割：128+128+128+64 = 4个TLP
        `uvm_info(get_type_name(),"[SEQ] Case1: aligned addr, 448B", UVM_LOW)
        send_write(64'h0000_0000_1000_0000, 8'd55);

        // ── 场景2：非对齐地址大Burst ──────────────────
        // addr=0x1000_0040（非128B对齐，在MPS中间）
        // 第一个TLP从0x40到0x80 = 64字节
        // 后续TLP满载128字节
        `uvm_info(get_type_name(),"[SEQ] Case2: unaligned addr, MPS boundary split", UVM_LOW)
        send_write(64'h0000_0000_1000_0040, 8'd55);

        // ── 场景3：刚好在MPS边界 ──────────────────────
        // addr=0x1000_0080（正好在MPS边界）
        // 共256字节 = 2个满载TLP
        `uvm_info(get_type_name(), "[SEQ] Case3: exactly at MPS boundary", UVM_LOW)
        send_write(64'h0000_0000_1000_0080, 8'd31);

        // ── 场景4：跨4KB边界 ──────────────────────────
        // addr=0x1000_0F80（离4KB边界128字节）
        // 第一个TLP到4KB边界：128字节
        // 后续TLP：跨过4KB边界继续
        `uvm_info(get_type_name(),"[SEQ] Case4: cross 4KB boundary", UVM_LOW)
        send_write(64'h0000_0000_1000_0F80, 8'd31);

        `uvm_info(get_type_name(),"[SEQ] WR_BURST_MPS_SPLIT done", UVM_LOW)
    endtask

endclass

// ════════════════════════════════════════════════════
// WR_RANDOM：随机写（用于覆盖率驱动测试）
// ════════════════════════════════════════════════════
class wr_random_seq extends axi_base_seq;
    `uvm_object_utils(wr_random_seq)

    int unsigned num_trans; // 发送事务数量

    function new(string name = "wr_random_seq");
        super.new(name);
        num_trans = 20;
    endfunction

    virtual task body();
        axi_seq_item tr;
        `uvm_info(get_type_name(), $sformatf("[SEQ] WR_RANDOM start, %0d trans", num_trans), UVM_LOW)

        repeat(num_trans) begin
            tr = axi_seq_item::type_id::create("wr_rand_tr");
            start_item(tr);
            assert(tr.randomize() with {
                is_write == 1;
                size     == 3'b011;
                burst    == 2'b01;
                // addr约束：低2位为0（DW偶数对齐）
                addr[1:0] == 2'b00;
            }) else `uvm_fatal(get_type_name(), "randomize failed")
            finish_item(tr);
        end

        `uvm_info(get_type_name(),"[SEQ] WR_RANDOM done", UVM_LOW)
    endtask

endclass