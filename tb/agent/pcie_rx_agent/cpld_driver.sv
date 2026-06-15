// cpld_driver.sv
// 职责：
//   接收cpld_sequencer发来的cpld_seq_item
//   按PCIe CplD TLP格式驱动s_axis接口注入DUT

class cpld_driver extends uvm_driver #(cpld_seq_item);
    `uvm_component_utils(cpld_driver)

    virtual pcie_rx_if vif;

    function new(string name = "cpld_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db #(virtual pcie_rx_if)::get(this, "", "pcie_rx_vif", vif))
            `uvm_fatal("NOVIF",{"virtual interface must be set: ", get_full_name()})
    endfunction

    virtual task run_phase(uvm_phase phase);
        // 复位期间拉低所有输出
        vif.driver_cb.tvalid <= 0;
        vif.driver_cb.tdata  <= 0;
        vif.driver_cb.tkeep  <= 0;
        vif.driver_cb.tlast  <= 0;

        wait(vif.rst_n === 1'b1);
        @(vif.driver_cb);

        forever begin
            seq_item_port.get_next_item(req);
            drive_cpld(req);
            seq_item_port.item_done();
        end
    endtask

    // ════════════════════════════════════════════════
    // 驱动一个CplD TLP到s_axis接口
    // CplD固定3DW Header + Payload
    // Header独占第一个transfer（128bit）
    // Payload按transfer顺序发送
    // ════════════════════════════════════════════════
    task drive_cpld(cpld_seq_item tr);
        logic [127:0] hdr;
        int           payload_dw;
        int           payload_xfer; // Payload需要几个transfer

        @(vif.driver_cb);

        // ── 等tready ──────────────────────────────────
        while(!vif.driver_cb.tready)
            @(vif.driver_cb);

        // ── 计算Payload DW数 ──────────────────────────
        payload_dw   = tr.data.size();
        payload_xfer = (payload_dw + 3) / 4; // 每transfer 4DW

        // ── 拼装CplD Header（3DW）────────────────────
        // DW0：Fmt=3'b100（3DW有数据），Type=5'b01010
        hdr[31:29] = 3'b100;           // Fmt: 3DW有数据
        hdr[28:24] = 5'b01010;         // Type: Completion
        hdr[23]    = 1'b0;             // T9
        hdr[22:20] = 3'b000;           // TC=0
        hdr[19:15] = 5'b0;             // 保留
        hdr[14]    = 1'b0;             // EP
        hdr[13:12] = 2'b00;            // Attr
        hdr[11:10] = 2'b00;            // AT
        hdr[9:0]   = payload_dw[9:0];  // Length（DW数）

        // DW1：Completer ID / Status / ByteCount
        hdr[63:48] = tr.completer_id;  // Completer ID
        hdr[47:45] = tr.cpl_status;    // Status
        hdr[44]    = 1'b0;             // BCM
        hdr[43:32] = tr.byte_count;    // Byte Count

        // DW2：Requester ID / Tag / LowerAddr
        hdr[31+64:16+64] = tr.requester_id; // hdr[95:80]
        hdr[79:72]       = tr.tag;           // Tag
        hdr[71]          = 1'b0;             // 保留
        hdr[70:64]       = tr.lower_addr;    // Lower Address

        // ── 发送Header transfer ───────────────────────
        @(vif.driver_cb);
        vif.driver_cb.tdata  <= hdr;
        vif.driver_cb.tkeep  <= 16'h0FFF; // 3DW=12字节有效
        vif.driver_cb.tvalid <= 1;
        // 如果没有Payload，Header就是最后一个transfer
        vif.driver_cb.tlast  <= (payload_dw == 0);

        // 等tready确认Header发出
        while(!vif.driver_cb.tready)
            @(vif.driver_cb);

        `uvm_info(get_type_name(), $sformatf("[CPLD DRV] tag=%0d payload=%0d DW sent header", tr.tag, payload_dw), UVM_HIGH)

        // ── 发送Payload transfers ─────────────────────
        for(int x = 0; x < payload_xfer; x++) begin
            logic [127:0] pdata;
            logic [15:0]  pkeep;
            int           dw_base;
            int           remaining;

            dw_base   = x * 4;
            remaining = payload_dw - dw_base;
            pdata     = '0;
            pkeep     = '0;

            // 填入最多4个DW
            for(int d = 0; d < 4 && d < remaining; d++) begin
                pdata[d*32 +: 32] = tr.data[dw_base + d];
                pkeep[d*4  +: 4]  = 4'hF; // 4字节全有效
            end

            @(vif.driver_cb);
            // 等tready
            while(!vif.driver_cb.tready)
                @(vif.driver_cb);
            vif.driver_cb.tdata  <= pdata;
            vif.driver_cb.tkeep  <= pkeep;
            vif.driver_cb.tvalid <= 1;
            vif.driver_cb.tlast  <= (x == payload_xfer - 1);

            
        end

        // ── 发完后拉低valid ───────────────────────────
        @(vif.driver_cb);
        while(!vif.driver_cb.tready)
                @(vif.driver_cb);
        vif.driver_cb.tvalid <= 0;
        vif.driver_cb.tlast  <= 0;

        `uvm_info(get_type_name(), $sformatf("[CPLD DRV] tag=%0d done", tr.tag), UVM_MEDIUM)
    endtask

endclass