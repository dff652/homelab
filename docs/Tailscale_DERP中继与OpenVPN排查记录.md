# Tailscale DERP 中继与 iStoreOS OpenVPN 排查记录

- 日期：2026-04-12
- 环境：GL-MT2500 (gl-mt2500-3) 家庭旁路由 ↔ iStoreOS (istoreos) 公司旁路由，通过 Tailscale 组网，自建 DERP 中继在阿里云 (bj-ali-hb2)

## 最终目标

| # | 目标 | 当前状态 |
|---|------|---------|
| 1 | **家庭 ↔ 公司互访**：22 服务器、gl-mt2500-3 能访问公司 Bitbucket (192.168.199.94:7990)、Ubuntu 服务器 (192.168.199.126) 等 | 已实现（通过 Tailscale + 策略路由） |
| 2 | **低延迟 DERP 中继**：自建国内 DERP（目标 < 20ms） | 未实现 — 自建 DERP 901 TLS 被阿里云阻断，当前走海外 DERP(nue) ~468ms |
| 3 | **稳定可靠**：不依赖 tunnel-in-tunnel 等临时方案 | 部分实现 — 已清除 OpenVPN 依赖，但 DERP 延迟过高 |

## 完整节点清单

### Tailscale 网络 (tailnet: dff652@)

| 节点名 | Tailscale IP | 系统 | 位置 | 用途 |
|--------|-------------|------|------|------|
| gl-mt2500-3 | 100.83.20.58 | Linux (OpenWrt) | 家庭 | 旁路由，OpenVPN 服务端，DNS/代理 |
| bj-ali-hb2 | 100.83.26.98 | Linux (Debian) | 阿里云北京 | DERP 中继服务器 |
| istoreos | 100.105.216.126 | Linux (iStoreOS) | 公司 | 旁路由 (PVE VM, 宿主 .243)，Docker |
| win-h2ti2vbr4q8 | 100.120.45.117 | Windows | 公司 | OpenVPN 客户端连家庭 |
| desktop-2brkgla-1 | 100.107.46.64 | Windows | 公司 | - |
| dff-workstation | 100.107.13.89 | Windows | 公司 | - |
| hp-400g2 | 100.117.142.59 | Windows | 公司 | - |
| gl-mt2500 | 100.82.21.34 | Linux | 家庭(旧) | offline |
| dff-nuc9 | 100.123.250.61 | Windows | 家庭 | offline |
| dff-unraid | 100.117.164.93 | Linux | 家庭 | offline |

### 关键 IP 地址

| 地址 | 归属 | 说明 |
|------|------|------|
| 192.168.2.1 | 家庭主路由 | 拨号上网，光猫桥接，同时也是旁路由网关 |
| 192.168.2.123 | gl-mt2500-3 (旁路由) | OpenVPN/Tailscale/ADG/OpenClash |
| 192.168.2.22 | 22 服务器 | 家庭工作站，网关指向 .123，运行 Claude Code |
| 192.168.100.1 | 公司主路由 | 详细信息不可获取 |
| 192.168.100.243 | PVE 宿主 | Proxmox VE 物理机，运行 istoreos VM |
| 192.168.100.244 | istoreos (旁路由 VM) | Tailscale/Docker，iStoreOS 24.10.4 |
| 192.168.199.0/24 | 公司服务器段 | 与 100 段的互通方式不明；Bitbucket (.94:7990), Ubuntu 服务器 (.126) |
| 10.8.0.0/24 | OpenVPN 隧道 | 服务端 gl-mt2500-3 (10.8.0.1) |
| 124.64.222.148 | 家庭公网出口 | 主路由 (192.168.2.1) 的公网 IP，所有家庭设备共享此出口 |
| 219.142.137.169 | 公司公网出口 | 公司 NAT 出口 |
| 39.102.98.79 | 阿里云 bj-ali-hb2 | DERP 中继服务器公网 IP |

### gl-mt2500-3 NAT 特征

```
MappingVariesByDestIP: true   ← 对称型 NAT，打洞困难
HairPinning: false
PortMapping: (无)
```

对称型 NAT 意味着 Tailscale 无法在家庭侧和公司侧之间直接打洞，必须依赖 DERP 中继。

### gl-mt2500-3 DNS/代理架构

详见同目录 `DNS链路方案_终极架构.md`：
- AdGuard Home (Port 53) → OpenClash (Port 7874, Fake-IP/TUN 模式) / dnsmasq (Port 5335)
- OpenClash TUN 模式通过策略路由劫持所有非本地流量

### istoreos 额外信息

- iStoreOS 24.10.4 (OpenWrt 衍生)
- 安装了 Docker (172.17.0.1)
- NodeBabyLink 接口 (100.66.1.2/32，飞鼠 VPN 相关)
- 已安装但已禁用：`luci-app-openvpn-client`, `openvpn-openssl`, `luci-app-feishuvpn`

### OpenVPN 服务端已知问题 (gl-mt2500-3)

`server.ovpn` 中 server 行格式异常（详见 Bitbucket 排查文档）：
```
# 当前（缺少网段地址，但 OpenVPN 正常运行）：
server  255.255.255.0
# 应为：
server 10.8.0.0 255.255.255.0
```
服务端推送 `redirect-gateway def1`，导致所有 OpenVPN 客户端的全部流量经过 VPN。DDNS 地址：`dff.x3322.net:5003`。

---

## 问题起因

在完成 Bitbucket 7990 端口排查（见同目录文档）后，执行 `tailscale status` 发现异常：

```
100.105.216.126 istoreos  dff652@  linux  active; direct 10.8.0.5:41641
```

istoreos 的 Tailscale 直连端点显示为 OpenVPN 隧道 IP `10.8.0.5`，而非公网 IP 或 DERP 中继。

> 注意：`tailscale ping 192.168.199.126` 也返回 `pong from istoreos`，这是因为 istoreos 通过 Tailscale 子网路由广播了 192.168.199.0/24 网段。192.168.199.126 本身是一台 Ubuntu 服务器，不是 istoreos。

同时健康检查报告：

```
# Health check:
#     - not connected to home DERP region 901
```

## 网络拓扑

### 完整链路图

```
                        ┌─────────────────────────────────────────┐
                        │          阿里云北京 (bj-ali-hb2)         │
                        │  39.102.98.79  TS: 100.83.26.98         │
                        │  DERP 中继 (derp.wcdz.tech:443)         │
                        │  STUN: UDP 3478                         │
                        │  ⚠ 当前 TLS 入站被 Anti-DDoS 阻断       │
                        └──────────┬──────────────────┬───────────┘
                              DERP TLS (不通)     DERP TLS (不通)
                                   │                    │
    ══════════════════════════════════════════════════════════════════
    ║  公网 (互联网)                                                ║
    ══════════════════════════════════════════════════════════════════
           │                                          │
     124.64.222.148                            219.142.137.169
     (家庭公网出口)                             (公司公网出口)
           │                                          │
    ┌──────┴──────────────────┐          ┌────────────┴────────────┐
    │  家庭主路由 192.168.2.1  │          │  公司主路由 192.168.100.1│
    │  光猫桥接，主路由拨号     │          │  (详细信息不可获取)      │
    │  同时也是旁路由的网关     │          │                         │
    └──────┬──────────────────┘          └────────────┬────────────┘
           │ 192.168.2.0/24                           │ 192.168.100.0/24
           │                                          │
    ┌──────┼──────────────────────┐    ┌──────────────┼───────────────────┐
    │      │                      │    │              │                   │
    │  ┌───┴────────────────┐     │    │  ┌───────────┴────────────┐      │
    │  │ gl-mt2500-3 (旁路由)│     │    │  │ PVE 宿主 192.168.100.243│     │
    │  │ 192.168.2.123      │     │    │  │ Proxmox VE              │     │
    │  │ TS: 100.83.20.58   │     │    │  │  ┌──────────────────┐   │     │
    │  │ OVPN Server: 10.8.0.1│   │    │  │  │istoreos (VM 旁路由)│  │     │
    │  │ DNS: ADG+OC+dnsmasq │    │    │  │  │192.168.100.244    │  │     │
    │  │ DDNS: dff.x3322.net │    │    │  │  │TS: 100.105.216.126│  │     │
    │  └───┬────────────────┘     │    │  │  │Docker, NodeBabyLink│ │     │
    │      │                      │    │  │  └──────────────────┘   │     │
    │  ┌───┴────────────────┐     │    │  └────────────────────────┘      │
    │  │ 22服务器            │     │    │                                  │
    │  │ 192.168.2.22       │     │    │  ┌──────────────────────┐        │
    │  │ 网关→192.168.2.123 │     │    │  │ win-h2ti2vbr4q8      │        │
    │  │ (Claude Code 运行处)│     │    │  │ OVPN Client: 10.8.0.4│       │
    │  └────────────────────┘     │    │  │ TS: 100.120.45.117   │        │
    │                             │    │  └──────────────────────┘        │
    └─────────────────────────────┘    │                                  │
                                       │  ┌──────────────────────┐        │
              OpenVPN 隧道              │  │ 192.168.199.0/24 网段 │       │
     gl-mt2500-3 ◄═══════════════════► │  │ (与100段的互通方式不明)│       │
     10.8.0.1        10.8.0.4          │  │ Bitbucket: .94:7990  │        │
     (DDNS: dff.x3322.net:5003)        │  │ Ubuntu:    .126      │        │
                                       │  └──────────────────────┘        │
              Tailscale WireGuard       └─────────────────────────────────┘
     gl-mt2500-3 ◄ ─ ─ DERP(nue) ─ ─ ► istoreos
     100.83.20.58     ~470ms延迟        100.105.216.126
```

### 旁路由工作方式

两端都是旁路由模式，不是主网关：

| | 家庭 gl-mt2500-3 | 公司 istoreos |
|--|--|--|
| 角色 | 旁路由 | 旁路由 (Proxmox VM) |
| IP | 192.168.2.123 | 192.168.100.244 |
| 主路由/网关 | 192.168.2.1 (拨号路由) | 192.168.100.1 (不可控) |
| 使用此旁路由的设备 | 手动设置网关为 .123 的设备（如 22 服务器） | 手动设置网关为 .244 的设备 |
| 功能 | DNS 过滤(ADG)、代理(OC)、VPN | Tailscale 组网、Docker |
| PVE 宿主 | N/A (物理设备 GL-iNet MT2500) | 192.168.100.243 |

---

## 排查过程一：10.8.0.5 是谁

### 1. 确认 OpenVPN 拓扑模式

```bash
root@GL-MT2500:~# grep -i topology /etc/openvpn/ovpn/server.ovpn
topology subnet
```

topology subnet 模式下每个客户端分配独立 IP，10.8.0.5 是一个独立客户端。

### 2. 查找 10.8.0.5 的来源

```bash
root@GL-MT2500:~# logread | grep "MULTI_sva: pool returned"
Sun Apr 12 14:50:41 2026 daemon.notice ovpnserver[4154]: OpenVpn client/219.142.137.169:51506 MULTI_sva: pool returned IPv4=10.8.0.5
```

10.8.0.5 从公网 IP 219.142.137.169（公司出口）连入。

### 3. SSH 确认设备身份

```bash
root@GL-MT2500:~# ssh root@10.8.0.5
```

SSH 进去后确认是 **iStoreOS 24.10.4**（即 istoreos），`ip addr` 显示：

```
14: tailscale0:  inet 100.105.216.126/32          ← Tailscale IP，确认是 istoreos
26: ovpn_cfg019277:  inet 10.8.0.5/24             ← luci-app-openvpn-client 建立的隧道
```

**结论：istoreos 上装了 OpenVPN 客户端，通过 DDNS `dff.x3322.net:5003` 连回家庭路由 gl-mt2500-3。**

### 4. 发现 istoreos 有两个 OpenVPN 进程

```bash
root@iStoreOS:~# ps | grep openvpn
 5895 root  /usr/sbin/openvpn --config myclient.conf          ← openvpn-opkg 基础包
32295 root  /usr/sbin/openvpn --cd /var/etc/openvpn-client/cfg019277 --config client.conf  ← luci-app-openvpn-client
```

两个进程连的都是同一个服务端 `dff.x3322.net:5003`，分别拿到 10.8.0.3 和 10.8.0.5。

### 5. Tailscale 走 OpenVPN 隧道的原因

Tailscale 的 NAT 穿透尝试多条路径。发现 10.8.0.5 ↔ 10.8.0.1 之间无 NAT、延迟低（~35ms），直接把 WireGuard 流量跑在了 OpenVPN 隧道上面（tunnel-in-tunnel）。

```
istoreos ──WireGuard──► 10.8.0.5 ──OpenVPN隧道──► 10.8.0.1 (gl-mt2500-3)
```

---

## 排查过程二：清理 istoreos 的 OpenVPN

### 1. 禁用 luci-app-openvpn-client

```bash
root@iStoreOS:~# /etc/init.d/luci-app-openvpn-client stop
root@iStoreOS:~# /etc/init.d/luci-app-openvpn-client disable
```

### 2. 禁用 openvpn-opkg

```bash
root@iStoreOS:~# /etc/init.d/openvpn stop
root@iStoreOS:~# /etc/init.d/openvpn disable
```

### 3. 重启 istoreos 并验证

重启后确认：
- 无 OpenVPN 进程
- 无 tun/ovpn 接口
- 两个服务均为 disabled
- `/etc/config/openvpn` 为空
- UCI 中 47 条 openvpn 条目均为 openvpn-opkg 包的默认示例配置，无影响

### 4. OpenVPN 清理后的 Tailscale 状态

```bash
root@GL-MT2500:~# tailscale status | grep istoreos
100.105.216.126 istoreos  dff652@  linux  active; relay "ali-bj-hb2", tx 2960 rx 0
```

Tailscale 已切换到 DERP 中继模式，但 `rx 0`（收不到回包）。

```bash
root@GL-MT2500:~# tailscale ping istoreos
pong from istoreos (100.105.216.126) via DERP(nue) in 492ms
```

走了 Nuremberg (德国) 的官方 DERP，延迟 ~492ms。自建 DERP 901 (ali-bj-hb2) 不可用。

---

## 排查过程三：DERP 901 为什么不通

### 1. DERP 服务状态

```bash
root@iZ2ze529wb7v0j0o3lfdu4Z:~# docker ps -a | grep derp
a9b60ec1e08f  fredliang/derper:latest  Up 2 weeks  0.0.0.0:80->80, 0.0.0.0:443->443, 0.0.0.0:3478->3478/udp  derper
```

容器运行正常，端口映射正常。

### 2. TLS 握手失败

DERP 容器日志全是 TLS 握手错误：

```
http: TLS handshake error from 124.64.222.148:44242: write tcp 172.17.0.2:443->124.64.222.148:44242: write: connection reset by peer
http: TLS handshake error from 219.142.137.169:5371: write tcp 172.17.0.2:443->219.142.137.169:5371: write: connection reset by peer
```

来自家庭（124.64.222.148）和公司（219.142.137.169）的 TLS 连接全部被 reset。

### 3. 从本机测试 TLS

```bash
# 从 bj-ali-hb2 本机（localhost）
root@iZ2ze529wb7v0j0o3lfdu4Z:~# echo | openssl s_client -connect 127.0.0.1:443 -servername derp.wcdz.tech
subject=CN = derp.wcdz.tech
issuer=C = US, O = Let's Encrypt, CN = E7
# ✅ 成功

# 从 bj-ali-hb2 通过公网 IP
root@iZ2ze529wb7v0j0o3lfdu4Z:~# echo | openssl s_client -connect 39.102.98.79:443 -servername derp.wcdz.tech
subject=CN = derp.wcdz.tech
issuer=C = US, O = Let's Encrypt, CN = E7
# ✅ 成功

# 从 gl-mt2500-3（外部）
root@GL-MT2500:~# curl -vk --connect-timeout 5 https://derp.wcdz.tech:443
OpenSSL SSL_connect: Connection reset by peer
# ❌ 失败
```

**本机 TLS 正常，外部 TLS 全部被 reset。**

### 4. 证书状态

Let's Encrypt 证书有效（2026-03-24 ~ 2026-06-22），certmode=letsencrypt，域名 `derp.wcdz.tech` DNS 正确解析到 `39.102.98.79`。证书不是问题。

### 5. 排除 iptables 干扰

```bash
# ts-input 链不影响普通 TCP 443 流量
root@iZ2ze529wb7v0j0o3lfdu4Z:~# iptables -L ts-input -n -v
  381K   20M DROP  !tailscale0  100.64.0.0/10   ← 只 DROP CGNAT 范围的非 tailscale 流量
  646 39120 ACCEPT udp dpt:41641                 ← ACCEPT tailscale WireGuard
# 其他流量 RETURN 到 INPUT chain (policy ACCEPT)

# derper 启动/停止前后 iptables 完全一致（只有时间戳差异）
root@iZ2ze529wb7v0j0o3lfdu4Z:~# diff /tmp/ipt_running.txt /tmp/ipt_stopped.txt
# 仅时间戳不同
```

### 6. 排除 OpenClash 干扰

在 gl-mt2500-3 上添加策略路由绕过 OpenClash TUN：

```bash
root@GL-MT2500:~# ip rule add to 39.102.98.79 lookup main prio 50
root@GL-MT2500:~# curl -vk --connect-timeout 5 https://derp.wcdz.tech:12345
# ❌ 仍然 Connection reset by peer
root@GL-MT2500:~# ip rule del to 39.102.98.79 lookup main prio 50
```

不是 OpenClash 的问题。

### 7. 关键发现：Go TLS vs OpenSSL TLS

停掉 derper 后，用 openssl s_server 在同端口测试：

```bash
root@iZ2ze529wb7v0j0o3lfdu4Z:~# docker stop derper
root@iZ2ze529wb7v0j0o3lfdu4Z:~# openssl s_server -accept 443 -cert /etc/nginx/derp.crt -key /etc/nginx/derp.key -www &
```

```bash
root@GL-MT2500:~# curl -vk --connect-timeout 5 https://39.102.98.79:443 2>&1 | head -10
TLSv1.3 (IN), TLS handshake, Server hello (2):
TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
TLSv1.3 (IN), TLS handshake, Certificate (11):
# ✅ 成功！
```

**openssl s_server 的 TLS 从外部能通，derper (Go TLS) 不能通。**

### 8. 进一步排除 nginx

安装 nginx 作为 TLS 反代（TLS 终结用 OpenSSL），代理到 derper:8080（HTTP）：

```bash
apt install -y nginx
# 配置 nginx -> proxy_pass http://127.0.0.1:8080
```

```bash
root@GL-MT2500:~# curl -vk --connect-timeout 5 https://derp.wcdz.tech:443
# ❌ Connection reset by peer（nginx 也被 reset）
```

nginx 也不通。但 nginx 同样使用 OpenSSL。

### 9. 发现真正规律：derper 进程在/不在

多次对比测试发现：

| 测试 | derper 容器 | TLS 服务 | 外部 TLS |
|------|------------|---------|---------|
| openssl s_server on 443 | 已停止(充分冷却) | openssl | ✅ 成功 |
| openssl s_server on 12345 | 已停止(充分冷却) | openssl | ✅ 成功 |
| nginx on 443 | 运行中(8080) | nginx | ❌ reset |
| nginx on 12345 | 已停止(刚停不久) | nginx | ❌ reset |
| socat on 12345 | 运行中(8080) | socat | ❌ reset |
| socat on 12345 | 运行中(8080,无STUN) | socat | ❌ reset |

> 注意："已停止(充分冷却)" 指停掉 derper 后等待了足够时间让 Anti-DDoS 解除封禁。"已停止(刚停不久)" 指 derper 近期运行过、封禁仍在生效中。openssl s_server 测试成功的关键不是 TLS 实现差异，而是测试时封禁恰好已冷却。

**规律：Anti-DDoS 封禁在 derper 相关连接风暴停止后需要一定冷却时间才解除。只有在充分冷却后，外部 TLS 才能恢复。**

### 10. 最终结论

**根因：阿里云 Anti-DDoS Basic（网络层面防护，默认启用）**

1. DERP 901 的 TLS 问题可能已存在较长时间（首次检查时健康检查就报 `not connected to home DERP region 901`）
2. Tailscale 客户端（gl-mt2500-3、istoreos 等）持续高频重试连接 DERP 901 的 TLS 端口
3. 这些连接全部失败（原始原因可能是 Go TLS 指纹被识别，或其他初始触发条件）
4. 大量失败的 TLS 连接触发了阿里云 Anti-DDoS 的速率限制/流量清洗
5. 一旦触发，**该 IP 的所有入站 TLS 连接**都被网络层面 reset（不经过服务器 iptables）
6. Tailscale 客户端继续重试 → 封禁持续刷新 → 形成死循环
7. 只有停掉所有服务、等待足够冷却时间后，封禁才短暂解除

**注意：** Anti-DDoS Basic 是网络层面的，不在服务器 iptables 中体现，也无法从服务器侧关闭。这也解释了为什么从服务器自身（localhost/公网IP回环）测试 TLS 总是成功——本机流量不经过 Anti-DDoS 设备。

### 11. STUN (UDP 3478) 不受影响

`tailscale netcheck` 始终显示 `ali-bj-hb2: 11.1ms`，因为 STUN 是 UDP 协议，不受 TLS 层面的封禁影响。这也是为什么 Tailscale 认为 DERP 901 "可达"但实际无法建立 TLS 连接的原因。

---

## 当前状态（2026-04-12 结束时）

### 连通性现状

```
tailscale ping istoreos → via DERP(nue) in ~468ms
tailscale netcheck:
  - ali-bj-hb2: 无延迟数据（STUN 已禁用，DERP map 端口设为 99999）
  - 最近官方 DERP: San Francisco 377ms, Nuremberg 586ms
  - MappingVariesByDestIP: true（对称 NAT，直连打洞不可行）
```

**当前家庭 ↔ 公司通信路径**：

```
gl-mt2500-3 → 公网 → Nuremberg DERP (德国) → 公网 → istoreos
   100.83.20.58                                  100.105.216.126
                        往返延迟 ~468ms
```

> 目标是 < 20ms（国内 DERP），当前 468ms，差距 20 倍以上。

### bj-ali-hb2 (39.102.98.79)

- **derper 容器**：运行中，`--network=host`，STUN 禁用，HTTP 端口 8080
- **socat**：运行中，监听 12345 端口，TLS 终结后转发到 derper:8080（但外部 TLS 不通）
- **nginx**：已安装，配置在 `/etc/nginx/sites-available/derp`（监听 12345 ssl），当前 stopped
- **证书**：Let's Encrypt (E7)，`/etc/nginx/derp.crt` + `/etc/nginx/derp.key`（从 `/root/derp/certs/derp.wcdz.tech` 提取），有效期至 2026-06-22
- **apt 源**：已从 `mirrors.cloud.aliyuncs.com` 改为 `mirrors.aliyun.com`（内网源不可用）
- **安全组**：TCP 443, 8443, 12345 和 UDP 3478 已放行

### Tailscale Access Controls (ACL)

配置位置：https://login.tailscale.com/admin/acls

当前 ACL policy 中的 derpMap 部分（临时禁用状态）：

```jsonc
{
    // ... 其他 ACL 规则 ...

    "derpMap": {
        "OmitDefaultRegions": false,
        "Regions": {
            "901": {
                "RegionID":   901,
                "RegionCode": "ali-bj-hb2",
                "RegionName": "Aliyun Beijing Relay",
                "Nodes": [
                    {
                        "Name":     "1",
                        "RegionID": 901,
                        "HostName": "derp.wcdz.tech",
                        "IPv4":     "39.102.98.79",
                        "DERPPort": 99999,
                    },
                ],
            },
        },
    },
}
```

> **DERPPort 当前设为 99999（临时禁用）**，原始值为 443。
> `OmitDefaultRegions: false` 表示保留 Tailscale 官方 DERP 节点（当前通过 nue 通信）。
> 需根据方案 A/B/C 决定恢复策略：方案 A 改为 12345，方案 B 删除整个 derpMap，方案 C 改为新服务器信息。

### istoreos

- OpenVPN 已完全清理（两个服务均 disabled，无进程、无接口）
- Tailscale 正常运行，通过 DERP(nue) 中继连接，延迟 ~468ms
- 功能正常，只是延迟高

### gl-mt2500-3

- OpenVPN 服务端仍运行（为 win-h2ti2vbr4q8 提供连接）
- OpenClash TUN 模式正常
- Tailscale 正常，通过 DERP(nue) 中继
- 到公司 192.168.199.0/24 的策略路由 + MASQUERADE 规则正常（Bitbucket 可访问）

---

## 下一步：三个解决方案

### 方案 A：长时间冷却后精确恢复自建 DERP

**思路**：等 Anti-DDoS 封禁完全解除后，用 socat (OpenSSL TLS) 替代 Go TLS，一次性成功建立连接。

**步骤**：
1. 停掉 bj-ali-hb2 上的 socat 和 derper：
   ```bash
   kill $(pgrep socat)
   docker stop derper
   ```
2. 确认 Tailscale ACL 中 DERPPort 设为 99999（已完成）
3. **等待 20-30 分钟**，让所有 Tailscale 客户端拉取新 DERP map + Anti-DDoS 完全冷却
4. 启动 derper（STUN 禁用，防止客户端探测到 DERP 存活后尝试连接）：
   ```bash
   docker start derper  # 之前创建的无 STUN 版本
   ```
5. 启动 socat TLS 终结：
   ```bash
   socat OPENSSL-LISTEN:12345,cert=/etc/nginx/derp.crt,key=/etc/nginx/derp.key,verify=0,reuseaddr,fork TCP:127.0.0.1:8080 &
   ```
6. 手动验证 TLS 可达：
   ```bash
   # 从 gl-mt2500-3
   curl -vk --connect-timeout 5 https://derp.wcdz.tech:12345
   ```
7. 确认成功后，修改 Tailscale ACL 的 DERPPort 为 12345，同时启用 STUN：
   ```bash
   docker stop derper && docker rm derper
   # 重新创建启用 STUN 的版本（DERP_STUN=true）
   ```
8. 监控 DERP 连接状态：
   ```bash
   tailscale status | grep istoreos
   tailscale ping istoreos
   ```

**优点**：延迟最低（~11ms），利用现有服务器
**缺点**：操作复杂，Anti-DDoS 可能再次触发（连接失败一次就可能重新封禁），socat 需持久化为 systemd 服务
**风险**：不确定冷却时间是否足够，Anti-DDoS 行为不可控

### 方案 B：接受官方 DERP，删除自建配置

**思路**：放弃自建 DERP 901，使用 Tailscale 官方 DERP 节点。

**步骤**：
1. 删除 Tailscale ACL 中的 `derpMap` 部分（或将 `OmitDefaultRegions` 保持 false，删除 `Regions.901`）
2. 停掉 bj-ali-hb2 上的 derper、socat、nginx：
   ```bash
   kill $(pgrep socat)
   docker stop derper && docker rm derper
   systemctl stop nginx && systemctl disable nginx
   ```
3. 验证 Tailscale 使用官方 DERP：
   ```bash
   tailscale ping istoreos
   # 预期：via DERP(nue) in ~470ms 或其他官方节点
   ```

**优点**：零维护，无 Anti-DDoS 风险，稳定可靠
**缺点**：延迟 ~470ms（最近的官方 DERP 在欧洲 Nuremberg），国内无官方节点
**适用场景**：对延迟不敏感的场景（SSH、git 操作等）

### 方案 C：迁移 DERP 到非阿里云服务器

**思路**：在没有 Anti-DDoS 干扰的服务器上部署 DERP。

**候选平台**：
- 腾讯云轻量应用服务器（国内，便宜）
- 华为云 ECS
- 其他国内小厂 VPS（Bandwagon 国内线路等）

**步骤**：
1. 在新服务器上部署 derper（可直接用 Go TLS，不需要 socat/nginx）：
   ```bash
   docker run -d --name derper --restart=always \
     -p 443:443 -p 3478:3478/udp -p 80:80 \
     -e DERP_DOMAIN=<新域名> \
     -e DERP_CERT_MODE=letsencrypt \
     -e DERP_ADDR=:443 \
     -e DERP_STUN=true \
     -e DERP_VERIFY_CLIENTS=false \
     registry.linkease.net:5443/fredliang/derper:latest
   ```
2. DNS 配置：将新域名 A 记录指向新服务器 IP
3. 更新 Tailscale ACL 的 DERP map：
   ```json
   "derpMap": {
       "OmitDefaultRegions": false,
       "Regions": {
           "901": {
               "RegionID": 901,
               "RegionCode": "custom",
               "RegionName": "Custom Relay",
               "Nodes": [{
                   "Name": "1",
                   "RegionID": 901,
                   "HostName": "<新域名>",
                   "IPv4": "<新IP>",
                   "DERPPort": 443
               }]
           }
       }
   }
   ```
4. 验证连接。

**优点**：彻底解决 Anti-DDoS 问题，低延迟（选国内节点可 < 20ms）
**缺点**：额外费用，需要新服务器，迁移工作量
**建议**：先测试新平台是否存在同样的 TLS 干扰问题（购买最低配 VPS 测试 derper TLS）

---

## 关键文件路径

| 文件 | 位置 | 说明 |
|------|------|------|
| derper 证书缓存 | bj-ali-hb2: `/root/derp/certs/` | Let's Encrypt ACME 证书 |
| nginx 证书 | bj-ali-hb2: `/etc/nginx/derp.crt`, `/etc/nginx/derp.key` | 从 ACME 缓存提取 |
| nginx 配置 | bj-ali-hb2: `/etc/nginx/sites-available/derp` | 端口 12345，TLS 反代到 8080 |
| derper docker 脚本 | bj-ali-hb2: `/tmp/r.sh` | 最后一次使用的启动命令 |
| OpenVPN 服务端 | gl-mt2500-3: `/etc/openvpn/ovpn/server.ovpn` | 仍为 win-h2ti2vbr4q8 提供服务 |
| 网络检查脚本 | 本项目: `scripts/check-network.sh` | Tailscale/OpenVPN/防火墙检查修复 |

## 问题清单

### 已解决

- [x] **10.8.0.5 身份确认**：是 istoreos 自身的 OpenVPN 客户端，通过 LuCI 插件 `luci-app-openvpn-client` 配置
- [x] **istoreos OpenVPN 清理**：两个 OpenVPN 服务（openvpn-opkg + luci-app-openvpn-client）均已 disabled 并验证无残留
- [x] **Tailscale tunnel-in-tunnel 消除**：Tailscale 不再走 OpenVPN 隧道，已切换到 DERP 中继
- [x] **Bitbucket 7990 访问**：通过策略路由 + MASQUERADE 解决（见 Bitbucket 排查文档）
- [x] **OpenVPN push route 缺失**：已添加 `push "route 192.168.199.0 255.255.255.0"` 到 server.ovpn
- [x] **rc.local exit 0 顺序问题**：已修复，规则移到 exit 0 之前

### 已验证/已排除

- [x] **DERP 证书有效**：Let's Encrypt E7，2026-03-24 ~ 2026-06-22，域名 DNS 正确
- [x] **DERP 服务本身正常**：从服务器本机（localhost 和公网 IP 回环）TLS 握手成功
- [x] **iptables 无干扰**：tailscale 的 ts-input 链不影响普通 TCP 入站；derper 启停前后 iptables 完全一致
- [x] **OpenClash 不是原因**：绕过 OpenClash TUN 后外部 TLS 仍然被 reset
- [x] **STUN (UDP 3478) 正常**：netcheck 显示 11.1ms，UDP 不受影响
- [x] **端口无关**：443、8443、12345 端口均表现一致
- [x] **Go TLS vs OpenSSL**：停掉所有服务后 openssl s_server 可从外部连通，确认 OpenSSL TLS 链路无问题
- [x] **nginx TLS 指纹**：nginx 即使在 derper 停止状态下也被 reset（可能被 DPI 识别）

### 发现的线索

- **derper 进程相关性**：derper 容器运行时，同机器的任何 TLS 服务（nginx/socat）均被外部 reset；停掉后等待冷却，openssl s_server 可通
- **Anti-DDoS Basic 疑似触发**：阿里云网络层面防护，不在 iptables 中体现，无法从服务器侧关闭
- **双因素干扰**：可能同时存在 (1) TLS 指纹识别 + (2) 连接风暴触发速率限制
- **本机流量免疫**：从服务器自身测试 TLS 始终成功（不经过 Anti-DDoS 设备）
- **DERP 问题早于本次操作**：首次 `tailscale status` 就报告 `not connected to home DERP region 901`

### 未解决 — 按优先级排序

**P0（阻塞最终目标）**：
- [ ] **DERP 901 外部 TLS 不通**：阿里云 Anti-DDoS 阻断入站 TLS。当前家庭 ↔ 公司走海外 DERP(nue) 延迟 ~468ms，远超目标 < 20ms。需选择方案 A/B/C 解决。

**P1（影响稳定性/安全性）**：
- [ ] **OpenVPN 客户端证书泄露**：istoreos 的私钥和 TLS 密钥在终端输出，需在 gl-mt2500-3 上重新生成 OpenVPN 客户端配置
- [ ] **Let's Encrypt 证书续期**：当前证书 2026-06-22 到期，derper 已不在 443 端口运行，autocert 续期可能失败
- [ ] **阿里云 Anti-DDoS 具体机制不明**：无法确定冷却时间、触发阈值、是否可在控制台查看清洗记录或调整策略

**P2（技术债务）**：
- [ ] **server.ovpn server 行格式异常**：`server  255.255.255.0` 缺少网段地址，固件升级后可能出问题
- [ ] **firewall.user 规则幂等化**：rc.local 和 firewall.user 中的 ip rule/iptables 规则应改为先删再加（见 Bitbucket 排查文档）
- [ ] **socat 未持久化**：当前以后台进程运行，重启丢失。如选方案 A 需配置为 systemd 服务
- [ ] **bj-ali-hb2 残留服务清理**：derper (无 STUN) + socat + nginx 均在运行/安装状态，需根据最终方案决定保留或清理

---

## 第二轮排查：自动化诊断实验（2026-04-12 晚）

### 背景

针对 P0 问题"DERP 901 外部 TLS 不通"，设计了自动化对照实验脚本，在 bj-ali-hb2（服务端）和 gl-mt2500-3（客户端）上交互执行。

### Anti-DDoS 排除验证

**阿里云控制台确认：**

| 项目 | 值 |
|------|------|
| 实例 ID | facae0627cb94c3d8527a4dd3a573ecc |
| 状态 | 正常 |
| 防护类型 | DDoS 基础防护 |
| 清洗阈值 | bps 200M / pps 200K |
| 清洗/黑洞事件 | **无** |

**tcpdump 抓包验证（排除 Anti-DDoS 前）：**

```bash
# bj-ali-hb2（443 端口未监听状态）
root@iZ2ze529wb7v0j0o3lfdu4Z:~# tcpdump -i eth0 -nn 'host 124.64.222.148 and port 443' -c 20

# 结果：SYN 包到达服务器，服务器回 RST（端口无服务）
124.64.222.148.41560 > 172.25.0.148.443: Flags [S]       ← SYN 到达
172.25.0.148.443 > 124.64.222.148.41560: Flags [R.]      ← 服务器自己回 RST

# gl-mt2500-3 对应的报错
curl: (7) Failed to connect to derp.wcdz.tech port 443: Connection refused
```

**结论：Anti-DDoS 从未被触发，SYN 包完整到达服务器。原"Anti-DDoS 阻断 TLS"结论被推翻。**

### 实验设计（6 组对照实验）

| # | 服务端 443 | 服务端 8080 | 控制变量 | 验证目标 |
|---|------------|------------|----------|----------|
| 1 | nc（纯 TCP） | - | TCP 基线 | 端口连通性 |
| 2 | openssl s_server | - | TLS 基线 | 最简 TLS 能否握手 |
| 3 | derper (Go TLS) | - | 核心问题 | Go TLS 是否被干扰 |
| 4 | openssl s_server | derper (HTTP) | 进程隔离 | derper 后台运行是否干扰别的 TLS |
| 5 | socat → 8080 | derper (HTTP) | 方案验证 | socat TLS 终结能否端到端工作 |
| 6 | nc 12345（纯 TCP） | derper (HTTP) | 交叉验证 | derper 存在时 TCP 是否正常 |

脚本位于 `scripts/derp-diag-server.sh`（服务端）和 `scripts/derp-diag-client.sh`（客户端）。

### 第一轮执行结果（v1 脚本，有 bug）

**脚本缺陷导致实验结果全部作废：**

`nc` 使用 `while true; do nc -l -p 443; done &` 循环，实验间清理时只杀了子进程但循环立即重生，导致 nc 僵尸进程始终霸占 443 端口。

服务端日志证据：

```
# 实验 2 端口状态（应只有 openssl，实际 nc 还在）
LISTEN 0  1  0.0.0.0:443  users:(("nc",pid=50640,fd=3))   ← nc 僵尸
LISTEN 0  1  0.0.0.0:443  users:(("nc",pid=50617,fd=3))   ← nc 僵尸

# 实验 3 derper 启动失败
derper: listen tcp :443: bind: address already in use
Exited (1) 5 seconds ago
```

6 个实验实际全在测 nc 回的纯文本 `DERP_DIAG_TCP_OK_EXP1\n`（22 字节），curl 收到非 TLS 数据后报错：
- 用 IP 连接：`ssl3_get_record:wrong version number`（收到纯文本而非 TLS）
- 用域名连接：`Connection reset by peer`

**客户端脚本额外 bug：** busybox nc 不支持 `-w` 参数，导致实验 1/6 的 TCP 测试直接失败；`logrun` 通过 pipe 到 tee 丢失了 curl 真实退出码（始终返回 0）。

### 第一轮有效成果

虽然对照实验作废，但 pcap 和控制台数据提供了三个确定性结论：

| 结论 | 证据 | 状态 |
|------|------|------|
| **Anti-DDoS 不是原因** | 控制台无清洗事件；阈值 200Mbps 远超实际流量；pcap 中 SYN 到达服务器 | **确认** |
| **网络链路完全正常** | pcap 显示 TCP 三次握手成功，nc 的 22 字节被客户端收到，数据双向传输正常；ping RTT 8ms | **确认** |
| **IPv6 两端不可用** | 家庭：OpenClash 关闭了 IPv6，无全局地址；公司：仅 Tailscale ULA 地址 `fd7a:` | **确认** |

### 第一轮新发现的状态变化

| 项目 | 原文档记录 | 实际最新状态 |
|------|-----------|-------------|
| Let's Encrypt 证书 | 2026-03-24 ~ 2026-06-22 | **已自动续期**: 2026-04-12 ~ 2026-07-11 |
| Nearest DERP | Nuremberg (nue) ~470ms | San Francisco (sfo) 348ms（最近官方节点有变化） |
| bj-ali-hb2 额外服务 | - | 发现 `kspeeder` 进程监听 5443/5003 端口 |

### 第一轮需修正的原有结论

以下原文档中的已验证/已排除项需要重新评估：

- [x] ~~**OpenClash 不是原因**~~：原测试仅用 `ip rule` 绕过路由，但 OpenClash TUN 模式通过 iptables MARK 劫持流量，`ip rule` 可能不够。**待第二轮验证。**
- [x] ~~**derper 进程相关性**~~：原观察（derper 在运行时其他 TLS 也不通）可能是 nc 僵尸进程的干扰，而非 derper 真的影响了其他服务。**待第二轮验证。**

### v2 脚本修复

1. nc 改为单次执行（不用 while 循环），杀即死
2. 新增 `nuke_port()` 函数：`fuser -k -9` + ss PID 提取 + pkill 三重清理
3. 每个实验前 `assert_port_free` 断言端口为空，启动后 `assert_port_held_by` 验证正确进程监听
4. 客户端 nc 兼容 busybox（去掉 `-w` 参数）
5. 客户端 curl 退出码改用 `$()` 捕获（不再经过 tee pipe）

### 第二轮测试计划

**核心问题：derper Go TLS 从外部到底能不能连？（上一轮因端口冲突未得到答案）**

#### 步骤 1：v2 脚本 6 组对照实验

```bash
# 部署（从 22 服务器）
scp scripts/derp-diag-server.sh root@39.102.98.79:/tmp/
scp scripts/derp-diag-client.sh root@192.168.2.123:/tmp/

# 终端 B — 阿里云服务端
ssh root@39.102.98.79 'sh /tmp/derp-diag-server.sh'

# 终端 C — 家庭路由客户端
ssh root@192.168.2.123 'sh /tmp/derp-diag-client.sh'
```

**验收标准：** 每个实验开始前服务端日志必须有 `[ OK ] 端口 443 已清空`，实验 3 derper 日志不能有 `address already in use`。

#### 步骤 2：根据结果决策

| 实验 2 (openssl) | 实验 3 (derper) | 判定 | 执行步骤 3 的内容 |
|---|---|---|---|
| 通 | 通 | derper 正常，之前问题已自愈 | 跳到步骤 4 恢复 DERP |
| 通 | 不通 | Go TLS 被干扰（DPI 或 OpenClash） | 步骤 3A + 3B |
| 不通 | 不通 | 客��端侧有问题（大概率 OpenClash） | 步骤 3A |
| 不通 | 不通 且 实验 5 通 | socat 方案可行 | 步骤 3C |

#### 步骤 3A：OpenClash 排除测试（如果实验 2 或 3 不通）

在 gl-mt2500-3 上临时关闭 OpenClash，用同样的 curl 命令重测：

```bash
# gl-mt2500-3 — 关闭 OpenClash（影响：该路由下所有设备暂时无法翻墙）
/etc/init.d/openclash stop

# 重测实验 2 的场景（服务端需提前启动 openssl s_server）
curl -vk --connect-timeout 5 https://39.102.98.79:443
curl -vk --connect-timeout 5 https://derp.wcdz.tech:443

# 重测实验 3 的场景（服务端需启动 derper on 443）
curl -vk --connect-timeout 5 https://39.102.98.79:443
curl -vk --connect-timeout 5 https://derp.wcdz.tech:443

# 恢复 OpenClash
/etc/init.d/openclash start
```

**判断：**
- 关 OpenClash 后全通 → **OpenClash 是根因**，需配置白名单或旁路规则
- 关 OpenClash 后仍不通 → 排除 OpenClash，问题在��务端或链路中间设备

#### 步骤 3B：从其他设备交叉验证（如果需要进一步隔离）

从 22 服务器（192.168.2.22，网关指向 gl-mt2500-3）或手机热点直接测试，排除 gl-mt2500-3 本机环境的干扰：

```bash
# 22 服务器（走 gl-mt2500-3 旁路由出网）
curl -vk --connect-timeout 5 https://39.102.98.79:443
curl -vk --connect-timeout 5 https://derp.wcdz.tech:443

# 如果 22 服务器也不通，临时改网关直连主路由绕过旁路由：
sudo ip route replace default via 192.168.2.1 dev eth0
curl -vk --connect-timeout 5 https://derp.wcdz.tech:443
# 测完恢复
sudo ip route replace default via 192.168.2.123 dev eth0
```

#### 步骤 3C：socat 方案部署（如果实验 5 验证通过）

```bash
# bj-ali-hb2 上部署
# 1. derper HTTP 模式
docker run -d --name derper --restart=always --network=host \
    -e DERP_DOMAIN=derp.wcdz.tech \
    -e DERP_CERT_MODE=letsencrypt \
    -e DERP_ADDR=:8080 \
    -e DERP_STUN=true \
    -e DERP_VERIFY_CLIENTS=false \
    registry.linkease.net:5443/fredliang/derper:latest

# 2. socat TLS 终结（持久化为 systemd 服务）
cat > /etc/systemd/system/derp-tls.service <<'EOF'
[Unit]
Description=DERP TLS termination (socat)
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/socat OPENSSL-LISTEN:443,cert=/etc/nginx/derp.crt,key=/etc/nginx/derp.key,verify=0,reuseaddr,fork TCP:127.0.0.1:8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now derp-tls
```

#### 步骤 4：恢复 DERP ACL 并验证端到端

```bash
# 修改 Tailscale ACL (https://login.tailscale.com/admin/acls)
# DERPPort: 99999 → 443（或实验 5 场景下仍为 443）

# 等待 2-3 分钟让所有节点拉取新 DERP map

# gl-mt2500-3 验证
tailscale netcheck                    # 确认 ali-bj-hb2 有延迟数据
tailscale ping istoreos               # 期望: via DERP(ali-bj-hb2) in <20ms
tailscale ping bj-ali-hb2             # 期望: direct 或 via DERP <20ms

# istoreos 验证
tailscale ping gl-mt2500-3            # 期望: via DERP(ali-bj-hb2) in <20ms
```

**最终目标验收：** `tailscale ping istoreos` 延迟从 ~468ms 降至 <20ms。

---

## 问题清单（更新）

### 已解决

- [x] **10.8.0.5 身份确认**：是 istoreos 自身的 OpenVPN 客户端
- [x] **istoreos OpenVPN 清理**：两个 OpenVPN 服务均已 disabled
- [x] **Tailscale tunnel-in-tunnel 消除**：已切换到 DERP 中继
- [x] **Bitbucket 7990 访问**：通过策略路由 + MASQUERADE 解决
- [x] **OpenVPN push route 缺失**：已添加
- [x] **rc.local exit 0 顺序问题**：已修复
- [x] **Anti-DDoS 排除**：控制台确认状态正常，pcap 证实 SYN 到达服务器（第二轮新增）

### 已验证/已排除

- [x] **DERP 证书有效**：Let's Encrypt E7，已自动续期至 2026-07-11
- [x] **iptables 无干扰**：derper 启停前后 iptables 仅时间戳差异
- [x] **STUN (UDP 3478) 正常**：netcheck 显示正常
- [x] **网络链路正常**：pcap 证实 TCP 三次握手成功、数据双向传输（ping 8ms）
- [x] **IPv6 不可用**：家庭无全局 IPv6（OpenClash 关闭），公司仅 Tailscale ULA

### 需重新验证（原结论可能有误）

- [ ] **OpenClash 是否干扰 TLS**：原测试用 `ip rule` 绕过不够充分，TUN 模式通过 iptables 劫持。需关闭 OpenClash 后重测
- [ ] **derper 进程是否干扰同机 TLS**：原观察可能被 nc 僵尸进程污染。需第二轮干净实验验证
- [ ] **Go TLS vs OpenSSL**：原结论"openssl 通、derper 不通"需在端口干净的条件下重新验证

### 未解决 — 按优先级排序

**P0（阻塞最终目标）**：
- [ ] **DERP 901 外部 TLS 不通**：根因待定（Anti-DDoS 已排除，可能是 OpenClash 劫持或 Go TLS 被 DPI 干扰）。当前家庭 ↔ 公司走海外 DERP 延迟 ~348-468ms，远超目标 < 20ms。

**P1（影响稳定性/安全性）**：
- [ ] **OpenVPN 客户端证书泄露**：istoreos 的私钥和 TLS 密钥在终端输出，需��新生成
- [ ] **Let's Encrypt 证书续期机制**：证书已续期（~2026-07-11），但 derper 不在 443 端口运行时 autocert 续期路径需确认

**P2（技术债务）**：
- [ ] **server.ovpn server 行格式异常**：`server  255.255.255.0` 缺少网段地址
- [ ] **firewall.user 规则幂等化**
- [ ] **bj-ali-hb2 残留服务清理**：derper + socat + nginx + kspeeder (5443/5003)
- [ ] **bj-ali-hb2 安全扫描暴露面大**：pcap 显示大量外部 IP（5.x/23.x/45.x）扫描 443 端口

---

## 安全提醒

排查过程中 istoreos 的 OpenVPN 客户端配置（含私钥和 TLS 密钥）被输出到终端。建议在 gl-mt2500-3 上**重新生成 OpenVPN 客户端证书**：

```
GL-iNet 管理界面 → VPN → OpenVPN Server → 重新生成客户端配置
```

重新生成后，需要将新的 `client.ovpn` 重新分发给 win-h2ti2vbr4q8。
