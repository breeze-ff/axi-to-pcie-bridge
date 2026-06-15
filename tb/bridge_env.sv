class bridge_env extends uvm_env;
    
    `uvm_component_utils(bridge_env)

    axi_master_agent axi_agt;    
    pcie_rx_agent rx_agt;   // 接收mrd  发cpld给scoreboard
    pcie_tx_agent tx_agt;   // 发送mrd
    scoreboard scb;
    bridge_coverage cov;
    virtual_sequencer v_seqr;  // 同时启动读写

    function new(string name = "bridge_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        axi_agt = axi_master_agent::type_id::create("axi_agt", this);
        rx_agt = pcie_rx_agent::type_id::create("rx_agt",this);
        tx_agt = pcie_tx_agent::type_id::create("tx_agt",this);
        scb = scoreboard::type_id::create("scb",this);
        cov = bridge_coverage::type_id::create("cov",this);
        v_seqr = virtual_sequencer::type_id::create("v_seqr",this);

    endfunction

    virtual function void connect_phase(uvm_phase phase);

        `uvm_info(get_type_name(), "connect_phase started.", UVM_LOW)

        // 跨组件连接桥梁 (Topology Connections)
        // 规则：永远是左边的 port ──> 连右边的 export 或 imp

        // 连接 1：把 TX Agent 抓到的 MRD 读请求，送进 RX Agent 的外壳，用来推导 CplD
        tx_agt.ap_mrd.connect(rx_agt.ap_mrd);
        // 连接scoreboard
        axi_agt.ap.connect(scb.ap_axi);  // (AW+W)或者(AR+R)
        tx_agt.ap_tlp.connect(scb.ap_tlp);
        rx_agt.ap_cpld.connect(scb.ap_cpld);
        axi_agt.ap_ar.connect(scb.ap_ar); // AR
        // 连接coverage
        axi_agt.ap.connect(cov.ap_axi);
        tx_agt.ap_tlp.connect(cov.ap_tlp);
        rx_agt.ap_cpld.connect(cov.ap_cpld);
        // 匹配虚拟接口
        v_seqr.axi_seqr  = axi_agt.sequencer;
        v_seqr.cpld_seqr = rx_agt.cpl_seqr.seqr;

    endfunction

endclass