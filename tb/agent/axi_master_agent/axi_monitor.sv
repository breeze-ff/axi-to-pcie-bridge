// axi_monitor.sv 修正版：AW和W并发监听，队列汇合

class axi_monitor extends uvm_monitor;
    `uvm_component_utils(axi_monitor)

    virtual axi_if vif;
    uvm_analysis_port #(axi_seq_item) ap;
    uvm_analysis_port #(axi_seq_item) ap_ar;   // 新增，AR握手后立即发出

    // ── AW和W独立缓存队列 ─────────────────────────────
    // AW队列：每项是一个只含地址信息的seq_item
    axi_seq_item aw_queue[$];
    // W队列：每项是一个只含数据的seq_item（wdata/wstrb已填好）
    axi_seq_item w_queue[$];

    function new(string name = "axi_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        ap_ar = new("ap_ar", this);
        if(!uvm_config_db #(virtual axi_if)::get(this, "", "axi_vif", vif))
            `uvm_fatal("NOVIF", {"virtual interface must be set: ", get_full_name()})
    endfunction

    virtual task run_phase(uvm_phase phase);
        wait(vif.rst_n === 1'b1);
        @(vif.monitor_cb);

        fork
            monitor_aw();    // 独立监听AW通道
            monitor_w();     // 独立监听W通道
            merge_write();   // 汇合AW+W，发ap
            monitor_ar();    // 独立监听AR通道
            monitor_r();     // 独立监听R通道
        join
    endtask

    // ════════════════════════════════════════════════
    // 监听AW通道，握手成功入aw_queue
    // ════════════════════════════════════════════════
    task monitor_aw();
        forever begin
            axi_seq_item tr;

            // 等AW握手
            do begin
                @(vif.monitor_cb);
            end while(!(vif.monitor_cb.awvalid && vif.monitor_cb.awready));

            tr = axi_seq_item::type_id::create("tr_aw");
            tr.is_write = 1;
            tr.id       = vif.monitor_cb.awid;
            tr.addr     = vif.monitor_cb.awaddr;
            tr.len      = vif.monitor_cb.awlen;
            tr.size     = vif.monitor_cb.awsize;
            tr.burst    = vif.monitor_cb.awburst;

            aw_queue.push_back(tr);

            `uvm_info(get_type_name(), $sformatf("[MON AW] id=%0d addr=0x%016h len=%0d", tr.id, tr.addr, tr.len), UVM_MEDIUM)
        end
    endtask

    // ════════════════════════════════════════════════
    // 监听W通道，收集完一个Burst的所有beat入w_queue
    // W通道没有ID，靠wlast判断Burst结束
    // ════════════════════════════════════════════════
    task monitor_w();
        forever begin
            axi_seq_item tr;
            int beat_cnt;

            // 等第一个W握手来临，确定这个Burst开始
            do begin
                @(vif.monitor_cb);
            end while(!(vif.monitor_cb.wvalid && vif.monitor_cb.wready));

            // 先创建tr，但len还不知道（W通道不带len）
            // 用动态数组边收边push
            tr = axi_seq_item::type_id::create("tr_w");
            tr.is_write = 1;
            tr.wdata    = new[0];
            tr.wstrb    = new[0];
            beat_cnt    = 0;

            // 收集当前这一拍（已确认握手）
            begin
                int new_size;
                new_size     = beat_cnt + 1;
                tr.wdata     = new[new_size](tr.wdata);
                tr.wstrb     = new[new_size](tr.wstrb);
                tr.wdata[beat_cnt] = vif.monitor_cb.wdata;
                tr.wstrb[beat_cnt] = vif.monitor_cb.wstrb;
                beat_cnt++;
            end

            // 如果这一拍就是wlast，Burst只有1拍
            if(!vif.monitor_cb.wlast) begin
                // 继续收后续beat直到wlast
                do begin
                    @(vif.monitor_cb);
                    if(vif.monitor_cb.wvalid &&
                       vif.monitor_cb.wready) begin
                        int new_size;
                        new_size           = beat_cnt + 1;
                        tr.wdata           = new[new_size](tr.wdata);
                        tr.wstrb           = new[new_size](tr.wstrb);
                        tr.wdata[beat_cnt] = vif.monitor_cb.wdata;
                        tr.wstrb[beat_cnt] = vif.monitor_cb.wstrb;
                        beat_cnt++;
                    end
                end while(!(vif.monitor_cb.wvalid  && vif.monitor_cb.wready && vif.monitor_cb.wlast));
            end

            w_queue.push_back(tr);

            `uvm_info(get_type_name(), $sformatf("[MON W] %0d beats captured", beat_cnt), UVM_MEDIUM)
        end
    endtask

    // ════════════════════════════════════════════════
    // 汇合线程：从aw_queue和w_queue各取一项拼成完整事务
    // 再等B通道握手，最后发ap
    // ════════════════════════════════════════════════
    task merge_write();
        forever begin
            axi_seq_item aw_tr, w_tr, full_tr;

            // 等两个队列都有数据
            wait(aw_queue.size() > 0 && w_queue.size() > 0);

            aw_tr = aw_queue.pop_front();
            w_tr  = w_queue.pop_front();

            // 拼成完整事务
            full_tr          = axi_seq_item::type_id::create("tr_full");
            full_tr.is_write = 1;
            full_tr.id       = aw_tr.id;
            full_tr.addr     = aw_tr.addr;
            full_tr.len      = aw_tr.len;
            full_tr.size     = aw_tr.size;
            full_tr.burst    = aw_tr.burst;
            full_tr.wdata    = w_tr.wdata;
            full_tr.wstrb    = w_tr.wstrb;

            // 等B通道握手
            do begin
                @(vif.monitor_cb);
            end while(!(vif.monitor_cb.bvalid && vif.monitor_cb.bready));

            full_tr.resp = vif.monitor_cb.bresp;

            `uvm_info(get_type_name(), $sformatf("[MON WR DONE] id=%0d addr=0x%016h resp=0x%0h", full_tr.id, full_tr.addr, full_tr.resp), UVM_MEDIUM)

            ap.write(full_tr);
        end
    endtask

    // ════════════════════════════════════════════════
    // 读事务监听：AR 和 R 通道独立监控 + 汇合
    // ════════════════════════════════════════════════
    // 键是 int (ID)，值是队列 (Queue)
    // 每一个 ID 拥有一个独立的先进先出队列，用来记录该 ID 所有的 outstanding 请求
    axi_seq_item ar_cache[int][$];  

    // ── monitor_ar：独立捕获 AR，发 ap_ar ──────────
    task monitor_ar();
        forever begin
            axi_seq_item tr;

            // 等 AR 握手
            do begin
                @(vif.monitor_cb);
            end while(!(vif.monitor_cb.arvalid && vif.monitor_cb.arready));

            tr = axi_seq_item::type_id::create("tr_rd");
            tr.is_write = 0;
            tr.id       = vif.monitor_cb.arid;
            tr.addr     = vif.monitor_cb.araddr;
            tr.len      = vif.monitor_cb.arlen;
            tr.size     = vif.monitor_cb.arsize;
            tr.burst    = vif.monitor_cb.arburst;

            // 直接推入对应 ID 队列的尾部 (push_back)
            ar_cache[tr.id].push_back(tr);

            ap_ar.write(tr);
            `uvm_info(get_type_name(), $sformatf("[MON AR] id=%0d addr=0x%016h len=%0d", tr.id, tr.addr, tr.len), UVM_MEDIUM)
        end
    endtask

    // ── monitor_r：独立捕获 R 通道，发 ap ──────────
    task monitor_r();
        forever begin
            axi_seq_item tr;
            logic [63:0] tmp_q[$];
            int          current_rid;
            bit          ar_found;

            // 等 R 握手来临
            do begin
                @(vif.monitor_cb);
            end while(!(vif.monitor_cb.rvalid && vif.monitor_cb.rready));

            current_rid = vif.monitor_cb.rid;
            ar_found    = 0;

            // 用 rid 去捕获对应的 AR 历史队列
            if (ar_cache.exists(current_rid) && ar_cache[current_rid].size() > 0) begin
                // AXI 相同 ID 保序原则：队列最前端 [0] 的那笔 AR 一定是当前 R 数据的对应请求
                tr = ar_cache[current_rid][0]; 
                ar_found = 1;
            end else begin
                // 没找到 AR，创建一个只含基础信息的 tr
                tr = axi_seq_item::type_id::create("tr_rd");
                tr.is_write = 0;
                tr.id       = current_rid;
                tr.addr     = 64'h0;  // AR 已错过，无法获取
                tr.len      = 0;
                tr.size     = 0;
                tr.burst    = 0;
                `uvm_warning(get_type_name(), $sformatf("[MON R] Cannot find matching AR in ar_cache for RID=%0d", current_rid))
            end

            tmp_q.delete();

            // 收集当前拍（已确认握手）
            tmp_q.push_back(vif.monitor_cb.rdata);
            tr.resp = vif.monitor_cb.rresp;

            // 如果不是最后一拍，继续收后续 beat
            if (!(vif.monitor_cb.rlast)) begin
                do begin
                    @(vif.monitor_cb);
                    if (vif.monitor_cb.rvalid && vif.monitor_cb.rready) begin
                        tmp_q.push_back(vif.monitor_cb.rdata);
                        tr.resp = vif.monitor_cb.rresp;
                    end
                end while(!(vif.monitor_cb.rvalid && vif.monitor_cb.rready && vif.monitor_cb.rlast));
            end

            // 将收集完整的 R 通道数据打包进 tr
            tr.rdata = tmp_q;

            `uvm_info(get_type_name(), $sformatf("[MON RD DONE] id=%0d addr=0x%016h resp=0x%0h data_beats=%0d", tr.id, tr.addr, tr.resp, tmp_q.size()), UVM_MEDIUM)
            ap.write(tr);

            // 在整笔读事务（RLAST 成功握手）结束后，清理缓存
            if (ar_found) begin
                // 弹出该 ID 队列最前面的那一笔 AR,加上void表示不需要返回值，防止警告
                void'(ar_cache[current_rid].pop_front());
            end
        end
    endtask

    // 旧方法已移除，由 monitor_ar + monitor_r 替代

endclass