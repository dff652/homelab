# GitHub Fake-IP 与 SSH/HTTPS 双通道排查记录

**日期**：2026-04-25
**环境**：pve-vm100-ubu (Ubuntu 24.04，PVE VM) → GL-MT2500 旁路由 (OpenClash + AdGuardHome) → ISP
**性质**：跨设备问题（症状在 VM，根因在路由器）
**前情提要**：[router/docs/GitHub_HTTPS推送失败排查记录.md](../router/docs/GitHub_HTTPS推送失败排查记录.md) (2026-04-14)
**关键结论**：⚠️ **本次结论与前次相反**——前次推荐 `,DIRECT`，本次推荐 `,代理组`

---

## 0. TL;DR

新部署的 PVE VM 内：
- `git clone https://github.com` 报 `gnutls_handshake() failed`
- 切换到 SSH 后 `ssh -T git@github.com` 报 `Connection closed by 198.18.0.88 port 443`
- 浏览器访问 GitHub 不稳定

根因是**两个独立配置层互相冲突**：
- DNS 层：OpenClash Fake-IP Filter 中没有 `github.com` → 解析返回假 IP `198.18.x.x` → SSH（无 SNI）无法被路由
- 规则层：OpenClash 规则把 GitHub 设为 `,DIRECT`（沿用 4 月 14 日方案）→ 即使把 github 加入 Fake-IP Filter 拿到真实 IP，HTTPS 也会被 GFW 在 TLS 握手阶段 RST

最终方案（**与前次相反**）：
1. **保留** `github.com` 在 Fake-IP Filter 中（让 SSH 拿真实 IP，对 GFW 友好）
2. **移除** GitHub 域名的 `,DIRECT` 规则，改为 `,代理组` + IP-CIDR 兜底
3. 启用 SNI Sniffer

---

## 1. 故障现象

### 1.1 HTTPS git clone

```
$ git clone https://github.com/dff652/hermes-agent.git
fatal: 无法访问 'https://github.com/dff652/hermes-agent.git/'：
gnutls_handshake() failed: The TLS connection was non-properly terminated.
```

### 1.2 切到 SSH 后

```
$ ssh -T git@github.com
Connection closed by 198.18.0.88 port 443
```

`198.18.0.0/15` 是 RFC 2544 保留段，被 Clash 系（包括 OpenClash）用作 **fake-IP 池**。`Connection closed` 代表 OpenClash 接到了流量但无法识别，直接关闭。

### 1.3 浏览器

`https://github.com` 时通时断（约 30% 成功率），大量 `ERR_CONNECTION_RESET` 与 `ERR_SSL_PROTOCOL_ERROR`。

---

## 2. 环境与既有配置

### 2.1 PVE VM (pve-vm100-ubu)
| 项 | 值 |
|---|---|
| OS | Ubuntu 24.04 |
| Git TLS 后端 | `libcurl-gnutls.so.4` + `libgnutls.so.30` |
| curl TLS 后端 | OpenSSL（与 git 不同，但本次都失败） |
| 默认网关 | MT2500 旁路由 |
| 本机代理监听 | 无（流量必经路由器） |

### 2.2 MT2500 既有 OpenClash 配置
- Fake-IP 模式 + TUN
- 自定义规则中沿用前次方案：
  ```yaml
  - DOMAIN-SUFFIX,github.com,DIRECT
  - DOMAIN-SUFFIX,githubusercontent.com,DIRECT
  - DOMAIN-SUFFIX,githubassets.com,DIRECT
  - DOMAIN-SUFFIX,github.io,DIRECT
  ```
- **github.com 不在** Fake-IP Filter 中

---

## 3. 排查过程

### 3.1 既有诊断脚本盲区

[`pve/codex/codex_net_fix.sh`](../pve/codex/codex_net_fix.sh) 只测了 `auth.openai.com` / `api.openai.com`，**没测 GitHub**，所以一开始无法用脚本复现。

**修复**：在 `diagnose_conn` 中追加：
- GitHub DNS 解析（`getent ahosts github.com`、`codeload.github.com`）
- `curl -I https://github.com` HTTPS 握手测试
- `ldd git-remote-http` 检测 git 链接的是 GnuTLS 还是 OpenSSL（决定 TLS 兼容性）
- `git ls-remote https://github.com/git/git.git HEAD` 真实拉取测试（与 `git clone` 走完全相同的 TLS 栈，比 curl HEAD 更接近实战）

并在 `print_conn_conclusion` 中加入双探针判定逻辑：
- curl OK + git OK → 完全可用
- curl OK + git 失败 → GnuTLS 在握手途中被 RST（典型 GFW 行为）
- 都失败 → DNS 污染 / TLS SNI 阻断 / 出口拦截

### 3.2 SSH 切换尝试与 fake-IP 发现

按计划生成 ed25519 key、配置 `~/.ssh/config` 走 `ssh.github.com:443`，结果：

```
ssh -T git@github.com
Connection closed by 198.18.0.88 port 443
```

进一步验证：
```
$ getent ahosts ssh.github.com
198.18.11.208   STREAM ssh.github.com

$ getent ahosts github.com
198.18.7.95     STREAM github.com

$ dig +short @8.8.8.8 ssh.github.com
198.18.11.208            ← 注意：直接查 8.8.8.8 也返回假 IP
```

⚠️ **关键观察**：`dig @8.8.8.8` **也**返回 fake-IP，说明 DNS 劫持在**上游路由器**做（OpenClash 的 DNS 劫持是网关级 53/UDP 劫持，本机绕不开）。

### 3.3 用 DoH 拿到真实 IP

```bash
curl -s -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=ssh.github.com&type=A'
# → 140.82.116.36

curl -s -H 'accept: application/dns-json' \
  'https://1.1.1.1/dns-query?name=github.com&type=A'
# → 140.82.116.4
```

DoH 走 HTTPS 加密通道，绕开了网关级 UDP/53 劫持。

### 3.4 SSH 失败的根本原因

- Clash Fake-IP 模式：DNS 返回 198.18.x.x，TUN 拦截到此假 IP → Clash 嗅探流量决定如何路由
- HTTPS：握手包带 SNI = `github.com` → Clash 嗅探到 → 命中 `DOMAIN-SUFFIX,github.com,DIRECT` → 走直连
- **SSH：协议头是 `SSH-2.0-...`，没有 SNI** → Clash 无法识别域名 → 找不到匹配规则 → fallback 行为（不同 Clash 实现可能：fake-IP 反查、IP-CIDR、MATCH 兜底，或直接关闭连接）→ 本例直接关闭

### 3.5 把 github 加入 Fake-IP Filter（解 SSH）

在 OpenClash → DNS 设置 → Fake-IP Filter 中追加：
```
+.github.com
+.githubusercontent.com
```

刷新 DNS 后：
```
$ getent ahosts ssh.github.com
140.82.116.35   STREAM ssh.github.com    ← 真实 IP

$ ssh -T git@github.com
Hi dff652! You've successfully authenticated...    ← ✅ 通了
```

SSH 解决：拿到真实 IP，连接到 `ssh.github.com:443`，GFW 对 SSH-on-443 默认放行（这是 GitHub 官方为大陆用户准备的备用通道）。

### 3.6 但 HTTPS 同时崩了

```
$ curl -I https://github.com
curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL

$ git ls-remote https://github.com/dff652/homelab.git HEAD
fatal: gnutls_handshake() failed: The TLS connection was non-properly terminated.
```

链路分析：
- DNS 拿到真实 IP 140.82.116.4（Filter 生效）
- 流量进入 OpenClash → 命中规则 `DOMAIN-SUFFIX,github.com,DIRECT` → 直连出网关
- 直连流量出口 IP 在大陆 → 撞 GFW → TLS ClientHello 中 `SNI = github.com` 被实时检测 → RST 注入

**这就是与 4 月 14 日结论的反转点**：之前 `,DIRECT` 可用，是因为当时的网络出口/GFW 状态允许直连握手；今天直连必败。

### 3.7 最终方案：删 DIRECT，改走代理

把 OpenClash 自定义规则中的 4 条 `,DIRECT` 改为 `,代理组`，并补 IP-CIDR 兜底（覆盖无 SNI 场景），见下节。

---

## 4. 最终配置

### 4.1 OpenClash → DNS 设置 → Fake-IP Filter（保留）

```
+.github.com
+.githubusercontent.com
```

> `+.` 为 Clash 通配语法，匹配该域名及所有子域。**保留这条** 是 SSH 拿真实 IP 的必要前提。

### 4.2 OpenClash → 覆写设置 → 自定义规则（替换原 4 条 DIRECT）

```yaml
# === GitHub: 走代理（HTTPS、SSH 全覆盖）===
- DOMAIN-SUFFIX,github.com,🚀 节点选择
- DOMAIN-SUFFIX,githubusercontent.com,🚀 节点选择
- DOMAIN-SUFFIX,githubassets.com,🚀 节点选择
- DOMAIN-SUFFIX,github.io,🚀 节点选择
- DOMAIN-SUFFIX,githubapp.com,🚀 节点选择

# IP 段兜底（无 SNI 时由 IP 命中；对 SSH 关键）
- IP-CIDR,140.82.112.0/20,🚀 节点选择,no-resolve
- IP-CIDR,143.55.64.0/20,🚀 节点选择,no-resolve
- IP-CIDR,185.199.108.0/22,🚀 节点选择,no-resolve
- IP-CIDR,192.30.252.0/22,🚀 节点选择,no-resolve
```

> 把 `🚀 节点选择` 替换为你实际的代理组名。**位置必须在订阅规则之前**（OpenClash 的"自定义规则前置"区域），否则可能被订阅里的 DIRECT 规则抢先匹配。

### 4.3 OpenClash → 覆写设置 → 实验性

启用 **SNI Sniffer**（让 HTTPS 即使解析到真实 IP，仍能匹配 DOMAIN 规则）。

---

## 5. 验证

```bash
# 1. HTTPS curl
curl -I --max-time 10 https://github.com
# 期望: HTTP/2 200

# 2. HTTPS git ls-remote
git ls-remote https://github.com/dff652/homelab.git HEAD
# 期望: 返回 commit SHA

# 3. SSH
ssh -T git@github.com
# 期望: Hi dff652! You've successfully authenticated...

# 4. DNS（验证 Fake-IP Filter 仍生效）
getent ahosts github.com | head -1
# 期望: 140.82.116.x（真实 IP），不是 198.18.x.x

# 5. 稳定性（连续 5 次）
for i in 1 2 3 4 5; do
  curl -o /dev/null -s --max-time 8 -w "$i: HTTP %{http_code}\n" https://github.com
done
# 期望: 5/5 都是 200
```

本次实测：5/5 全部 200，无抖动。

---

## 6. 关键心智模型

> **Fake-IP Filter 决定"DNS 给真假 IP"，OpenClash 规则决定"流量走代理还是直连"。两者互相独立，必须分别配置。**

| 协议 | DNS 需求 | 路由需求 | 当前实现 |
|---|---|---|---|
| **SSH (443)** | 需要真实 IP（无 SNI 嗅探，假 IP 找不到回路） | 走代理或直连均可，GFW 对 SSH-443 放行 | Fake-IP Filter 给真实 IP + IP-CIDR 兜底走代理 |
| **HTTPS** | 真假 IP 都行（有 SNI 可嗅探） | **必须走代理**（直连撞 GFW SNI 阻断） | DOMAIN-SUFFIX 走代理（靠 SNI Sniffer） |

GitHub 同时需要 SSH 和 HTTPS 都通，所以这两层都得对齐：DNS 给真实 IP（救 SSH）+ 流量走代理（救 HTTPS）。

---

## 7. 与 4 月 14 日方案的对比

| 维度 | 4 月 14 日（dff652-gpu, Ubuntu 22.04） | 本次（pve-vm100-ubu, Ubuntu 24.04） |
|---|---|---|
| Fake-IP Filter 含 GitHub | ❌ 不加 | ✅ 加 |
| OpenClash 规则 | `DIRECT` | `代理组` |
| 当时直连 GitHub | 可达 | 撞 GFW，TLS 被 RST |
| 当时代理转发 GitHub | 不稳定 | 稳定 |

**反转的可能原因**：
- GFW 状态变化（SNI 阻断策略调整）
- 网络出口路径不同（不同 VM 走不同 NAT/路由）
- 代理节点稳定性变化（4 月初的不稳定节点已替换）

**启示**：直连 vs 代理的选择**不是恒定真理**，依赖当前 GFW 与代理节点的状态。建议每次出现 GitHub 访问异常时重新跑一次 [`pve/codex/codex_net_fix.sh diagnose`](../pve/codex/codex_net_fix.sh)（含本次新增的 GitHub 检测块）做一次现状判定。

---

## 8. 影响范围

- **所有经 MT2500 网关的设备**：本次 OpenClash 规则改动是路由器侧配置，对全网生效
- **PVE 内多个 VM**：同样路径，同样症状
- **OpenVPN 客户端**：经过 MT2500 出网的客户端同样受益
- **后续部署的新 VM**：DNS 路径相同，无需各自做客户端修复

---

## 9. 工具引用

- [`pve/codex/codex_net_fix.sh`](../pve/codex/codex_net_fix.sh) —— 含本次新增的 GitHub TLS / git ls-remote 双探针检测
- [`router/scripts/diag-github.sh`](../router/scripts/diag-github.sh) —— 路由器侧的 GitHub 链路诊断
- [`router/docs/GitHub_HTTPS推送失败排查记录.md`](../router/docs/GitHub_HTTPS推送失败排查记录.md) —— 4 月 14 日的前次记录（结论已被本次推翻）
- [`router/docs/DNS链路方案_终极架构.md`](../router/docs/DNS链路方案_终极架构.md) —— DNS 链路全景

---

## 10. 待办与优化方向

- [ ] 周期性验证：每 30 天跑一次 `pve/codex/codex_net_fix.sh diagnose-github`，监控直连 vs 代理状态变化
- [x] ~~把 §5 的 5 项检查脚本化~~ → 已落地为 [`pve/codex/codex_net_fix.sh diagnose-github`](../pve/codex/codex_net_fix.sh)（CLI 子命令 + 交互菜单选项 5）
- [ ] 考虑给 router 侧加一个 OpenClash 规则版本控制（git 跟踪 `/etc/openclash/custom/openclash_custom_rules.list`），避免 GUI 改完忘记同步进仓
