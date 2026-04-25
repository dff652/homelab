#!/bin/bash
#
# GitHub 连通性诊断脚本
# 用于排查开发机通过旁路由 (OpenClash + AdGuardHome) 访问 GitHub 的问题
#
# 使用: bash diag-github.sh [旁路由IP]
# 示例: bash diag-github.sh 192.168.2.123
#

set -u

ROUTER_IP="${1:-192.168.2.123}"
OPENCLASH_DNS_PORT=7874

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE} GitHub 连通性诊断报告${NC}"
echo -e "${BLUE}======================================${NC}"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "旁路由: $ROUTER_IP"
echo ""

# ============================================================
echo -e "${BLUE}[1/7] 基础网络连通性${NC}"
# ============================================================

if ping -c 1 -W 3 "$ROUTER_IP" &>/dev/null; then
    pass "旁路由 $ROUTER_IP 可达"
else
    fail "旁路由 $ROUTER_IP 不可达"
    echo "    检查: ip route show default"
    exit 1
fi

if ping -c 1 -W 5 github.com &>/dev/null; then
    GH_PING_IP=$(ping -c 1 -W 5 github.com 2>/dev/null | head -1 | grep -oP '\(\K[^)]+')
    pass "github.com 可 ping ($GH_PING_IP)"
else
    fail "github.com 不可 ping"
fi

echo ""

# ============================================================
echo -e "${BLUE}[2/7] DNS 解析检查${NC}"
# ============================================================

# 本地 DNS
LOCAL_IP=$(dig +short github.com 2>/dev/null | head -1)
if [ -z "$LOCAL_IP" ]; then
    fail "本地 DNS 解析 github.com 失败"
elif echo "$LOCAL_IP" | grep -qP '^198\.18\.'; then
    fail "github.com → $LOCAL_IP (Fake-IP! 需加入 OpenClash Fake-IP Filter)"
else
    pass "github.com → $LOCAL_IP (真实 IP)"
fi

# 旁路由 AdGuardHome
ROUTER_IP_RESULT=$(dig @"$ROUTER_IP" +short github.com 2>/dev/null | head -1)
if echo "$ROUTER_IP_RESULT" | grep -qP '^198\.18\.'; then
    fail "旁路由 ADG github.com → $ROUTER_IP_RESULT (Fake-IP, Filter 未生效)"
else
    pass "旁路由 ADG github.com → $ROUTER_IP_RESULT"
fi

# OpenClash DNS 直查
OC_IP=$(dig @"$ROUTER_IP" -p "$OPENCLASH_DNS_PORT" +short github.com 2>/dev/null | head -1)
if echo "$OC_IP" | grep -qP '^198\.18\.'; then
    warn "OpenClash DNS github.com → $OC_IP (仍为 Fake-IP，Filter 可能未生效)"
else
    pass "OpenClash DNS github.com → $OC_IP (Filter 已生效)"
fi

# 其他 GitHub 域名
echo ""
info "GitHub 相关域名解析:"
for domain in github.com api.github.com raw.githubusercontent.com gist.github.com ssh.github.com; do
    ip=$(dig +short "$domain" 2>/dev/null | head -1)
    if echo "$ip" | grep -qP '^198\.18\.'; then
        printf "    %-35s → %s ${YELLOW}(Fake-IP)${NC}\n" "$domain" "$ip"
    else
        printf "    %-35s → %s ${GREEN}(真实IP)${NC}\n" "$domain" "$ip"
    fi
done

echo ""

# ============================================================
echo -e "${BLUE}[3/7] HTTPS/TLS 握手测试${NC}"
# ============================================================

CURL_RESULT=$(curl -sI --connect-timeout 10 -o /dev/null -w "%{http_code}|%{ssl_verify_result}|%{remote_ip}|%{time_connect}|%{time_appconnect}" https://github.com 2>&1)
HTTP_CODE=$(echo "$CURL_RESULT" | cut -d'|' -f1)
SSL_VERIFY=$(echo "$CURL_RESULT" | cut -d'|' -f2)
REMOTE_IP=$(echo "$CURL_RESULT" | cut -d'|' -f3)
TIME_CONNECT=$(echo "$CURL_RESULT" | cut -d'|' -f4)
TIME_TLS=$(echo "$CURL_RESULT" | cut -d'|' -f5)

if [ "$HTTP_CODE" = "200" ]; then
    pass "HTTPS github.com → HTTP $HTTP_CODE (IP: $REMOTE_IP, TLS: ${TIME_TLS}s)"
elif [ "$HTTP_CODE" = "000" ]; then
    fail "HTTPS github.com → 连接失败 (TLS 握手中断)"
    # 尝试用 --resolve 绕过
    BYPASS_CODE=$(curl -sI --connect-timeout 10 --resolve "github.com:443:140.82.113.3" -o /dev/null -w "%{http_code}" https://github.com 2>&1)
    if [ "$BYPASS_CODE" = "200" ]; then
        info "用真实 IP 绕过后正常 → 问题在 Fake-IP/DNS 层"
    fi
else
    warn "HTTPS github.com → HTTP $HTTP_CODE (非预期响应码)"
fi

if [ "$SSL_VERIFY" = "0" ]; then
    pass "TLS 证书验证通过 (ssl_verify_result=0)"
elif [ -n "$SSL_VERIFY" ] && [ "$SSL_VERIFY" != "0" ]; then
    fail "TLS 证书验证失败 (ssl_verify_result=$SSL_VERIFY)"
fi

echo ""

# ============================================================
echo -e "${BLUE}[4/7] TLS 证书详情${NC}"
# ============================================================

CERT_INFO=$(echo | openssl s_client -connect github.com:443 -servername github.com 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null)
if [ -n "$CERT_INFO" ]; then
    pass "TLS 证书获取成功"
    echo "$CERT_INFO" | while IFS= read -r line; do
        info "$line"
    done
else
    fail "无法获取 TLS 证书"
fi

echo ""

# ============================================================
echo -e "${BLUE}[5/7] Git 操作测试${NC}"
# ============================================================

# 检查 git 的 SSL 后端
GIT_SSL=$(ldd "$(which git)" 2>/dev/null | grep -oE "lib(gnutls|ssl|crypto)" | head -1)
info "Git SSL 后端: ${GIT_SSL:-unknown}"

# 测试 git ls-remote
if git ls-remote --exit-code https://github.com/github/docs.git HEAD &>/dev/null; then
    pass "git ls-remote (HTTPS) 成功"
else
    fail "git ls-remote (HTTPS) 失败"
fi

echo ""

# ============================================================
echo -e "${BLUE}[6/7] SSH 连接测试${NC}"
# ============================================================

SSH_RESULT=$(ssh -T git@github.com -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new 2>&1)
if echo "$SSH_RESULT" | grep -q "successfully authenticated"; then
    pass "SSH git@github.com 认证成功"
else
    SSH_ERR=$(echo "$SSH_RESULT" | head -1)
    fail "SSH git@github.com 失败: $SSH_ERR"
fi

# SSH config 检查
if grep -q "github.com" ~/.ssh/config 2>/dev/null; then
    SSH_HOST=$(grep -A3 "github.com" ~/.ssh/config | grep -i hostname | awk '{print $2}')
    SSH_PORT=$(grep -A3 "github.com" ~/.ssh/config | grep -i port | awk '{print $2}')
    info "SSH 配置: Hostname=$SSH_HOST Port=$SSH_PORT"
fi

echo ""

# ============================================================
echo -e "${BLUE}[7/7] 网络路径分析${NC}"
# ============================================================

info "默认网关: $(ip route show default | awk '{print $3}' | head -1)"
info "DNS 服务器: $(grep nameserver /etc/resolv.conf | awk '{print $2}')"

# 检查 systemd-resolved
if systemctl is-active systemd-resolved &>/dev/null; then
    RESOLVED_DNS=$(resolvectl status 2>/dev/null | grep "Current DNS Server" | head -1 | awk '{print $NF}')
    info "systemd-resolved 当前 DNS: $RESOLVED_DNS"
fi

# 检查路由路径
GH_ROUTE=$(ip route get 20.205.243.166 2>/dev/null | head -1)
info "到 GitHub (20.205.243.166) 路由: $GH_ROUTE"

echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE} 诊断完成${NC}"
echo -e "${BLUE}======================================${NC}"

# 汇总
echo ""
if [ "$HTTP_CODE" = "200" ] && [ "$SSL_VERIFY" = "0" ]; then
    echo -e "${GREEN}结论: GitHub HTTPS 连接正常${NC}"
else
    echo -e "${RED}结论: GitHub HTTPS 存在问题${NC}"
    echo ""
    echo "建议排查步骤:"
    echo "  1. 检查 github.com 是否在 OpenClash Fake-IP Filter 中"
    echo "  2. 清理 OpenClash DNS 缓存 (LuCI → OpenClash → 清理 DNS 缓存)"
    echo "  3. 刷新本地 DNS: sudo systemctl restart systemd-resolved"
    echo "  4. 临时方案: git remote set-url origin git@github.com:<user>/<repo>.git"
fi
