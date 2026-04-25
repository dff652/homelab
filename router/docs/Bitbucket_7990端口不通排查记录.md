# Bitbucket 7990 端口不通排查记录

- 日期：2026-04-12
- 环境：22服务器（192.168.2.22）通过 GL-MT2500 软路由访问内网 Bitbucket

## 问题描述

22服务器（192.168.2.22）无法 `git clone http://192.168.199.94:7990/...`，连接超时。但能 ping 通该 IP，且软路由（GL-MT2500）本机可以正常 clone。

## 网络拓扑

```
22服务器 (192.168.2.22)
    │
    │ 默认网关
    ▼
GL-MT2500 软路由 (192.168.2.123, eth0)
    │
    │ Tailscale (100.83.20.58, tailscale0)
    ▼
Bitbucket Server (192.168.199.94:7990)
```

- 22服务器与 Bitbucket 不在同一子网，需要通过软路由转发
- 软路由到 Bitbucket 的实际路径是 **Tailscale 隧道**（非直连局域网）

## 排查过程

### 1. 确认端口不通

```bash
# 22服务器上测试
curl -v --connect-timeout 5 http://192.168.199.94:7990/
# 结果：Connection timeout after 5001 ms
```

Ping 能通（ICMP 可达），但 TCP 7990 超时，说明问题在传输层。

### 2. 确认软路由本机可达

```bash
# GL-MT2500 上测试
curl -v --connect-timeout 5 http://192.168.199.94:7990/
# 结果：HTTP/1.1 302，正常响应
```

说明路由器到 Bitbucket 的链路没有问题，问题在路由器的**流量转发**环节。

### 3. 检查 iptables — 排除 NAT 劫持

```bash
iptables -t nat -L PREROUTING -n --line-numbers
# 结果：没有 OpenClash 相关的 REDIRECT/TPROXY 规则
```

排除了 iptables NAT 劫持的可能。

### 4. 定位流量劫持方式 — TUN 模式

路由器上存在 `utun` 接口（198.18.0.1/30），确认 OpenClash 使用的是 **TUN 模式**，通过策略路由（ip rule）而非 iptables 劫持流量。

### 5. 分析策略路由规则

```bash
ip rule list
```

关键规则：
```
0:    from all to 192.168.2.0/24 lookup main    # 本地子网直连
0:    from all to 192.168.8.0/24 lookup main    # 本地子网直连
1:    from all iif lo lookup 16800              # 路由器自身流量
1101: not from all fwmark 0x8000/0xc000 lookup 8000  # Clash TUN
5270: from all lookup 52                        # Tailscale
```

- 192.168.199.0/24 不在 prio 0 的直连绕行列表中
- 转发流量（从22服务器来的）在 prio 1101 被送入 **table 8000（Clash TUN）**
- Clash 无法正确处理这个流量，导致超时
- 路由器自身流量走 prio 1 的 `iif lo → table 16800`，最终到达 Tailscale，所以路由器本机能通

### 6. 确认实际路由路径

```bash
ip route get 192.168.199.94
# 192.168.199.94 dev tailscale0 table 52 src 100.83.20.58
```

确认 192.168.199.94 是通过 **Tailscale（table 52）** 到达的。

## 根因总结

**两个问题叠加：**

1. **Clash TUN 模式劫持**：OpenClash 的 TUN 模式通过策略路由将所有非本地子网的转发流量导入 Clash（table 8000），Clash 无法正确处理发往 192.168.199.94 的流量
2. **缺少 NAT/MASQUERADE**：即使绕过 Clash 将流量送入 Tailscale（table 52），由于源 IP 是 192.168.2.22（非 Tailscale 地址），对端无法回包

## 解决方案

在 GL-MT2500 软路由上执行两条命令：

```bash
# 1. 添加策略路由，让 192.168.199.0/24 的流量绕过 Clash，直接走 Tailscale（table 52）
ip rule add to 192.168.199.0/24 lookup 52 prio 100

# 2. 添加 MASQUERADE，将转发流量的源 IP 伪装为路由器的 Tailscale IP（100.83.20.58）
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
```

## 持久化

以上规则是临时的，需要在两个地方持久化以覆盖不同场景：

### 场景一：软路由重启

写入开机脚本 `/etc/rc.local`：

```bash
cat >> /etc/rc.local <<'EOF'
ip rule add to 192.168.199.0/24 lookup 52 prio 100
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
EOF
```

### 场景二：仅重启 OpenClash

OpenClash 重启时会重建策略路由规则，可能覆盖 prio 100 的规则。`rc.local` 只在开机时执行，无法覆盖此场景。

需要在 LuCI 界面 **网络 → 防火墙 → 自定义规则** 中添加：

```bash
ip rule add to 192.168.199.0/24 lookup 52 prio 100
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
```

防火墙自定义规则在每次防火墙重载时执行（包括 OpenClash 重启触发的重载），比 `rc.local` 更可靠。

**建议两处都配置，确保万无一失。**

## 后续排查与修复（2026-04-12 补充）

### OpenVPN 问题

通过 OpenVPN 连接软路由的 PC 无法 ping 通 192.168.199.126，原因是 `server.ovpn` 中缺少 `push route`。

**已修复：**
```bash
echo 'push "route 192.168.199.0 255.255.255.0"' >> /etc/openvpn/ovpn/server.ovpn
/etc/init.d/openvpn restart
```

修复后 Win11 VPN 客户端可正常访问 `http://192.168.199.94:7990/`。

**待修复（低优先级）：** `server.ovpn` 中 server 行格式异常：
```
# 当前（缺少网段地址）：
server  255.255.255.0
# 应为：
server 10.8.0.0 255.255.255.0
```
当前 OpenVPN 正常运行（接口 `ovpnserver` IP 为 `10.8.0.1`），GL-MT2500 的管理程序可能不完全依赖此行。固件升级后可能出问题，建议维护窗口修复。

### rc.local 的 exit 0 顺序问题

**已修复。** 原来两条规则写在 `exit 0` 之后，永远不会执行。已将 `exit 0` 移到末尾。

修复后 `/etc/rc.local` 内容：
```bash
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

. /lib/functions/gl_util.sh
remount_ubifs

ip rule add to 192.168.199.0/24 lookup 52 prio 100
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
exit 0
```

### 规则重复叠加问题

**待修复。** `firewall.user` 每次防火墙重载都会执行，当前的 `add` 写法会导致规则不断叠加。应改为幂等写法（先删再加）：

```bash
# /etc/firewall.user 中应改为：
ip rule del to 192.168.199.0/24 lookup 52 prio 100 2>/dev/null
ip rule add to 192.168.199.0/24 lookup 52 prio 100
iptables -t nat -D POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
```

同理 `/etc/rc.local` 也建议改为幂等写法。

## 后续排查：OpenVPN 客户端路由失效（2026-04-13）

### 问题

家庭侧 Win11 PC（192.168.2.115）通过 OpenVPN 连接 gl-mt2500-3，无法 ping 通 192.168.199.126。22 服务器（走 LAN）可正常访问同一地址。

### 排查过程

1. **VPN 连通性确认**：PC 能 ping 10.8.0.1（VPN 网关），VPN 隧道正常
2. **redirect-gateway 确认**：`route print` 显示 0.0.0.0/1 和 128.0.0.0/1 via 10.8.0.1，redirect-gateway def1 生效
3. **push route 失效**：`server.ovpn` 有 `push "route 192.168.199.0 ..."` 但 PC 路由表无此条目。GL-iNet OpenVPN 界面开启了"自定义路由规则模式"，该模式下客户端忽略服务端推送的路由
4. **手动加路由**：PC 上 `route add 192.168.199.0 mask 255.255.255.0 10.8.0.1`，初次加到了物理网卡（192.168.2.1）；修改客户端 `.ovpn` 加 `route 192.168.199.0 255.255.255.0 vpn_gateway` 后路由正确指向 VPN 接口
5. **路由正确但包不进隧道**：

   | 测试 | 结果 |
   |------|------|
   | ping 8.8.8.8 (via VPN) | ✅ 通，tcpdump 在 ovpnserver 看到包 |
   | ping 100.105.216.126 (istoreos TS IP, via VPN) | ✅ 通，15ms |
   | ping 192.168.199.126 (via VPN) | ❌ 超时，tcpdump -i any 无包 |

6. **Windows 路由确认**：`Find-NetRoute -RemoteIPAddress 192.168.199.126` 显示正确选择 VPN 接口（InterfaceIndex 10, NextHop 10.8.0.1）
7. **Windows 防火墙排除**：关闭防火墙后仍超时
8. **结论**：Windows OpenVPN TAP/TUN 驱动对 192.168.x.x 地址段存在兼容性问题，包在 PC 本机 VPN 驱动层被丢弃，不进入隧道。其他地址段（8.8.8.8、100.x.x.x）通过同一 VPN 正常转发

### 进一步排查：根因定位（2026-04-13）

#### 关闭 GL-iNet"自定义路由规则模式"

GL-iNet OpenVPN 界面开启的"自定义路由规则模式"导致服务端 `push "route 192.168.199.0 ..."` 不下发给客户端。关闭该模式后，Windows PC 恢复正常（~44ms）。

但手机端 OpenVPN 客户端（OpenVPN Connect）关闭自定义模式后仍不通，需要在客户端 `.ovpn` 配置中显式添加路由。

#### 服务端 push route vs 客户端 route 的区别

**服务端 push route 的工作方式：**
```
# server.ovpn
push "route 192.168.199.0 255.255.255.0"
```
服务端在 TLS 控制通道下发路由指令给客户端。客户端收到后执行两件事：
1. 在系统路由表添加条目（`192.168.199.0/24 via VPN gateway`）
2. 通知 TAP/TUN 驱动该网段的流量需要送进隧道

**问题：** push route 受 GL-iNet"自定义路由规则模式"影响（开启时屏蔽 push），也受客户端 app 版本/实现差异影响（部分移动端 app 忽略 push route）。

**客户端 route 指令的工作方式：**
```
# client.ovpn
route 192.168.199.0 255.255.255.0 vpn_gateway
```
客户端本地执行，不依赖服务端推送。OpenVPN 客户端在建立隧道后直接配置路由表和 TAP/TUN 驱动。

**关键区别：** 客户端 `route` 指令是在 OpenVPN 连接建立过程中由客户端进程直接执行，能正确配置 TAP/TUN 驱动。而手动 `route add`（Windows 命令行）只修改系统路由表，不通知 TAP/TUN 驱动，导致路由表正确但驱动不转发包。

**这也解释了之前的现象：**
- 手动 `route add` → 路由表正确（`Find-NetRoute` 显示 VPN 接口）但包不进隧道 ❌
- 客户端 `.ovpn` 加 `route` → 路由表正确 + TAP 驱动正确配置 → 包正常进隧道 ✅

### 最终解决方案

**所有 OpenVPN 客户端的 `.ovpn` 配置文件添加：**

```
route 192.168.199.0 255.255.255.0 vpn_gateway
```

此方式不依赖服务端 push、不受 GL-iNet 自定义路由模式影响、所有平台（Windows/Android/iOS）通用。

**验证结果（2026-04-13）：**

| 客户端 | 方式 | 结果 |
|--------|------|------|
| Win11 PC | `.ovpn` 加 route | ✅ ping 192.168.199.126 ~44ms |
| 手机 | `.ovpn` 加 route | ✅ ping 192.168.199.126 通 |

### 备选方案：Tailscale 直连

对于安装了 Tailscale 的设备，可以不走 OpenVPN，直接通过 Tailscale 子网路由访问 192.168.199.0/24。

**istoreos 配置：**

```bash
tailscale up --advertise-routes=192.168.199.0/24
```

在 [Tailscale Admin](https://login.tailscale.com/admin/machines) 批准 istoreos 的子网路由。

**设备配置：** 安装 Tailscale，登录 tailnet，确认 Use Tailscale Subnets 已勾选。

**结果：**

```
PC: ping 192.168.199.126 → 41ms (via DERP ali-bj-hb2)
```

### 两种方案对比

| | OpenVPN 方案 | Tailscale 方案 |
|--|--|--|
| 链路 | 设备 → OpenVPN → gl-mt2500-3 → Tailscale → istoreos → 目标 | 设备 → Tailscale → DERP → istoreos → 目标 |
| 延迟 | ~44ms | ~41ms |
| 配置 | 客户端 `.ovpn` 加 route | 安装 Tailscale + 勾选子网 |
| 依赖 | gl-mt2500-3 旁路由必须在线 | 仅依赖 DERP 和 istoreos |
| 适用 | 不便安装 Tailscale 的设备 | 能装 Tailscale 的设备（推荐） |

## 维护脚本

已编写交互式检查修复脚本 `gl-mt2500-network-check.sh`，存放于 `/home/dff652/文档/` 目录。

使用方式：`scp` 到软路由后执行，或通过 SSH：
```bash
ssh root@192.168.2.123 'sh -s' < /home/dff652/文档/gl-mt2500-network-check.sh
```
