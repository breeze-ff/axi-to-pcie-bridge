// scoreboard.sv
// 职责：
//   写路径：比对AXI写事务 和 PCIe TX侧捕获的MWr TLP
//   读路径：比对注入的CplD数据 和 AXI R通道返回的数据

// ── analysis imp：接收各路数据 ────────────────────
    // 来自axi_monitor（写事务和读事务）
`uvm_analysis_imp_decl(_axi)
`uvm_analysis_imp_decl(_tlp)
`uvm_analysis_imp_decl(_cpld)
`uvm_analysis_imp_decl(_ar)

class scoreboard extends uvm_scoreboard;
    `uvm_component_utils(scoreboard)

    uvm_analysis_imp_axi  #(axi_seq_item,   scoreboard) ap_axi;
    uvm_analysis_imp_tlp  #(pcie_tlp_item,  scoreboard) ap_tlp;
    uvm_analysis_imp_cpld #(cpld_seq_item,  scoreboard) ap_cpld;
    uvm_analysis_imp_ar #(axi_seq_item, scoreboard) ap_ar;

    // ── 内部队列 ──────────────────────────────────────
    
    axi_seq_item  wr_axi_queue[$];      // 写路径：缓存AXI写事务等待TLP到来比对
    pcie_tlp_item mwr_tlp_queue[$];     // 写路径：缓存捕获的MWr TLP
    cpld_seq_item cpld_golden[int];     // 读路径：缓存注入的CplD数据（golden）key = tag，value = cpld_seq_item
    // axi_seq_item  rd_axi_queue[$];      // 读路径：缓存AXI读响应事务

    // ── 读路径：per-ARID事务队列 ─────────────────────
    // key=arid，value=该ARID的AXI读事务队列（按AR顺序）
    axi_seq_item  rd_queue_by_arid[int][$];


    // ── 每个AXI事务对应的Tag列表 ─────────────────────
    // key = arid_axi_addr拼接的字符串，唯一标识一笔AXI事务
    int  axi_event_tags[string][$];  // 这笔事务包含的Tag列表
    int  axi_event_need[string];     // 这笔事务需要几个Tag


    // ── 统计计数 ──────────────────────────────────────
    int wr_pass_cnt;
    int wr_fail_cnt;
    int rd_pass_cnt;
    int rd_fail_cnt;

    function new(string name = "scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap_axi  = new("ap_axi",  this);
        ap_tlp  = new("ap_tlp",  this);
        ap_cpld = new("ap_cpld", this);
        ap_ar = new("ap_ar", this);
        wr_pass_cnt = 0;
        wr_fail_cnt = 0;
        rd_pass_cnt = 0;
        rd_fail_cnt = 0;
    endfunction

    // run_phase：启动后台比对任务
    // ════════════════════════════════════════════════════
    virtual task run_phase(uvm_phase phase);
        fork
            run_write_checker();
            run_read_checker();
        join_none
    endtask

    // ════════════════════════════════════════════════
    // 接收AXI事务（写事务和读响应）
    // ════════════════════════════════════════════════
    virtual function void write_axi(axi_seq_item tr);
        if(tr.is_write) begin
            // 写事务：放入写队列，等TLP到来比对
            wr_axi_queue.push_back(tr);
            `uvm_info(get_type_name(), $sformatf("[SB] AXI WR queued id=%0d addr=0x%016h len=%0d", tr.id, tr.addr, tr.len), UVM_MEDIUM)
        end else begin
            // 读事务R通道完成：更新rd_queue_by_arid里对应事务的rdata
            // 找到对应的队列项，更新rdata
            update_rd_rdata(tr);
        end
    endfunction

    // ════════════════════════════════════════════════
    // 接收PCIe TX侧捕获的TLP
    // ════════════════════════════════════════════════
    virtual function void write_tlp(pcie_tlp_item tlp);
        if(tlp.tlp_type == TLP_MWR) begin
            mwr_tlp_queue.push_back(tlp);
            `uvm_info(get_type_name(), $sformatf("[SB] MWr TLP queued addr=0x%016h len=%0d", tlp.address, tlp.length_dw), UVM_MEDIUM)
        end else if(tlp.tlp_type == TLP_MRD) begin
            // 找到这个MRd属于哪个AXI事务
            // 方法：遍历rd_queue_by_arid，找包含该地址的事务
            find_and_register_tag(tlp);
        end
    endfunction

    // ════════════════════════════════════════════════
    // 接收注入的CplD（golden数据）
    // ════════════════════════════════════════════════
    virtual function void write_cpld(cpld_seq_item cpl);
        // 用tag作为key存入golden表
        cpld_golden[cpl.tag] = cpl;
        `uvm_info(get_type_name(), $sformatf("[SB] CplD golden stored tag=%0d", cpl.tag), UVM_MEDIUM)
    endfunction

    // 新增write_ar函数：AR握手时立即建立rd_queue_by_arid
    virtual function void write_ar(axi_seq_item tr);
        string key;
        key = $sformatf("%0d_%016h", tr.id, tr.addr);

        // AR握手时立即入队，不等R通道
        rd_queue_by_arid[tr.id].push_back(tr);

        // 初始化这笔事务的Tag列表
        axi_event_tags[key] = {};
        axi_event_need[key] = calc_expected_tlp_num(tr.addr, (tr.len+1)*8,256);  // MRRS

        `uvm_info(get_type_name(),
            $sformatf("[SB] AR registered arid=%0d addr=0x%016h need_mrd=%0d",tr.id, tr.addr, axi_event_need[key]), UVM_MEDIUM)
    endfunction

    // ── 找到MRd对应的AXI事务，注册Tag ───────────────
    function void find_and_register_tag(pcie_tlp_item mrd);
        // 遍历所有ARID的队列
        foreach(rd_queue_by_arid[arid]) begin
            foreach(rd_queue_by_arid[arid][i]) begin
                axi_seq_item tr;
                logic [63:0] axi_start, axi_end;
                string       key;

                tr        = rd_queue_by_arid[arid][i];
                axi_start = tr.addr;
                axi_end   = tr.addr + (tr.len+1)*8 - 1;
                key       = $sformatf("%0d_%016h", tr.id, tr.addr);

                // 如果这笔 AXI 事务的 Tag 已经收够了，说明属于它的 MRd 完结了，直接看下一笔
                if(axi_event_tags[key].size() >= axi_event_need[key]) begin
                    continue;
                end

                // MRd地址落在这个AXI事务范围内
                if(mrd.address >= axi_start && mrd.address <= axi_end) begin
                    // 注册Tag到这个事务
                    axi_event_tags[key].push_back(mrd.tag);

                    `uvm_info(get_type_name(), $sformatf("[SB] MRd tag=%0d → arid=%0d axi_addr=0x%016h", mrd.tag, tr.id, tr.addr),UVM_MEDIUM)
                    return;
                end
            end
        end

        `uvm_warning(get_type_name(),$sformatf("[SB] MRd addr=0x%016h tag=%0d , no matching AXI event, rd_queue_by_arid size is %0d", 
        mrd.address, mrd.tag, rd_queue_by_arid.size()))
    endfunction

    // 更新已有队列项的rdata（R通道完成时调用）
    function void update_rd_rdata(axi_seq_item tr);
        if(!rd_queue_by_arid.exists(tr.id)) begin
            `uvm_warning(get_type_name(),$sformatf("[SB] RD rdata update: arid=%0d not found",tr.id))
            return;
        end

        // 找到addr匹配的队列项，更新rdata
        foreach(rd_queue_by_arid[tr.id][i]) begin
            if(rd_queue_by_arid[tr.id][i].addr == tr.addr) begin
                rd_queue_by_arid[tr.id][i].rdata = tr.rdata;
                rd_queue_by_arid[tr.id][i].resp  = tr.resp;
                `uvm_info(get_type_name(),$sformatf("[SB] RD rdata updated arid=%0d addr=0x%016h",tr.id, tr.addr), UVM_MEDIUM)
                return;
            end
        end

        `uvm_warning(get_type_name(),$sformatf("[SB] RD rdata update: addr=0x%016h not found in arid=%0d queue", tr.addr, tr.id))
    endfunction

    // ════════════════════════════════════════════════
    // 写路径比对
    // 一个AXI写事务可能对应多个MWr TLP（Burst切割）
    // 比对策略：
    //   按顺序从wr_axi_queue取一个事务
    //   计算期望的TLP序列
    //   从mwr_tlp_queue取对应数量的TLP逐一比对
    // ════════════════════════════════════════════════
    // ── 写路径后台比对 ────────────────────────────────
    task run_write_checker();
        forever begin
            // 等两个队列都有数据
            wait(wr_axi_queue.size() > 0 && mwr_tlp_queue.size() > 0);

            begin
                axi_seq_item  axi_tr;
                int           expect_tlp_num;
                int           mps = 128;

                axi_tr         = wr_axi_queue[0];
                expect_tlp_num = calc_expected_tlp_num(axi_tr.addr, (axi_tr.len + 1) * 8, mps);

                // 等TLP全部到齐
                wait(mwr_tlp_queue.size() >= expect_tlp_num);

                axi_tr = wr_axi_queue.pop_front();

                begin
                    pcie_tlp_item tlp_list[$];
                    for(int i = 0; i < expect_tlp_num; i++)
                        tlp_list.push_back(mwr_tlp_queue.pop_front());
                    check_write(axi_tr, tlp_list);
                end
            end
        end
    endtask

    // ── 写路径详细比对 ────────────────────────────────
    function void check_write(
        axi_seq_item  axi_tr,
        pcie_tlp_item tlp_list[$]
    );
        logic [63:0] cur_addr;
        int          remain_bytes;
        int          mps = 128;
        bit          pass = 1;

        cur_addr      = axi_tr.addr;
        remain_bytes  = (axi_tr.len + 1) * 8;

        `uvm_info(get_type_name(), $sformatf("[SB WR] checking id=%0d addr=0x%016h tlp_num=%0d",
            axi_tr.id, axi_tr.addr, tlp_list.size()), UVM_MEDIUM)

        foreach(tlp_list[i]) begin
            pcie_tlp_item tlp;
            int           expect_bytes;
            int           mps_offset;
            int           bytes_to_mps;
            int           bytes_to_4k;
            tlp = tlp_list[i];

            // ── 比对地址 ──────────────────────────────
            if(tlp.address !== cur_addr) begin
                `uvm_error(get_type_name(), $sformatf("[SB WR FAIL] TLP[%0d] addr mismatch:  exp=0x%016h got=0x%016h",i, cur_addr, tlp.address))
                pass = 0;
            end

            // ── 计算本TLP期望字节数（四重约束）─────────
            mps_offset   = cur_addr & (mps - 1);
            bytes_to_mps = (mps_offset == 0) ? mps : mps - mps_offset;
            bytes_to_4k  = 'h1000 - (cur_addr & 'hFFF);

            expect_bytes = bytes_to_mps;
            if(bytes_to_4k  < expect_bytes) expect_bytes = bytes_to_4k;
            if(mps          < expect_bytes) expect_bytes = mps;
            if(remain_bytes < expect_bytes) expect_bytes = remain_bytes;

            // ── 比对Length ────────────────────────────
            begin
                int expect_dw;
                expect_dw = (expect_bytes + 3) / 4;
                // 非对齐时要加上首DW偏移
                expect_dw = (cur_addr[1:0] != 0) ? expect_dw + 1 : expect_dw;

                if(tlp.length_dw != expect_dw) begin
                    `uvm_error(get_type_name(), $sformatf("[SB WR FAIL] TLP[%0d] length mismatch:  exp=%0d got=%0d DW",
                        i, expect_dw, tlp.length_dw))
                    pass = 0;
                end
            end

            // ── 比对Payload数据（全局字节流匹配）───────────
            begin
                // 1. 建立一个临时字节队列，把当前 AXI 事务的所有有效 payload 拍平
                // (这一步也可以挪到 function 顶端做一次)
                byte total_axi_bytes[$];
                int  tlp_dw_counter = 0;
                
                foreach(axi_tr.wdata[b]) begin
                    for(int i=0; i<8; i++) begin
                        total_axi_bytes.push_back(axi_tr.wdata[b][i*8 +: 8]);
                    end
                end

                // 2. 核心逻辑：计算当前 TLP 在整体 AXI 传输中的起始字节偏移量
                // 彻底解决因为地址对齐切片导致的“不连续空间错位”
                begin
                    int global_byte_offset;
                    global_byte_offset = cur_addr - axi_tr.addr;

                    for(int b = 0; b < expect_bytes; b++) begin
                        int current_global_byte_idx = global_byte_offset + b;
                        int current_tlp_dw_idx      = b / 4;
                        int current_tlp_byte_in_dw  = b % 4;
                        
                        logic [7:0] exp_byte;
                        logic [7:0] got_byte;

                        // 抓取期望的 AXI 连续字节
                        exp_byte = total_axi_bytes[current_global_byte_idx];

                        // 抓取 TLP 收到的对应字节 (从 32-bit DW 中提取)
                        if(current_tlp_dw_idx < tlp.payload.size()) begin
                            got_byte = tlp.payload[current_tlp_dw_idx][current_tlp_byte_in_dw*8 +: 8];
                            
                            // 逐字节精准比对
                            if(got_byte !== exp_byte) begin
                                `uvm_error(get_type_name(), $sformatf(
                                    "[SB WR FAIL] TLP[%0d] Payload Byte Mismatch! Global Address=0x%016h\n       Expected (AXI Global Byte[%0d]): 0x%02h\n       Got      (TLP Payload DW[%0d] Byte[%0d]): 0x%02h",
                                    i, cur_addr + b, current_global_byte_idx, exp_byte, current_tlp_dw_idx, current_tlp_byte_in_dw, got_byte
                                ))
                                pass = 0;
                                break; // 错一个就别打印了，直接跳出省得刷屏
                            end
                        end else begin
                            `uvm_error(get_type_name(), $sformatf("[SB WR FAIL] TLP[%0d] payload size too small! expect_bytes=%0d, tlp.payload.size()=%0d DW", 
                                i, expect_bytes, tlp.payload.size()))
                            pass = 0;
                            break;
                        end
                    end
                end
            end

            // 更新地址和剩余字节
            cur_addr     += expect_bytes;
            remain_bytes -= expect_bytes;
        end

        if(pass) begin
            wr_pass_cnt++;
            `uvm_info(get_type_name(), $sformatf("[SB WR PASS] id=%0d addr=0x%016h (%0d total)",
                axi_tr.id, axi_tr.addr, wr_pass_cnt), UVM_LOW)
        end else begin
            wr_fail_cnt++;
        end
    endfunction

    // ════════════════════════════════════════════════
    // 读路径比对
    // 比对AXI R通道数据 和 注入的CplD golden数据
    // per-ARID独立检查，互不影响
    // ════════════════════════════════════════════════
    task run_read_checker();
        forever begin
            // 扫描所有ARID，找到有完整数据的事务
            #1ns; // 让出时间片，避免死循环占满仿真

            foreach(rd_queue_by_arid[arid]) begin
                // `uvm_info(get_type_name(),$sformatf("[SB] rd_queue_by_arid test %d",arid), UVM_MEDIUM)
                if(rd_queue_by_arid[arid].size() > 0) begin
                    // `uvm_info(get_type_name(),$sformatf("[SB] come in check_arid_queue"), UVM_MEDIUM)
                    check_arid_queue(arid);
                end
            end
        end
    endtask

    // ── 检查某个ARID的队头事务是否可以比对 ───────────
    task check_arid_queue(int arid);
        axi_seq_item tr;
        string       key;

        if(rd_queue_by_arid[arid].size() == 0) begin
            // `uvm_info(get_type_name(),$sformatf("[SB] rd_queue_by_arid size is 0"), UVM_MEDIUM)
            return;
        end
        tr  = rd_queue_by_arid[arid][0];
        key = $sformatf("%0d_%016h", tr.id, tr.addr);

        // 判断条件：
        // 1. 这笔事务的所有Tag都已经在tag_meta里注册了
        // 2. 所有Tag的CplD都已经在cpld_golden里
        if(!axi_event_need.exists(key)) begin
            // `uvm_info(get_type_name(),$sformatf("[SB] axi_event_need this key %0d_%016h value is null",tr.id, tr.addr), UVM_MEDIUM)
            return;
        end

        begin
            int tags[$];
            int need;
            bit all_cpl_ready;

            if(!axi_event_tags.exists(key)) begin
                // `uvm_info(get_type_name(),$sformatf("[SB] axi_event_tags this key %0d_%016h value is null",tr.id, tr.addr), UVM_MEDIUM)
                return;
            end
            tags = axi_event_tags[key];
            need = axi_event_need[key];

            // Tag还没全部注册（MRd还没全发出）
            if(tags.size() < need) begin
                // `uvm_info(get_type_name(),$sformatf("[SB] Tag hadn't register"), UVM_MEDIUM)
                return;
            end
            // 检查所有Tag的CplD是否都到了
            all_cpl_ready = 1;
            foreach(tags[i]) begin
                if(!cpld_golden.exists(tags[i])) begin
                    all_cpl_ready = 0;
                    break;
                end
            end
            if(!all_cpl_ready) begin
                // `uvm_info(get_type_name(),$sformatf("[SB] CplD with Tag has not arrived yet"), UVM_MEDIUM)
                return;
            end

            // ← 新增：检查rdata是否已经填充（R通道是否完成）
            if(tr.rdata.size() == 0) begin
                // `uvm_info(get_type_name(),$sformatf("[SB] arid=%0d addr=0x%016h waiting for R channel", arid, tr.addr), UVM_MEDIUM)
                return;
            end

            // 所有数据就绪，开始比对
            rd_queue_by_arid[arid].pop_front();
            axi_event_tags.delete(key);
            axi_event_need.delete(key);

            check_read(tr, tags);
        end
    endtask

    // ── 读路径详细比对 ────────────────────────────────
    // 读路径详细比对
    // tags：这笔事务的Tag列表（按发出顺序）
    // ════════════════════════════════════════════════
    function void check_read(axi_seq_item rd_tr, int tags[$]);
        bit          pass = 1;
        logic [7:0]  golden_bytes[$];
        logic [7:0]  actual_bytes[$];
        int          valid_byte_total;

        `uvm_info(get_type_name(),$sformatf("[SB RD] checking arid=%0d addr=0x%016h len=%0d tags=%0d",
            rd_tr.id, rd_tr.addr, rd_tr.len, tags.size()),UVM_MEDIUM)


        // ── 按Tag顺序收集golden字节 ───────────────────
        foreach(tags[i]) begin
            cpld_seq_item cpl;
            int           tag;
            tag = tags[i];

            if(!cpld_golden.exists(tag)) begin
                `uvm_error(get_type_name(),$sformatf("[SB RD FAIL] golden missing tag=%0d",tag))
                pass = 0;
                continue;
            end

            cpl = cpld_golden[tag];
            foreach(cpl.data[d]) begin
                golden_bytes.push_back(cpl.data[d][7:0]);
                golden_bytes.push_back(cpl.data[d][15:8]);
                golden_bytes.push_back(cpl.data[d][23:16]);
                golden_bytes.push_back(cpl.data[d][31:24]);
            end
            cpld_golden.delete(tag);
        end

        // ── 从rdata提取非X字节 ────────────────────────
        foreach(rd_tr.rdata[i]) begin
            for(int b = 0; b < 8; b++) begin
                logic [7:0] cur_byte;
                cur_byte = rd_tr.rdata[i][b*8 +: 8];
                if(!$isunknown(cur_byte))
                    actual_bytes.push_back(cur_byte);
            end
        end

        // ── 字节数检查 ────────────────────────────────
        valid_byte_total = (rd_tr.len + 1) * (1 << rd_tr.size);

        // golden截断到有效字节数
        while(golden_bytes.size() > valid_byte_total)
            golden_bytes.pop_back();

        `uvm_info(get_type_name(),
            $sformatf("[SB RD] golden=%0d actual=%0d expected=%0d", golden_bytes.size(), actual_bytes.size(),valid_byte_total), UVM_MEDIUM)

        if(actual_bytes.size() != valid_byte_total) begin
            `uvm_error(get_type_name(),$sformatf("[SB RD FAIL] actual size mismatch: exp=%0d got=%0d", valid_byte_total, actual_bytes.size()))
            pass = 0;
        end

        if(golden_bytes.size() != valid_byte_total) begin
            `uvm_error(get_type_name(), $sformatf("[SB RD FAIL] golden size mismatch: exp=%0d got=%0d", valid_byte_total, golden_bytes.size()))
            pass = 0;
        end

        // ── 逐字节比对 ────────────────────────────────
        if(pass) begin
            foreach(golden_bytes[i]) begin
                if(i >= actual_bytes.size()) break;
                if(actual_bytes[i] !== golden_bytes[i]) begin
                    `uvm_error(get_type_name(),
                        $sformatf("[SB RD FAIL] byte[%0d]: exp=0x%02h got=0x%02h", i, golden_bytes[i], actual_bytes[i]))
                    pass = 0;
                end
            end
        end

        // ── resp检查 ──────────────────────────────────
        if(rd_tr.resp !== 2'b00) begin
            `uvm_error(get_type_name(), $sformatf("[SB RD FAIL] bad resp=0x%0h", rd_tr.resp))
            pass = 0;
        end

        if(pass) begin
            rd_pass_cnt++;
            `uvm_info(get_type_name(), $sformatf("[SB RD PASS] arid=%0d addr=0x%016h (%0d total)", rd_tr.id, rd_tr.addr, rd_pass_cnt), UVM_LOW)
        end else begin
            rd_fail_cnt++;
        end
    endfunction

    // 辅助函数
    // function int calc_expected_mrd_num(
    //     input logic [63:0] addr,
    //     input int          total_bytes,
    //     input int          mrrs = 256,
    //     input int          mps  = 128
    // );
    //     int cnt, remain;
    //     logic [63:0] cur;
    //     cnt    = 0;
    //     remain = total_bytes;
    //     cur    = addr;

    //     while(remain > 0) begin
    //         int mps_off, to_mps, to_4k, this_bytes;
    //         mps_off    = cur & (mps-1);
    //         to_mps     = (mps_off==0) ? mps : mps-mps_off;
    //         to_4k      = 'h1000 - (cur & 'hFFF);
    //         this_bytes = to_mps;
    //         if(to_4k   < this_bytes) this_bytes = to_4k;
    //         if(mrrs    < this_bytes) this_bytes = mrrs;
    //         if(remain  < this_bytes) this_bytes = remain;
    //         cur    += this_bytes;
    //         remain -= this_bytes;
    //         cnt++;
    //     end
    //     return cnt;
    // endfunction

    // ════════════════════════════════════════════════
    // 计算AXI事务产生的TLP数量
    // ════════════════════════════════════════════════
    function int calc_expected_tlp_num(
        input logic [63:0] addr,
        input int          total_bytes,
        input int          mps
    );
        int  cnt;
        int  remain;
        logic [63:0] cur;

        cnt    = 0;
        remain = total_bytes;
        cur    = addr;

        while(remain > 0) begin
            int mps_offset, bytes_to_mps;
            int bytes_to_4k, this_bytes;

            mps_offset   = cur & (mps - 1);
            bytes_to_mps = (mps_offset == 0) ? mps : mps - mps_offset;
            bytes_to_4k  = 'h1000 - (cur & 'hFFF);

            this_bytes   = bytes_to_mps;
            if(bytes_to_4k  < this_bytes) this_bytes = bytes_to_4k;
            if(mps          < this_bytes) this_bytes = mps;
            if(remain       < this_bytes) this_bytes = remain;

            cur    += this_bytes;
            remain -= this_bytes;
            cnt++;
        end

        return cnt;
    endfunction

    // ════════════════════════════════════════════════
    // report_phase：打印最终统计
    // ════════════════════════════════════════════════
    virtual function void report_phase(uvm_phase phase);
        `uvm_info(get_type_name(),
        $sformatf({"\n========== Scoreboard Report ==========\n",
                "Write: PASS=%0d  FAIL=%0d\n",
                "Read:  PASS=%0d  FAIL=%0d\n",
                "======================================="},
        wr_pass_cnt, wr_fail_cnt,
        rd_pass_cnt, rd_fail_cnt), UVM_LOW)

        if(wr_fail_cnt > 0 || rd_fail_cnt > 0)
            `uvm_error(get_type_name(), "Scoreboard: FAILED transactions detected")
        else
            `uvm_info(get_type_name(), "Scoreboard: ALL PASS", UVM_LOW)
    endfunction

endclass