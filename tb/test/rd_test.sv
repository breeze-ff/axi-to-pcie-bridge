// rd_tests.sv
// ════════════════════════════════════════════════════
// RD_SINGLE_ALIGN Test
// ════════════════════════════════════════════════════
class rd_single_align_test extends base_test;
    `uvm_component_utils(rd_single_align_test)

    function new(string name = "rd_single_align_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        rd_single_align_seq seq;
        seq = rd_single_align_seq::type_id::create("seq");

        `uvm_info(get_type_name(), "=== RD_SINGLE_ALIGN Test Start ===", UVM_LOW)
        seq.start(env.axi_agt.sequencer);
        // 发了1笔读，等1笔读比对完
        wait_for_sb_done(.expect_rd(1), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== RD_SINGLE_ALIGN Test Done ===", UVM_LOW)
    endtask
endclass

class rd_burst_no_split_test extends base_test;
    `uvm_component_utils(rd_burst_no_split_test)

    function new(string name = "rd_burst_no_split_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        rd_burst_no_split_seq seq;
        seq = rd_burst_no_split_seq::type_id::create("seq");

        `uvm_info(get_type_name(), "=== RD_BURST_NO_SPLIT Test Start ===", UVM_LOW)
        seq.start(env.axi_agt.sequencer);
        // 发了1笔读，等1笔读比对完
        wait_for_sb_done(.expect_rd(1), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== RD_BURST_NO_SPLIT Test Done ===", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_BURST_MRRS_SPLIT Test
// ════════════════════════════════════════════════════
class rd_burst_mrrs_split_test extends base_test;
    `uvm_component_utils(rd_burst_mrrs_split_test)

    function new(string name = "rd_burst_mrrs_split_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        rd_burst_mrrs_split_seq seq;
        seq = rd_burst_mrrs_split_seq::type_id::create("seq");

        `uvm_info(get_type_name(), "=== RD_BURST_MRRS_SPLIT Test Start ===", UVM_LOW)
        seq.start(env.axi_agt.sequencer);
        // 3个场景各1笔读
        wait_for_sb_done(.expect_rd(3), .timeout_ns(100000));
        `uvm_info(get_type_name(), "=== RD_BURST_MRRS_SPLIT Test Done ===", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_MULTI_OUTSTANDING Test
// ════════════════════════════════════════════════════
class rd_multi_outstanding_test extends base_test;
    `uvm_component_utils(rd_multi_outstanding_test)

    function new(string name = "rd_multi_outstanding_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        rd_multi_outstanding_seq seq;
        seq = rd_multi_outstanding_seq::type_id::create("seq");
        seq.num_req = 8;

        `uvm_info(get_type_name(), "=== RD_MULTI_OUTSTANDING Test Start ===", UVM_LOW)
        seq.start(env.axi_agt.sequencer);
        wait_for_sb_done(.expect_rd(8), .timeout_ns(200000));
        `uvm_info(get_type_name(), "=== RD_MULTI_OUTSTANDING Test Done ===", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// RD_MULTI_ID Test
// ════════════════════════════════════════════════════
class rd_multi_id_test extends base_test;
    `uvm_component_utils(rd_multi_id_test)

    function new(string name = "rd_multi_id_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        rd_multi_id_seq seq;
        seq = rd_multi_id_seq::type_id::create("seq");

        `uvm_info(get_type_name(), "=== RD_MULTI_ID Test Start ===", UVM_LOW)
        seq.start(env.axi_agt.sequencer);
        // 发了6笔读，等6笔读比对完
        wait_for_sb_done(.expect_rd(6), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== RD_MULTI_ID Test Done ===", UVM_LOW)
    endtask
endclass

class rd_random_test extends base_test;
    `uvm_component_utils(rd_random_test)

    function new(string name = "rd_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        rd_random_seq seq;
        seq = rd_random_seq::type_id::create("seq");
        seq.num_trans = 60;

        `uvm_info(get_type_name(),"=== rd_random_seq Test Start ===", UVM_LOW)

        // 在AXI Master sequencer上启动
        seq.start(env.axi_agt.sequencer);
        wait_for_sb_done(.expect_rd(seq.num_trans), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== rd_random_seq Test Sequence Done ===", UVM_LOW)
    endtask

endclass
