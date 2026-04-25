#!/bin/sh
# GL-MT2500 网络配置检查与修复脚本
# 用途：检查 Tailscale 转发、OpenVPN、防火墙规则的配置状态
# 使用：ssh root@192.168.2.123 'sh -s' < gl-mt2500-network-check.sh
#       或 scp 到路由器后直接执行

TARGET_NET="192.168.199.0/24"
TS_IFACE="tailscale0"
RULE_PRIO="100"
RULE_TABLE="52"
VPN_CONF="/etc/openvpn/ovpn/server.ovpn"
VPN_SUBNET="10.8.0.0"
VPN_MASK="255.255.255.0"
RC_LOCAL="/etc/rc.local"
FW_USER="/etc/firewall.user"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass()  { printf "${GREEN}[OK]${NC}   %s\n" "$1"; }
fail()  { printf "${RED}[FAIL]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
info()  { printf "       %s\n" "$1"; }

ask_yn() {
    printf "%s [y/N] " "$1"
    read -r ans
    case "$ans" in y|Y) return 0;; *) return 1;; esac
}

echo "========================================"
echo " GL-MT2500 网络配置检查"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

NEED_FIX=""

# ── 1. 运行时：策略路由 ──
echo "── 1. 策略路由规则 ──"
if ip rule list | grep -q "to ${TARGET_NET} lookup ${RULE_TABLE}"; then
    pass "ip rule to ${TARGET_NET} lookup ${RULE_TABLE} 已生效"
else
    fail "ip rule to ${TARGET_NET} lookup ${RULE_TABLE} 不存在"
    NEED_FIX="${NEED_FIX} iprule_runtime"
fi

# 检查是否有重复规则
RULE_COUNT=$(ip rule list | grep -c "to ${TARGET_NET} lookup ${RULE_TABLE}")
if [ "$RULE_COUNT" -gt 1 ]; then
    warn "策略路由规则重复 ${RULE_COUNT} 条（应为 1 条）"
    NEED_FIX="${NEED_FIX} iprule_dup"
fi

# ── 2. 运行时：iptables MASQUERADE ──
echo ""
echo "── 2. iptables MASQUERADE ──"
if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "${TARGET_NET}"; then
    pass "MASQUERADE 规则已生效"
else
    fail "MASQUERADE 规则不存在"
    NEED_FIX="${NEED_FIX} masq_runtime"
fi

MASQ_COUNT=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "${TARGET_NET}")
if [ "$MASQ_COUNT" -gt 1 ]; then
    warn "MASQUERADE 规则重复 ${MASQ_COUNT} 条（应为 1 条）"
    NEED_FIX="${NEED_FIX} masq_dup"
fi

# ── 3. OpenVPN 配置 ──
echo ""
echo "── 3. OpenVPN 配置 ──"
if [ -f "$VPN_CONF" ]; then
    # 检查 server 行
    SERVER_LINE=$(grep '^server ' "$VPN_CONF" 2>/dev/null)
    if echo "$SERVER_LINE" | grep -q "^server ${VPN_SUBNET} ${VPN_MASK}$"; then
        pass "server 行格式正确：${SERVER_LINE}"
    elif echo "$SERVER_LINE" | grep -q "^server.*${VPN_MASK}$"; then
        fail "server 行缺少网段地址：${SERVER_LINE}"
        info "应为：server ${VPN_SUBNET} ${VPN_MASK}"
        NEED_FIX="${NEED_FIX} vpn_server"
    else
        warn "未找到 server 行或格式不识别"
    fi

    # 检查 push route
    if grep -q "push \"route ${TARGET_NET%/*}" "$VPN_CONF"; then
        pass "push route 已配置"
    else
        fail "缺少 push route ${TARGET_NET}"
        NEED_FIX="${NEED_FIX} vpn_push"
    fi
else
    warn "OpenVPN 配置文件不存在：${VPN_CONF}"
fi

# ── 4. rc.local 持久化 ──
echo ""
echo "── 4. rc.local 持久化 ──"
if [ -f "$RC_LOCAL" ]; then
    if grep -q "ip rule add to ${TARGET_NET}" "$RC_LOCAL"; then
        pass "ip rule 规则已写入 rc.local"
    else
        fail "ip rule 规则未写入 rc.local"
        NEED_FIX="${NEED_FIX} rc_iprule"
    fi

    if grep -q "MASQUERADE" "$RC_LOCAL" && grep -q "${TARGET_NET}" "$RC_LOCAL"; then
        pass "MASQUERADE 规则已写入 rc.local"
    else
        fail "MASQUERADE 规则未写入 rc.local"
        NEED_FIX="${NEED_FIX} rc_masq"
    fi

    # 检查 exit 0 顺序
    if [ -n "$(sed -n '/^exit 0$/,$ { /ip rule\|iptables/p }' "$RC_LOCAL")" ]; then
        fail "rc.local 中规则在 exit 0 之后，不会执行"
        NEED_FIX="${NEED_FIX} rc_exit0"
    else
        pass "rc.local 中 exit 0 顺序正确"
    fi

    # 检查幂等写法
    if grep -q "ip rule del" "$RC_LOCAL"; then
        pass "rc.local 使用幂等写法（先删再加）"
    else
        warn "rc.local 未使用幂等写法，多次执行可能叠加规则"
        NEED_FIX="${NEED_FIX} rc_idempotent"
    fi
else
    fail "rc.local 不存在"
fi

# ── 5. firewall.user 持久化 ──
echo ""
echo "── 5. firewall.user 持久化 ──"
if [ -f "$FW_USER" ]; then
    if grep -q "ip rule add to ${TARGET_NET}" "$FW_USER"; then
        pass "ip rule 规则已写入 firewall.user"
    else
        fail "ip rule 规则未写入 firewall.user"
        NEED_FIX="${NEED_FIX} fw_iprule"
    fi

    if grep -q "MASQUERADE" "$FW_USER" && grep -q "${TARGET_NET}" "$FW_USER"; then
        pass "MASQUERADE 规则已写入 firewall.user"
    else
        fail "MASQUERADE 规则未写入 firewall.user"
        NEED_FIX="${NEED_FIX} fw_masq"
    fi

    # 检查幂等写法
    if grep -q "ip rule del" "$FW_USER"; then
        pass "firewall.user 使用幂等写法"
    else
        warn "firewall.user 未使用幂等写法，防火墙重载会叠加规则"
        NEED_FIX="${NEED_FIX} fw_idempotent"
    fi
else
    fail "firewall.user 不存在"
fi

# ── 6. 连通性测试 ──
echo ""
echo "── 6. 连通性测试 ──"
if ping -c 1 -W 3 192.168.199.94 >/dev/null 2>&1; then
    pass "ping 192.168.199.94 成功"
else
    fail "ping 192.168.199.94 失败"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://192.168.199.94:7990/ 2>/dev/null)
if [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "200" ]; then
    pass "HTTP 192.168.199.94:7990 可达 (${HTTP_CODE})"
else
    fail "HTTP 192.168.199.94:7990 不可达 (${HTTP_CODE})"
fi

# ── 修复 ──
echo ""
echo "========================================"

if [ -z "$NEED_FIX" ]; then
    printf "${GREEN}所有检查通过，无需修复。${NC}\n"
    exit 0
fi

echo "发现以下问题需要修复：${NEED_FIX}"
echo ""

# 修复运行时规则
for item in $NEED_FIX; do
    case "$item" in
        iprule_runtime)
            if ask_yn "添加策略路由规则？"; then
                ip rule add to ${TARGET_NET} lookup ${RULE_TABLE} prio ${RULE_PRIO}
                pass "策略路由规则已添加"
            fi
            ;;
        iprule_dup)
            if ask_yn "清理重复的策略路由规则（保留 1 条）？"; then
                while [ "$(ip rule list | grep -c "to ${TARGET_NET} lookup ${RULE_TABLE}")" -gt 1 ]; do
                    ip rule del to ${TARGET_NET} lookup ${RULE_TABLE} prio ${RULE_PRIO}
                done
                pass "重复规则已清理，剩余 $(ip rule list | grep -c "to ${TARGET_NET} lookup ${RULE_TABLE}") 条"
            fi
            ;;
        masq_runtime)
            if ask_yn "添加 MASQUERADE 规则？"; then
                iptables -t nat -A POSTROUTING -d ${TARGET_NET} -o ${TS_IFACE} -j MASQUERADE
                pass "MASQUERADE 规则已添加"
            fi
            ;;
        masq_dup)
            if ask_yn "清理重复的 MASQUERADE 规则（保留 1 条）？"; then
                while [ "$(iptables -t nat -L POSTROUTING -n | grep -c "${TARGET_NET}")" -gt 1 ]; do
                    iptables -t nat -D POSTROUTING -d ${TARGET_NET} -o ${TS_IFACE} -j MASQUERADE
                done
                pass "重复 MASQUERADE 已清理"
            fi
            ;;
        vpn_server)
            if ask_yn "修复 server.ovpn 的 server 行？"; then
                sed -i "s/^server  ${VPN_MASK}\$/server ${VPN_SUBNET} ${VPN_MASK}/" "$VPN_CONF"
                pass "server 行已修复"
                info "建议重启 OpenVPN: /etc/init.d/openvpn restart"
            fi
            ;;
        vpn_push)
            if ask_yn "添加 push route 到 server.ovpn？"; then
                echo "push \"route ${TARGET_NET%/*} ${VPN_MASK}\"" >> "$VPN_CONF"
                pass "push route 已添加"
                info "建议重启 OpenVPN: /etc/init.d/openvpn restart"
            fi
            ;;
        rc_exit0)
            if ask_yn "修复 rc.local 中 exit 0 的位置？"; then
                sed -i '/^exit 0$/d' "$RC_LOCAL"
                echo 'exit 0' >> "$RC_LOCAL"
                pass "rc.local exit 0 已移到末尾"
            fi
            ;;
        rc_idempotent|rc_iprule|rc_masq)
            # 只处理一次
            echo "$NEED_FIX" | grep -q "rc_done" && continue
            NEED_FIX="${NEED_FIX} rc_done"
            if ask_yn "将 rc.local 中的规则改为幂等写法（先删再加）？"; then
                sed -i '/ip rule.*192.168.199/d; /iptables.*192.168.199/d' "$RC_LOCAL"
                sed -i '/^exit 0$/d' "$RC_LOCAL"
                cat >> "$RC_LOCAL" <<'RCEOF'
ip rule del to 192.168.199.0/24 lookup 52 prio 100 2>/dev/null
ip rule add to 192.168.199.0/24 lookup 52 prio 100
iptables -t nat -D POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
exit 0
RCEOF
                pass "rc.local 已更新为幂等写法"
            fi
            ;;
        fw_idempotent|fw_iprule|fw_masq)
            echo "$NEED_FIX" | grep -q "fw_done" && continue
            NEED_FIX="${NEED_FIX} fw_done"
            if ask_yn "将 firewall.user 中的规则改为幂等写法（先删再加）？"; then
                sed -i '/ip rule.*192.168.199/d; /iptables.*192.168.199/d' "$FW_USER"
                cat >> "$FW_USER" <<'FWEOF'
ip rule del to 192.168.199.0/24 lookup 52 prio 100 2>/dev/null
ip rule add to 192.168.199.0/24 lookup 52 prio 100
iptables -t nat -D POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -d 192.168.199.0/24 -o tailscale0 -j MASQUERADE
FWEOF
                pass "firewall.user 已更新为幂等写法"
            fi
            ;;
    esac
done

echo ""
echo "========================================"
echo " 修复完成，建议重新运行本脚本验证"
echo "========================================"
