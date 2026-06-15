// axi_driver.sv

class axi_driver extends uvm_driver #(axi_seq_item);
    `uvm_component_utils(axi_driver)

    virtual axi_if vif;
    // 引入两个内部队列，用于读写事务解耦分流
    axi_seq_item write_queue[$];
    axi_seq_item read_queue[$];

    function new(string name = "axi_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if(!uvm_config_db #(virtual axi_if)::get(this, "", "axi_vif", vif))
            `uvm_fatal("NOVIF",{"virtual interface must be set: ", get_full_name()})
    endfunction

    virtual task run_phase(uvm_phase phase);
        // 复位期间把所有输出拉低
        init_signals();
        
        wait(vif.rst_n === 1'b1);
        @(vif.driver_cb);  

        fork
            fetch_items();    // 进程 1：只管从 sequencer 抓取并分流
            write_handler();  // 进程 2：专职处理写通道
            read_handler();   // 进程 3：专职处理读通道
            b_handler();      // 处理B通道
            r_handler();      // 处理R通道

        join
    endtask

    // ── 复位时初始化所有驱动信号 ──────────────────────
    task init_signals();
        vif.driver_cb.awvalid <= 0;
        vif.driver_cb.awid    <= 0;
        vif.driver_cb.awaddr  <= 0;
        vif.driver_cb.awlen   <= 0;
        vif.driver_cb.awsize  <= 0;
        vif.driver_cb.awburst <= 0;
        vif.driver_cb.wvalid  <= 0;
        vif.driver_cb.wdata   <= 0;
        vif.driver_cb.wstrb   <= 0;
        vif.driver_cb.wlast   <= 0;
        vif.driver_cb.bready  <= 0;
        vif.driver_cb.arvalid <= 0;
        vif.driver_cb.arid    <= 0;
        vif.driver_cb.araddr  <= 0;
        vif.driver_cb.arlen   <= 0;
        vif.driver_cb.arsize  <= 0;
        vif.driver_cb.arburst <= 0;
        vif.driver_cb.rready  <= 0;
    endtask

    // ── 进程 1：抓取与分流 ─────────────────────────────────
    task fetch_items();
        forever begin
            seq_item_port.get_next_item(req);
            
            // 根据读写属性，克隆一份丢进对应的管道
            if(req.is_write) begin
                write_queue.push_back(req);
            end else begin
                read_queue.push_back(req);
            end
            
            seq_item_port.item_done(); 
        end
    endtask

    // ── 进程 2：独立的写驱动服务 ───────────────────────────
    task write_handler();
        forever begin
            // 当队列里有写请求时才工作
            wait(write_queue.size() > 0);
            begin
                axi_seq_item tr = write_queue.pop_front();
                drive_write(tr); 
            end
        end
    endtask

    // ── 进程 3：独立的读驱动服务 ───────────────────────────
    task read_handler();
        forever begin
            // 当队列里有读请求时才工作
            wait(read_queue.size() > 0);
            begin
                axi_seq_item tr = read_queue.pop_front();
                drive_read(tr); 
            end
        end
    endtask

    // ──  B 通道接收（只打印，不记账） ─────────────────
    task b_handler();
        vif.driver_cb.bready <= 1; // 驱动输出：这是合法的
        
        forever begin
            @(vif.driver_cb); 
            // 删掉对 bready 的采样，只判断 input 信号 bvalid
            // 因为 bready 已经是 1 了，bvalid 只要为 1 就代表握手成功
            if(vif.driver_cb.bvalid) begin
                `uvm_info(get_type_name(), $sformatf("[DRV_B] 收到写响应 -> BID=%0d, BRESP=0x%0h", 
                            vif.driver_cb.bid, vif.driver_cb.bresp), UVM_MEDIUM)
            end
        end
    endtask

    // ──  R 通道接收（只打印，不记账） ─────────────────
    task r_handler();
        bit [3:0] local_rid;
        int       beat_cnt = 0; 
        
        vif.driver_cb.rready <= 1; // 驱动输出：这是合法的
        
        forever begin
            @(vif.driver_cb); 
            // 删掉对 rready 的采样，只判断 input 信号 rvalid
            if(vif.driver_cb.rvalid) begin
                local_rid = vif.driver_cb.rid;
                beat_cnt++;
                
                if(vif.driver_cb.rlast) begin
                    `uvm_info(get_type_name(), $sformatf("[DRV_R] 读传输完成 -> RID=%0d, 共 %0d 个Beat, 最后一拍 RRESP=0x%0h", 
                                local_rid, beat_cnt, vif.driver_cb.rresp), UVM_MEDIUM)
                    beat_cnt = 0; 
                end
            end
        end
    endtask

    // ════════════════════════════════════════════════
    // 写事务：AW和W并发
    // ════════════════════════════════════════════════
    task drive_write(axi_seq_item tr);
        `uvm_info(get_type_name(), tr.convert2string(), UVM_MEDIUM)

        fork
            // ── AW通道 ────────────────────────────
            begin
                @(vif.driver_cb);

                // 等ready，驱动valid那一拍就开始采样
                while(!vif.driver_cb.awready)
                    @(vif.driver_cb);

                vif.driver_cb.awid    <= tr.id;
                vif.driver_cb.awaddr  <= tr.addr;
                vif.driver_cb.awlen   <= tr.len;
                vif.driver_cb.awsize  <= tr.size;
                vif.driver_cb.awburst <= tr.burst;
                vif.driver_cb.awvalid <= 1;

                

                // 握手完成
                @(vif.driver_cb);
                // 等ready
                while(!vif.driver_cb.awready) begin
                    @(vif.driver_cb);
                end
                vif.driver_cb.awvalid <= 0;
                `uvm_info(get_type_name(), "AW handshake done", UVM_MEDIUM)
            end

            // ── W通道 ─────────────────────────────
            begin

                foreach(tr.wdata[i]) begin
                    @(vif.driver_cb);
                    // 等ready
                    while(!vif.driver_cb.wready) begin
                        @(vif.driver_cb);   
                    end
                    vif.driver_cb.wdata  <= tr.wdata[i];
                    vif.driver_cb.wstrb  <= tr.wstrb[i];
                    vif.driver_cb.wlast  <= (i == tr.len);
                    vif.driver_cb.wvalid <= 1;
                    
                    
                    // ready=1，本beat握手完成
                    // 循环体下一次迭代会@(driver_cb)进入下一拍
                    
                end

                @(vif.driver_cb);
                // 等ready
                while(!vif.driver_cb.wready) begin
                    @(vif.driver_cb);
                end
                vif.driver_cb.wvalid <= 0;
                vif.driver_cb.wlast  <= 0;
                `uvm_info(get_type_name(), "W channel done", UVM_MEDIUM)
            end
        join

    endtask

    // ════════════════════════════════════════════════
    // 读事务：AR握手后等R通道rlast
    // ════════════════════════════════════════════════
    task drive_read(axi_seq_item tr);
        `uvm_info(get_type_name(), tr.convert2string(), UVM_MEDIUM)

        // ── AR通道 ────────────────────────────────
        @(vif.driver_cb);
        while(!vif.driver_cb.arready)
            @(vif.driver_cb);
        vif.driver_cb.arid    <= tr.id;
        vif.driver_cb.araddr  <= tr.addr;
        vif.driver_cb.arlen   <= tr.len;
        vif.driver_cb.arsize  <= tr.size;
        vif.driver_cb.arburst <= tr.burst;
        vif.driver_cb.arvalid <= 1;

        

        @(vif.driver_cb);
        while(!vif.driver_cb.arready)
            @(vif.driver_cb);
        vif.driver_cb.arvalid <= 0;
        `uvm_info(get_type_name(), "AR handshake done", UVM_MEDIUM)

    endtask

endclass