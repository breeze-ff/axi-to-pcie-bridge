# AXI-to-PCIe Bridge — RTL Design & UVM Verification

> 从协议理解、RTL设计到UVM全环境搭建，覆盖率达到 **93.26%**。

---

## 项目概述

本项目实现了一个 **AXI4 Slave 到 PCIe TLP（Transaction Layer Packet）** 的协议转换桥，配套搭建了完整的 UVM 1.2 验证环境，覆盖写路径、读路径及并发场景。

```
AXI4 Master（SoC/CPU）
        │
        │  AXI4 Slave 接口
        ▼
┌─────────────────────────────────┐
│       AXI-to-PCIe Bridge        │
│                                 │
│  Write Engine  ──►  MWr TLP    │──► PCIe TX（m_axis）
│  Read Engine   ──►  MRd TLP    │──► PCIe TX（m_axis）
│  CplD Parser   ◄──  CplD TLP  │◄── PCIe RX（s_axis）
│  Reorder Buffer ──► AXI R 通道 │
└─────────────────────────────────┘
        │
        │  PCIe TLP（AXI-Stream 接口对接 PHY IP）
        ▼
   PCIe Endpoint / Root Complex
```

---

## 目录结构

```
axi2pcie/
├── rtl/                          # RTL 设计文件
│   ├── axi_pcie_pkg.sv           # 公共类型定义（结构体/函数）
│   ├── axi_pcie_bridge_top.sv    # 顶层模块（连线）
│   ├── axi_wr_if.sv              # AXI 写接口（AW_FIFO + W_FIFO）
│   ├── write_engine.sv           # 写引擎（Burst 切割 + MWr TLP 生成）
│   ├── axi_rd_if.sv              # AXI 读接口（AR_FIFO）
│   ├── read_engine.sv            # 读引擎（MRd TLP 生成）
│   ├── tag_allocator.sv          # PCIe Tag 分配器（Round-Robin）
│   ├── cpld_parser.sv            # CplD TLP 解析器
│   ├── reorder_buffer.sv         # 乱序重组缓冲（per-ARID 独立队列）
│   ├── tx_arbiter.sv             # TX 发送仲裁器（WRR + Credit 检查）
│   └── credit_manager.sv         # PCIe Flow Control Credit 管理
│
├── tb/                           # UVM 验证环境
│   ├── top_tb.sv                 # TB 顶层（DUT 例化 + VIF 注册）
│   ├── bridge_env_pkg.sv         # 环境包（统一 import）
│   ├── bridge_env.sv             # UVM Env（组件连线）
│   ├── scoreboard.sv             # Scoreboard（写路径 TLP 比对 + 读路径数据比对）
│   ├── bridge_coverage.sv        # 功能覆盖率模型（6 个 covergroup）
│   │
│   ├── interface/                # SystemVerilog Interface
│   │   ├── axi_if.sv             # AXI 五通道接口（含 clocking block）
│   │   ├── pcie_tx_if.sv         # PCIe TX AXI-Stream 接口
│   │   ├── pcie_rd_if.sv         # PCIe RX AXI-Stream 接口
│   │   └── cfg_if.sv             # 配置接口（Credit 注入 + 参数配置）
│   │
│   ├── transcation/              # UVM Transaction
│   │   ├── axi_seq_item.sv       # AXI 读写事务（含随机约束）
│   │   ├── pcie_tlp_item.sv      # PCIe TLP 事务（Monitor 捕获用）
│   │   └── cpld_seq_item.sv      # CplD 回注事务（含延迟随机化）
│   │
│   ├── agent/
│   │   ├── axi_master_agent/     # AXI Master Agent
│   │   │   ├── axi_driver.sv     # 驱动 AW/W/AR 通道（读写并发分流）
│   │   │   ├── axi_monitor.sv    # 监听五通道（AW/W 并发 + AR 即时上报）
│   │   │   └── axi_master_agent.sv
│   │   ├── pcie_tx_agent/        # PCIe TX Agent（Passive，只监听）
│   │   │   ├── pcie_tx_monitor.sv # 捕获并解析 MWr/MRd TLP
│   │   │   └── pcie_tx_agent.sv
│   │   └── pcie_rx_agent/        # PCIe RX Agent（Active，注入 CplD）
│   │       ├── cpld_driver.sv    # 驱动 s_axis 注入 CplD
│   │       ├── cpld_sequencer.sv # Reactive 机制（监听 MRd 自动构造 CplD）
│   │       └── pcie_rx_agent.sv
│   │
│   ├── sequence/                 # UVM Sequence
│   │   ├── base_sequence.sv      # 基类（send_write / send_read 封装）
│   │   ├── wr_sequence.sv        # 写路径场景序列
│   │   ├── rd_sequence.sv        # 读路径场景序列
│   │   ├── virtual_sequencer.sv  # Virtual Sequencer（跨 Agent 协调）
│   │   └── virtual_sequence.sv   # 并发读写序列
│   │
│   └── test/                     # UVM Test
│       ├── base_test.sv          # 基类（DUT 初始化 + Credit 注入）
│       ├── wr_test.sv            # 写路径测试集
│       ├── rd_test.sv            # 读路径测试集
│       └── concurrent_test.sv    # 读写并发 + 压力测试
│
└── sim/
    └── Makefile                  # 编译/仿真/回归/覆盖率脚本
```

---

## 设计特性

### RTL 设计亮点

| 特性 | 说明 |
|------|------|
| **TLP 四重切割约束** | MPS 边界 + 4KB 边界 + MRRS 限制 + 剩余字节，四者取最小 |
| **非对齐传输** | 支持地址非 DW 对齐，自动计算 First/Last DW Byte Enable |
| **AXI Burst 拆分** | 大 Burst 自动切割为多个合规 TLP，全局字节指针保证数据连续 |
| **Tag Round-Robin** | 128 个 PCIe Tag 轮转分配，Tag 耗尽时 ARREADY 自动背压 |
| **CplD 乱序重组** | per-ARID 独立 FIFO，同 ID 严格有序，异 ID 乱序返回 |
| **Credit 流控** | 独立追踪 PH/PD/NPH 三类 Credit，不足时 TLP 在 TX 队列等待 |
| **Completion 超时** | 每个 Tag 独立计时器，超时触发错误上报 |
| **burst_in_progress** | R_NEXT_TAG 状态锁定当前 ARID，防止仲裁器 mid-burst 切换 ID |

### UVM 验证环境亮点

| 特性 | 说明 |
|------|------|
| **Reactive CplD 机制** | pcie_tx_monitor 捕获 MRd → cpld_sequencer 自动构造并回注 CplD |
| **乱序 CplD 注入** | delay_dispatcher 并发 fork，各 CplD 独立延迟，实现真实乱序 |
| **per-ARID Scoreboard** | 以 Tag 为纽带建立 MRd→AXI 事务映射，支持多 ID 并发比对 |
| **AR 即时上报** | monitor 分 ap_ar（AR 握手即上报）和 ap（R 完成后上报），解决时序竞争 |
| **Virtual Sequencer** | 并发测试中协调 AXI 写序列和读序列同步启动 |
| **6 个 CoverGroup** | 覆盖写/读事务、MWr/MRd TLP、CplD 特征及读写并发场景 |

---

## 验证场景

| Test | 场景描述 |
|------|----------|
| `wr_single_align_test` | 单次 DW 对齐写，验证基本写路径 |
| `wr_burst_no_split_test` | 小 Burst 写，不触发 TLP 切割 |
| `rd_single_align_test` | 单次对齐读，验证基本读路径 + CplD 回注 |
| `rd_burst_no_split_test` | 小 Burst 读，单个 MRd TLP |
| `rd_burst_mrrs_split_test` | 大 Burst 读，触发 MRRS 切割 + CplD 重组 |
| `rd_multi_outstanding_test` | 多 outstanding 读，验证 Tag 管理 + ROB 顺序输出 |
| `concurrent_test` | 读写并发 + 乱序 CplD + 随机压力，验证全路径 |

**回归结果：7 个测试全部通过，功能覆盖率 93.26%**

---

## 快速开始

### 环境要求

- **仿真工具**：Synopsys VCS（O-2018.09 或更高版本）
- **波形查看**：Synopsys Verdi
- **操作系统**：Linux（CentOS 7 / Ubuntu 18.04+）
- **UVM 版本**：UVM 1.2

### 编译与仿真

```bash
# 进入仿真目录
cd sim/

# 编译
make comp

# 运行单个测试（默认 concurrent_test）
make sim

# 指定测试和随机种子
make sim TEST=rd_burst_mrrs_split_test SEED=42

# 运行完整回归（7 个测试）
make regression

# 查看波形（需要先跑仿真且开启波形dump）
make wave

# 查看覆盖率
make verdi_cov

# 清理编译产物
make clean
```

### 可配置参数

在 `rtl/axi_pcie_bridge_top.sv` 顶层可调整：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `MPS_BYTES` | 128 | Max Payload Size（字节） |
| `MRRS_BYTES` | 512 | Max Read Request Size（字节，运行时可配） |
| `TAG_NUM` | 32 | PCIe Tag 数量 |
| `TAG_WIDTH` | 5 | log2(TAG_NUM) |
| `AW_FIFO_DEPTH` | 8 | AXI 写地址 FIFO 深度 |
| `W_FIFO_DEPTH` | 256 | AXI 写数据 FIFO 深度 |
| `AR_FIFO_DEPTH` | 8 | AXI 读地址 FIFO 深度 |
| `ARID_NUM` | 16 | 支持的 ARID 数量 |
| `TIMEOUT_CYC` | 1,000,000 | Completion 超时周期数 |

---

## 协议说明

### AXI 接口规格

- **版本**：AXI4
- **数据位宽**：64 bit
- **地址位宽**：64 bit
- **ID 位宽**：4 bit（支持 16 个 ARID/AWID）
- **支持 Burst 类型**：INCR（不支持 WRAP/FIXED）

### PCIe 接口规格

- **TLP 接口**：AXI-Stream（128 bit，对接 PHY/DLL IP）
- **支持 TLP 类型**：MWr（32/64 bit 地址）、MRd（32/64 bit 地址）、CplD
- **Flow Control**：PH / PD / NPH 三类 Credit 独立管理

### 关键约束

```
写路径切割（四重约束取最小）：
  1. MPS 边界（MaxPayloadSize）
  2. 4KB 自然对齐边界
  3. MPS 自然对齐边界（首包不能越过对齐边界）
  4. 剩余字节数

读路径切割（四重约束取最小）：
  1. MRRS 边界（MaxReadRequestSize）
  2. 4KB 自然对齐边界
  3. MPS 自然对齐边界
  4. 剩余字节数
```

---

## 架构图

### 写路径

```
AXI Master
   │
   ├─ AW 通道 ──► AW_FIFO ──┐
   │                          ├──► Write Engine ──► TLP Header
   └─ W  通道 ──► W_FIFO  ──┘        │
                                      │ 四重切割
                                      ▼
                               TX Arbiter（WRR 仲裁）
                                      │ Credit 检查
                                      ▼
                               PCIe TX（m_axis）──► MWr TLP
                                      │
                               B 通道 ◄── （TLP 入队后即返回）
```

### 读路径

```
AXI Master
   │
   └─ AR 通道 ──► AR_FIFO ──► Read Engine ──► MRd TLP
                                   │
                              Tag Allocator（Round-Robin）
                                   │
                              TX Arbiter ──► PCIe TX

PCIe RX（s_axis）──► CplD TLP
   │
   ├──► CplD Parser（解析 Header + 写数据）
   │         │
   │    Tag Allocator（更新 rcvd_bytes / 释放 Tag）
   │         │
   └──► Reorder Buffer（per-ARID 独立队列）
              │
         R 通道 ──► AXI Master（严格有序）
```

---

## 已知限制

- AXI Burst 类型仅支持 **INCR**，不支持 WRAP/FIXED
- PCIe 配置空间（Config Space）未实现
- DLL/PHY 层由外部 IP 提供，本设计只实现 Transaction Layer
- CplD 拆分（RCB 边界）由验证环境模拟，RTL 支持多个 CplD 重组

---

## 作者

YL N

---

## License

MIT License
