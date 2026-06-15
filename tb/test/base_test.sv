class base_test extends uvm_test;
    `uvm_component_utils(base_test)

    bridge_env env;
    virtual cfg_if cfg_vif;     // cfg接口
    event test_done;            // 仿真完成标志

    function new(string name = "base_test", uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = bridge_env::type_id::create("env", this);
        if(!uvm_config_db #(virtual cfg_if)::get(this, "", "cfg_vif", cfg_vif))
            `uvm_fatal("NOVIF",{"cfg_vif must be set: ", get_full_name()})
    endfunction

    // 环境初始化：所有test公用
    // 在run_phase最开始调用
    virtual task init_dut();
        // ── 等复位完成 ────────────────────────────────
        wait(cfg_vif.rst_n === 1'b1);
        repeat(5) @(posedge cfg_vif.clk);

        // ── 配置基本参数 ──────────────────────────────
        cfg_vif.init_cfg(
            16'h1000,   // requester_id
            10'd256     // mrrs_bytes
        );

        // ── 注入Credit（给足，不测Credit限制时）────────
        // PH：Posted Header Credit
        repeat(3) begin
            cfg_vif.inject_credit(2'b00, 12'hfff);
        end
        // PD：Posted Data Credit
        cfg_vif.inject_credit(2'b01, 12'hfff);
        // NPH：Non-Posted Header Credit
        repeat(3) begin
            cfg_vif.inject_credit(2'b10, 12'hfff);
        end

        `uvm_info(get_type_name(), "[TEST] DUT init done, credit injected", UVM_LOW)
    endtask

    // 等待scoreboard比对完成
    virtual task wait_for_sb_done(
        int unsigned expect_wr = 0,
        int unsigned expect_rd = 0,
        int          timeout_ns = 50000
    );
        fork
            begin
                
                // ── 等Driver队列清空 ──────────────────────
                wait(env.axi_agt.drv.write_queue.size() == 0 && env.axi_agt.drv.read_queue.size()  == 0);

                // ── 等Monitor队列清空 ─────────────────────
                wait(env.axi_agt.mon.aw_queue.size() == 0 && env.axi_agt.mon.w_queue.size()  == 0);
                // ── 等scoreboard完成指定数量的比对 ────────
                // 写事务：等expect_wr笔写全部比对完
                if(expect_wr > 0) begin
                    wait(env.scb.wr_pass_cnt + env.scb.wr_fail_cnt >= expect_wr);
                    `uvm_info(get_type_name(), $sformatf("[TEST] %0d WR done", expect_wr), UVM_LOW)
                end

                // 读事务：等expect_rd笔读全部比对完
                if(expect_rd > 0) begin
                    wait(env.scb.rd_pass_cnt + env.scb.rd_fail_cnt >= expect_rd);
                    `uvm_info(get_type_name(),$sformatf("[TEST] %0d RD done", expect_rd), UVM_LOW)
                end

                // 如果没有指定数量，退化为等队列清空
                // 尽量指定，防止提前退出仿真
                if(expect_wr == 0 && expect_rd == 0) begin
                    wait(env.scb.wr_axi_queue.size()  == 0 && env.scb.mwr_tlp_queue.size() == 0 &&
                        env.scb.rd_queue_by_arid.size()  == 0 && env.scb.cpld_golden.size()   == 0);
                end

                `uvm_info(get_type_name(),"[TEST] All transactions done", UVM_LOW)
            end

            begin
                #(timeout_ns * 1ns);
                `uvm_error(get_type_name(), $sformatf("[TEST] Timeout after %0dns", timeout_ns))
            end
        join_any
        disable fork;
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        // 所有test共用的初始化
        init_dut();

        // 子类实现具体测试内容
        run_test_body(phase);

        // 等scoreboard比对完成,test里面写

        // 额外等几拍确保所有输出稳定
        repeat(20) @(posedge cfg_vif.clk);

        phase.drop_objection(this);
    endtask

    // ── 子类重写此函数实现具体测试 ────────────────────
    virtual task run_test_body(uvm_phase phase);
        // 基类为空，子类实现
    endtask

endclass