// cpld_sequencer.sv
// 职责：
//   监听pcie_tx_monitor发来的MRd TLP
//   自动构造对应的CplD并发给cpld_driver
//   实现Reactive CplD回注

// ── 辅助：inline sequence，只发一个item ───────────────
class cpld_inline_seq extends uvm_sequence #(cpld_seq_item);
`uvm_object_utils(cpld_inline_seq)

cpld_seq_item cpl;

function new(string name = "cpld_inline_seq");
    super.new(name);
endfunction

virtual task body();
    start_item(cpl);
    // 不再randomize，直接用外部填好的cpl
    finish_item(cpl);
endtask
endclass

class cpld_sequencer extends uvm_component;
    `uvm_component_utils(cpld_sequencer)

    // ── 接收MRd通知 ───────────────────────────────────
    // pcie_tx_monitor的ap_mrd连接到这里
    uvm_analysis_imp #(pcie_tlp_item, cpld_sequencer) ap_mrd;
    // 把生成的cpld发送给scoreboard
    uvm_analysis_port #(cpld_seq_item) ap_cpld;

    // ── 内置sequencer，驱动cpld_driver ────────────────
    uvm_sequencer #(cpld_seq_item) seqr;

    // ── 待发CplD队列（线程安全的mailbox）─────────────
    mailbox #(cpld_seq_item) cpld_mbx;
    // ── 新增：每个pending的CplD一个独立mailbox ────────
    // 每个CplD等完自己的delay后放入ready_mbx
    mailbox #(cpld_seq_item) ready_mbx;  // 等完延迟后准备发送的CplD

    int last_delay = -1;

    // ── cfg接口（获取completer_id）────────────────────
    virtual cfg_if cfg_vif;

    function new(string name = "cpld_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap_mrd   = new("ap_mrd", this);
        ap_cpld   = new("ap_cpld", this);
        seqr     = uvm_sequencer #(cpld_seq_item)::type_id::create("seqr", this);
        cpld_mbx = new(0); // 无界mailbox
        ready_mbx = new(0);

        if(!uvm_config_db #(virtual cfg_if)::get(this, "", "cfg_vif", cfg_vif))
            `uvm_fatal("NOVIF",{"cfg_vif must be set: ", get_full_name()})
    endfunction

    // ── analysis port回调：MRd到来时触发 ─────────────
    // 自动构造CplD，放入mailbox
    virtual function void write(pcie_tlp_item mrd);
        cpld_seq_item cpl;
        cpl = cpld_seq_item::type_id::create("cpl");

        // 从MRd信息推导CplD字段
        cpl.build_from_mrd(mrd);
        cpl.completer_id = cfg_vif.cfg_requester_id;   // 为了方便可以假设PCIE设备和桥的ID相同,也可以自定义

        // 随机化前，先把历史值传给当前 item
        cpl.prev_delay = last_delay;
        // 随机化延迟和数据
        if(!cpl.randomize())
            `uvm_fatal(get_type_name(), "CplD randomize failed")

        last_delay = cpl.delay_cycles; // 更新历史
        // 强制保持tag不变（randomize可能覆盖）
        cpl.tag = mrd.tag;


        cpld_mbx.try_put(cpl);   // write函数中不能用阻塞线程，所以用try_put而不是put

        `uvm_info(get_type_name(),$sformatf("[CPLD SEQ] MRd tag=%0d captured, CplD queued",mrd.tag), UVM_MEDIUM)
    endfunction

    // ════════════════════════════════════════════════
    // run_phase：两个并发线程
    //   线程1：从cpld_mbx取CplD，为每个CplD fork延迟线程
    //   线程2：从ready_mbx取就绪的CplD，串行发给driver
    // ════════════════════════════════════════════════
    virtual task run_phase(uvm_phase phase);
        fork
            delay_dispatcher();  // 线程1：管理延迟
            send_dispatcher();   // 线程2：串行发送
        join
    endtask

    // ── 线程1：为每个CplD独立等待延迟 ───────────────
    // 各CplD的延迟并发倒计时，等完了放入ready_mbx
    task delay_dispatcher();
        forever begin
            cpld_seq_item cpl;
            cpld_mbx.get(cpl);

            // 发送给scoreboard（在延迟前就记录golden）
            ap_cpld.write(cpl);

            // fork ... join_none独立延迟线程，不阻塞主循环, 只管发起，不停留
            fork
                automatic cpld_seq_item cpl_copy = cpl;
                begin
                    // 等待自己的延迟
                    repeat(cpl_copy.delay_cycles)
                        @(posedge cfg_vif.clk);

                    // 延迟结束，放入ready队列
                    ready_mbx.put(cpl_copy);

                    `uvm_info("cpld_sequencer", $sformatf("[CPLD SEQ] tag=%0d delay done, ready to send, delay is %d",
                         cpl_copy.tag, cpl_copy.delay_cycles), UVM_MEDIUM)
                end
            join_none
        end
    endtask

    // ── 线程2：串行从ready_mbx取CplD发给driver ───────
    // driver接口是串行的，这里保证一次只发一个
    // 但发送顺序由各CplD的延迟决定（先delay完的先发）
    task send_dispatcher();
        forever begin
            cpld_seq_item cpl;
            ready_mbx.get(cpl);  // 等第一个delay完的CplD

            `uvm_info("cpld_sequencer",$sformatf("[CPLD SEQ] sending tag=%0d",cpl.tag), UVM_MEDIUM)

            send_cpld(cpl);
        end
    endtask

    // ── 把cpld_seq_item发给seqr（进而到driver）────────
    task send_cpld(cpld_seq_item cpl);
        // 用inline sequence发送
        cpld_inline_seq inline_seq;
        inline_seq = cpld_inline_seq::type_id::create("inline_seq");
        inline_seq.cpl = cpl;
        inline_seq.start(seqr);
    endtask

endclass
