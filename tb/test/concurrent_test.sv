// concurrent_test.sv

// ════════════════════════════════════════════════════
// Concurrent Test
// ════════════════════════════════════════════════════
class concurrent_test extends base_test;
    `uvm_component_utils(concurrent_test)

    function new(string name = "concurrent_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_test_body(uvm_phase phase);
        `uvm_info(get_type_name(), "=== CONCURRENT Test Start ===", UVM_LOW)

        // ── 场景1：读写并发 ───────────────────────────
        begin
            wr_rd_concurrent_seq seq;
            seq = wr_rd_concurrent_seq::type_id::create("seq");
            // 在virtual sequencer上启动
            seq.start(env.v_seqr);
            // wait_for_sb_done(.expect_wr(4), .expect_rd(6), .timeout_ns(50000));
        end

        // ── 场景2：乱序CplD ───────────────────────────
        begin
            ooo_cpld_concurrent_seq seq;
            seq = ooo_cpld_concurrent_seq::type_id::create("seq");
            seq.start(env.v_seqr);
            // wait_for_sb_done(.expect_wr(0), .expect_rd(3), .timeout_ns(50000));
        end

        // ── 场景3：随机混合压力 ───────────────────────
        begin
            random_mix_seq seq;
            seq = random_mix_seq::type_id::create("seq");
            seq.num_wr = 40;
            seq.num_rd = 50;
            seq.start(env.v_seqr);
            // wait_for_sb_done(.expect_wr(20), .expect_rd(20), .timeout_ns(200000));
        end
        wait_for_sb_done(.expect_wr(44), .expect_rd(59), .timeout_ns(200000));
        `uvm_info(get_type_name(),"=== CONCURRENT Test Done ===", UVM_LOW)
    endtask
endclass