// coverage.sv

// 已经在scoreboard里面注册过了，同名称不用再次定义
// `uvm_analysis_imp_decl(_axi)
// `uvm_analysis_imp_decl(_tlp)
// `uvm_analysis_imp_decl(_cpld)

class bridge_coverage extends uvm_component;
    `uvm_component_utils(bridge_coverage)

    // ── analysis imp ──────────────────────────────────
    uvm_analysis_imp_axi  #(axi_seq_item,  bridge_coverage) ap_axi;
    uvm_analysis_imp_tlp  #(pcie_tlp_item, bridge_coverage) ap_tlp;
    uvm_analysis_imp_cpld #(cpld_seq_item, bridge_coverage) ap_cpld;

    // ── 采样变量 ──────────────────────────────────────
    axi_seq_item  axi_tr;
    pcie_tlp_item tlp_tr;
    cpld_seq_item cpld_tr;

    // ── 统计变量（用于跨covergroup分析）──────────────
    int unsigned outstanding_rd_cnt; // 当前outstanding读数量
    int unsigned max_outstanding_seen;

    // ════════════════════════════════════════════════
    // AXI写事务覆盖组
    // ════════════════════════════════════════════════
    covergroup axi_wr_cg;
        // 地址低2位对齐情况
        cp_addr_align: coverpoint axi_tr.addr[1:0] {
            bins dw_aligned   = {2'b00};
            // bins byte1_offset = {2'b01};
            // bins byte2_offset = {2'b10};
            // bins byte3_offset = {2'b11};
        }

        // Burst长度
        cp_wr_len: coverpoint axi_tr.len {
            bins single        = {0};
            bins short_2_7     = {[1:7]};
            bins medium_8_15   = {[8:15]};
            bins medium_16_31  = {[16:31]};
            bins long_32_63    = {[32:63]};
        }

        // 地址是否跨4KB边界
        cp_cross_4k: coverpoint
            ((axi_tr.addr[11:0] + (axi_tr.len+1)*8) > 12'hFFF) {
            bins no_cross  = {0};
            bins cross_4k  = {1};
        }

        // 地址是否跨MPS（128B）边界
        cp_cross_mps: coverpoint
            ((axi_tr.addr[6:0] + (axi_tr.len+1)*8) > 7'h7F) {
            bins no_cross  = {0};
            bins cross_mps = {1};
        }

        // AWID分布
        cp_awid: coverpoint axi_tr.id {
            bins id_0      = {0};
            bins id_1_7    = {[1:7]};
            bins id_8_15   = {[8:15]};
        }

        // 地址对齐 × Burst长度
        cx_align_len: cross cp_addr_align, cp_wr_len;

        // 是否跨4KB × 是否跨MPS
        cx_boundary: cross cp_cross_4k, cp_cross_mps;

        // ID × 长度
        cx_id_len: cross cp_awid, cp_wr_len;
    endgroup

    // ════════════════════════════════════════════════
    // AXI读事务覆盖组
    // ════════════════════════════════════════════════
    covergroup axi_rd_cg;
        cp_addr_align: coverpoint axi_tr.addr[1:0] {
            bins dw_aligned   = {2'b00};
            // bins byte1_offset = {2'b01};
            // bins byte2_offset = {2'b10};
            // bins byte3_offset = {2'b11};
        } // 暂时只验证DW对齐，RTL设计非DW对齐只能出现在开头或者末尾，不允许在中间

        cp_rd_len: coverpoint axi_tr.len {
            bins single        = {0};
            bins short_2_7     = {[1:7]};
            bins medium_8_15   = {[8:15]};
            bins medium_16_31  = {[16:31]};
            bins long_32_63    = {[32:63]};
        }

        // 是否跨4KB边界
        cp_cross_4k: coverpoint
            ((axi_tr.addr[11:0] + (axi_tr.len+1)*8) > 12'hFFF) {
            bins no_cross  = {0};
            bins cross_4k  = {1};
        }

        // 是否跨MRRS（512B）边界
        cp_cross_mrrs: coverpoint
            ((axi_tr.addr[8:0] + (axi_tr.len+1)*8) > 9'h1FF) {
            bins no_cross   = {0};
            bins cross_mrrs = {1};
        }

        // ARID分布
        cp_arid: coverpoint axi_tr.id {
            bins id_0      = {0};
            bins id_1_3    = {[1:3]};
            bins id_4_7    = {[4:7]};
            bins id_8_15   = {[8:15]};
        }

        // outstanding读数量
        cp_outstanding: coverpoint outstanding_rd_cnt {
            bins one       = {1};
            bins two_four  = {[2:4]};
            bins five_plus = {[5:32]};
        }

        // 地址对齐 × 长度
        cx_align_len: cross cp_addr_align, cp_rd_len;

        // ID × 长度（验证多ID并发）
        cx_id_len: cross cp_arid, cp_rd_len;

        // 是否跨边界 × 长度
        cx_cross_len: cross cp_cross_4k, cp_rd_len;

        // outstanding × ID
        cx_outstanding_id: cross cp_outstanding, cp_arid;
    endgroup

    // ════════════════════════════════════════════════
    // PCIe MWr TLP覆盖组
    // ════════════════════════════════════════════════
    covergroup mwr_tlp_cg;
        // TLP长度
        cp_len: coverpoint tlp_tr.length_dw {
            bins single_dw   = {1};
            bins small_2_8   = {[2:8]};
            bins medium_9_16 = {[9:16]};
            bins large_17_31 = {[17:31]};
            bins full_mps    = {32};
        }

        // 地址低2位
        cp_addr_align: coverpoint tlp_tr.address[1:0] {
            bins aligned   = {2'b00};
            // bins offset_1  = {2'b01};
            // bins offset_2  = {2'b10};
            // bins offset_3  = {2'b11};
        }

        // first_dw_be
        cp_first_be: coverpoint tlp_tr.first_dw_be {
            bins full          = {4'b1111};
            // bins high_2byte    = {4'b1100};
            // bins high_1byte    = {4'b1000};
            // bins low_2byte     = {4'b0011};
            // bins low_1byte     = {4'b0001};
            bins other         = default;
        }

        // last_dw_be
        cp_last_be: coverpoint tlp_tr.last_dw_be {
            bins full          = {4'b1111};
            // bins single_dw_end = {4'b0000};
            // bins high_3byte    = {4'b0111};
            // bins high_2byte    = {4'b0011};
            // bins high_1byte    = {4'b0001};
            bins other         = default;
        }

        // 地址是否在高32位（4DW Header）
        cp_hdr_type: coverpoint tlp_tr.fmt[1] {
            bins hdr_3dw = {0};
            bins hdr_4dw = {1};
        }

        // first_be × last_be（验证非对齐传输）
        // cx_be: cross cp_first_be, cp_last_be;

        // 长度 × 地址对齐
        cx_len_align: cross cp_len, cp_addr_align;

        // Header类型 × 长度
        cx_hdr_len: cross cp_hdr_type, cp_len;
    endgroup

    // ════════════════════════════════════════════════
    // PCIe MRd TLP覆盖组
    // ════════════════════════════════════════════════
    covergroup mrd_tlp_cg;
        // TLP长度
        cp_len: coverpoint tlp_tr.length_dw {
            bins single_dw   = {1};
            bins small_2_16  = {[2:16]};
            bins medium_17_64  = {[17:64]};
            bins large_65_128  = {[65:128]};
        }

        // Tag值分布（验证Tag分配是否均匀）
        cp_tag: coverpoint tlp_tr.tag {
            bins tag_0_7   = {[0:7]};
            bins tag_8_15  = {[8:15]};
            bins tag_16_23 = {[16:23]};
            bins tag_24_31 = {[24:31]};
        }

        // 地址对齐
        cp_addr_align: coverpoint tlp_tr.address[1:0] {
            bins aligned  = {2'b00};
            // bins unaligned= {[2'b01:2'b11]};
        }

        // first_be
        cp_first_be: coverpoint tlp_tr.first_dw_be {
            bins full      = {4'b1111};
            bins partial   = default;
        }

        // Header类型
        cp_hdr_type: coverpoint tlp_tr.fmt[1] {
            bins hdr_3dw = {0};
            bins hdr_4dw = {1};
        }

        // Tag × 长度
        cx_tag_len: cross cp_tag, cp_len;

        // 地址对齐 × 长度
        cx_align_len: cross cp_addr_align, cp_len;
    endgroup

    // ════════════════════════════════════════════════
    // CplD覆盖组（验证回注的CplD特征）
    // ════════════════════════════════════════════════
    covergroup cpld_cg;
        // CplD状态
        cp_status: coverpoint cpld_tr.cpl_status {
            bins sc = {3'b000};  // 成功
            // bins ur = {3'b001};  // Unsupported Request
            // bins ca = {3'b100};  // Completer Abort
        }

        // 回注延迟
        cp_delay: coverpoint cpld_tr.delay_cycles {
            bins short_0_5   = {[0:5]};
            bins medium_6_15 = {[6:15]};
            bins long_16plus = {[16:255]};
        }

        // Tag分布
        cp_tag: coverpoint cpld_tr.tag {
            bins tag_0_7   = {[0:7]};
            bins tag_8_15  = {[8:15]};
            bins tag_16_23 = {[16:23]};
            bins tag_24_31 = {[24:31]};
        }

        // 状态 × 延迟
        cx_status_delay: cross cp_status, cp_delay;

        // Tag × 状态
        cx_tag_status: cross cp_tag, cp_status;
    endgroup

    // ════════════════════════════════════════════════
    // 读写并发覆盖组
    // ════════════════════════════════════════════════
    covergroup rw_concurrent_cg;
        // 写事务的ID
        cp_wr_id: coverpoint axi_tr.id {
            bins id_0_3  = {[0:3]};
            bins id_4_7  = {[4:7]};
            bins id_8_15 = {[8:15]};
        }
        // 读事务outstanding数
        cp_rd_outstanding: coverpoint outstanding_rd_cnt {
            bins three_plus = {[0:32]};
            bins more = {[33:100]};
        }
        // 写时有读outstanding（验证读写并发）
        cx_wr_rd: cross cp_wr_id, cp_rd_outstanding;
    endgroup

    // ════════════════════════════════════════════════
    // 构造函数
    // ════════════════════════════════════════════════
    function new(string name = "bridge_coverage", uvm_component parent = null);
        super.new(name, parent);
        outstanding_rd_cnt  = 0;
        max_outstanding_seen = 0;
        axi_wr_cg    = new();
        axi_rd_cg    = new();
        mwr_tlp_cg   = new();
        mrd_tlp_cg   = new();
        cpld_cg      = new();
        rw_concurrent_cg = new();
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap_axi  = new("ap_axi",  this);
        ap_tlp  = new("ap_tlp",  this);
        ap_cpld = new("ap_cpld", this);
    endfunction

    // ════════════════════════════════════════════════
    // 接收AXI事务
    // ════════════════════════════════════════════════
    virtual function void write_axi(axi_seq_item tr);
        axi_tr = tr;
        if(tr.is_write) begin
            axi_wr_cg.sample();
            rw_concurrent_cg.sample();
        end else begin
            // 读事务完成，outstanding减少
            if(outstanding_rd_cnt > 0)
                outstanding_rd_cnt--;
            axi_rd_cg.sample();
        end
    endfunction

    // ════════════════════════════════════════════════
    // 接收TLP
    // ════════════════════════════════════════════════
    virtual function void write_tlp(pcie_tlp_item tr);
        tlp_tr = tr;
        case(tr.tlp_type)
            TLP_MWR: mwr_tlp_cg.sample();
            TLP_MRD: begin
                // MRd发出，outstanding增加
                outstanding_rd_cnt++;
                if(outstanding_rd_cnt > max_outstanding_seen)
                    max_outstanding_seen = outstanding_rd_cnt;
                mrd_tlp_cg.sample();
            end
            default: ;
        endcase
    endfunction

    // ════════════════════════════════════════════════
    // 接收CplD
    // ════════════════════════════════════════════════
    virtual function void write_cpld(cpld_seq_item tr);
        cpld_tr = tr;
        cpld_cg.sample();
    endfunction

    // ════════════════════════════════════════════════
    // report_phase
    // ════════════════════════════════════════════════
    virtual function void report_phase(uvm_phase phase);
        `uvm_info(get_type_name(),
        $sformatf({
            "\n",
            "╔══════════════════════════════════════════╗\n",
            "║          Coverage Report                 ║\n",
            "╠══════════════════════════════════════════╣\n",
            "║  AXI Write    Coverage : %6.2f%%         ║\n",
            "║  AXI Read     Coverage : %6.2f%%         ║\n",
            "║  MWr TLP      Coverage : %6.2f%%         ║\n",
            "║  MRd TLP      Coverage : %6.2f%%         ║\n",
            "║  CplD         Coverage : %6.2f%%         ║\n",
            "║  RW Concurrent Coverage: %6.2f%%         ║\n",
            "╠══════════════════════════════════════════╣\n",
            "║  Max Outstanding Read  : %3d             ║\n",
            "║  Average       Coverage: %6.2f%%         ║\n",
            "╚══════════════════════════════════════════╝"
        }, // 注意：花括号闭合，然后点一个逗号！后面才是变量列表
        axi_wr_cg.get_coverage(),
        axi_rd_cg.get_coverage(),
        mwr_tlp_cg.get_coverage(),
        mrd_tlp_cg.get_coverage(),
        cpld_cg.get_coverage(),
        rw_concurrent_cg.get_coverage(),
        max_outstanding_seen,
        (axi_wr_cg.get_coverage()+axi_rd_cg.get_coverage()+mwr_tlp_cg.get_coverage()+
        mrd_tlp_cg.get_coverage()+cpld_cg.get_coverage()+rw_concurrent_cg.get_coverage())/6),
        UVM_LOW)
    endfunction

endclass