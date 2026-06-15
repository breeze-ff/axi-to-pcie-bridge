// base_sequence.sv
// 所有sequence的基类，封装常用操作

class axi_base_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_base_seq)

    function new(string name = "axi_base_seq");
        super.new(name);
    endfunction

    // ── 发送一笔写事务的封装 ──────────────────────────
    task send_write(
        input logic [63:0] addr,
        input logic [7:0]  len,
        input logic [3:0]  id = 0
    );
        axi_seq_item tr;
        tr = axi_seq_item::type_id::create("wr_tr");
        start_item(tr);
        assert(tr.randomize() with {
            is_write  == 1;            // tr 的属性，不加前缀
            addr      == local::addr;  // tr.addr 等于 Task 入参 addr
            len       == local::len;   // tr.len  等于 Task 入参 len
            id        == local::id;    // tr.id   等于 Task 入参 id
            size      == 3'b011;       // tr 的属性，不加前缀
            burst     == 2'b01;        // tr 的属性，不加前缀
        }) else `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(tr);
        `uvm_info(get_type_name(), $sformatf("[SEQ] WR sent addr=0x%016h len=%0d id=%0d", addr, len, id), UVM_MEDIUM)
    endtask

    // ── 发送一笔读事务的封装 ──────────────────────────
    task send_read(
        input logic [63:0] addr,
        input logic [7:0]  len,
        input logic [3:0]  id = 0
    );
        axi_seq_item tr;
        tr = axi_seq_item::type_id::create("rd_tr");
        start_item(tr);
        assert(tr.randomize() with {
            is_write  == 0;            // tr 的属性，不加前缀
            addr      == local::addr;  // tr.addr 等于 Task 入参 addr
            len       == local::len;   // tr.len  等于 Task 入参 len
            id        == local::id;    // tr.id   等于 Task 入参 id
            size      == 3'b011;       // tr 的属性，不加前缀
            burst     == 2'b01;        // tr 的属性，不加前缀
        }) else `uvm_fatal(get_type_name(), "randomize failed")
        finish_item(tr);
        `uvm_info(get_type_name(), $sformatf("[SEQ] RD sent addr=0x%016h len=%0d id=%0d", addr, len, id), UVM_MEDIUM)
    endtask

endclass

// ── Virtual Sequence基类 ──────────────────────────────
// 第三层测试用，持有virtual_sequencer引用
class virtual_base_seq extends uvm_sequence;
    `uvm_object_utils(virtual_base_seq)

    // 通过p_sequencer访问各子sequencer
    `uvm_declare_p_sequencer(virtual_sequencer)

    function new(string name = "virtual_base_seq");
        super.new(name);
    endfunction

    // ── 并发启动多个sequence的封装 ────────────────────
    task run_seq_on_axi(uvm_sequence #(axi_seq_item) seq);
        seq.start(p_sequencer.axi_seqr);
    endtask

endclass