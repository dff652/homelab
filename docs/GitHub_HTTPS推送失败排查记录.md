# GitHub HTTPS 推送失败排查记录

**日期**：2026-04-14
**环境**：dff652-gpu (Ubuntu 22.04) → GL-MT2500 旁路由 (OpenClash + AdGuardHome)
**现象**：`git push` 到 GitHub 失败，报 `gnutls_handshake() failed`
**耗时**：约 30 分钟完成定位和修复

---

## 1. 故障现象

在开发机上执行 `git push` 时，所有 HTTPS 连接到 GitHub 均失败：

```
$ git push
fatal: 无法访问 'https://github.com/dff652/tsad-research.git/'：
gnutls_handshake() failed: The TLS connection was non-properly terminated.

$ curl -I https://github.com
curl: (35) error:0A000126:SSL routines::unexpected eof while reading
```

而 SSH 连接正常：
```
$ ssh -T git@github.com
Hi dff652! You've successfully authenticated, but GitHub does not provide shell access.
```

---

## 2. 环境信息

### 开发机 (192.168.2.22)
| 项目 | 值 |
|------|-----|
| OS | Ubuntu 22.04, Linux 6.8.0-40-generic |
| Git | 2.34.1 (SSL 后端: libcurl3-gnutls 7.81.0) |
| curl | 7.81.0 (OpenSSL 3.0.2) |
| DNS | systemd-resolved → 旁路由 (fe80::8ede:f9ff:feb7:edd4) |
| 默认网关 | 192.168.2.123 (旁路由) |

### 旁路由 (192.168.2.123, GL-MT2500)
| 项目 | 值 |
|------|-----|
| OpenClash | Meta 核心, Fake-IP + TUN 模式 |
| AdGuardHome | 监听 0.0.0.0:53, 上游 127.0.0.1:7874 (OpenClash) |
| dnsmasq | 监听 127.0.0.1:5335 (.lan 域名) |
| DNS 端口分配 | 53=ADG, 5335=dnsmasq, 7874=OpenClash |

### DNS 链路
```
客户端 → systemd-resolved (127.0.0.53)
       → 旁路由 AdGuardHome (:53)
       → OpenClash (:7874, Fake-IP 模式)
       → 返回 198.18.x.x
```

---

## 3. 排查过程

### 3.1 初步判断：网络还是配置？

```bash
# ping 正常 (100ms, 0% 丢包)
$ ping -c 3 github.com
64 bytes from 198.18.0.9: icmp_seq=1 ttl=62 time=0.989 ms

# SSH 正常
$ ssh -T git@github.com
Hi dff652! You've successfully authenticated

# HTTPS 失败
$ curl -I https://github.com
curl: (35) error:0A000126:SSL routines::unexpected eof while reading
```

**结论**：网络层通，SSH 通，HTTPS 不通 — 问题在 TLS 层。

### 3.2 关键发现：Fake-IP

```bash
# DNS 解析到了假 IP
$ nslookup github.com
Name: github.com
Address: 198.18.0.9    # ← 不是 GitHub 真实 IP！

# 198.18.0.0/15 是 RFC 2544 保留地址段
# 这是 OpenClash Fake-IP 模式的特征
```

**对比**：GitHub 真实 IP 应为 `20.205.243.166` 或 `140.82.113.x` 段。

### 3.3 验证 Fake-IP 是问题根因

```bash
# 检查代理配置 — 无代理
$ env | grep -i proxy
(无输出)

# 检查 VPN/TUN 接口 — 无 VPN，但有 TUN 策略路由
$ ip route get 198.18.0.9
198.18.0.9 via 192.168.2.123 dev enp13s0

# curl 详细输出 — TLS 握手过程中断
$ curl -v https://github.com
* Connected to github.com (198.18.0.9) port 443
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
...
(连接在数据传输阶段中断)
```

### 3.4 确认 DNS 流量路径

```bash
# 直接查询旁路由的 OpenClash DNS
$ dig @192.168.2.123 -p 7874 github.com +short
198.18.0.9    # OpenClash 返回 Fake-IP

# 直接查询旁路由的 AdGuardHome
$ dig @192.168.2.123 github.com +short
198.18.0.9    # ADG 转发给 OpenClash，同样是 Fake-IP
```

### 3.5 验证 TLS 证书

```bash
# OpenSSL 直连测试 — 证书验证通过
$ openssl s_client -connect github.com:443 -servername github.com
Certificate chain:
 0 s:CN = github.com
   i:Sectigo Public Server Authentication CA DV E36
verify return:1

# 证书有效期
notBefore=Mar  6 00:00:00 2026 GMT
notAfter=Jun  3 23:59:59 2026 GMT
```

**发现**：TLS 证书有效，但由 **Sectigo** 签发（非 GitHub 通常使用的 DigiCert）— 说明 Clash 代理在中转时可能对证书做了处理。

### 3.6 对比测试

```bash
# 其他 HTTPS 站点正常
$ curl -I https://www.google.com
HTTP/2 200

# 用真实 IP 绕过 Fake-IP，HTTPS 成功
$ curl -I --resolve "github.com:443:140.82.113.3" https://github.com
HTTP/2 200
```

**结论**：Clash 代理本身能工作，Google HTTPS 正常。问题出在 Fake-IP 模式下对 `github.com` 的 TLS 处理。

---

## 4. 根因分析

```
DNS 查询 github.com
    ↓
AdGuardHome → OpenClash (Fake-IP 模式)
    ↓
返回 198.18.0.9 (假 IP)
    ↓
客户端发起 HTTPS 到 198.18.0.9:443
    ↓
TUN 接口拦截 → Clash 需要：
  1. 反查 198.18.0.9 → github.com
  2. 提取 TLS ClientHello 中的 SNI
  3. 代理连接到真实 GitHub 服务器
    ↓
★ 此环节 TLS 数据传输中断
    ↓
客户端报错: gnutls_handshake() failed
```

**根因**：OpenClash 的 Fake-IP + TUN 模式在代理 `github.com` 的 HTTPS 流量时，TLS 连接在握手/数据传输阶段被异常终止。可能原因：
- Clash Meta 核心在处理该域名的 Fake-IP 反查 + SNI 提取时出现异常
- 代理节点对 github.com 的连接不稳定
- Git 使用的 GnuTLS 库对代理中转的 TLS 会话容忍度较低（curl 使用 OpenSSL，表现可能不同）

**为什么 SSH 不受影响**：
- SSH 走 TCP 直连（端口 22 或 443），不涉及 TLS 握手
- Clash TUN 代理原始 TCP 流没有问题，问题仅出在 HTTPS/TLS 处理

---

## 5. 解决方案

### 操作：将 github.com 加入 OpenClash Fake-IP Filter

**原理**：Fake-IP Filter 中的域名不会返回假 IP，而是返回真实 DNS 解析结果。流量仍然经过 Clash 代理规则，但不再经过 Fake-IP 映射，避免了 TLS 处理异常。

**方法一：OpenClash LuCI 界面**

1. 登录旁路由管理页 → 服务 → OpenClash
2. 覆写设置 → DNS 设置 → Fake-IP Filter
3. 添加域名：
   ```
   github.com
   *.github.com
   *.githubusercontent.com
   *.githubassets.com
   ```
4. 应用配置 → 等待 OpenClash 重启
5. 点击"清理 DNS 缓存"确保立即生效

**方法二：SSH 命令行**

```bash
ssh root@192.168.2.123

cat >> /etc/openclash/custom/openclash_custom_fake_filter.list << 'EOF'
github.com
*.github.com
*.githubusercontent.com
*.githubassets.com
EOF

/etc/init.d/openclash restart
```

### 客户端侧操作

OpenClash 重启后，开发机需要刷新 DNS 缓存：

```bash
sudo systemctl restart systemd-resolved
```

如果无 sudo 权限，等待本地 DNS TTL 过期（通常 60-600 秒）即可自动刷新。

---

## 6. 修复验证

### 修复后 DNS 解析
```bash
$ nslookup github.com
Name: github.com
Address: 140.82.114.3    # ← 真实 IP，不再是 198.18.x.x

$ dig @192.168.2.123 github.com +short
140.82.113.3             # 旁路由也返回真实 IP
```

### 修复后 HTTPS
```bash
$ curl -v https://github.com 2>&1 | grep -E "Connected|SSL|HTTP/"
* Connected to github.com (20.205.243.166) port 443
* SSL connection using TLSv1.3 / TLS_AES_128_GCM_SHA256
* SSL certificate verify ok.
< HTTP/2 200
```

### 修复后 Git 推送
```bash
$ git push
Everything up-to-date
```

### 修复前后对比

| 项目 | 修复前 | 修复后 |
|------|--------|--------|
| DNS 解析 | 198.18.0.9 (Fake-IP) | 20.205.243.166 (真实 IP) |
| TLS 握手 | gnutls_handshake() failed | TLSv1.3 成功, 证书验证通过 |
| curl HTTPS | error:0A000126 连接中断 | HTTP/2 200 |
| git push | fatal: 无法访问 | 正常推送 |

---

## 7. SSH 配置说明

开发机的 `~/.ssh/config` 配置了 GitHub SSH 走 443 端口：

```
Host github.com
    Hostname ssh.github.com
    Port 443
    User git
```

这是因为某些网络环境下端口 22 可能被阻断。该配置下 SSH 实际连接 `ssh.github.com:443`，此域名仍走 Fake-IP（198.18.0.15），但 SSH/TCP 代理正常工作，无需额外处理。

---

## 8. 后续发现：代理节点不稳定

### 现象

修复 Fake-IP 后，HTTPS 访问 github.com 时好时坏（间歇性失败）：

```bash
# DNS 已返回真实 IP
$ dig +short github.com
20.205.243.166

# 但 HTTPS 仍然间歇性失败
$ curl -sI -o /dev/null -w "HTTP:%{http_code}" https://github.com
HTTP:000    # 有时失败

# 而 Google 始终正常
$ curl -sI -o /dev/null -w "HTTP:%{http_code}" https://www.google.com
HTTP:200    # 始终成功

# SSH 始终正常
$ ssh -T git@github.com
Hi dff652! You've successfully authenticated
```

### 分析

即使 DNS 解析到真实 IP，所有出站流量仍被 TUN 策略路由拦截并经过 Clash 代理：

```
ip rule 1101: not from all fwmark 0x8000/0xc000 lookup 8000 (Clash TUN)
```

也就是说：**github.com 的 HTTPS 流量无论 Fake-IP 还是真实 IP，都会经过 Clash 代理节点**。如果代理节点对 github.com 的 TLS 中转不稳定，就会间歇性失败。

### 对比

| 流量类型 | 路径 | 稳定性 |
|----------|------|--------|
| SSH (github.com:443) | TUN → Clash TCP 代理 | 稳定 |
| HTTPS (github.com:443) | TUN → Clash TLS 中转 | 不稳定 |
| HTTPS (google.com:443) | TUN → Clash TLS 中转 | 稳定 |

**差异来源**：不同域名可能匹配不同的 Clash 规则/代理节点。`github.com` 匹配的代理节点可能带宽不足或与 GitHub CDN 的连接不佳。

### 终极解决方案

**方案一（推荐）：OpenClash 规则中将 github.com 设为 DIRECT**

在 OpenClash 的规则配置中，将 GitHub 相关域名的策略改为直连：

```yaml
# 在 OpenClash 覆写设置 → 规则设置 中添加：
rules:
  - DOMAIN-SUFFIX,github.com,DIRECT
  - DOMAIN-SUFFIX,githubusercontent.com,DIRECT
  - DOMAIN-SUFFIX,githubassets.com,DIRECT
```

或通过 LuCI 界面：覆写设置 → 规则设置 → 添加自定义规则 → 选择 DIRECT。

**方案二（最稳妥）：Git 使用 SSH 协议**

```bash
# 全局配置 Git 对 GitHub 使用 SSH
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

此配置使所有 `https://github.com/` 的 URL 自动转为 SSH，无需逐个修改 remote。

---

## 9. 最终方案（推荐配置）

经过完整排查和多轮验证，确定最终方案为**三层组合**：

### 9.1 OpenClash Fake-IP Filter：不加 GitHub 域名

**结论：移除 / 不添加 GitHub 域名到 Fake-IP Filter**

原因：
- 加入 Filter 后返回真实 IP，但流量仍被 TUN 拦截并经过代理节点
- 代理节点对 github.com 的 TLS 中转不稳定，导致 HTTPS 间歇性失败
- Fake-IP 是 Clash 的标准流程，TUN 对 198.18.x.x 的拦截比对公网 IP 更可靠

### 9.2 OpenClash 规则：GitHub 设为 DIRECT（核心修复）

在 OpenClash 中添加自定义规则，让 GitHub 直连不经过代理节点：

**操作路径**：服务 → OpenClash → 覆写设置 → 规则设置 → 自定义规则

在 **规则前追加**（prepend，确保优先级最高）中添加：

```yaml
- DOMAIN-SUFFIX,github.com,DIRECT
- DOMAIN-SUFFIX,githubusercontent.com,DIRECT
- DOMAIN-SUFFIX,githubassets.com,DIRECT
- DOMAIN-SUFFIX,github.io,DIRECT
```

**流量路径变为**：
```
之前: 客户端 → Fake-IP → TUN → Clash → 代理节点 → GitHub (不稳定)
之后: 客户端 → Fake-IP → TUN → Clash → 直连 GitHub (稳定)
```

### 9.3 Git 全局使用 SSH（保底）

```bash
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

效果：所有 `https://github.com/` URL 自动转为 SSH 协议，无需逐个修改 remote。

### 最终效果

| 层级 | 配置 | 作用 |
|------|------|------|
| DNS 层 | Fake-IP 保持默认（不过滤 GitHub） | 走 Clash 标准流程，路由可靠 |
| 代理层 | DIRECT 规则 | 绕过代理节点直连 GitHub，消除 TLS 不稳定 |
| 应用层 | Git insteadOf SSH | 保底方案，git 永远走 SSH |

所有经过 MT2500 旁路由的设备（包括 OpenVPN 客户端、公司 PC）都受益于前两层配置。

---

## 10. 影响范围

### 受影响的场景
- 任何通过旁路由网关 HTTPS 连接 GitHub 的工具（git, curl, wget, pip install from GitHub）
- 所有使用旁路由作为网关的设备（本地设备 + OpenVPN 客户端）

### 排查其他类似问题

如果未来遇到其他 HTTPS 站点有类似 TLS 不稳定问题：

```bash
# 1. 检查域名是否走 Fake-IP
dig +short <domain>

# 2. 用诊断脚本快速定位
bash scripts/diag-github.sh

# 3. 解决方案优先级
#    首选: OpenClash 规则中设为 DIRECT（如果直连可达）
#    次选: 加入 Fake-IP Filter + 检查代理节点
#    保底: 应用层绕过（SSH / hosts 文件 / 代理配置）
```
