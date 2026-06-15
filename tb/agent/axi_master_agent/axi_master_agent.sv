class axi_master_agent extends uvm_agent;
    `uvm_component_utils(axi_master_agent)

    axi_driver   drv;
    uvm_sequencer #(axi_seq_item) sequencer;
    axi_monitor  mon;

    // analysis port透传给env层连接scoreboard
    uvm_analysis_port #(axi_seq_item) ap;
    uvm_analysis_port #(axi_seq_item) ap_ar;  // AR立即上报

    function new(string name = "axi_master_agent", uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv    = axi_driver::type_id::create("drv", this);
        sequencer = uvm_sequencer#(axi_seq_item)::type_id::create("sequencer", this);
        mon = axi_monitor::type_id::create("mon",this);
        ap  = new("ap", this);
        ap_ar = new("ap_ar", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sequencer.seq_item_export);
        // monitor的ap透传到agent的ap
        // env层再把agent.ap连到scoreboard
        mon.ap.connect(ap);
        mon.ap_ar.connect(ap_ar);  // ← 新增透传
    endfunction

endclass