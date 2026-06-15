// pcie_rx_agent.sv

class pcie_rx_agent extends uvm_agent;
    `uvm_component_utils(pcie_rx_agent)

    cpld_driver     drv;
    cpld_sequencer  cpl_seqr;

    // 接收pcie_tx_monitor的MRd通知
    // 透传给cpld_sequencer的ap_mrd,所以不是port，必须定义为export
    uvm_analysis_export #(pcie_tlp_item) ap_mrd;
    // 把生成的cpld发送给scoreboard
    uvm_analysis_port #(cpld_seq_item) ap_cpld;

    function new(string name = "pcie_rx_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv      = cpld_driver::type_id::create("drv", this);
        cpl_seqr = cpld_sequencer::type_id::create("cpl_seqr", this);
        ap_mrd   = new("ap_mrd", this);
        ap_cpld = new("ap_cpld", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        // driver连sequencer
        drv.seq_item_port.connect(cpl_seqr.seqr.seq_item_export);
        // export连接到imp
        ap_mrd.connect(cpl_seqr.ap_mrd);
        // port子组件连接到这个agent的port，暴露出来，方便外联，注意方向
        cpl_seqr.ap_cpld.connect(ap_cpld);
    endfunction

endclass