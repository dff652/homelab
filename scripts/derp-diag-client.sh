#!/bin/sh
# DERP 中继诊断 — 客户端 (gl-mt2500-3)
# 兼容 busybox ash (OpenWrt)
# 部署：
#   scp scripts/derp-diag-client.sh root@192.168.2.123:/tmp/
#   ssh root@192.168.2.123 'sh /tmp/derp-diag-client.sh'

SERVER_IP="39.102.98.79"
SERVER_DOMAIN="derp.wcdz.tech"
LOG="/tmp/derp-diag-client.log"

# 清空日志
: > "$LOG"

# 同时输出到终端和日志（兼容 ash，不用进程替换）
log() {
    echo "$@" | tee -a "$LOG"
}

logrun() {
    # 执行命令，stdout+stderr 同时到终端和日志
    "$@" 2>&1 | tee -a "$LOG"
}

step() {
    echo "" | tee -a "$LOG"
    echo "══════════ $1 ══════════" | tee -a "$LOG"
}

info()  { echo "[INFO]  $1" | tee -a "$LOG"; }
pass()  { echo "[ OK ]  $1" | tee -a "$LOG"; }
fail()  { echo "[FAIL]  $1" | tee -a "$LOG"; }

wait_server() {
    echo ""
    echo ">>> 确认服务端已准备好，按 Enter 执行测试 <<<"
    read -r _
}

next_exp() {
    echo ""
    echo "回到服务端按 Enter，然后回来按 Enter 进入下一实验..."
    read -r _
}

# 测试 TLS（不用 logrun，直接捕获输出和退出码）
test_tls() {
    target="$1"; port="$2"; label="$3"
    log ""
    info "--- $label ---"
    info "命令: curl -vk --connect-timeout 5 https://${target}:${port}"
    log ">>>>>>>>"
    # 捕获输出到变量，保留真实退出码
    CURL_OUT=$(curl -vk --connect-timeout 5 "https://${target}:${port}" 2>&1)
    rc=$?
    log "$CURL_OUT"
    log "<<<<<<<<"
    log "exit_code=$rc"
    if [ $rc -eq 0 ]; then
        pass "$label -> 成功 (exit=$rc)"
    else
        fail "$label -> 失败 (exit=$rc)"
    fi
    # 额外标注具体错误类型
    if echo "$CURL_OUT" | grep -q "wrong version number"; then
        info "  错误类型: wrong version number (收到非 TLS 数据)"
    elif echo "$CURL_OUT" | grep -q "reset by peer"; then
        info "  错误类型: Connection reset by peer"
    elif echo "$CURL_OUT" | grep -q "Connection refused"; then
        info "  错误类型: Connection refused (端口无服务)"
    elif echo "$CURL_OUT" | grep -q "timed out"; then
        info "  错误类型: 超时"
    fi
    log ""
}

# 测试纯 TCP（兼容 busybox nc：无 -w 参数，用 timeout 包装）
test_tcp() {
    port="$1"; label="$2"
    log ""
    info "--- $label ---"
    info "命令: nc ${SERVER_IP} ${port} (5s timeout)"
    log ">>>>>>>>"
    # busybox nc 不支持 -w，用 timeout 或后台+wait 替代
    if command -v timeout >/dev/null 2>&1; then
        RESULT=$(echo "test" | timeout 5 nc "$SERVER_IP" "$port" 2>&1)
        rc=$?
    else
        echo "test" | nc "$SERVER_IP" "$port" &
        NC_BG=$!
        sleep 3
        if kill -0 $NC_BG 2>/dev/null; then
            kill $NC_BG 2>/dev/null
            wait $NC_BG 2>/dev/null
            RESULT="(timeout - nc still running after 3s)"
            rc=1
        else
            wait $NC_BG
            rc=$?
            RESULT="(nc exited with $rc)"
        fi
    fi
    log "$RESULT"
    log "<<<<<<<<"
    log "exit_code=$rc"
    if [ $rc -eq 0 ]; then
        pass "$label -> 成功 (exit=$rc, 响应: $RESULT)"
    else
        fail "$label -> 失败 (exit=$rc)"
    fi
    log ""
}

# ═══════════════════════════════════════════
log "┌──────────────────────────────────────────────┐"
log "│  DERP 中继诊断 — 客户端 (gl-mt2500-3)       │"
log "└──────────────────────────────────────────────┘"
log "时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "主机: $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)"
log "日志: $LOG"

# ═══════════════════════════════════════════
step "0. 客户端环境快照"
# ═══════════════════════════════════════════

info "--- 系统 ---"
logrun uname -a
logrun cat /etc/openwrt_release 2>/dev/null || true
log ""

info "--- 网络接口 (摘要) ---"
logrun ip -4 addr show scope global
log ""

info "--- 默认路由 ---"
logrun ip route show default
log ""

info "--- 到 $SERVER_IP 的策略路由 ---"
RULE=$(ip rule show 2>/dev/null | grep "$SERVER_IP")
if [ -n "$RULE" ]; then
    log "$RULE"
else
    log "(无针对 $SERVER_IP 的策略路由)"
fi
log ""

info "--- DNS 解析 $SERVER_DOMAIN ---"
logrun nslookup "$SERVER_DOMAIN" 2>&1 || true
log ""

info "--- ping $SERVER_IP ---"
logrun ping -c 3 -W 3 "$SERVER_IP"
log ""

info "--- Tailscale 状态 ---"
logrun tailscale status
log ""

info "--- tailscale netcheck (30s timeout) ---"
if command -v timeout >/dev/null 2>&1; then
    timeout 30 tailscale netcheck 2>&1 | tee -a "$LOG" || log "(netcheck timed out or failed)"
else
    logrun tailscale netcheck
fi
log ""

# ═══════════════════════════════════════════
step "实验 1/6：纯 TCP 基线（无 TLS 无 derper）"
# ═══════════════════════════════════════════

info "目的：TCP 443 端口基础连通性"
wait_server
test_tcp 443 "实验1: TCP 443 (无 derper)"
next_exp

# ═══════════════════════════════════════════
step "实验 2/6：openssl s_server TLS 基线"
# ═══════════════════════════════════════════

info "目的：最简单的 OpenSSL TLS"
wait_server
test_tls "$SERVER_IP" 443 "实验2: openssl s_server 443 (IP)"
test_tls "$SERVER_DOMAIN" 443 "实验2: openssl s_server 443 (域名)"
next_exp

# ═══════════════════════════════════════════
step "实验 3/6：derper 原始配置 on 443"
# ═══════════════════════════════════════════

info "目的：复现 derper Go TLS 外部连接问题"
wait_server
test_tls "$SERVER_DOMAIN" 443 "实验3: derper 443 (域名)"
test_tls "$SERVER_IP" 443 "实验3: derper 443 (IP)"
next_exp

# ═══════════════════════════════════════════
step "实验 4/6：derper 8080 + openssl TLS 443"
# ═══════════════════════════════════════════

info "目的：derper 在后台(8080)时，openssl TLS 是否受影响"
wait_server
test_tls "$SERVER_IP" 443 "实验4: openssl 443 + derper 8080 后台"
next_exp

# ═══════════════════════════════════════════
step "实验 5/6：derper 8080 + socat TLS 443->8080"
# ═══════════════════════════════════════════

info "目的：socat TLS 终结 + derper HTTP 端到端验证"
wait_server
test_tls "$SERVER_IP" 443 "实验5: socat 443->derper 8080 (IP)"
test_tls "$SERVER_DOMAIN" 443 "实验5: socat 443->derper 8080 (域名)"

log ""
info "--- 额外：DERP 健康检查 ---"
info "命令: curl -vk --connect-timeout 5 https://${SERVER_DOMAIN}:443/derp/latency-check"
log ">>>>>>>>"
logrun curl -vk --connect-timeout 5 "https://${SERVER_DOMAIN}:443/derp/latency-check"
log "<<<<<<<<"
log ""
next_exp

# ═══════════════════════════════════════════
step "实验 6/6：derper 运行时纯 TCP 12345"
# ═══════════════════════════════════════════

info "目的：derper 在 8080 运行时，其他端口 TCP 是否受干扰"
wait_server
test_tcp 12345 "实验6: TCP 12345 + derper 8080 后台"
next_exp

# ═══════════════════════════════════════════
step "实验后 Tailscale 状态"
# ═══════════════════════════════════════════

info "--- tailscale status ---"
logrun tailscale status
log ""

info "--- tailscale ping bj-ali-hb2 ---"
logrun tailscale ping bj-ali-hb2 || true
log ""

# ═══════════════════════════════════════════
step "诊断完成"
# ═══════════════════════════════════════════

log ""
log "客户端日志: $LOG"
log ""
log "取回日志（从 22 服务器）："
log "  scp root@192.168.2.123:$LOG /tmp/derp-diag-client.log"
log "  scp root@39.102.98.79:/tmp/derp-diag-server.log /tmp/"
