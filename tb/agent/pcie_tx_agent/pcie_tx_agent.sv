// 连接pcie_tx_monitor,捕获MRD发给pcie_rx_agent和scoreboard
class pcie_tx_agent extends uvm_agent;
    `uvm_component_utils(pcie_tx_agent)

    pcie_tx_monitor mon;
    uvm_analysis_port #(pcie_tlp_item) ap_tlp;
    uvm_analysis_port #(pcie_tlp_item) ap_mrd;  // 向外发送mrd去解析，所以还是发送端，是port而不是export


    function new(string name = "pcie_tx_agent", uvm_component parent);
        super.new(name,parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mon = pcie_tx_monitor::type_id::create("mon",this);
        ap_tlp = new("ap_tlp",this);
        ap_mrd = new("ap_mrd",this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        mon.ap_tlp.connect(ap_tlp);
        mon.ap_mrd.connect(ap_mrd);
    endfunction
endclass