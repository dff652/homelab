#!/bin/sh
# DERP 中继诊断 — 客户端 (gl-mt2500-3)
# 子命令模式：可按顺序全跑，也可单项测试
#
# 用法：
#   sh derp-diag-client.sh all             # 全部实验顺序执行
#   sh derp-diag-client.sh test <1-6>      # 单项测试
#   sh derp-diag-client.sh openclash       # OpenClash 开关对比测试
#   sh derp-diag-client.sh snapshot        # 输出客户端环境快照

SERVER_IP="39.102.98.79"
SERVER_DOMAIN="derp.wcdz.tech"
LOG="/tmp/derp-diag-client.log"

# ── 日志 ──
log()    { echo "$@" | tee -a "$LOG"; }
logrun() { "$@" 2>&1 | tee -a "$LOG"; }
step()   { log ""; log "══════════ $1 ══════════"; }
info()   { log "[INFO]  $1"; }
pass()   { log "[ OK ]  $1"; }
fail()   { log "[FAIL]  $1"; }

# ── 测试函数 ──
test_tls() {
    target="$1"; port="$2"; label="$3"
    log ""
    info "--- $label ---"
    info "curl -vk --connect-timeout 5 https://${target}:${port}"
    log ">>>>>>>>"
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
    if echo "$CURL_OUT" | grep -q "wrong version number"; then
        info "  错误: wrong version number (收到非 TLS 数据)"
    elif echo "$CURL_OUT" | grep -q "reset by peer"; then
        info "  错误: Connection reset by peer (SNI 被拦截?)"
    elif echo "$CURL_OUT" | grep -q "internal error"; then
        info "  错误: tlsv1 alert internal error (服务端 TLS 异常)"
    elif echo "$CURL_OUT" | grep -q "Connection refused"; then
        info "  错误: Connection refused (端口无服务)"
    elif echo "$CURL_OUT" | grep -q "timed out"; then
        info "  错误: 超时"
    fi
    log ""
}

test_tcp() {
    port="$1"; label="$2"
    log ""
    info "--- $label ---"
    info "nc ${SERVER_IP} ${port} (5s timeout)"
    log ">>>>>>>>"
    NC_TMP="/tmp/derp-diag-nc-$$"
    if command -v timeout >/dev/null 2>&1; then
        RESULT=$(echo "test" | timeout 5 nc "$SERVER_IP" "$port" 2>&1)
        rc=$?
    else
        echo "test" | nc "$SERVER_IP" "$port" > "$NC_TMP" 2>&1 &
        NC_BG=$!
        sleep 3
        if kill -0 $NC_BG 2>/dev/null; then
            kill $NC_BG 2>/dev/null; wait $NC_BG 2>/dev/null
            RESULT="$(cat "$NC_TMP" 2>/dev/null) (timeout)"; rc=1
        else
            wait $NC_BG; rc=$?
            RESULT=$(cat "$NC_TMP" 2>/dev/null)
        fi
        rm -f "$NC_TMP"
    fi
    log "$RESULT"
    log "<<<<<<<<"
    log "exit_code=$rc"
    if [ $rc -eq 0 ]; then pass "$label -> 成功"; else fail "$label -> 失败 (exit=$rc)"; fi
    log ""
}

# ── snapshot ──
cmd_snapshot() {
    step "客户端环境快照"
    log "时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "主机: $(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)"
    logrun uname -a
    logrun cat /etc/openwrt_release 2>/dev/null || true
    log ""
    info "--- 网络接口 ---"
    logrun ip -4 addr show scope global
    log ""
    info "--- 默认路由 ---"
    logrun ip route show default
    log ""
    info "--- 到 $SERVER_IP 的策略路由 ---"
    ip rule show 2>/dev/null | grep "$SERVER_IP" | tee -a "$LOG" || log "(无)"
    log ""
    info "--- DNS: $SERVER_DOMAIN ---"
    logrun nslookup "$SERVER_DOMAIN" 2>&1 || true
    log ""
    info "--- ping $SERVER_IP ---"
    logrun ping -c 3 -W 3 "$SERVER_IP"
    log ""
    info "--- Tailscale ---"
    logrun tailscale status
    log ""
    info "--- tailscale netcheck (30s timeout) ---"
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 tailscale netcheck 2>&1 | tee -a "$LOG" || log "(超时或失败)"
    else
        logrun tailscale netcheck
    fi
    log ""
}

# ── test N ──
cmd_test() {
    exp="$1"
    case "$exp" in
    1)
        step "实验 1：纯 TCP 443"
        test_tcp 443 "TCP 443 (无 derper)"
        ;;
    2)
        step "实验 2：openssl s_server TLS 基线"
        test_tls "$SERVER_IP" 443 "openssl 443 (IP)"
        test_tls "$SERVER_DOMAIN" 443 "openssl 443 (域名)"
        ;;
    3)
        step "实验 3：derper Go TLS 443"
        test_tls "$SERVER_DOMAIN" 443 "derper 443 (域名)"
        test_tls "$SERVER_IP" 443 "derper 443 (IP)"
        ;;
    4)
        step "实验 4：openssl 443 + derper 8080"
        test_tls "$SERVER_IP" 443 "openssl 443 + derper 8080 (IP)"
        ;;
    5)
        step "实验 5：socat 443 → derper 8080"
        test_tls "$SERVER_IP" 443 "socat→derper (IP)"
        test_tls "$SERVER_DOMAIN" 443 "socat→derper (域名)"
        info "--- DERP 健康检查 ---"
        test_tls "$SERVER_DOMAIN" 443 "DERP latency-check (域名)"
        ;;
    6)
        step "实验 6：TCP 12345 + derper 8080"
        test_tcp 12345 "TCP 12345 + derper 8080"
        ;;
    *)
        echo "未知实验: $exp (可选 1-6)"
        return 1
        ;;
    esac
}

# ── openclash: 开关对比测试 ──
cmd_openclash() {
    step "OpenClash 开关对比测试"
    info "前提：服务端已运行 socat+derper (sh derp-diag-server.sh socat)"
    log ""

    info "=== 1/3 OpenClash 开启状态（当前） ==="
    test_tls "$SERVER_IP" 443 "OC开启 IP"
    test_tls "$SERVER_DOMAIN" 443 "OC开启 域名"

    log ""
    info "=== 2/3 关闭 OpenClash ==="
    info "执行: /etc/init.d/openclash stop"
    /etc/init.d/openclash stop 2>&1 | tee -a "$LOG"
    sleep 3
    info "OpenClash 已关闭"

    test_tls "$SERVER_IP" 443 "OC关闭 IP"
    test_tls "$SERVER_DOMAIN" 443 "OC关闭 域名"

    log ""
    info "=== 3/3 恢复 OpenClash ==="
    info "执行: /etc/init.d/openclash start"
    /etc/init.d/openclash start 2>&1 | tee -a "$LOG"
    info "OpenClash 已恢复"

    log ""
    step "OpenClash 测试结果汇总"
    log "  OC开启 + IP:   看上方结果"
    log "  OC开启 + 域名: 看上方结果"
    log "  OC关闭 + IP:   看上方结果"
    log "  OC关闭 + 域名: 看上方结果"
    log ""
    log "如果 OC关闭后域名测试成功 → OpenClash 是根因"
    log "配置 OpenClash 放行 derp.wcdz.tech 即可解决"
}

# ── all ──
cmd_all() {
    : > "$LOG"
    cmd_snapshot

    for exp in 1 2 3 4 5 6; do
        echo ""
        echo ">>> 确认服务端已 setup $exp，按 Enter 开始测试 <<<"
        read -r _
        cmd_test "$exp"
    done

    step "实验后 Tailscale"
    logrun tailscale status
    logrun tailscale ping bj-ali-hb2 || true
    log ""
    step "完成"
    log "日志: $LOG"
}

# ── sni: SNI DPI 隔离测试 ──
cmd_sni() {
    step "SNI DPI 隔离测试"
    info "前提：服务端 socat+derper 在运行"
    log ""

    info "=== 1. IP 直连（无 SNI）==="
    test_tls "$SERVER_IP" 443 "IP 直连（无域名 SNI）"

    info "=== 2. 真实域名 ==="
    test_tls "$SERVER_DOMAIN" 443 "域名 $SERVER_DOMAIN"

    info "=== 3. --resolve 强制域名走真实 IP（排除 DNS）==="
    log ""
    info "--- --resolve $SERVER_DOMAIN ---"
    info "curl -vk --connect-timeout 5 --resolve ${SERVER_DOMAIN}:443:${SERVER_IP} https://${SERVER_DOMAIN}:443"
    log ">>>>>>>>"
    CURL_OUT=$(curl -vk --connect-timeout 5 --resolve "${SERVER_DOMAIN}:443:${SERVER_IP}" "https://${SERVER_DOMAIN}:443" 2>&1)
    rc=$?
    log "$CURL_OUT"
    log "<<<<<<<<"
    log "exit_code=$rc"
    if [ $rc -eq 0 ]; then pass "--resolve 域名 -> 成功"; else fail "--resolve 域名 -> 失败 (exit=$rc)"; fi
    log ""

    info "=== 4. 无关域名 → 同 IP（测试是否所有域名都被拦）==="
    log ""
    info "--- --resolve hello.example.org ---"
    CURL_OUT=$(curl -vk --connect-timeout 5 --resolve "hello.example.org:443:${SERVER_IP}" "https://hello.example.org:443" 2>&1)
    rc=$?
    log "exit_code=$rc"
    if [ $rc -eq 0 ]; then pass "无关域名 -> 成功"; else fail "无关域名 -> 失败 (exit=$rc)"; fi
    log ""

    step "SNI 测试结论"
    log "  IP 通 + 所有域名不通 → IP 被 DPI 标记，所有域名 SNI 被拦"
    log "  IP 通 + 特定域名不通 → 该域名/关键词被 DPI 拦截"
    log "  IP 通 + 域名也通     → 无 SNI DPI 干扰"
}

# ── killclash: 强制杀 OpenClash 后测试 ──
cmd_killclash() {
    step "强制杀 OpenClash 测试"
    info "目的：排除 OpenClash 对 TLS 的干扰"
    log ""

    info "=== 杀掉 OpenClash（watchdog + clash）==="
    pgrep -f openclash_watchdog | xargs kill 2>/dev/null || true
    sleep 1
    killall clash 2>/dev/null
    sleep 2
    if ps | grep -i clash | grep -v grep > /dev/null; then
        fail "clash 仍在运行"
    else
        pass "clash 已停止"
    fi
    log ""

    info "=== 测试 ==="
    test_tls "$SERVER_IP" 443 "OC死亡 IP"
    test_tls "$SERVER_DOMAIN" 443 "OC死亡 域名"

    info "=== 恢复 OpenClash ==="
    /etc/init.d/openclash restart 2>&1 | tee -a "$LOG"
    log ""

    step "killclash 结论"
    log "  杀 OC 后域名通 → OpenClash 是原因"
    log "  杀 OC 后域名仍不通 → 非 OpenClash（ISP DPI 等）"
}

# ── verify: 部署后端到端验证 ──
cmd_verify() {
    step "DERP 端到端验证"
    log "时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log ""

    info "--- tailscale netcheck ---"
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 tailscale netcheck 2>&1 | tee -a "$LOG" || log "(超时)"
    else
        logrun tailscale netcheck
    fi
    log ""

    info "--- tailscale ping istoreos ---"
    logrun tailscale ping -c 5 istoreos 2>&1 || logrun tailscale ping istoreos
    log ""

    info "--- tailscale ping bj-ali-hb2 ---"
    logrun tailscale ping -c 5 bj-ali-hb2 2>&1 || logrun tailscale ping bj-ali-hb2
    log ""

    info "--- tailscale status (relay 信息) ---"
    logrun tailscale status | grep -E '(istoreos|bj-ali-hb2)'
    log ""

    step "验收标准"
    log "  netcheck: ali-bj 延迟 < 20ms"
    log "  ping istoreos: via DERP(ali-bj) < 20ms"
}

# ── 主入口 ──
case "${1:-help}" in
    all)        cmd_all ;;
    test)       cmd_test "${2:?用法: test <1-6>}" ;;
    openclash)  cmd_openclash ;;
    sni)        cmd_sni ;;
    killclash)  cmd_killclash ;;
    verify)     cmd_verify ;;
    snapshot)   cmd_snapshot ;;
    help|*)
        cat <<'USAGE'
DERP 中继诊断 — 客户端

用法：
  sh derp-diag-client.sh all              全部 6 个实验顺序执行
  sh derp-diag-client.sh test <1-6>       单项实验测试
  sh derp-diag-client.sh openclash        OpenClash init 开关对比
  sh derp-diag-client.sh killclash        强制杀 clash 进程后测试
  sh derp-diag-client.sh sni              SNI DPI 隔离测试
  sh derp-diag-client.sh verify           部署后端到端验证
  sh derp-diag-client.sh snapshot         客户端环境快照

实验列表：
  1  纯 TCP 443          2  openssl TLS 基线
  3  derper Go TLS       4  openssl + derper 隔离
  5  socat → derper      6  TCP + derper 交叉
USAGE
        ;;
esac
