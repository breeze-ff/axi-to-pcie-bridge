// ════════════════════════════════════════════════════
// 并发读写sequence（运行在virtual sequencer上）
// ════════════════════════════════════════════════════
class wr_rd_concurrent_seq extends virtual_base_seq;
    `uvm_object_utils(wr_rd_concurrent_seq)

    function new(string name = "wr_rd_concurrent_seq");
        super.new(name);
    endfunction

    virtual task body();
        wr_burst_mps_split_seq wr_seq;
        rd_multi_id_seq        rd_seq;

        wr_seq = wr_burst_mps_split_seq::type_id::create("wr_seq");
        rd_seq = rd_multi_id_seq::type_id::create("rd_seq");

        `uvm_info(get_type_name(), "[VSEQ] WR_RD_CONCURRENT start", UVM_LOW)

        // ── 读写完全并发 ──────────────────────────────
        // fork让写和读同时启动
        fork
            wr_seq.start(p_sequencer.axi_seqr);
            rd_seq.start(p_sequencer.axi_seqr);
        join

        `uvm_info(get_type_name(), "[VSEQ] WR_RD_CONCURRENT done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// 乱序CplD并发sequence
// 写的同时，读的CplD故意延迟，测试ROB乱序重组
// ════════════════════════════════════════════════════
class ooo_cpld_concurrent_seq extends virtual_base_seq;
    `uvm_object_utils(ooo_cpld_concurrent_seq)

    function new(string name = "ooo_cpld_concurrent_seq");
        super.new(name);
    endfunction

    virtual task body();
        rd_ooo_cpld_seq rd_seq;
        rd_seq = rd_ooo_cpld_seq::type_id::create("rd_seq");

        `uvm_info(get_type_name(), "[VSEQ] OOO_CPLD_CONCURRENT start", UVM_LOW)

        // 发读请求（产生3个MRd Tag0/1/2）
        // Reactive机制会自动回注CplD
        // cpld_seq_item的delay_cycles是随机的
        // 可能出现Tag1的CplD先回来，Tag0慢
        // ROB必须等Tag0回来才能按顺序输出
        rd_seq.start(p_sequencer.axi_seqr);

        `uvm_info(get_type_name(), "[VSEQ] OOO_CPLD_CONCURRENT done", UVM_LOW)
    endtask
endclass

// ════════════════════════════════════════════════════
// 随机读写混合sequence
// ════════════════════════════════════════════════════
class random_mix_seq extends virtual_base_seq;
    `uvm_object_utils(random_mix_seq)

    int unsigned num_wr;
    int unsigned num_rd;

    function new(string name = "random_mix_seq");
        super.new(name);
        num_wr = 10;
        num_rd = 10;
    endfunction

    virtual task body();
        wr_random_seq wr_seq;
        rd_random_seq rd_seq;

        wr_seq = wr_random_seq::type_id::create("wr_seq");
        rd_seq = rd_random_seq::type_id::create("rd_seq");
        wr_seq.num_trans = num_wr;
        rd_seq.num_trans = num_rd;

        `uvm_info(get_type_name(), $sformatf("[VSEQ] RANDOM_MIX start wr=%0d rd=%0d", num_wr, num_rd), UVM_LOW)

        fork
            wr_seq.start(p_sequencer.axi_seqr);
            rd_seq.start(p_sequencer.axi_seqr);
        join

        `uvm_info(get_type_name(), "[VSEQ] RANDOM_MIX done", UVM_LOW)
    endtask
endclass