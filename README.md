# homelab

个人 homelab 基础设施仓库。覆盖 PVE 主机与虚拟机、GL-iNet MT2500 旁路由、跨设备网络问题排查。

由 [`dff652/pve_setup`](https://github.com/dff652/pve_setup) 与 [`dff652/gl-mt2500-ops`](https://github.com/dff652/gl-mt2500-ops) 通过 `git subtree` 合并而来，**完整保留两份历史**。

---

## 目录结构

```
homelab/
├── pve/        — PVE 主机 + Ubuntu VM 配置（来自 pve_setup）
├── router/     — GL-iNet MT2500 旁路由运维（来自 gl-mt2500-ops）
├── tools/      — 跨平台工具（任意 Linux 可用，来自各独立仓库）
└── docs/       — 跨设备问题（症状在一边、根因在另一边）
```

### 子目录语义边界

| 目录 | 含义 | 判断标准 |
|---|---|---|
| `pve/` | 只在 PVE 主机或其 VM 内有意义 | 改 `/etc/sysctl.conf`、`systemd-resolved`、特定网卡名等 |
| `router/` | 只在 OpenWrt/MT2500 上有意义 | 用 `uci`、`/etc/openclash`、busybox 特性 |
| `tools/` | 任何 Linux 机器都能跑的独立工具 | 不依赖特定硬件/系统设定，每个子项目可单独使用 |
| `docs/` | 症状在一边、根因在另一边的跨设备记录 | 不属于上面任何一边 |

### `pve/` — PVE 与 VM
| 入口 | 用途 |
|---|---|
| [`pve/setup_vm.sh`](pve/setup_vm.sh) | Ubuntu 24.04 VM 一键初始化（换源、静态 IP、SSH、Guest Agent、Docker、nvm） |
| [`pve/network/codex_net_fix.sh`](pve/network/codex_net_fix.sh) | 网络诊断与一键修复（OpenAI、GitHub、DNS、IPv6） |
| [`pve/Proxmox VE 硬件部署与性能调优全指南.md`](pve/Proxmox%20VE%20硬件部署与性能调优全指南.md) | PVE 硬件 / 性能调优笔记 |

### `router/` — MT2500 (OpenWrt) 旁路由
| 入口 | 用途 |
|---|---|
| [`router/scripts/diag-github.sh`](router/scripts/diag-github.sh) | GitHub 链路从路由器侧诊断 |
| [`router/scripts/diag-dns.sh`](router/scripts/diag-dns.sh) | DNS 链路验证（53/5335/7874 多端口） |
| [`router/scripts/deploy-derp.sh`](router/scripts/deploy-derp.sh) | Tailscale DERP 中继部署 |
| [`router/docs/DNS链路方案_终极架构.md`](router/docs/DNS链路方案_终极架构.md) | AdGuardHome + dnsmasq + OpenClash 三层 DNS 拓扑 |
| [`router/docs/Tailscale_DERP中继与OpenVPN排查记录.md`](router/docs/Tailscale_DERP中继与OpenVPN排查记录.md) | DERP 自建 + OpenVPN 子网路由排查 |

### `tools/` — 跨平台工具
独立的、自带 README 与文档的小工具，**任意 Linux 机器都能跑**，不绑定 PVE 或 MT2500。

| 工具 | 用途 |
|---|---|
| [`tools/disk-health-analyzer/`](tools/disk-health-analyzer/) | SMART/NVMe/eMMC/RAID 磁盘健康检测 + fio/dd 测速；含 [`migrate_hfd_models.sh`](tools/disk-health-analyzer/migrate_hfd_models.sh) (HuggingFace 模型跨盘迁移)、[`scripts/plot_nvme_temperature.py`](tools/disk-health-analyzer/scripts/plot_nvme_temperature.py) (NVMe 温度趋势可视化) |

每个 `tools/<name>/` 子目录有自己的 README，使用方式见各自文档。

### `docs/` — 跨设备问题
症状出现在 VM 或客户端、根因在网关/路由器的问题（独立于 `pve/` 与 `router/`）。

| 文档 | 时间 |
|---|---|
| [`docs/GitHub_FakeIP与SSH-HTTPS双通道排查.md`](docs/GitHub_FakeIP与SSH-HTTPS双通道排查.md) | 2026-04-25 |

---

## 路径目录指引

**遇到 GitHub 访问问题** → 先看 [`docs/GitHub_FakeIP与SSH-HTTPS双通道排查.md`](docs/GitHub_FakeIP与SSH-HTTPS双通道排查.md)，再跑 [`pve/network/codex_net_fix.sh`](pve/network/codex_net_fix.sh) 诊断。

**新建 VM** → [`pve/setup_vm.sh`](pve/setup_vm.sh) 一键完成，跑完后如需 Codex/AI 工具，再运行 [`pve/network/codex_net_fix.sh`](pve/network/codex_net_fix.sh)。

**OpenClash 规则改坏** → 参考 [`router/docs/DNS链路方案_终极架构.md`](router/docs/DNS链路方案_终极架构.md) + [`docs/GitHub_FakeIP与SSH-HTTPS双通道排查.md`](docs/GitHub_FakeIP与SSH-HTTPS双通道排查.md) 的 §4 规则。

**DERP / Tailscale 异常** → [`router/docs/Tailscale_DERP中继与OpenVPN排查记录.md`](router/docs/Tailscale_DERP中继与OpenVPN排查记录.md) + [`router/scripts/derp-diag-server.sh`](router/scripts/derp-diag-server.sh)。

**磁盘满 / SMART 异常 / 想跑测速** → [`tools/disk-health-analyzer/`](tools/disk-health-analyzer/)（自带交互菜单），或参考 [`tools/disk-health-analyzer/disk_cleanup_2026-04-19.md`](tools/disk-health-analyzer/disk_cleanup_2026-04-19.md) 的处理思路。

**外部引用** —— 不并入本仓但仍属个人 homelab：
- [dff652/pve-diy](https://github.com/dff652/pve-diy) — PVE 一键脚本（fork 自上游，作为独立 fork 维护，不并入避免与上游分歧）

---

## 开发约定

- **不在仓里存敏感信息**：API key、私钥、设备口令等一律走环境变量或本地 `.env`（`.gitignore` 兜底）
- **跨设备问题写 `docs/`，不要塞进 `pve/` 或 `router/`**：保持子项目语义边界
- **诊断脚本要带"结论判定"**：见 `pve/network/codex_net_fix.sh` 的 `print_*_conclusion` 函数风格——不仅采集，还自动给出 `[OK]` / `[!]` / `[WARN]` 解读
- **GUI 改的配置（如 OpenClash 规则）落档进仓**：避免改了忘记，未来回滚无据可查
