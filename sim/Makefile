#==============================================================
# Makefile for  UVM DV
#==============================================================

#--------------------------------------------------------------
# 工具配置
#--------------------------------------------------------------
VCS     = vcs
VERDI   = verdi
PYTHON  = python3

#--------------------------------------------------------------
# 目录配置
#--------------------------------------------------------------
RTL_DIR  = ../rtl
TB_DIR   = ../tb
SIM_DIR  = ./sim_out
LOG_DIR  = ./logs
COV_DIR  = ./coverage

#--------------------------------------------------------------
# 默认测试（make sim不指定TEST时用这个）
#--------------------------------------------------------------
TEST    ?= concurrent_test
SEED    ?= 1
UVM_VERBOSITY ?= UVM_MEDIUM

#--------------------------------------------------------------
# RTL文件列表
#--------------------------------------------------------------
RTL_FILES = \
    $(RTL_DIR)/axi_pcie_pkg.sv        \
    $(RTL_DIR)/axi_wr_if.sv 		\
	$(RTL_DIR)/write_engine.sv			\
	$(RTL_DIR)/tx_arbiter.sv			\
	$(RTL_DIR)/credit_manager.sv			\
	$(RTL_DIR)/axi_rd_if.sv			\
	$(RTL_DIR)/read_engine.sv			\
	$(RTL_DIR)/tag_allocator.sv			\
	$(RTL_DIR)/cpld_parser.sv			\
	$(RTL_DIR)/reorder_buffer.sv			\
	$(RTL_DIR)/axi_pcie_bridge_top.sv  

#--------------------------------------------------------------
# TB文件列表
#--------------------------------------------------------------
TB_FILES = \
	$(TB_DIR)/interface/axi_if.sv  \
	$(TB_DIR)/interface/pcie_tx_if.sv  \
	$(TB_DIR)/interface/pcie_rd_if.sv  \
	$(TB_DIR)/interface/cfg_if.sv  \
	$(TB_DIR)/bridge_env_pkg.sv		\
	$(TB_DIR)/top_tb.sv
    
    

#--------------------------------------------------------------
# VCS编译选项
#--------------------------------------------------------------
VCS_COMPILE_OPTS = \
    -sverilog                   \
    -full64                     \
    -timescale=1ns/1ps          \
    -ntb_opts uvm-1.2           \
    +define+VCS                 \
    +define+UVM_NO_DEPRECATED   \
    -debug_access+all           \
    -kdb                        \
    +incdir+$(TB_DIR)           \
	+incdir+$(TB_DIR)/interface           \
	+incdir+$(TB_DIR)/transcation           \
	+incdir+$(TB_DIR)/sequence           \
	+incdir+$(TB_DIR)/axi_master_agent           \
	+incdir+$(TB_DIR)/pcie_tx_agent           \
	+incdir+$(TB_DIR)/pcie_rx_agent           \
	+incdir+$(TB_DIR)/test           \
    +incdir+$(RTL_DIR)          \
	-l $(LOG_DIR)/compile.log  \
    -cm line+cond+fsm+tgl+branch+assert \
    -assert enable -assert svaext

#--------------------------------------------------------------
# VCS仿真选项
#--------------------------------------------------------------
VCS_SIM_OPTS = \
    -l ../$(LOG_DIR)/sim_$(TEST)_$(SEED).log  \
    +UVM_TESTNAME=$(TEST)                  \
    +UVM_VERBOSITY=$(UVM_VERBOSITY)        \
    +ntb_random_seed=$(SEED)               \
    -cm line+cond+fsm+tgl+branch+assert \
    -cm_name $(TEST)_cov \
    # -ucli -do $(TB_DIR)/wave.tcl

#==============================================================
# 主要目标
#==============================================================

# 默认目标
all: comp sim

#--------------------------------------------------------------
# 编译
#--------------------------------------------------------------
comp: $(LOG_DIR) $(SIM_DIR)
	$(VCS) $(VCS_COMPILE_OPTS) \
	    $(RTL_FILES) $(TB_FILES) \
	    -o $(SIM_DIR)/simv
	@echo ">>> 编译完成"

#--------------------------------------------------------------
# 仿真（单个测试）
#--------------------------------------------------------------
sim: $(SIM_DIR)/simv $(LOG_DIR)
	cd $(SIM_DIR) && ./simv $(VCS_SIM_OPTS)
	@echo ">>> 仿真完成: TEST=$(TEST) SEED=$(SEED)"

#--------------------------------------------------------------
# 回归测试（跑所有测试）
#--------------------------------------------------------------
TESTS = \
    wr_single_align_test       \
    wr_burst_no_split_test    \
    rd_single_align_test          \
    rd_burst_no_split_test             \
    rd_burst_mrrs_split_test       \
	rd_multi_outstanding_test      \
	concurrent_test

regression: comp                  # 依赖comp,如果没有comp，会先执行comp
	@for t in $(TESTS); do \
	    echo ">>> 运行 $$t"; \
	    (cd $(SIM_DIR) && ./simv \
	        -l ../$(LOG_DIR)/sim_$${t}.log \
	        +UVM_TESTNAME=$$t \
	        +UVM_VERBOSITY=UVM_LOW \
	        +ntb_random_seed=1 \
			-cm line+cond+fsm+tgl+branch+assert \
			-cm_name $${t}_cov); \
	done
	@echo ">>> 回归完成"
	@grep -l "^UVM_ERROR\|^UVM_FATAL" $(LOG_DIR)/sim_*.log | \
		awk -F'[: ]+' '{sum += $$2} END {\
		if(sum==0)\
			print "全部通过！";\
		else\
			print "有测试失败！Total Errors and fatals = " sum}'

# @grep -l "UVM_ERROR\|UVM_FATAL" $(LOG_DIR)/sim_*.log \
#     && echo ">>> 有测试失败！" \
#     || echo ">>> 全部通过！"

#--------------------------------------------------------------
# 打开波形
#--------------------------------------------------------------
wave:
	$(VERDI) -sv \
	$(RTL_FILES) \
	$(TB_FILES) \
	-ssf $(SIM_DIR)/novas.fsdb &

#--------------------------------------------------------------
# 打开覆盖率（支持指定单个测试或查看整体）
# 默认 COV_NAME 为空，代表看整体
COV_NAME ?=

verdi_cov:
ifeq ($(COV_NAME),)
	@echo ">>> 正在打开 [全部用例合并] 的总覆盖率视图..."
	verdi -cov -covdir $(SIM_DIR)/simv.vdb &
else
	@echo ">>> 正在打开单个用例 [$(COV_NAME)_cov] 的独立覆盖率视图..."
	verdi -cov -covdir $(SIM_DIR)/simv.vdb -covdb_name "$(COV_NAME)_cov" &
endif
# 解释：
# -covdir simv.vdb : 指定覆盖率数据库
# &                : 后台打开


# 覆盖率合并和报告
#--------------------------------------------------------------
cov: $(COV_DIR)
	$(VCS) -covdir $(SIM_DIR)/simv.vdb \
	    -report $(COV_DIR)/report

#--------------------------------------------------------------
# 清理
#--------------------------------------------------------------
clean:
	rm -rf $(SIM_DIR) $(LOG_DIR) $(COV_DIR)
	rm -rf csrc ucli.key vc_hdrs.h *.log *.fsdb *.rc *.conf verdiLog

#--------------------------------------------------------------
# 创建目录
#--------------------------------------------------------------
$(SIM_DIR):
	mkdir -p $(SIM_DIR)

$(LOG_DIR):
	mkdir -p $(LOG_DIR)

$(COV_DIR):
	mkdir -p $(COV_DIR)

.PHONY: all compile sim regression wave cov_merge clean