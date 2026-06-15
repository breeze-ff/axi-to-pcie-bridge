// rd_sequences.sv
// ════════════════════════════════════════════════════
// RD_SINGLE_ALIGN：单次对齐读
// ════════════════════════════════════════════════════
class rd_single_align_seq extends axi_base_seq;
    `uvm_object_utils(rd_single_align_seq)

    function new(string name = "rd_single_align_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info(get_type_name(), "[SEQ] RD_SINGLE_ALIGN start", UVM_LOW)
        // DW对齐，单beat读
        send_read(64'h0000_0000_1000_0000, 8'd0);
        `uvm_info(get_type_name(), "[SEQ] RD_SINGLE_ALIGN done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_BURST_NO_SPLIT：小Burst，不触发切割
// ════════════════════════════════════════════════════
class rd_burst_no_split_seq extends axi_base_seq;
    `uvm_object_utils(rd_burst_no_split_seq)

    function new(string name = "rd_burst_no_split_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info(get_type_name(), "[SEQ] RD_BURST_NO_SPLIT start", UVM_LOW)
        // 8拍×8字节=64字节 < MRRS，对齐地址
        // 只产生1个MRd TLP，1个CplD回注
        send_read(64'h0000_0000_1000_0000, 8'd7);
        `uvm_info(get_type_name(), "[SEQ] RD_BURST_NO_SPLIT done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_BURST_MRRS_SPLIT：大Burst，触发MRRS切割
// ════════════════════════════════════════════════════
class rd_burst_mrrs_split_seq extends axi_base_seq;
    `uvm_object_utils(rd_burst_mrrs_split_seq)

    function new(string name = "rd_burst_mrrs_split_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info(get_type_name(),"[SEQ] RD_BURST_MRRS_SPLIT start", UVM_LOW)

        // ── 场景1：对齐地址大Burst，跨MRRS边界 ─────────
        // addr=0x1000_0000，56拍=448字节
        // MRRS=256：切成 256+192 = 2个MRd TLP
        `uvm_info(get_type_name(), "[SEQ] Case1: aligned, 448B cross MRRS", UVM_LOW)
        send_read(64'h0000_0000_1000_0000, 8'd55,0);

        // ── 场景2：非对齐地址，MPS边界+MRRS切割 ────────
        // addr=0x1000_0040（在MPS中间）
        // 第一个MRd：到下一个MPS边界=64字节
        // 后续MRd：按MRRS切
        `uvm_info(get_type_name(), "[SEQ] Case2: unaligned, MPS+MRRS split", UVM_LOW)
        send_read(64'h0000_0000_1000_0040, 8'd55,1);

        // ── 场景3：跨4KB边界 ─────────────────────────
        `uvm_info(get_type_name(), "[SEQ] Case3: cross 4KB boundary", UVM_LOW)
        send_read(64'h0000_0000_1000_2F80, 8'd31,2);

        `uvm_info(get_type_name(), "[SEQ] RD_BURST_MRRS_SPLIT done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_MULTI_OUTSTANDING：多outstanding读
// 连续发多个AR，不等R通道返回
// 验证Tag分配/ROB顺序输出
// ════════════════════════════════════════════════════
class rd_multi_outstanding_seq extends axi_base_seq;
    `uvm_object_utils(rd_multi_outstanding_seq)

    int unsigned num_req; // outstanding数量

    function new(string name = "rd_multi_outstanding_seq");
        super.new(name);
        num_req = 8;
    endfunction

    virtual task body();
        `uvm_info(get_type_name(), $sformatf("[SEQ] RD_MULTI_OUTSTANDING start, %0d reqs", num_req), UVM_LOW)

        // 同一个ARID，连续发多个AR
        // Reactive机制自动回注CplD
        // ROB必须按发出顺序返回R通道数据
        for(int i = 0; i < num_req; i++) begin
            // 每次地址递增，避免地址重叠
            send_read(
                64'h0000_0000_1000_0000 + i * 64,
                8'd7,    // 每次8拍
                4'd0     // 同一个ARID
            );
        end

        `uvm_info(get_type_name(), "[SEQ] RD_MULTI_OUTSTANDING done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_MULTI_ID：不同ARID并发读
// 验证异ID乱序返回（ROB per-ARID队列）
// ════════════════════════════════════════════════════
class rd_multi_id_seq extends axi_base_seq;
    `uvm_object_utils(rd_multi_id_seq)

    function new(string name = "rd_multi_id_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info(get_type_name(), "[SEQ] RD_MULTI_ID start", UVM_LOW)

        // 交替发不同ARID的读请求
        // Reactive CplD回注时可以调整延迟
        // 验证ARID=1可以先于ARID=0返回
        send_read(64'h0000_0000_1000_0000, 8'd7, 4'd2);
        send_read(64'h0000_0000_2000_0000, 8'd7, 4'd1);
        send_read(64'h0000_0000_1000_1040, 8'd7, 4'd0);
        send_read(64'h0000_0000_2000_1040, 8'd7, 4'd2);
        send_read(64'h0000_0000_3000_0000, 8'd7, 4'd1);
        send_read(64'h0000_0000_3000_1040, 8'd7, 4'd0);

        `uvm_info(get_type_name(), "[SEQ] RD_MULTI_ID done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_OOO_CPLD：乱序CplD测试
// 需要配合cpld_ooo_seq使用
// 验证ROB乱序重组能力
// ════════════════════════════════════════════════════
class rd_ooo_cpld_seq extends axi_base_seq;
    `uvm_object_utils(rd_ooo_cpld_seq)

    function new(string name = "rd_ooo_cpld_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info(get_type_name(), "[SEQ] RD_OOO_CPLD start", UVM_LOW)

        // 发3个读请求，产生3个MRd TLP（Tag0/1/2）
        // cpld_sequencer的Reactive机制会自动回注
        // 在concurrent_test里通过调整cpld延迟实现乱序
        send_read(64'h0000_0000_1000_0000, 8'd7, 4'd0);
        send_read(64'h0000_0000_1000_0040, 8'd7, 4'd0);
        send_read(64'h0000_0000_1000_0080, 8'd7, 4'd0);

        `uvm_info(get_type_name(), "[SEQ] RD_OOO_CPLD done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_ERROR_CPLD：错误CplD测试
// 注入status=CA的CplD，验证错误上报
// ════════════════════════════════════════════════════
class rd_error_cpld_seq extends axi_base_seq;
    `uvm_object_utils(rd_error_cpld_seq)

    function new(string name = "rd_error_cpld_seq");
        super.new(name);
    endfunction

    virtual task body();
        `uvm_info(get_type_name(), "[SEQ] RD_ERROR_CPLD start", UVM_LOW)
        // 发一笔读，Reactive机制回注错误CplD
        // 需要在test里配置cpld_sequencer产生错误响应
        send_read(64'h0000_0000_1000_0000, 8'd7, 4'd0);
        `uvm_info(get_type_name(), "[SEQ] RD_ERROR_CPLD done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_RANDOM：随机读
// ════════════════════════════════════════════════════
class rd_random_seq extends axi_base_seq;
    `uvm_object_utils(rd_random_seq)

    int unsigned num_trans;

    function new(string name = "rd_random_seq");
        super.new(name);
        num_trans = 20;
    endfunction

    virtual task body();
        axi_seq_item tr;
        `uvm_info(get_type_name(), $sformatf("[SEQ] RD_RANDOM start, %0d trans", num_trans), UVM_LOW)

        repeat(num_trans) begin
            tr = axi_seq_item::type_id::create("rd_rand_tr");
            start_item(tr);
            assert(tr.randomize() with {
                is_write  == 0;
                size      == 3'b011;
                burst     == 2'b01;
                addr[1:0] == 2'b00;
            }) else `uvm_fatal(get_type_name(),"randomize failed")
            finish_item(tr);
        end

        `uvm_info(get_type_name(),"[SEQ] RD_RANDOM done", UVM_LOW)
    endtask
endclass