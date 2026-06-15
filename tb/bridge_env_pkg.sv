package bridge_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // 指向子文件夹内部的组件图纸
    `include "transcation/axi_seq_item.sv"
    `include "transcation/pcie_tlp_item.sv"
    `include "transcation/cpld_seq_item.sv"
    
    `include "sequence/virtual_sequencer.sv"
    `include "sequence/base_sequence.sv"
    `include "sequence/wr_sequence.sv"
    `include "sequence/rd_sequence.sv"
    `include "sequence/virtual_sequence.sv"

    `include "agent/axi_master_agent/axi_driver.sv"
    `include "agent/axi_master_agent/axi_monitor.sv"
    `include "agent/axi_master_agent/axi_master_agent.sv"

    `include "agent/pcie_tx_agent/pcie_tx_monitor.sv"
    `include "agent/pcie_tx_agent/pcie_tx_agent.sv"

    `include "agent/pcie_rx_agent/cpld_driver.sv"
    `include "agent/pcie_rx_agent/cpld_sequencer.sv"
    `include "agent/pcie_rx_agent/pcie_rx_agent.sv"

    `include "scoreboard.sv"
    `include "bridge_coverage.sv"

    `include "bridge_env.sv"

    `include "test/base_test.sv"
    `include "test/wr_test.sv"
    `include "test/rd_test.sv"
    `include "test/concurrent_test.sv"
    
endpackage