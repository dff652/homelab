这份文档汇总了你在这台 **华硕 PB62 + i9-11900T ES (QV1L)** 机器上进行 PVE 安装、存储架构规划及 CPU 性能调优的全过程。

------

# Proxmox VE 硬件部署与性能调优全指南 (ASUS PB62 + QV1L)

## 一、 硬件架构方案

为了在北桥锁频的情况下获得最优体验，建议采用“系统与数据物理隔离”的布局：

| **物理位置**       | **推荐硬件**                       | **建议用途**           | **逻辑分配 (PVE)**                                    |
| ------------------ | ---------------------------------- | ---------------------- | ----------------------------------------------------- |
| **M.2 (PCIe 3.0)** | 三星 PM961 / 浦科特 M9PeGN (256GB) | **系统盘 (OS)**        | `local`: 存放系统、ISO 镜像、容器模板。               |
| **M.2 (PCIe 4.0)** | **铠侠 XG7 (1TB)**                 | **核心虚拟机盘 (VMs)** | **`LVM-Thin`**: 利用 **$78.8$ 万 IOPS** 跑高负载 VM。 |
| **SATA 接口**      | 1TB SATA SSD                       | **备份与冷数据**       | **`Directory`**: 专门用于 VM 每日快照备份。           |

------

## 二、 PVE 系统安装与分区优化

在 256GB 系统盘安装过程中，点击 `Advanced Options` 手动配置分区：

- **`hdsize`**: `256`。
- **`maxroot`**: `60` (GB)。预留足够空间给系统日志和监控，防止系统崩溃。
- **`minfree`**: `16` (GB)。预留给 SSD 做磨损均衡，延长寿命。
- **`maxvz`**: `0`。不在系统盘创建 `local-lvm`，将剩余空间全部给 `local` 存放 ISO。

------

## 三、 CPU 性能解锁与持久化

QV1L ES 处理器的核心在于解除功耗限制并维持 IPC 指令效率。

### 1. 核心调优命令

Bash

```
# 安装 MSR 工具
apt update && apt install msr-tools -y

# 解锁功耗墙 (35W -> 62W)
wrmsr 0x610 0x00008A2000008A20

# 修正倍频逻辑 (尝试修复 Uncore)
wrmsr 0x620 0x1E1E

# 诱导核显进入最深节能 (提升 IPC)
echo "auto" > /sys/bus/pci/devices/0000:00:02.0/power/control
```

### 2. systemd 服务持久化

创建 `/etc/systemd/system/cpu-unlock.service`：

Ini, TOML

```
[Unit]
Description=Unlock Power Limit and Uncore for QV1L ES
After=sysinit.target

[Service]
Type=oneshot
ExecStartPre=/sbin/modprobe msr
ExecStart=/usr/local/bin/unlock-cpu.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

------

## 四、 存储性能校验命令

验证铠侠 XG7 在你的 QV1L 平台上是否开启了 PCIe 4.0：

### 1. 物理链路检查

Bash

```
# 查看物理层速度：应显示 LnkSta: Speed 16GT/s 代表 PCIe 4.0
lspci -vvv -s $(lspci | grep -i nvme | awk '{print $1}') | grep -E "LnkCap:|LnkSta:"
```

### 2. 性能实测

Bash

```
# 顺序读取测试 (理想值约 3900MB/s，受限于北桥频率)
fio --name=SeqRead --rw=read --bs=1M --size=10G --numjobs=1 --runtime=30 --group_reporting --filename=/dev/nvme0n1 --direct=1 --ioengine=libaio --iodepth=64

# 随机 4K 读取测试 (预期约 78 万 IOPS)
fio --name=RandRead4K --rw=randread --bs=4k --size=4G --numjobs=4 --runtime=30 --group_reporting --filename=/dev/nvme0n1 --direct=1 --ioengine=libaio --iodepth=128
```

------

## 五、 关键避坑与结论

1. **Headless 模式（关键）**：QV1L 在不接显示器的情况下，IPC 能从 **$0.04$ 回升至 $1.38$**。接显示器或直通核显会严重拖累 CPU 效率。

2. **北桥锁频**：Uncore 锁定在 **$800\text{ MHz}$** 是硬件 Bug，无法通过软件完全解除。顺序读写被卡在 **$4000\text{ MB/s}$** 左右是正常现象。

3. **VM 设置**：

   - 磁盘总线：**SCSI**。

   - 控制器：**VirtIO SCSI single**。

   - 高级：勾选 **IO Thread**（提升并发）和 **Discard**（支持 TRIM）。

     

以下是基于本次会话中关于 **华硕 PB62 + i9-11900T ES (QV1L)** 平台的 PVE 安装、存储规划及性能调优过程的总结文档。

------

# Proxmox VE 安装与硬件调优总结报告 (ASUS PB62 + QV1L)

## 1. 硬件环境概览

- **CPU**: Intel Core i5-11900T ES (代号: QV1L)。
- **机型**: 华硕 PB62 小主机。
- **内存**: 16GB DDR4 (可用 15.36GB)。
- **存储布局**:
  - **系统盘**: 256GB M.2 SSD (推荐使用 Plextor M9PeGN 或 三星 PM961)。
  - **虚拟机数据盘**: 1TB 铠侠 (Kioxia) XG7 (PCIe 4.0)。
  - **备份/仓库盘**: 1TB SATA SSD。

------

## 2. 存储规划与安装建议

### 2.1 物理盘位分配

- **PCIe 3.0 插槽**: 安装 **256GB 系统盘**。PVE 宿主机系统对带宽要求低，Gen3 绰绰有余。
- **PCIe 4.0 插槽**: 安装 **1TB 铠侠 XG7**。用于存放虚拟机（VM），充分利用其高 IOPS 性能。
- **SATA 接口**: 安装 **1TB SATA SSD**。作为冷数据和虚拟机备份仓库。

### 2.2 PVE 安装参数优化

在安装界面的 `Advanced Options` 中建议执行以下配置：

- **hdsize**: 256 (GB)
- **maxroot**: 60 (GB) —— 系统分区 60GB 足够，防止日志占满整盘。
- **minfree**: 16 (GB) —— 为 SSD 留出余量，延长寿命。
- **maxvz**: 0 —— 强制不创建 `local-lvm`，将剩余空间全部并入 `local` 存储，用于存放 ISO 镜像。

------

## 3. CPU 性能突破与调试 (QV1L 专题)

### 3.1 核心问题：北桥频率锁死

- **现象**: QV1L 在开启核显的情况下，北桥频率（Ring Bus）会被物理锁死在 **800MHz**。
- **实测影响**: 导致内存带宽受限（约 8-9GB/s），系统在高负载下存在“粘滞感”。

### 3.2 功耗解锁与北桥优化

通过 MSR 寄存器成功解锁功耗墙，并将全核睿频维持在较高水平：

- **解锁命令**:
  - 功耗解锁（~62W）: `wrmsr 0x610 0x00008A2000008A20`
  - 北桥锁定（尝试）: `wrmsr 0x620 0x1E1E`
- **关键发现**: **拔掉显示器（Headless 模式）**能将 IPC（指令效率）从 **0.04 回升至 1.38**，显著改善系统流畅度。

### 3.3 性能持久化脚本

创建 `/etc/systemd/system/cpu-unlock.service`，确保重启后自动生效：

Bash

```
# 核心脚本内容摘要
modprobe msr
wrmsr 0x610 0x00008A2000008A20  # 功耗解锁至 62W 档位
wrmsr 0x620 0x1E1E              # 修正倍频逻辑
echo "auto" > /sys/bus/pci/devices/0000:00:02.0/power/control # 诱导核显节能
```

------

## 4. 存储性能实测报告 (铠侠 XG7)

通过 `lspci` 和 `fio` 测试，验证了在 QV1L 平台上的实际存储表现：

| **测试项**              | **实测结果**             | **结论解读**                                            |
| ----------------------- | ------------------------ | ------------------------------------------------------- |
| **物理链路 (LnkSta)**   | **16GT/s (PCIe 4.0 x4)** | PB62 成功开启了 PCIe 4.0 通道。                         |
| **顺序读取 (Seq Read)** | **3952 MB/s**            | 受限于北桥 800MHz，表现为 PCIe 3.0 极限速度。           |
| **随机读取 (4K IOPS)**  | **78.8 万 IOPS**         | 表现为 **顶级 PCIe 4.0 水平**，极大地提升 VM 运行效率。 |

------

## 5. 调试结论与最终定论

1. **性能状态**: 你的 PB62 目前处于 **“计算核心火力全开 (62W)、数据中转拥堵 (800MHz)”** 的平衡态。
2. **VM 优化建议**:
   - 磁盘总线选 **SCSI**，控制器选 **VirtIO SCSI single**。
   - 开启 **IO Thread** 和 **Discard**。
3. **直通风险**: 直通核显给虚拟机可能导致 IPC 效率再次跌回 0.1 左右，建议仅在 Headless 模式下使用纯算力。

------

**文档版本**: 2026-03-09

**操作人**: douff