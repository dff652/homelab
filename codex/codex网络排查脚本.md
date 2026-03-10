## 脚本

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<'EOF'
用法:
  ./codex_net_fix.sh                        进入交互菜单（推荐）
  ./codex_net_fix.sh diagnose               采集网络、DNS、IPv4/IPv6、OpenAI 连通性信息
  ./codex_net_fix.sh disable-ipv6-temp      临时关闭 IPv6（重启失效）
  ./codex_net_fix.sh disable-ipv6-permanent 永久关闭 IPv6（修改 /etc/sysctl.conf）
  ./codex_net_fix.sh enable-ipv6-temp       临时启用 IPv6
  ./codex_net_fix.sh set-dns-temp <iface> <dns1> [dns2 ...]
  ./codex_net_fix.sh set-dns-permanent <dns1> [dns2 ...]
  ./codex_net_fix.sh write-resolvconf-static <dns1> [dns2 ...]
  ./codex_net_fix.sh restore-resolvconf-stub
  ./codex_net_fix.sh one-click-fix          一键修复（关闭IPv6、设置DNS、测试连通性）

最推荐的命令是直接运行本脚本进入交互菜单，或者依次执行:
  1. diagnose (诊断问题)
  2. disable-ipv6-permanent (永久关闭 IPv6 避免直连绕过)
  3. set-dns-permanent 8.8.8.8 8.8.4.4 (修复 DNS 解析)

示例:
  sudo ./codex_net_fix.sh diagnose
  sudo ./codex_net_fix.sh one-click-fix
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] 请使用 root 或 sudo 运行。"
    exit 1
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$file" "${file}.bak.${ts}"
    echo "[INFO] 已备份 $file -> ${file}.bak.${ts}"
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_default_iface() {
  local iface
  iface=$(ip route | awk '/default/ {print $5}' | head -n1)
  if [[ -z "$iface" ]]; then
    echo ""
  else
    echo "$iface"
  fi
}

diagnose() {
  echo "========== 基础信息 =========="
  date || true
  uname -a || true
  if cmd_exists lsb_release; then
    lsb_release -a || true
  fi
  echo

  echo "========== Codex 信息 =========="
  command -v codex || true
  codex --version || true
  ss -lntp | grep 1455 || true
  lsof -i:1455 || true
  echo

  echo "========== 网卡与路由 =========="
  ip a || true
  echo
  ip route || true
  echo
  ip -6 route || true
  echo

  echo "========== IPv6 状态 =========="
  sysctl net.ipv6.conf.all.disable_ipv6 || true
  sysctl net.ipv6.conf.default.disable_ipv6 || true
  echo

  echo "========== DNS 配置 =========="
  cat /etc/resolv.conf || true
  echo
  if cmd_exists resolvectl; then
    resolvectl status || true
  fi
  echo

  echo "========== 代理变量 =========="
  env | grep -Ei 'proxy|http_proxy|https_proxy|all_proxy|no_proxy' || true
  echo

  echo "========== OpenAI 解析 =========="
  getent ahosts auth.openai.com || true
  echo
  getent ahosts api.openai.com || true
  echo

  if cmd_exists nslookup; then
    echo "========== nslookup =========="
    nslookup auth.openai.com || true
    echo
    nslookup api.openai.com || true
    echo
  fi

  echo "========== 出口 IP =========="
  curl -4 --max-time 10 -sS https://ifconfig.me || true
  echo
  curl -6 --max-time 10 -sS https://ifconfig.me || true
  echo
  curl -4 --max-time 10 -sS https://ipinfo.io || true
  echo
  curl -6 --max-time 10 -sS https://ipinfo.io || true
  echo

  echo "========== OpenAI 连通性 =========="
  curl -4 -I --max-time 15 https://auth.openai.com || true
  echo
  curl -6 -I --max-time 15 https://auth.openai.com || true
  echo
  curl -4 -I --max-time 15 https://api.openai.com || true
  echo
  curl -6 -I --max-time 15 https://api.openai.com || true
  echo

  echo "========== auth.openai.com 详细握手(前40行) =========="
  bash -lc 'curl -v --max-time 20 https://auth.openai.com 2>&1 | head -40' || true
  echo

  echo "[DONE] 诊断完成。"
}

disable_ipv6_temp() {
  require_root
  sysctl -w net.ipv6.conf.all.disable_ipv6=1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1
  echo "[DONE] 已临时关闭 IPv6。"
}

enable_ipv6_temp() {
  require_root
  sysctl -w net.ipv6.conf.all.disable_ipv6=0
  sysctl -w net.ipv6.conf.default.disable_ipv6=0
  echo "[DONE] 已临时启用 IPv6。"
}

disable_ipv6_permanent() {
  require_root
  backup_file /etc/sysctl.conf
  grep -q '^net\.ipv6\.conf\.all\.disable_ipv6=' /etc/sysctl.conf 2>/dev/null && \
    sed -i 's/^net\.ipv6\.conf\.all\.disable_ipv6=.*/net.ipv6.conf.all.disable_ipv6=1/' /etc/sysctl.conf || \
    printf '
net.ipv6.conf.all.disable_ipv6=1
' >> /etc/sysctl.conf

  grep -q '^net\.ipv6\.conf\.default\.disable_ipv6=' /etc/sysctl.conf 2>/dev/null && \
    sed -i 's/^net\.ipv6\.conf\.default\.disable_ipv6=.*/net.ipv6.conf.default.disable_ipv6=1/' /etc/sysctl.conf || \
    printf 'net.ipv6.conf.default.disable_ipv6=1
' >> /etc/sysctl.conf

  sysctl -p
  echo "[DONE] 已永久关闭 IPv6，并重新加载 sysctl。"
}

set_dns_temp() {
  require_root
  if [[ $# -lt 2 ]]; then
    # 自动获取网卡
    local def_iface
    def_iface=$(get_default_iface)
    if [[ -z "$def_iface" ]]; then
      echo "[ERROR] 未能自动识别默认网卡，用法: $SCRIPT_NAME set-dns-temp <iface> <dns1> [dns2 ...]"
      exit 1
    fi
    echo "[INFO] 自动识别到默认网卡: $def_iface"
    set -- "$def_iface" 8.8.8.8 8.8.4.4
  fi
  local iface="$1"
  shift
  if ! cmd_exists resolvectl; then
    echo "[ERROR] 当前系统没有 resolvectl。"
    exit 1
  fi
  resolvectl dns "$iface" "$@"
  resolvectl domain "$iface" '~.'
  echo "[DONE] 已通过 resolvectl 为网卡 $iface 临时设置 DNS: $*"
}

set_dns_permanent() {
  require_root
  if [[ $# -lt 1 ]]; then
    echo "[INFO] 未提供 DNS，默认使用: 8.8.8.8 8.8.4.4"
    set -- 8.8.8.8 8.8.4.4
  fi
  backup_file /etc/systemd/resolved.conf
  local dns_list="$*"
  cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=${dns_list}
FallbackDNS=8.8.4.4 1.0.0.1
DNSStubListener=yes
EOF
  systemctl restart systemd-resolved
  echo "[DONE] 已永久写入 /etc/systemd/resolved.conf 并重启 systemd-resolved。"
}

write_resolvconf_static() {
  require_root
  if [[ $# -lt 1 ]]; then
    echo "[INFO] 未提供 DNS，默认使用: 8.8.8.8 8.8.4.4"
    set -- 8.8.8.8 8.8.4.4
  fi
  backup_file /etc/resolv.conf
  rm -f /etc/resolv.conf
  : > /etc/resolv.conf
  for dns in "$@"; do
    echo "nameserver ${dns}" >> /etc/resolv.conf
  done
  chmod 644 /etc/resolv.conf
  echo "[DONE] 已写入静态 /etc/resolv.conf: $*"
}

restore_resolvconf_stub() {
  require_root
  rm -f /etc/resolv.conf
  ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved || true
  echo "[DONE] 已恢复 /etc/resolv.conf 指向 systemd-resolved stub。"
}

one_click_fix() {
  require_root
  echo "============== 执行一键修复 =============="
  echo "1. 永久关闭 IPv6..."
  disable_ipv6_permanent
  
  echo "2. 配置推荐 DNS..."
  read -rp "请输入 DNS (多个IP用空格分隔，直接回车默认使用 8.8.8.8 8.8.4.4): " dns_input
  if [[ -n "$dns_input" ]]; then
    set_dns_permanent $dns_input
  else
    set_dns_permanent 8.8.8.8 8.8.4.4
  fi
  
  echo "3. 测试 OpenAI (auth.openai.com) 连通性..."
  if curl -4 -I --max-time 10 https://auth.openai.com >/dev/null 2>&1; then
    echo -e "
[OK] ========================="
    echo "[OK] 连通性正常！修复成功！"
    echo "[OK] ========================="
  else
    echo -e "
[WARN] ========================="
    echo "[WARN] 连通性测试失败，建议执行 diagnose 选择项排查完整日志。"
    echo "[WARN] ========================="
  fi
  echo "============== 一键修复完成 =============="
}

interactive_menu() {
  require_root
  while true; do
    echo "======================================"
    echo "      Codex 网络环境自动修复工具"
    echo "======================================"
    echo "推荐操作 (永久生效):"
    echo "  1) 一键自动修复 (完全关闭IPv6 + 自定义/推荐DNS + 连通性测试)"
    echo "  2) 全面网络诊断 (输出全部网络状态与请求日志，用于定位问题)"
    echo "基本操作:"
    echo "  3) 永久关闭 IPv6 (推荐，修改 sysctl.conf)"
    echo "  4) 临时关闭 IPv6 (不推荐，重启服务器后失效)"
    echo "  5) 永久设置系统 DNS (推荐，支持自动识别网卡，通过 systemd-resolved)"
    echo "  6) 恢复 DNS 到系统默认配置 (systemd-resolved stub)"
    echo "  0) 退出工具"
    echo "======================================"
    read -rp "请输入选项数字 [0-6] 默认[1]: " choice
    if [[ -z "$choice" ]]; then
      choice="1"
    fi

    case "$choice" in
      1) one_click_fix; break ;;
      2) diagnose; break ;;
      3) disable_ipv6_permanent; break ;;
      4) disable_ipv6_temp; break ;;
      5)
        read -rp "请输入 DNS (多个IP用空格分隔，直接回车默认使用 8.8.8.8 8.8.4.4): " dns_input
        if [[ -n "$dns_input" ]]; then
          set_dns_permanent $dns_input
        else
          set_dns_permanent 8.8.8.8 8.8.4.4
        fi
        break
        ;;
      6) restore_resolvconf_stub; break ;;
      0) echo "已退出"; exit 0 ;;
      *) echo "[ERROR] 无效的选项，请重新输入." ;;
    esac
    echo
  done
}

main() {
  local action="${1:-}"
  case "$action" in
    diagnose) diagnose ;;
    disable-ipv6-temp) disable_ipv6_temp ;;
    disable-ipv6-permanent) disable_ipv6_permanent ;;
    enable-ipv6-temp) enable_ipv6_temp ;;
    set-dns-temp) shift; set_dns_temp "$@" ;;
    set-dns-permanent) shift; set_dns_permanent "$@" ;;
    write-resolvconf-static) shift; write_resolvconf_static "$@" ;;
    restore-resolvconf-stub) restore_resolvconf_stub ;;
    one-click-fix) one_click_fix ;;
    -h|--help|help) usage ;;
    "")
      # 如果没有任何参数，则进入交互模式
      interactive_menu
      ;;
    *)
      echo "[ERROR] 未知命令: $action"
      usage
      exit 1
      ;;
  esac
}

main "$@"
```

下面直接贴出文档和脚本。

## Markdown 文档

~~~markdown
# Codex CLI 远程登录排障记录与操作手册

## 背景

场景是：

- 在本地 Windows 机器上通过 SSH 登录远程 Linux 服务器
- 在远程服务器运行 `codex`
- 选择 **Sign in with ChatGPT**
- 在本地浏览器中完成授权
- 通过 `ssh -L 1455:127.0.0.1:1455 ...` 将本地 `localhost:1455` 转发到远程 Codex CLI 的本地回调端口

最终问题定位并解决成功。

---

## 现象与结论

### 1. 初始失败现象

最早遇到的是：

- 浏览器跳转到 `http://localhost:1455/auth/callback?...`
- 本地浏览器报 `ERR_CONNECTION_REFUSED`

这说明：

- 本地浏览器访问的是**本地** `localhost:1455`
- 但 Codex CLI 的回调监听器运行在**远程服务器**
- 如果没有做 SSH 本地端口转发，本地浏览器无法访问远程的 `127.0.0.1:1455`

### 2. 通过 SSH 端口转发修复回调链路

使用下面命令建立端口转发：

```bash
ssh -L 1455:127.0.0.1:1455 user@server
~~~

之后本地浏览器回调可以到达远程 Codex CLI。

### 3. 服务器 1 与服务器 2 行为不同

后续对比发现：

- **服务器 2** 可以正常登录
- **服务器 1** 登录失败

核心差异不是“机器地域”本身，而是**实际访问 OpenAI 的出网路径不同**。

### 4. 服务器 2 成功的原因

服务器 2 本机运行了 `mihomo/clash`，并启用了 TUN/fake-ip 接管。

证据：

- `getent ahosts auth.openai.com` 解析为 `198.18.x.x`
- `198.18.0.0/15` 是 fake-ip / 透明代理环境常见保留地址段
- 说明 OpenAI 流量被本机代理接管，再由代理节点转发

### 5. 服务器 1 失败的关键原因

服务器 1 最终定位到两个问题：

#### 问题 A：IPv6 直连绕过代理

在服务器 1 上：

```bash
curl -v https://auth.openai.com
```

日志显示优先连接了 IPv6 地址，例如：

```text
Trying 2606:4700:...
Connected to auth.openai.com ...
```

这说明：

- Linux 优先用了 IPv6
- 而软路由 OpenClash 并未完整接管该服务器的 IPv6 流量
- 导致 Codex/OpenAI 请求绕过代理直连外网
- 进而触发登录失败或区域/出口限制

#### 问题 B：关闭 IPv6 后 DNS 失效

执行：

```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

之后出现：

```text
curl: (6) Could not resolve host: auth.openai.com
curl: (6) Could not resolve host: ipinfo.io
```

同时 `/etc/resolv.conf` 指向：

```text
nameserver 127.0.0.53
```

这说明系统使用 `systemd-resolved` 作为本地 DNS stub。
关闭 IPv6 后，上游 DNS 没有正确补到 IPv4，导致 DNS 解析失败。

### 6. 最终修复方法

在服务器 1 上做了两件事：

1. 关闭 IPv6
2. 配置可用的 IPv4 DNS

之后 Codex 登录成功。

------

## 完整排障过程记录

### 第一步：验证 Codex CLI 是否已监听回调端口

```bash
which codex
codex --version
ss -lntp | grep 1455
lsof -i:1455
```

确认项：

- `codex` 已安装
- `codex-cli` 版本正常
- 远程 `127.0.0.1:1455` 已监听
- 进程确实是 `codex`

### 第二步：验证 SSH 端口转发是否正常

登录远程时使用：

```bash
ssh -L 1455:127.0.0.1:1455 user@server
```

如果浏览器回调阶段出现：

- `ERR_CONNECTION_REFUSED`
- `channel ... open failed: connect failed: Connection refused`

通常代表：

- 远程 1455 没有监听
- 或者 `codex` 登录流程已退出

### 第三步：检查公网出口与代理变量

```bash
curl https://ifconfig.me
curl https://ipinfo.io
env | grep -i proxy
git config --global --get http.proxy
git config --global --get https.proxy
```

注意：

- `ifconfig.me` / `ipinfo.io` 只能说明普通 HTTP 请求的出口
- **不一定等同于 Codex 实际访问 OpenAI 认证端点时的出口**
- 如果有透明代理、TUN、策略路由、IPv6 分流，结果可能不同

### 第四步：检查 OpenAI 域名解析与连通方式

```bash
getent ahosts auth.openai.com
getent ahosts api.openai.com
nslookup auth.openai.com
nslookup api.openai.com
curl -4 -I https://auth.openai.com
curl -6 -I https://auth.openai.com
curl -v https://auth.openai.com 2>&1 | head -40
```

重点观察：

- 是否优先连接 IPv6
- 是否解析到 fake-ip（如 `198.18.x.x`）
- 是否走公网地址
- 是否能正常完成 TLS 建连

### 第五步：检查 DNS 当前状态

```bash
cat /etc/resolv.conf
resolvectl status
```

如果看到：

```text
nameserver 127.0.0.53
```

说明系统使用 `systemd-resolved` 管理 DNS。
此时不能简单只看 `/etc/resolv.conf`，还要看 `resolvectl status` 中的上游 DNS。

------

## 最终可复用判断逻辑

### 情况 1：本地浏览器打不开 localhost:1455

排查：

- 是否加了 `ssh -L 1455:127.0.0.1:1455`
- 远程 `codex` 是否仍在运行
- 远程 `127.0.0.1:1455` 是否已监听

### 情况 2：能回调但报 `token_exchange_failed`

排查：

- 远程服务器是否能解析 `auth.openai.com`
- 远程服务器访问 OpenAI 时是否绕过代理
- 是否存在 IPv6 优先直连
- DNS 是否失效
- 是否存在 TUN/fake-ip 与直连路径差异

### 情况 3：关闭 IPv6 后完全无法访问域名

排查：

- `systemd-resolved` 是否仍在使用 `127.0.0.53`
- 上游 DNS 是否缺失
- 是否需要显式设置 IPv4 DNS

------

## 关键命令清单

### A. 端口与监听

```bash
ss -lntp | grep 1455
lsof -i:1455
```

### B. 出口与代理

```bash
curl https://ifconfig.me
curl https://ipinfo.io
env | grep -Ei 'proxy|http_proxy|https_proxy|all_proxy|no_proxy'
```

### C. OpenAI 解析与连通性

```bash
getent ahosts auth.openai.com
getent ahosts api.openai.com
curl -4 -I https://auth.openai.com
curl -6 -I https://auth.openai.com
curl -v https://auth.openai.com
```

### D. DNS 状态

```bash
cat /etc/resolv.conf
resolvectl status
```

### E. IPv6 状态

```bash
ip -6 addr
ip -6 route
sysctl net.ipv6.conf.all.disable_ipv6
sysctl net.ipv6.conf.default.disable_ipv6
```

------

## 关闭 IPv6 的方法

### 临时关闭（立即生效，重启失效）

```bash
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
```

### 永久关闭

编辑 `/etc/sysctl.conf`，加入：

```conf
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
```

然后执行：

```bash
sudo sysctl -p
```

------

## 修改 DNS 的方法

### 临时设置 systemd-resolved 上游 DNS

先查看网卡名：

```bash
ip a
```

然后设置，例如网卡为 `eth0`：

```bash
sudo resolvectl dns eth0 8.8.8.8 1.1.1.1
sudo resolvectl domain eth0 ~.
```

如果网卡是 `ens18` / `ens160` / `enp1s0`，替换为实际网卡名。

### 永久设置 systemd-resolved DNS

编辑：

```bash
sudo nano /etc/systemd/resolved.conf
```

配置：

```ini
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.4.4 1.0.0.1
DNSStubListener=yes
```

然后重启：

```bash
sudo systemctl restart systemd-resolved
```

### 静态覆盖 `/etc/resolv.conf`（适合简单服务器环境）

如果不想继续依赖 `systemd-resolved`，可以改为静态文件，但要注意某些系统/网络管理器可能会覆盖。

```bash
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
```

------

## 建议记录的关键信息

建议以后每次排障都记录以下内容：

### 基础信息

- 服务器 IP / 主机名
- 操作系统版本
- `codex-cli` 版本
- 登录时间
- 登录方式（ChatGPT / Device Auth / API Key）

### 网络信息

- 默认网关
- 是否启用 IPv6
- `ip a`
- `ip route`
- `ip -6 route`
- `resolvectl status`
- `/etc/resolv.conf`
- 出口 IP（IPv4 / IPv6）
- 是否存在代理变量
- 是否走 TUN/fake-ip/透明代理

### OpenAI 相关信息

- `auth.openai.com` 解析结果
- `api.openai.com` 解析结果
- `curl -4/-6` 测试结果
- `curl -v https://auth.openai.com` 关键片段
- 登录错误原文截图或完整日志

### 代理信息

- 本机 Clash / mihomo 是否启用
- 软路由 OpenClash 是否启用
- 是否启用 TUN
- 是否启用 fake-ip
- OpenAI 域名是否命中代理规则
- 是否存在局域网直连/绕过规则

------

## 更好的建议

### 建议 1：优先在服务器本机运行 mihomo/clash

如果服务器允许安装代理，**优先使用和服务器 2 一样的本机 mihomo TUN 方案**。
优点：

- 不依赖软路由是否正确接管
- 不容易被 IPv6 绕过
- 行为更可控、更容易复现
- 排障边界清晰

### 建议 2：对 OpenAI 相关域名单独做强制代理

至少对以下域名保证代理路径一致：

- `auth.openai.com`
- `api.openai.com`
- `chatgpt.com`
- `openai.com`
- 必要时包括其 CDN/相关认证域名

### 建议 3：为服务器统一禁用 IPv6 或统一代理 IPv6

如果当前网络体系对 IPv6 没有完整代理策略，建议：

- 要么统一禁用 IPv6
- 要么统一为 IPv6 配置代理和 DNS

不要处于“IPv4 代理、IPv6 直连”的半接管状态。

### 建议 4：固定 DNS 策略

对需要稳定访问外部服务的 Linux 服务器，建议固定 DNS 策略，避免：

- DHCP / RA / NetworkManager / systemd-resolved 来回接管
- 关闭 IPv6 后 DNS 丢失
- 软路由 DNS 劫持与本机 stub 叠加造成不确定行为

### 建议 5：写成一键排障脚本

建议保留一套脚本，自动采集：

- 端口监听
- DNS
- IPv4/IPv6
- OpenAI 连通性
- 出口信息
- 代理变量

后续排障效率会高很多。

------

## 本次最终结论

本次问题不是 Codex CLI 本身故障，而是远程服务器网络路径问题，核心包括：

1. 本地浏览器回调需要 SSH 端口转发
2. 服务器 1 的 OpenAI 访问流量未像服务器 2 那样被本机代理完整接管
3. Linux 优先使用 IPv6，导致代理绕过
4. 关闭 IPv6 后，systemd-resolved 上游 DNS 丢失，导致域名解析失败
5. 在关闭 IPv6 并补齐 IPv4 DNS 后，Codex 登录成功

```
## 脚本

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<'EOF'
用法:
  ./codex_net_fix.sh                        进入交互菜单（推荐）
  ./codex_net_fix.sh diagnose               采集网络、DNS、IPv4/IPv6、OpenAI 连通性信息
  ./codex_net_fix.sh disable-ipv6-temp      临时关闭 IPv6（重启失效）
  ./codex_net_fix.sh disable-ipv6-permanent 永久关闭 IPv6（修改 /etc/sysctl.conf）
  ./codex_net_fix.sh enable-ipv6-temp       临时启用 IPv6
  ./codex_net_fix.sh set-dns-temp <iface> <dns1> [dns2 ...]
  ./codex_net_fix.sh set-dns-permanent <dns1> [dns2 ...]
  ./codex_net_fix.sh write-resolvconf-static <dns1> [dns2 ...]
  ./codex_net_fix.sh restore-resolvconf-stub
  ./codex_net_fix.sh one-click-fix          一键修复（关闭IPv6、设置DNS、测试连通性）

最推荐的命令是直接运行本脚本进入交互菜单，或者依次执行:
  1. diagnose (诊断问题)
  2. disable-ipv6-permanent (永久关闭 IPv6 避免直连绕过)
  3. set-dns-permanent 8.8.8.8 8.8.4.4 (修复 DNS 解析)

示例:
  sudo ./codex_net_fix.sh diagnose
  sudo ./codex_net_fix.sh one-click-fix
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] 请使用 root 或 sudo 运行。"
    exit 1
  fi
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$file" "${file}.bak.${ts}"
    echo "[INFO] 已备份 $file -> ${file}.bak.${ts}"
  fi
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_default_iface() {
  local iface
  iface=$(ip route | awk '/default/ {print $5}' | head -n1)
  if [[ -z "$iface" ]]; then
    echo ""
  else
    echo "$iface"
  fi
}

diagnose() {
  echo "========== 基础信息 =========="
  date || true
  uname -a || true
  if cmd_exists lsb_release; then
    lsb_release -a || true
  fi
  echo

  echo "========== Codex 信息 =========="
  command -v codex || true
  codex --version || true
  ss -lntp | grep 1455 || true
  lsof -i:1455 || true
  echo

  echo "========== 网卡与路由 =========="
  ip a || true
  echo
  ip route || true
  echo
  ip -6 route || true
  echo

  echo "========== IPv6 状态 =========="
  sysctl net.ipv6.conf.all.disable_ipv6 || true
  sysctl net.ipv6.conf.default.disable_ipv6 || true
  echo

  echo "========== DNS 配置 =========="
  cat /etc/resolv.conf || true
  echo
  if cmd_exists resolvectl; then
    resolvectl status || true
  fi
  echo

  echo "========== 代理变量 =========="
  env | grep -Ei 'proxy|http_proxy|https_proxy|all_proxy|no_proxy' || true
  echo

  echo "========== OpenAI 解析 =========="
  getent ahosts auth.openai.com || true
  echo
  getent ahosts api.openai.com || true
  echo

  if cmd_exists nslookup; then
    echo "========== nslookup =========="
    nslookup auth.openai.com || true
    echo
    nslookup api.openai.com || true
    echo
  fi

  echo "========== 出口 IP =========="
  curl -4 --max-time 10 -sS https://ifconfig.me || true
  echo
  curl -6 --max-time 10 -sS https://ifconfig.me || true
  echo
  curl -4 --max-time 10 -sS https://ipinfo.io || true
  echo
  curl -6 --max-time 10 -sS https://ipinfo.io || true
  echo

  echo "========== OpenAI 连通性 =========="
  curl -4 -I --max-time 15 https://auth.openai.com || true
  echo
  curl -6 -I --max-time 15 https://auth.openai.com || true
  echo
  curl -4 -I --max-time 15 https://api.openai.com || true
  echo
  curl -6 -I --max-time 15 https://api.openai.com || true
  echo

  echo "========== auth.openai.com 详细握手(前40行) =========="
  bash -lc 'curl -v --max-time 20 https://auth.openai.com 2>&1 | head -40' || true
  echo

  echo "[DONE] 诊断完成。"
}

disable_ipv6_temp() {
  require_root
  sysctl -w net.ipv6.conf.all.disable_ipv6=1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1
  echo "[DONE] 已临时关闭 IPv6。"
}

enable_ipv6_temp() {
  require_root
  sysctl -w net.ipv6.conf.all.disable_ipv6=0
  sysctl -w net.ipv6.conf.default.disable_ipv6=0
  echo "[DONE] 已临时启用 IPv6。"
}

disable_ipv6_permanent() {
  require_root
  backup_file /etc/sysctl.conf
  grep -q '^net\.ipv6\.conf\.all\.disable_ipv6=' /etc/sysctl.conf 2>/dev/null && \
    sed -i 's/^net\.ipv6\.conf\.all\.disable_ipv6=.*/net.ipv6.conf.all.disable_ipv6=1/' /etc/sysctl.conf || \
    printf '
net.ipv6.conf.all.disable_ipv6=1
' >> /etc/sysctl.conf

  grep -q '^net\.ipv6\.conf\.default\.disable_ipv6=' /etc/sysctl.conf 2>/dev/null && \
    sed -i 's/^net\.ipv6\.conf\.default\.disable_ipv6=.*/net.ipv6.conf.default.disable_ipv6=1/' /etc/sysctl.conf || \
    printf 'net.ipv6.conf.default.disable_ipv6=1
' >> /etc/sysctl.conf

  sysctl -p
  echo "[DONE] 已永久关闭 IPv6，并重新加载 sysctl。"
}

set_dns_temp() {
  require_root
  if [[ $# -lt 2 ]]; then
    # 自动获取网卡
    local def_iface
    def_iface=$(get_default_iface)
    if [[ -z "$def_iface" ]]; then
      echo "[ERROR] 未能自动识别默认网卡，用法: $SCRIPT_NAME set-dns-temp <iface> <dns1> [dns2 ...]"
      exit 1
    fi
    echo "[INFO] 自动识别到默认网卡: $def_iface"
    set -- "$def_iface" 8.8.8.8 8.8.4.4
  fi
  local iface="$1"
  shift
  if ! cmd_exists resolvectl; then
    echo "[ERROR] 当前系统没有 resolvectl。"
    exit 1
  fi
  resolvectl dns "$iface" "$@"
  resolvectl domain "$iface" '~.'
  echo "[DONE] 已通过 resolvectl 为网卡 $iface 临时设置 DNS: $*"
}

set_dns_permanent() {
  require_root
  if [[ $# -lt 1 ]]; then
    echo "[INFO] 未提供 DNS，默认使用: 8.8.8.8 8.8.4.4"
    set -- 8.8.8.8 8.8.4.4
  fi
  backup_file /etc/systemd/resolved.conf
  local dns_list="$*"
  cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=${dns_list}
FallbackDNS=8.8.4.4 1.0.0.1
DNSStubListener=yes
EOF
  systemctl restart systemd-resolved
  echo "[DONE] 已永久写入 /etc/systemd/resolved.conf 并重启 systemd-resolved。"
}

write_resolvconf_static() {
  require_root
  if [[ $# -lt 1 ]]; then
    echo "[INFO] 未提供 DNS，默认使用: 8.8.8.8 8.8.4.4"
    set -- 8.8.8.8 8.8.4.4
  fi
  backup_file /etc/resolv.conf
  rm -f /etc/resolv.conf
  : > /etc/resolv.conf
  for dns in "$@"; do
    echo "nameserver ${dns}" >> /etc/resolv.conf
  done
  chmod 644 /etc/resolv.conf
  echo "[DONE] 已写入静态 /etc/resolv.conf: $*"
}

restore_resolvconf_stub() {
  require_root
  rm -f /etc/resolv.conf
  ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  systemctl restart systemd-resolved || true
  echo "[DONE] 已恢复 /etc/resolv.conf 指向 systemd-resolved stub。"
}

one_click_fix() {
  require_root
  echo "============== 执行一键修复 =============="
  echo "1. 永久关闭 IPv6..."
  disable_ipv6_permanent
  
  echo "2. 配置推荐 DNS..."
  read -rp "请输入 DNS (多个IP用空格分隔，直接回车默认使用 8.8.8.8 8.8.4.4): " dns_input
  if [[ -n "$dns_input" ]]; then
    set_dns_permanent $dns_input
  else
    set_dns_permanent 8.8.8.8 8.8.4.4
  fi
  
  echo "3. 测试 OpenAI (auth.openai.com) 连通性..."
  if curl -4 -I --max-time 10 https://auth.openai.com >/dev/null 2>&1; then
    echo -e "
[OK] ========================="
    echo "[OK] 连通性正常！修复成功！"
    echo "[OK] ========================="
  else
    echo -e "
[WARN] ========================="
    echo "[WARN] 连通性测试失败，建议执行 diagnose 选择项排查完整日志。"
    echo "[WARN] ========================="
  fi
  echo "============== 一键修复完成 =============="
}

interactive_menu() {
  require_root
  while true; do
    echo "======================================"
    echo "      Codex 网络环境自动修复工具"
    echo "======================================"
    echo "推荐操作 (永久生效):"
    echo "  1) 一键自动修复 (完全关闭IPv6 + 自定义/推荐DNS + 连通性测试)"
    echo "  2) 全面网络诊断 (输出全部网络状态与请求日志，用于定位问题)"
    echo "基本操作:"
    echo "  3) 永久关闭 IPv6 (推荐，修改 sysctl.conf)"
    echo "  4) 临时关闭 IPv6 (不推荐，重启服务器后失效)"
    echo "  5) 永久设置系统 DNS (推荐，支持自动识别网卡，通过 systemd-resolved)"
    echo "  6) 恢复 DNS 到系统默认配置 (systemd-resolved stub)"
    echo "  0) 退出工具"
    echo "======================================"
    read -rp "请输入选项数字 [0-6] 默认[1]: " choice
    if [[ -z "$choice" ]]; then
      choice="1"
    fi

    case "$choice" in
      1) one_click_fix; break ;;
      2) diagnose; break ;;
      3) disable_ipv6_permanent; break ;;
      4) disable_ipv6_temp; break ;;
      5)
        read -rp "请输入 DNS (多个IP用空格分隔，直接回车默认使用 8.8.8.8 8.8.4.4): " dns_input
        if [[ -n "$dns_input" ]]; then
          set_dns_permanent $dns_input
        else
          set_dns_permanent 8.8.8.8 8.8.4.4
        fi
        break
        ;;
      6) restore_resolvconf_stub; break ;;
      0) echo "已退出"; exit 0 ;;
      *) echo "[ERROR] 无效的选项，请重新输入." ;;
    esac
    echo
  done
}

main() {
  local action="${1:-}"
  case "$action" in
    diagnose) diagnose ;;
    disable-ipv6-temp) disable_ipv6_temp ;;
    disable-ipv6-permanent) disable_ipv6_permanent ;;
    enable-ipv6-temp) enable_ipv6_temp ;;
    set-dns-temp) shift; set_dns_temp "$@" ;;
    set-dns-permanent) shift; set_dns_permanent "$@" ;;
    write-resolvconf-static) shift; write_resolvconf_static "$@" ;;
    restore-resolvconf-stub) restore_resolvconf_stub ;;
    one-click-fix) one_click_fix ;;
    -h|--help|help) usage ;;
    "")
      # 如果没有任何参数，则进入交互模式
      interactive_menu
      ;;
    *)
      echo "[ERROR] 未知命令: $action"
      usage
      exit 1
      ;;
  esac
}

main "$@"
```

## 脚本增强说明（已实现）

当前的增强版脚本已经实现了以下高级特性：

1. **交互式菜单**：直接运行脚本无参数时，会自动进入可视化交互菜单，无需记忆任何命令参数，**强烈推荐使用该方式**。
2. **自动识别网卡**：在修改DNS时，脚本会自动通过 `ip route` 识别默认网卡的名称，无需手工指定。
3. **一键修复 (`one-click-fix`)**：包含永久关闭IPv6、设置自定义或Google DNS以及连通性自动测试和验证的全套流程。

**排障推荐流程：**
最推荐的排查命令是直接运行本脚本进入交互菜单，选择 `1) 一键自动修复`，或者依次手工执行排查 `diagnose` -> `disable-ipv6-permanent` -> `set-dns-permanent 8.8.8.8 8.8.4.4`。