class wr_single_align_test extends base_test;
    `uvm_component_utils(wr_single_align_test)

    function new(string name = "wr_single_align_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        wr_single_align_seq seq;
        seq = wr_single_align_seq::type_id::create("seq");

        `uvm_info(get_type_name(),"=== WR_SINGLE_ALIGN Test Start ===", UVM_LOW)

        // 在AXI Master sequencer上启动
        seq.start(env.axi_agt.sequencer);
        wait_for_sb_done(.expect_wr(1), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== WR_SINGLE_ALIGN Test Sequence Done ===", UVM_LOW)
endtask

endclass

class wr_burst_no_split_test extends base_test;
    `uvm_component_utils(wr_burst_no_split_test)

    function new(string name = "wr_burst_no_split_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        wr_burst_no_split_seq seq;
        seq = wr_burst_no_split_seq::type_id::create("seq");

        `uvm_info(get_type_name(),"=== wr_burst_no_split Test Start ===", UVM_LOW)

        // 在AXI Master sequencer上启动
        seq.start(env.axi_agt.sequencer);
        wait_for_sb_done(.expect_wr(1), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== wr_burst_no_split Test Sequence Done ===", UVM_LOW)
endtask

endclass

// ════════════════════════════════════════════════════
// WR_BURST_MPS_SPLIT Test
// ════════════════════════════════════════════════════
class wr_burst_mps_split_test extends base_test;
    `uvm_component_utils(wr_burst_mps_split_test)

    function new(string name = "wr_burst_mps_split_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        wr_burst_mps_split_seq seq;
        seq = wr_burst_mps_split_seq::type_id::create("seq");

        `uvm_info(get_type_name(),"=== WR_BURST_MPS_SPLIT Test Start ===", UVM_LOW)

        // 在AXI Master sequencer上启动
        seq.start(env.axi_agt.sequencer);
        // （4个场景）
        wait_for_sb_done(.expect_wr(4), .timeout_ns(100000));
        `uvm_info(get_type_name(), "=== WR_BURST_MPS_SPLIT Test Sequence Done ===", UVM_LOW)
    endtask

endclass

class wr_random_test extends base_test;
    `uvm_component_utils(wr_random_test)

    function new(string name = "wr_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        wr_random_seq seq;
        seq = wr_random_seq::type_id::create("seq");
        seq.num_trans = 50;   // 不能太多，怕超过credit上限

        `uvm_info(get_type_name(),"=== wr_random_seq Test Start ===", UVM_LOW)

        // 在AXI Master sequencer上启动
        seq.start(env.axi_agt.sequencer);
        wait_for_sb_done(.expect_wr(seq.num_trans), .timeout_ns(50000));
        `uvm_info(get_type_name(), "=== wr_random_seq Test Sequence Done ===", UVM_LOW)
    endtask

endclass