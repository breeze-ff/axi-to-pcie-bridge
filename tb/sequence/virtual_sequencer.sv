// virtual_sequencer.sv

class virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(virtual_sequencer)

    // ── 持有真实sequencer的引用 ───────────────────────
    // 在env的connect_phase里赋值
    uvm_sequencer #(axi_seq_item)  axi_seqr;
    uvm_sequencer #(cpld_seq_item) cpld_seqr;

    function new(string name = "virtual_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

endclass