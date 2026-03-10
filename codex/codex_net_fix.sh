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

diagnose_sys_net() {
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
  echo "[DONE] 系统与基础网络检测完成。"
}

diagnose_proxy_dns() {
  echo "========== DNS 配置 =========="
  echo "----- /etc/resolv.conf -----"
  grep -v '^#' /etc/resolv.conf | grep -v '^$' || true
  echo
  if cmd_exists resolvectl; then
    echo "----- resolvectl dns -----"
    resolvectl dns || true
    echo "----- resolvectl status (精简) -----"
    resolvectl status | grep -E "^Global|^Link|Current DNS Server:|DNS Servers:|Fallback DNS Servers:" || true
  fi
  echo

  echo "========== 代理变量 / Git 代理 =========="
  env | grep -Ei 'proxy|http_proxy|https_proxy|all_proxy|no_proxy' || true
  if cmd_exists git; then
    echo "----- Git Config -----"
    git config --global --get http.proxy || echo "no global http.proxy"
    git config --global --get https.proxy || echo "no global https.proxy"
  fi
  echo
  echo "[DONE] DNS与代理配置检测完成。"
}

diagnose_conn() {
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
  echo "[DONE] 公网与连通性检测完成。"
}

print_sys_net_conclusion() {
  local v6_ifaces
  v6_ifaces=$(ip -6 a | grep 'inet6' | grep -v 'lo' | awk '{print $NF}' | sort -u | tr '\n' ' ' || true)
  if [[ -n "$v6_ifaces" ]]; then
    echo "[!] 网卡 IPv6 残留: 发现 (${v6_ifaces}) 存在 IPv6 地址。这可能是NetworkManager尚未刷新，但若未关闭请在主菜单选择彻底关闭。"
  else
    echo "[OK] 网卡 IPv6 残留: 未发现任何物理网卡存在 IPv6 地址。"
  fi
}

print_proxy_dns_conclusion() {
  if cmd_exists resolvectl && resolvectl status 2>/dev/null | grep -q "fe80::"; then
    echo "[!] DNS 污染: 发现网卡 DNS 中含有 fe80:: 局域网IPv6 DNS（可能来自路由器）。它会导致域名解析等待超时，建议重启服务器或使用静态覆盖。"
  else
    echo "[OK] DNS 污染: 未发现残留的局域网 IPv6 DNS 服务器。"
  fi

  if env | grep -Ei 'proxy|http_proxy|https_proxy|all_proxy' >/dev/null 2>&1; then
    echo "[!] 环境代理: 系统配置了全局 proxy 变量。这可能拦截或干扰 Codex 连通，请确保代理端正常运行或 unset 并剔除它们。"
  else
    echo "[OK] 环境代理: 未发现环境变量级的全局代理配置。"
  fi

  if cmd_exists git && { git config --global --get http.proxy >/dev/null 2>&1 || git config --global --get https.proxy >/dev/null 2>&1; }; then
    echo "[!] Git 代理: 发现已配置全局 Git 代理。可能导致部分插件/拉取动作失败或走特定节点。"
  else
    echo "[OK] Git 代理: 未发现全局 Git 代理配置。"
  fi
}

print_conn_conclusion() {
  local conn_v4=""
  if curl -4 -I --max-time 10 https://auth.openai.com 2>&1 | grep -q -E "HTTP/2 (403|421)"; then
     conn_v4="[OK] IPv4 连通性: 成功。网络可直连 OpenAI (auth.openai.com 返回 403/421 是正常的连接成功标志)。"
  else
     conn_v4="[!] IPv4 连通性: 失败或超时。请检查 DNS 配置及大中华区网络环境。"
  fi
  echo "$conn_v4"

  local conn_v6=""
  # 通过捕获退出码来判断。如果 curl 返回 0，说明完整握手成功，这时候我们反而要报警（因为没禁用彻底）。
  # 通常如果是无法连接、DNS失败，curl的退出码会是非0的（如 7 或 6 或 28）。
  set +e
  curl -6 -I --max-time 5 https://auth.openai.com >/dev/null 2>&1
  local curl_exit_code=$?
  set -e
  
  if [[ $curl_exit_code -ne 0 ]]; then
     conn_v6="[OK] IPv6 连通性: 当前系统 IPv6 无法连接 (curl退出码:$curl_exit_code，符合永久禁用IPv6防止直连黑洞的预期)。"
  else
     conn_v6="[WARN] IPv6 连通性: IPv6 依然处于活跃或连接成功状态(退出码:0)，可能会导致分流泄漏！"
  fi
  echo "$conn_v6"
}

print_all_conclusions() {
  echo
  echo "============== 最终自动诊断结论 =============="
  print_sys_net_conclusion
  print_proxy_dns_conclusion
  print_conn_conclusion
  echo "=============================================="
  echo
}

diagnose_sys_net_only() {
  diagnose_sys_net
  echo "============== 诊断结论 =============="
  print_sys_net_conclusion
  echo "======================================"
}

diagnose_proxy_dns_only() {
  diagnose_proxy_dns
  echo "============== 诊断结论 =============="
  print_proxy_dns_conclusion
  echo "======================================"
}

diagnose_conn_only() {
  diagnose_conn
  echo "============== 诊断结论 =============="
  print_conn_conclusion
  echo "======================================"
}

diagnose() {
  diagnose_sys_net
  diagnose_proxy_dns
  diagnose_conn
  print_all_conclusions
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
  
  echo "[INFO] 当前检测到的物理网卡如下（排除回环网卡 lo）："
  ls /sys/class/net 2>/dev/null | grep -v 'lo' || true
  echo
  read -rp "请输入需要永久关闭 IPv6 的网卡名称 (多个网卡用空格分隔，直接回车则默认关闭所有网卡): " iface_input

  backup_file /etc/sysctl.conf
  
  # 基础配置: 禁用所有和默认的IPv6
  grep -q '^net\.ipv6\.conf\.all\.disable_ipv6=' /etc/sysctl.conf 2>/dev/null && \
    sed -i 's/^net\.ipv6\.conf\.all\.disable_ipv6=.*/net.ipv6.conf.all.disable_ipv6=1/' /etc/sysctl.conf || \
    printf '\nnet.ipv6.conf.all.disable_ipv6=1\n' >> /etc/sysctl.conf

  grep -q '^net\.ipv6\.conf\.default\.disable_ipv6=' /etc/sysctl.conf 2>/dev/null && \
    sed -i 's/^net\.ipv6\.conf\.default\.disable_ipv6=.*/net.ipv6.conf.default.disable_ipv6=1/' /etc/sysctl.conf || \
    printf 'net.ipv6.conf.default.disable_ipv6=1\n' >> /etc/sysctl.conf

  # 根据用户输入决定禁用哪些网卡的IPv6
  local target_ifaces
  if [[ -z "$iface_input" ]]; then
    target_ifaces=$(ls /sys/class/net 2>/dev/null | grep -v 'lo' || true)
    echo "[INFO] 未指定具体网卡，将尝试关闭所有已知网卡的 IPv6。"
  else
    target_ifaces="$iface_input"
    echo "[INFO] 将尝试关闭以下指定网卡的 IPv6: $target_ifaces"
  fi

  for iface in $target_ifaces; do
    if [[ ! -d "/sys/class/net/$iface" ]]; then
      echo "[WARN] 警告：系统当前不存在名为 '$iface' 的网卡目录，跳过配置。"
      continue
    fi
    grep -q "^net\.ipv6\.conf\.${iface}\.disable_ipv6=" /etc/sysctl.conf 2>/dev/null && \
      sed -i "s/^net\.ipv6\.conf\.${iface}\.disable_ipv6=.*/net.ipv6.conf.${iface}.disable_ipv6=1/" /etc/sysctl.conf || \
      printf "net.ipv6.conf.${iface}.disable_ipv6=1\n" >> /etc/sysctl.conf
  done

  sysctl -p
  echo "[DONE] 已永久关闭指定网卡的 IPv6，并重新加载 sysctl。"
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
  echo -e "\n[INFO] 当前系统中正在生效的 DNS 如下："
  if cmd_exists resolvectl; then
    resolvectl status | grep -E "DNS Server" || true
  fi
  echo
  read -rp "是否需要重新配置 DNS？[y/N 默认不配置跳过]: " modify_dns
  if [[ "$modify_dns" =~ ^[Yy]$ ]]; then
    read -rp "请输入 DNS (多个IP用空格分隔，直接回车默认使用 8.8.8.8 8.8.4.4): " dns_input
    # 将用户可能输入的逗号替换为空格
    dns_input="${dns_input//,/ }"
    if [[ -n "$dns_input" ]]; then
      set_dns_permanent $dns_input
    else
      set_dns_permanent 8.8.8.8 8.8.4.4
    fi
  else
    echo "[INFO] 用户选择跳过 DNS 配置。"
  fi
  
  # 重启 systemd-resolved 清理缓存，防止失效的 fe80:: 污染解析
  systemctl restart systemd-resolved 2>/dev/null || true
  sleep 2

  echo "3. 测试 OpenAI (auth.openai.com) 连通性..."
  if curl -4 -I --max-time 10 https://auth.openai.com >/dev/null 2>&1; then
    echo -e "\n[OK] ========================="
    echo "[OK] 连通性正常！网络配置成功！"
    echo "[OK] 【结论】当前网络能顺利完成域名解析并直连 OpenAI 端点，Codex 应当可以正常登录。"
    echo "[OK] ========================="
  else
    echo -e "\n[WARN] ========================="
    echo "[WARN] 连通性测试失败！"
    echo "[WARN] 【结论与排查建议】"
    echo "  1. 可能是刚禁用了 IPv6，但网卡原先的 DHCPv6 DNS (fe80::) 残留并被 systemd 优先使用了，导致解析超时。"
    echo "     -> 建议执行: systemctl restart NetworkManager (由于涉及您的 SSH 连接，请手动谨慎执行) 或者重启服务器。"
    echo "  2. 也可以在脚本选用 'write-resolvconf-static' 相关选项强制静态覆盖 /etc/resolv.conf 绕过 systemd-resolved。"
    echo "  3. 请返回主菜单选择 '2) 全面网络诊断' 查看 'DNS 配置' 中是否还存在 fe80:: 字段的 DNS。"
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
    echo "推荐操作 (一键与诊断):"
    echo "  1) 一键自动修复 (完全关闭IPv6 + 自定义DNS + 连通性测试)"
    echo "  2) 网络诊断 (包含全面和分项诊断功能)"
    echo "基本配置操作 (永久生效):"
    echo "  3) 永久关闭 IPv6 (修改 sysctl.conf)"
    echo "  5) 永久设置系统 DNS (通过 systemd-resolved)"
    echo "高级操作:"
    echo "  4) 临时关闭 IPv6 (重启失效)"
    echo "  6) 恢复 DNS 到系统默认配置 (systemd-resolved stub)"
    echo "  0) 退出工具"
    echo "======================================"
    read -rp "请输入选项数字 [0-6] 默认[1]: " choice
    if [[ -z "$choice" ]]; then
      choice="1"
    fi

    case "$choice" in
      1) one_click_fix; break ;;
      2) 
        echo "============== 诊断子菜单 =============="
        echo "  1) 全面诊断 (输出全部)"
        echo "  2) 仅诊断 系统与基础网络"
        echo "  3) 仅诊断 DNS与代理配置"
        echo "  4) 仅诊断 公网出口与连通性"
        echo "  0) 返回主菜单"
        echo "========================================"
        read -rp "请输入诊断选项 [0-4] 默认[1]: " diag_choice
        if [[ -z "$diag_choice" ]]; then diag_choice="1"; fi
        case "$diag_choice" in
          1) diagnose; break ;;
          2) diagnose_sys_net_only; break ;;
          3) diagnose_proxy_dns_only; break ;;
          4) diagnose_conn_only; break ;;
          0) continue ;;
          *) echo "[ERROR] 无效的诊断选项。"; continue ;;
        esac
        ;;
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
