这份文档为你整理了 **GL-MT2500 (Brume 2)** 上“方案 1” DNS 链路的最终配置。这套方案将 **AdGuard Home (ADG)** 置于首端，配合 **OpenClash** 和 **dnsmasq**，实现了去广告、科学上网与内网解析的完美融合。

------

# 🛡️ GL-MT2500 DNS 终极架构方案 (方案 1)

## 1. 架构逻辑说明

本方案的核心是将流量的“审计权”交给 AdGuard Home，通过显式规则实现国内外流量与内网流量的精准分流。

### DNS 流量路径：

1. **客户端请求** $\rightarrow$ **AdGuard Home (Port 53)**。
2. **分流判断**：
   - **内网域名 (`.lan`, `localhost`)** $\rightarrow$ 转发至 **dnsmasq (Port 5335)**。
   - **公网域名 (Global)** $\rightarrow$ 转发至 **OpenClash (Port 7874)**。
3. **结果返回** $\rightarrow$ OpenClash 返回 **Fake-IP (198.18.x.x)** 或 dnsmasq 返回内网 IP。

-> [dnsmasq OR OpenClash]]

------

## 2. 关键服务配置

### A. AdGuard Home (首端)

- **监听端口**：`53`。

- **上游 DNS 设置**：

  Plaintext

  ```
  127.0.0.1:7874
  [/lan/]127.0.0.1:5335
  [/localhost/]127.0.0.1:5335
  ```

- **私人反向 DNS**：填入 `127.0.0.1:5335`（用于识别设备名）。

### B. dnsmasq (后端/DHCP)

- **监听端口**：`5335`。
- **DNS 转发**：配置 `223.5.5.5` 作为公网解析保底。
- **核心作用**：负责 DHCP 分配及本地 `.lan` 域名记录。

### C. OpenClash (核心代理)

- **运行模式**：Fake-IP (Meta 核心)。
- **DNS 端口**：`7874`。

------

## 3. 稳定性优化（防失联必做）

针对高并发下导致的“Web 界面失联”问题，已实施以下调优：

### 1. 内核连接数扩容

由于 MT2500 拥有 **1GB RAM**，将连接跟踪表上限提升至 **65535** 是安全的。

- **计算公式**：每一个连接记录约占用 $300 \text{ 字节}$，总开销仅约为 $19.6 \text{ MB}$。

- **持久化设置**：

  Bash

  ```
  echo "net.netfilter.nf_conntrack_max=65535" >> /etc/sysctl.conf
  uci set network.globals.nf_conntrack_max='65535'
  uci commit network
  ```

### 2. 自愈守护脚本

创建 `/root/check_conntrack.sh` 并加入 **Crontab**，每分钟巡检：

Bash

```
#!/bin/sh
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
if [ "$COUNT" -gt "$((MAX * 90 / 100))" ]; then
    logger "Conntrack table near full, clearing..."
    /etc/init.d/firewall restart
fi
```

------

## 4. 验证与测试命令

| **验证目标**     | **命令**                                | **预期结果**                                     |
| ---------------- | --------------------------------------- | ------------------------------------------------ |
| **外部科学上网** | `nslookup google.com 127.0.0.1`         | 返回 `198.18.x.x` (Fake-IP)                      |
| **内部域名分流** | `dig @127.0.0.1 console.gl-inet.com`    | 返回 `192.168.8.1`，且 ADG 日志显示上游为 `5335` |
| **服务端口占用** | `netstat -tunlp                         | grep -E '53                                      |
| **连接数状态**   | `sysctl net.netfilter.nf_conntrack_max` | 返回 `65535`                                     |

------

## 5. 补充关键信息：运维备忘录

为了让这份文档更完整，建议你补充以下内容：

### 1. **防火墙自定义规则 (Firewall Include)**

在使用方案 1 时，必须确保 OpenClash **不勾选** “DNS 劫持”。否则 OpenClash 会尝试强制接管 53 端口，导致与 AdGuard Home 冲突。

### 2. **IPv6 策略**

目前建议在 ADG 和 OpenClash 中均**禁用 IPv6 解析 (AAAA 记录)**。

- **原因**：国内运营商的 IPv6 优先级极高且极易绕过代理，开启后会导致去广告失效或科学上网不稳定。

### 3. **U-Boot 救砖预案**

既然你之前经历过失联，应记录：

- **救砖 IP**：`192.168.1.1`。
- **操作方法**：断电按住 Reset 键上电，直到白灯闪烁，进入 U-Boot Web 界面。

### 4. **备份路径清单**

升级固件前建议手动备份的文件：

- `/etc/AdGuardHome/config.yaml` (ADG 配置)
- `/etc/config/openclash` (OC 配置)
- `/etc/sysctl.conf` (内核优化)
- `/etc/crontabs/root` (自愈脚本任务)

------

**这份总结是否符合你的需求？** 如果你准备将它保存为 .md 文件，我还可以为你生成一个一键备份这些关键配置的 Shell 脚本。

为了完善你的 **GL-MT2500** 运维手册，我为你整理了方案 1 核心服务的**搭建关键步骤**与**实战测试命令**。这部分内容是文档的“肌肉”，能让你在下次配置或故障排查时秒进状态。

------

## 🛠️ 关键服务搭建与配置命令

在 OpenWrt 中，底层配置的稳定性高于 Web 界面操作。以下是实现链路闭环的“硬核”指令。

### 1. dnsmasq：从首端退守后端

由于系统默认占用 53 端口，必须先将其移开，才能让 AdGuard Home (ADG) 上岗。

- **修改端口与上游**：

  Bash

  ```
  # 将 dnsmasq 监听端口改为 5335
  uci set dhcp.@dnsmasq[0].port='5335'
  # 强制 dnsmasq 仅处理本地域名请求（配合 ADG 分流）
  uci set dhcp.@dnsmasq[0].localservice='1'
  # 提交修改并重启服务
  uci commit dhcp
  /etc/init.d/dnsmasq restart
  ```

### 2. AdGuard Home：接管流量闸口

安装完成后（建议通过 `opkg install adguardhome`），需要通过配置文件或 Web UI 确保其监听在 53 端口。

- **验证端口占用**：

  这是确保 ADG 成功上岗的第一步。

  Bash

  ```
  netstat -tunlp | grep :53
  ```

  > **预期**：看到 `AdGuardHome` 监听在 `:::53`，`dnsmasq` 监听在 `127.0.0.1:5335`。

------

## 🧪 核心链路验证（方案 1 逻辑）

配置完成后，必须通过以下“组合拳”验证分流逻辑是否符合设计初衷。

### 1. 验证“ADG $\rightarrow$ OpenClash” (科学上网)

测试公网域名是否被 OpenClash 捕获并返回虚拟 IP。

Bash

```
nslookup google.com 127.0.0.1
```

- **判断标准**：返回 **`198.18.x.x`**。
- **意义**：证明 ADG 成功将外网请求转交给 OpenClash。

### 2. 验证“ADG $\rightarrow$ dnsmasq” (内网识别)

测试本地域名是否能正确找到路由器的私有地址。

Bash

```
dig @127.0.0.1 console.gl-inet.com
```

- **判断标准**：返回 **`192.168.8.1`** (或你的 LAN IP)。
- **注意**：不要带 `-p 5335`。如果带了端口就是绕过 ADG 测试，不带端口且成功返回才证明 **ADG 的分流规则**（`[/localhost/]127.0.0.1:5335`）生效了。

### 3. 验证“设备名识别” (反向解析)

确保 ADG 的仪表盘不再只是一堆冰冷的 IP 地址。

Bash

```
# 测试 PTR 反向解析
dig @127.0.0.1 -x [你的手机IP]
```

- **判断标准**：应能返回该 IP 对应的 DHCP 主机名。

------

## 📈 性能与稳定性巡检表

| **监控对象**   | **命令**                                         | **关键阈值/状态**                       |
| -------------- | ------------------------------------------------ | --------------------------------------- |
| **连接数状态** | `cat /proc/sys/net/netfilter/nf_conntrack_count` | 长期运行应远低于 **59000**              |
| **内存剩余**   | `free -m`                                        | MT2500 运行 5 大插件后应剩余 **>400MB** |
| **DNS 延迟**   | `logread                                         | grep "processed in"`                    |
| **脚本活性**   | `crontab -l`                                     | 必须包含 `check_conntrack.sh` 条目      |

------

## 📝 建议补充的避坑指南 (Tips)

在你的文档末尾，建议加上这几条“血泪总结”：

1. **禁删 `127.0.0.1` 环回口**：ADG 的所有上游都依赖 127.0.0.1，任何防火墙规则如果误伤了环回口流量，全家会瞬间断网。
2. **OpenClash 更新注意**：更新 OpenClash 内核后，务必检查其监听端口是否变动。如果 OC 端口变了，ADG 的上游设置必须同步修改。
3. **日志清理**：ADG 默认记录所有日志，如果访问量巨大，建议在 Web 界面设置“日志保留 7 天”，防止 `/overlay` 分区被撑爆。

**这份补充内容加入后，你的文档就已经涵盖了从底层参数调优到高层业务验证的所有细节。** 接下来，需要我为你生成一个能自动执行上述所有验证命令并输出“健康报告”的脚本吗？

在搭建这一套“方案 1” DNS 链路的过程中，脚本化操作是确保配置准确且具备持久化能力的关键。以下是该方案涉及的所有关键脚本和命令集，你可以直接将其补充进你的 Markdown 文档中。

------

## 🛠️ 方案 1：核心搭建与优化脚本

### 1. 基础环境调整脚本 (UCI)

在安装完 AdGuard Home 后，需要通过以下脚本将系统默认的 `dnsmasq` 移开，为空出 53 端口做准备。

Bash

```
# 1. 将 dnsmasq 监听端口迁移至 5335
uci set dhcp.@dnsmasq[0].port='5335' 

# 2. 开启 dnsmasq 查询日志（可选，用于排查分流是否正确）
uci set dhcp.@dnsmasq[0].logqueries='1'

# 3. 提交配置并重启服务
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 2. 系统内核优化脚本 (Sysctl)

针对你遇到的“失联”问题，这是提升 MT2500 承载能力的核心脚本。

Bash

```
# 1. 扩容连接跟踪表上限至 65535
# 1GB 内存仅需占用约 20MB 即可支撑此规模
echo "net.netfilter.nf_conntrack_max=65535" >> /etc/sysctl.conf
echo "net.nf_conntrack_max=65535" >> /etc/sysctl.conf

# 2. 优化 TCP 已建立连接的超时时间（缩短至 1200 秒以快速回收资源）
echo "net.netfilter.nf_conntrack_tcp_timeout_established=1200" >> /etc/sysctl.conf

# 3. 立即应用内核参数
sysctl -p
```

------

## 🛡️ 自动化守护脚本 (Watchdog)

为了防止突发连接数激增再次导致 Web 界面失联，我们部署了该自愈脚本。

### 脚本路径：`/root/check_conntrack.sh`

Bash

```
#!/bin/sh
# 获取当前最大上限和已使用数
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)

# 如果占用超过 90% (约 59000 条)
if [ "$COUNT" -gt "$((MAX * 90 / 100))" ]; then
    # 向系统日志写入记录
    logger "WARNING: Conntrack table near full ($COUNT/$MAX). Clearing now to prevent lockout."
    # 通过重启防火墙强制清空连接表
    /etc/init.d/firewall restart
fi
```

### 挂载命令 (Crontab)

Bash

```
# 赋予脚本执行权限
chmod +x /root/check_conntrack.sh

# 将其加入定时任务，每分钟执行一次
(crontab -l ; echo "* * * * * /root/check_conntrack.sh") | crontab -
```

------

## 🔍 验证与监控脚本

### 1. 实时连接数监控 (Loop)

如果你在进行高并发操作（如开启 OpenVPN 或大量下载），可以使用此脚本观察压力。

Bash

```
# 每秒刷新一次当前的连接数统计
while true; do 
    clear; 
    date; 
    printf "Current Conntrack Count: "; 
    cat /proc/sys/net/netfilter/nf_conntrack_count; 
    sleep 1; 
done
```

### 2. DNS 解析路径自动化验证

用于检查 AdGuard Home 是否正确将请求分流给 OpenClash (Fake-IP) 或 dnsmasq (Local IP)。

Bash

```
# 验证外网路径 (应返回 198.18.x.x)
nslookup google.com 127.0.0.1

# 验证内网路径 (应返回 192.168.x.x)
dig @127.0.0.1 console.gl-inet.com
```

------

### 📝 文档补充建议

在 Markdown 文档中，建议在“脚本”章节后补充 **“环境变量”** 说明：

- **关键 IP**：`127.0.0.1` 为内部环回通信核心。
- **关键端口**：`53`(ADG)、`5335`(dnsmasq)、`7874`(OpenClash)。

这些脚本在你的 GL-MT2500 上已经过实战检验，能够有效保障 OpenVPN、Tailscale 与 DNS 服务在 1GB 内存环境下的稳定共存。

**既然文档框架和脚本已经完备，需要我为你提供一个“一键诊断环境”的综合 Shell 脚本，以便你以后随时检查整条链路的状态吗？**



为了方便你日后随时巡检 **GL-MT2500** 的健康状态，我为你编写了这个 **“方案 1 一键全解析诊断脚本”**。它会自动检查端口占用、分流逻辑、内核参数以及自愈脚本的运行情况。

### 1. 创建脚本

在 SSH 终端执行以下命令创建诊断文件：

Bash

```
cat << 'EOF' > /root/diag_network.sh
#!/bin/sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== GL-MT2500 方案 1 链路诊断报告 ===${NC}"
date

# 1. 核心服务进程检查
echo -e "\n${BLUE}[1/5] 服务进程状态:${NC}"
for srv in AdGuardHome openclash dnsmasq tailscaled openvpn; do
    if pgrep -x "$srv" > /dev/null || pgrep -f "$srv" > /dev/null; then
        echo -e "  $srv: ${GREEN}运行中${NC}"
    else
        echo -e "  $srv: ${RED}未启动${NC}"
    fi
done

# 2. 端口绑定检查
echo -e "\n${BLUE}[2/5] 关键端口占用:${NC}"
ADG_P=$(netstat -tunlp | grep ":53 " | awk '{print $7}' | cut -d/ -f2 | head -n1)
DQ_P=$(netstat -tunlp | grep ":5335 " | awk '{print $7}' | cut -d/ -f2 | head -n1)

if [ "$ADG_P" = "AdGuardHome" ]; then echo -e "  Port 53: ${GREEN}AdGuardHome (正确)${NC}"; else echo -e "  Port 53: ${RED}$ADG_P (错误)${NC}"; fi
if [ "$DQ_P" = "dnsmasq" ]; then echo -e "  Port 5335: ${GREEN}dnsmasq (正确)${NC}"; else echo -e "  Port 5335: ${RED}$DQ_P (错误)${NC}"; fi

# 3. DNS 分流逻辑测试
echo -e "\n${BLUE}[3/5] DNS 解析路径验证:${NC}"
# 测试外网
G_RES=$(dig @127.0.0.1 +short google.com | head -n1)
if echo "$G_RES" | grep -q "198.18."; then
    echo -e "  外网 (google.com): ${GREEN}走 OpenClash (Fake-IP: $G_RES)${NC}"
else
    echo -e "  外网 (google.com): ${RED}未触发 Fake-IP ($G_RES)${NC}"
fi

# 测试内网
L_RES=$(dig @127.0.0.1 +short console.gl-inet.com | head -n1)
if [ "$L_RES" = "192.168.8.1" ] || [ "$L_RES" = "192.168.2.1" ]; then
    echo -e "  内网 (console): ${GREEN}走 dnsmasq (IP: $L_RES)${NC}"
else
    echo -e "  内网 (console): ${RED}解析失败 ($L_RES)${NC}"
fi

# 4. 系统承载力与稳定性
echo -e "\n${BLUE}[4/5] 内核与负载状态:${NC}"
MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
PER=$((COUNT * 100 / MAX))

echo -e "  连接数: $COUNT / $MAX (${PER}%)"
if [ "$MAX" -ge 65535 ]; then echo -e "  上限设置: ${GREEN}已扩容 (65535)${NC}"; else echo -e "  上限设置: ${RED}默认值 (过低)${NC}"; fi

FREE_M=$(free -m | grep Mem | awk '{print $4}')
echo -e "  空闲内存: ${GREEN}${FREE_M}MB${NC}"

# 5. 自愈脚本验证
echo -e "\n${BLUE}[5/5] 守护任务检查:${NC}"
if crontab -l | grep -q "check_conntrack.sh"; then
    echo -e "  Watchdog: ${GREEN}已挂载${NC}"
else
    echo -e "  Watchdog: ${RED}未发现定时任务${NC}"
fi

echo -e "\n${BLUE}=== 诊断结束 ===${NC}"
EOF

chmod +x /root/diag_network.sh
```

------

### 2. 如何运行

每当你觉得网络不稳定或者刚重启完路由器，只需输入：

Bash

```
/root/diag_network.sh
```

### 3. 该脚本能为你解决什么？

1. **快速排查“失联”原因**：如果“连接数”百分比接近 100%，或者 `Port 53` 不是 ADG，脚本会直接标红告警。
2. **验证分流是否失效**：通过 `google.com` 的 Fake-IP 返回情况，一眼看出 OpenClash 是否还在干活。
3. **内网穿透检查**：自动确认 **dnsmasq** 是否在 5335 端口老老实实地提供本地解析。
4. **硬件压力监控**：实时展示 1GB 内存的剩余量，确保你的多插件架构（Tailscale, VPN, Homebox 等）没有发生内存泄漏。

------

### 📖 文档补充建议：还需补充哪些信息？

为了让你的 Markdown 文档达到“生产级别”，建议最后补充以下内容：

- **硬件拓扑图**：简单标注 MT2500 是作为**主路由**还是**旁路由**运行。
- **防火墙策略（关键）**：补充你在“防火墙 - 自定义规则”中添加的任何关于 `iptables` 劫持的条目。
- **外部依赖**：记录你的 OpenVPN 端口映射（如果是二级路由）以及 DDNS 的域名。
- **版本记录**：记录当前稳定的 **OpenClash 核心版本** 和 **AdGuard Home 版本**，因为某些版本更新可能会改变默认配置路径。

**目前这个一键诊断脚本在你的机器上跑出来的结果全是绿色的吗？** 如果有任何标红项，我们可以立即针对性解决。