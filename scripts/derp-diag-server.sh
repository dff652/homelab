#!/bin/sh
# DERP 中继诊断 — 服务端 (bj-ali-hb2)
# v2: 修复端口清理问题
# 部署：
#   scp scripts/derp-diag-server.sh root@39.102.98.79:/tmp/
#   ssh root@39.102.98.79 'sh /tmp/derp-diag-server.sh'

CERT="/etc/nginx/derp.crt"
KEY="/etc/nginx/derp.key"
DERP_IMAGE="registry.linkease.net:5443/fredliang/derper:latest"
LOG="/tmp/derp-diag-server.log"
IPT_BASELINE="/tmp/derp-diag-ipt-baseline.txt"

: > "$LOG"

log()    { echo "$@" | tee -a "$LOG"; }
logrun() { "$@" 2>&1 | tee -a "$LOG"; }
step()   { log ""; log "══════════ $1 ══════════"; }
info()   { log "[INFO]  $1"; }
pass()   { log "[ OK ]  $1"; }
fail()   { log "[FAIL]  $1"; }

wait_client() {
    echo ""
    echo ">>> 切到客户端终端执行对应实验，完成后回来按 Enter <<<"
    read -r _
}

# 强制清理指定端口上的所有进程
nuke_port() {
    port="$1"

    # fuser 直接按端口杀（最精确，不误伤其他进程）
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${port}/tcp" 2>/dev/null || true
        sleep 0.3
        fuser -k -9 "${port}/tcp" 2>/dev/null || true
    fi

    # fallback: 从 ss 提取 PID 逐个杀
    for pid in $(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u); do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.3
}

# 停掉所有可能相关的服务
kill_all_services() {
    info "停止所有相关服务..."
    docker stop derper-test 2>/dev/null; docker rm derper-test 2>/dev/null
    docker stop derper 2>/dev/null
    pkill -9 -f 'openssl s_server' 2>/dev/null || true
    pkill -9 -f 'socat.*OPENSSL-LISTEN' 2>/dev/null || true
    pkill -9 -f 'socat.*openssl-listen' 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    nuke_port 443
    nuke_port 12345
    nuke_port 8080
}

# 确认端口干净，不干净就报错退出
assert_port_free() {
    port="$1"
    PIDS=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u)
    if [ -n "$PIDS" ]; then
        fail "端口 $port 仍被占用! PIDs: $PIDS"
        logrun ss -tlnp | grep ":${port} "
        fail "请手动清理后重试。脚本退出。"
        exit 1
    fi
    pass "端口 $port 已清空"
}

# 确认端口被预期的进程占用
assert_port_held_by() {
    port="$1"
    expected="$2"
    RESULT=$(ss -tlnp 2>/dev/null | grep ":${port} ")
    if echo "$RESULT" | grep -q "$expected"; then
        pass "端口 $port 由 $expected 监听"
        log "  $RESULT"
    else
        fail "端口 $port 未被 $expected 监听!"
        log "  实际: $RESULT"
        log "  (该实验结果可能不可信)"
    fi
}

# 启动 derper 容器（减少重复的 docker run）
# 用法: start_derper <port> <stun: true|false>
start_derper() {
    d_port="$1"
    d_stun="$2"
    logrun docker run -d --name derper-test --network=host \
        -e DERP_DOMAIN=derp.wcdz.tech \
        -e DERP_CERT_MODE=letsencrypt \
        -e DERP_ADDR=":${d_port}" \
        -e DERP_STUN="$d_stun" \
        -e DERP_VERIFY_CLIENTS=false \
        "$DERP_IMAGE"
    sleep 5
    info "--- derper 容器状态 ---"
    logrun docker ps -a --filter name=derper-test --format 'table {{.Names}}\t{{.Status}}'
    log ""
    info "--- derper 启动日志 ---"
    logrun docker logs derper-test 2>&1 | tail -20
    log ""
}

# 停止 derper 并清理端口
# 用法: stop_derper [port ...]
stop_derper() {
    docker stop derper-test 2>&1 | tee -a "$LOG"
    docker rm derper-test 2>&1 | tee -a "$LOG"
    for p in "$@"; do
        nuke_port "$p"
    done
}

# ═══════════════════════════════════════════
log "┌─────────────────────────────────────────┐"
log "│  DERP 中继诊断 v2 — 服务端 (bj-ali-hb2) │"
log "└─────────────────────────────────────────┘"
log "时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "主机: $(hostname)"
log "日志: $LOG"

# ═══════════════════════════════════════════
step "0. 环境快照 + 全面清理"
# ═══════════════════════════════════════════

info "--- 系统 ---"
logrun uname -a
log ""

info "--- IP 地址 ---"
logrun ip -4 addr show scope global
log ""

info "--- 证书 ---"
if [ -f "$CERT" ]; then
    logrun openssl x509 -in "$CERT" -noout -subject -issuer -dates
    pass "证书存在"
else
    fail "证书不存在: $CERT"
    exit 1
fi
log ""

info "--- Docker ---"
logrun docker --version
logrun docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
log ""

info "--- 清理前端口状态 ---"
logrun ss -tlnp
log ""

info "--- iptables 基线 ---"
iptables-save > "$IPT_BASELINE" 2>&1
logrun cat "$IPT_BASELINE"
log ""

# 全面清理
kill_all_services
assert_port_free 443
assert_port_free 8080
assert_port_free 12345
log ""

# ═══════════════════════════════════════════
step "实验 1/6：纯 TCP 基线（无 TLS 无 derper）"
# ═══════════════════════════════════════════

info "目的：验证 TCP 443 基础连通性"
# 不用 while 循环，单次 nc 即可（避免僵尸进程）
info "启动 nc 监听 443（单次）..."
echo "DERP_DIAG_TCP_OK" | nc -l -p 443 &
NC_PID=$!
sleep 0.5
assert_port_held_by 443 "nc"

wait_client

kill -9 $NC_PID 2>/dev/null; wait $NC_PID 2>/dev/null
nuke_port 443
assert_port_free 443
log ""

# ═══════════════════════════════════════════
step "实验 2/6：openssl s_server（TLS 基线）"
# ═══════════════════════════════════════════

info "目的：验证外部 OpenSSL TLS 握手（最简 TLS）"
assert_port_free 443
info "启动 openssl s_server on 443..."
openssl s_server -accept 443 -cert "$CERT" -key "$KEY" -www </dev/null >/dev/null 2>&1 &
OPENSSL_PID=$!
sleep 1
assert_port_held_by 443 "openssl"

wait_client

kill $OPENSSL_PID 2>/dev/null; wait $OPENSSL_PID 2>/dev/null
nuke_port 443
assert_port_free 443
log ""

# ═══════════════════════════════════════════
step "实验 3/6：derper 原始配置 on 443（复现问题）"
# ═══════════════════════════════════════════

info "目的：重现 derper Go TLS 外部连接"
assert_port_free 443
start_derper 443 true

# 检查 derper 是否真的在跑
if docker ps --filter name=derper-test --filter status=running -q | grep -q .; then
    pass "derper-test 容器运行中"
    assert_port_held_by 443 "derper\|docker"
else
    fail "derper-test 未运行（可能端口冲突或证书问题）"
    logrun ss -tlnp | grep ':443'
fi
log ""

info "--- iptables 变化 ---"
iptables-save > /tmp/derp-diag-ipt-exp3.txt 2>&1
# 过滤掉纯时间戳注释行，只看实质规则差异
DIFF=$(diff "$IPT_BASELINE" /tmp/derp-diag-ipt-exp3.txt 2>&1 | grep -vE '^[<>] #|^---$|^[0-9]' ) || true
if [ -z "$DIFF" ]; then
    pass "iptables 无实质变化"
else
    fail "iptables 有变化:"
    log "$DIFF"
fi
log ""

wait_client

info "--- derper 日志（实验后）---"
logrun docker logs derper-test 2>&1 | tail -20
log ""

stop_derper 443
assert_port_free 443
log ""

# ═══════════════════════════════════════════
step "实验 4/6：derper HTTP 8080 + openssl TLS 443"
# ═══════════════════════════════════════════

info "目的：隔离 Go TLS — derper 只跑 HTTP，openssl 做 TLS"
assert_port_free 443
assert_port_free 8080

start_derper 8080 false

info "启动 openssl s_server on 443..."
openssl s_server -accept 443 -cert "$CERT" -key "$KEY" -www </dev/null >/dev/null 2>&1 &
OPENSSL_PID=$!
sleep 1

assert_port_held_by 443 "openssl"
assert_port_held_by 8080 "derper\|docker"
log ""

wait_client

kill $OPENSSL_PID 2>/dev/null; wait $OPENSSL_PID 2>/dev/null
stop_derper 443 8080
assert_port_free 443
assert_port_free 8080
log ""

# ═══════════════════════════════════════════
step "实验 5/6：derper HTTP 8080 + socat TLS 443->8080"
# ═══════════════════════════════════════════

info "目的：验证 socat TLS 终结 + derper HTTP 端到端方案"
assert_port_free 443
assert_port_free 8080

start_derper 8080 true

info "启动 socat TLS 终结 443 -> 8080..."
socat OPENSSL-LISTEN:443,cert="$CERT",key="$KEY",reuseaddr,fork TCP:127.0.0.1:8080 &
SOCAT_PID=$!
sleep 1

assert_port_held_by 443 "socat"
assert_port_held_by 8080 "derper\|docker"
log ""

wait_client

info "--- derper 日志（实验后）---"
logrun docker logs derper-test 2>&1 | tail -10
log ""

kill $SOCAT_PID 2>/dev/null; wait $SOCAT_PID 2>/dev/null
stop_derper 443 8080
assert_port_free 443
assert_port_free 8080
log ""

# ═══════════════════════════════════════════
step "实验 6/6：derper 运行时纯 TCP 12345"
# ═══════════════════════════════════════════

info "目的：derper 在 8080 运行时，其他端口 TCP 是否受干扰"
assert_port_free 8080
assert_port_free 12345

start_derper 8080 true

info "启动 nc 监听 12345（单次）..."
echo "DERP_DIAG_TCP_OK" | nc -l -p 12345 &
NC_PID=$!
sleep 0.5

assert_port_held_by 12345 "nc"
assert_port_held_by 8080 "derper\|docker"
log ""

wait_client

kill -9 $NC_PID 2>/dev/null; wait $NC_PID 2>/dev/null
stop_derper 8080 12345
log ""

# ═══════════════════════════════════════════
step "实验后环境快照"
# ═══════════════════════════════════════════

info "--- iptables (实验后) ---"
iptables-save 2>&1 | tee -a "$LOG"
log ""

info "--- Docker 容器 ---"
logrun docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
log ""

info "--- 端口监听 ---"
logrun ss -tlnp
log ""

# ═══════════════════════════════════════════
step "诊断完成"
# ═══════════════════════════════════════════

log ""
log "服务端日志: $LOG"
log ""
log "取回日志（从 22 服务器）："
log "  scp root@39.102.98.79:$LOG /tmp/derp-diag-server.log"
