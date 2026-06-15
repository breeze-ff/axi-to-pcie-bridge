// 1. 监听 m_axis 接口，捕获DUT发出的TLP
// 2. 按transfer重组完整TLP（Header + Payload）
// 3. 解析TLP字段，填入pcie_tlp_item
// 4. 通过两个analysis port分别发给：
//    - scoreboard（比对MWr内容）
//    - cpld_sequencer（触发CplD回注，Reactive机制）
// pcie_tx_monitor.sv

class pcie_tx_monitor extends uvm_monitor;
    `uvm_component_utils(pcie_tx_monitor)

    virtual pcie_tx_if vif;

    // ── 两个analysis port ─────────────────────────────
    // 发给scoreboard（MWr/MRd都发）
    uvm_analysis_port #(pcie_tlp_item) ap_tlp;
    // 发给cpld_sequencer（只发MRd，触发CplD回注）
    uvm_analysis_port #(pcie_tlp_item) ap_mrd;

    function new(string name = "pcie_tx_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap_tlp = new("ap_tlp", this);
        ap_mrd = new("ap_mrd", this);
        if(!uvm_config_db #(virtual pcie_tx_if)::get(this, "", "pcie_tx_vif", vif))
            `uvm_fatal("NOVIF",{"virtual interface must be set: ", get_full_name()})
    endfunction

    virtual task run_phase(uvm_phase phase);
        wait(vif.rst_n === 1'b1);
        @(vif.monitor_cb);

        forever begin
            capture_tlp();
        end
    endtask

    // ════════════════════════════════════════════════
    // 捕获一个完整TLP
    // 每次调用捕获从tvalid&&tready&&第一拍
    // 到tlast的完整TLP
    // ════════════════════════════════════════════════
    string msg;
    task capture_tlp();
        // 原始TLP缓冲（最多Header4DW + Payload32DW = 36DW）
        // 每个transfer = 128bit = 4DW
        logic [127:0] raw_transfers[$];
        logic [15:0]  raw_keeps[$];
        pcie_tlp_item tlp;


        // ── 收集所有transfer直到tlast ─────────────────
        forever begin
            @(vif.monitor_cb);
            // 必须加上 valid 和 ready 的握手判断（除非你100%保证这4拍期间DUT从不拉低valid）
            if (vif.monitor_cb.tvalid && vif.monitor_cb.tready) begin
                raw_transfers.push_back(vif.monitor_cb.tdata);
                raw_keeps.push_back(vif.monitor_cb.tkeep);
                
                // 采完当拍，立刻在同一个时钟沿判断是不是最后一拍
                if (vif.monitor_cb.tlast) begin
                    break; // 是最后一拍，数据已经存了，完美退出
                end
            end
        end

        // `uvm_info(get_type_name(), $sformatf("[MON TX] raw_transfers size is %0d,raw_keeps size is %0d", 
        // raw_transfers.size(), raw_keeps.size()), UVM_MEDIUM)

        

        // 1. 先初始化表头信息
        msg = $sformatf("\n[MON TX] Captured TLP Raw Streams (Size: %0d):\n", raw_transfers.size());
        msg = {msg, "====================================================================================\n"};
        msg = {msg, " Beat  | tkeep   | tdata (128-bit Hex)\n"};
        msg = {msg, "------------------------------------------------------------------------------------\n"};

        // 2. 循环拼接每一拍的数据
        foreach (raw_transfers[i]) begin
            msg = {msg, $sformatf(" [%0d]   | 16'h%4h | 128'h%h\n", i, raw_keeps[i], raw_transfers[i])};
        end
        msg = {msg, "===================================================================================="};

        // 3. 一次性打印输出
        `uvm_info(get_type_name(), msg, UVM_MEDIUM)
        

        // 没有在tlast后再等一拍，继续监听下一个TLP

        // ── 解析TLP ───────────────────────────────────
        tlp = parse_tlp(raw_transfers, raw_keeps);

        if(tlp == null) begin
            `uvm_warning(get_type_name(), "Failed to parse TLP, skipping")
            return;
        end

        `uvm_info(get_type_name(), tlp.convert2string(), UVM_MEDIUM)

        // ── 发给scoreboard ────────────────────────────
        ap_tlp.write(tlp);

        // ── 如果是MRd，额外发给cpld_sequencer ─────────
        if(tlp.tlp_type == TLP_MRD)
            ap_mrd.write(tlp);

    endtask

    // ════════════════════════════════════════════════
    // TLP解析函数
    // 输入：raw transfer数组
    // 输出：填好字段的pcie_tlp_item
    // ════════════════════════════════════════════════
    function pcie_tlp_item parse_tlp(
        input logic [127:0] transfers[$],
        input logic [15:0]  keeps[$]
    );
        pcie_tlp_item tlp;
        logic [127:0] hdr_transfer;
        logic [2:0]   fmt;
        logic [4:0]   tlp_type_raw;
        logic         has_data;
        logic         is_4dw;

        if(transfers.size() == 0) return null;

        tlp          = pcie_tlp_item::type_id::create("tlp");
        hdr_transfer = transfers[0];
        tlp.raw_hdr  = hdr_transfer;

        // ── DW0解析 ───────────────────────────────────
        fmt         = hdr_transfer[31:29];
        tlp_type_raw= hdr_transfer[28:24];
        has_data    = fmt[2];       // Fmt bit2=1表示有Payload
        is_4dw      = fmt[1];       // Fmt bit1=1表示4DW Header

        tlp.fmt       = fmt;
        tlp.length_dw = hdr_transfer[9:0];

        // ── 判断TLP类型 ───────────────────────────────
        case({fmt[2:1], tlp_type_raw})
            // MRd 32bit：Fmt=000, Type=00000
            7'b00_00000: tlp.tlp_type = TLP_MRD;
            // MRd 64bit：Fmt=010, Type=00000
            7'b01_00000: tlp.tlp_type = TLP_MRD;
            // MWr 32bit：Fmt=100, Type=00000 (Fmt=100即bit[2:0]=100)
            // 注意：fmt[2]在DW0[31]，这里用fmt[1:0]
            // MWr 32bit：fmt=3'b100 → fmt[1:0]=2'b00，has_data=1
            // 用完整3bit fmt判断
            default: begin
                // 用完整fmt判断
                case(fmt)
                    3'b100: begin // 3DW有数据
                        if(tlp_type_raw == 5'b00000)
                            tlp.tlp_type = TLP_MWR;
                        else
                            tlp.tlp_type = TLP_UNKNOWN;
                    end
                    3'b110: begin // 4DW有数据
                        if(tlp_type_raw == 5'b00000)
                            tlp.tlp_type = TLP_MWR;
                        else
                            tlp.tlp_type = TLP_UNKNOWN;
                    end
                    3'b000: begin // 3DW无数据
                        if(tlp_type_raw == 5'b00000)
                            tlp.tlp_type = TLP_MRD;
                        else if(tlp_type_raw == 5'b01010)
                            tlp.tlp_type = TLP_CPL;
                        else
                            tlp.tlp_type = TLP_UNKNOWN;
                    end
                    3'b010: begin // 4DW无数据
                        if(tlp_type_raw == 5'b00000)
                            tlp.tlp_type = TLP_MRD;
                        else
                            tlp.tlp_type = TLP_UNKNOWN;
                    end
                    default: tlp.tlp_type = TLP_UNKNOWN;
                endcase
            end
        endcase

        // ── DW1解析（通用字段）────────────────────────
        tlp.requester_id = hdr_transfer[63:48];
        tlp.tag          = hdr_transfer[47:40];
        tlp.last_dw_be   = hdr_transfer[39:36];
        tlp.first_dw_be  = hdr_transfer[35:32];

        // ── DW2/DW3：地址解析 ─────────────────────────
        if(!is_4dw) begin
            // 3DW Header：DW2是32位地址
            tlp.address = {32'b0, hdr_transfer[95:64]};
            // Payload从transfer[1]开始（Header独占transfer[0]）
            parse_payload(tlp, transfers, keeps, 1);
        end else begin
            // 4DW Header：DW2是高32位，DW3是低32位
            // 但我们的transfer是128bit=4DW
            // Header占满整个transfer[0]
            tlp.address = {hdr_transfer[95:64],   // 高32位
                           hdr_transfer[127:96]};  // 低32位
            // 注意低32位地址在DW3，即transfer[0][127:96]
            // 需要处理PH字段（低2位）
            tlp.address[1:0] = 2'b00; // 清掉PH位
            parse_payload(tlp, transfers, keeps, 1);
        end

        return tlp;
    endfunction

    // ════════════════════════════════════════════════
    // Payload解析
    // start_idx：从第几个transfer开始是Payload
    // ════════════════════════════════════════════════
    function void parse_payload(
        pcie_tlp_item   tlp,
        logic [127:0]   transfers[$],
        logic [15:0]    keeps[$],
        int             start_idx
    );
        int dw_idx;
        dw_idx = 0;

        if(tlp.tlp_type != TLP_MWR) begin
            tlp.payload = new[0];
            return;
        end

        // 分配Payload数组（length_dw个DW）
        tlp.payload = new[tlp.length_dw];
        // `uvm_info(get_type_name(), $sformatf("[MON TX] tlp.length_dw is %0d DW", tlp.length_dw), UVM_MEDIUM)

        for(int t = start_idx; t < transfers.size(); t++) begin
            // `uvm_info(get_type_name(), $sformatf("[MON TX] keeps is %0h DW", keeps[t]), UVM_MEDIUM)
            // 每个transfer有4个DW，按keep判断哪些有效
            for(int d = 0; d < 4; d++) begin
                if(dw_idx >= tlp.length_dw) break;
                // keep对应字节：DW d → byte[d*4 +: 4]
                if(keeps[t][d*4]) begin // 简化：只检查每DW首字节
                    tlp.payload[dw_idx] = transfers[t][d*32 +: 32];
                    dw_idx++;
                end
            end
        end

        `uvm_info(get_type_name(), $sformatf("[MON TX] MWr payload %0d DW parsed", dw_idx), UVM_MEDIUM)
    endfunction

endclass