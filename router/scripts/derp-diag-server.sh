#!/bin/sh
# DERP 中继诊断 — 服务端 (bj-ali-hb2)
# 子命令模式：可按顺序全跑，也可单项操作
#
# 用法：
#   sh derp-diag-server.sh all         # 6 个实验顺序执行（交互式）
#   sh derp-diag-server.sh setup N     # 启动实验 N 的服务端环境 (1-6)
#   sh derp-diag-server.sh socat       # 启动 socat+derper 生产配置
#   sh derp-diag-server.sh clean       # 清理所有服务和端口
#   sh derp-diag-server.sh status      # 显示当前端口和容器状态
#   sh derp-diag-server.sh snapshot    # 输出完整环境快照（写入日志）

CERT="/etc/nginx/derp.crt"
KEY="/etc/nginx/derp.key"
DERP_IMAGE="registry.linkease.net:5443/fredliang/derper:latest"
LOG="/tmp/derp-diag-server.log"
IPT_BASELINE="/tmp/derp-diag-ipt-baseline.txt"

# ── 日志 ──
log()    { echo "$@" | tee -a "$LOG"; }
logrun() { "$@" 2>&1 | tee -a "$LOG"; }
step()   { log ""; log "══════════ $1 ══════════"; }
info()   { log "[INFO]  $1"; }
pass()   { log "[ OK ]  $1"; }
fail()   { log "[FAIL]  $1"; }

# ── 端口管理 ──
nuke_port() {
    port="$1"
    if command -v fuser >/dev/null 2>&1; then
        fuser -k "${port}/tcp" 2>/dev/null || true
        sleep 0.3
        fuser -k -9 "${port}/tcp" 2>/dev/null || true
    fi
    for pid in $(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u); do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.3
}

assert_port_free() {
    port="$1"
    PIDS=$(ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | sort -u)
    if [ -n "$PIDS" ]; then
        fail "端口 $port 仍被占用! PIDs: $PIDS"
        ss -tlnp 2>/dev/null | grep ":${port} " | tee -a "$LOG"
        return 1
    fi
    pass "端口 $port 已清空"
}

assert_port_held_by() {
    port="$1"; expected="$2"
    RESULT=$(ss -tlnp 2>/dev/null | grep ":${port} ")
    if echo "$RESULT" | grep -q "$expected"; then
        pass "端口 $port 由 $expected 监听"
    else
        fail "端口 $port 未被 $expected 监听: $RESULT"
    fi
}

# ── 服务管理 ──
start_derper() {
    d_port="$1"; d_stun="$2"
    info "启动 derper (port=$d_port, stun=$d_stun)..."
    logrun docker run -d --name derper-test --network=host \
        -e DERP_DOMAIN=gw1.wcdz.tech \
        -e DERP_CERT_MODE=letsencrypt \
        -e DERP_ADDR=":${d_port}" \
        -e DERP_STUN="$d_stun" \
        -e DERP_VERIFY_CLIENTS=false \
        "$DERP_IMAGE"
    sleep 5
    if docker ps --filter name=derper-test --filter status=running -q | grep -q .; then
        pass "derper-test 运行中"
        logrun docker logs derper-test 2>&1 | tail -10
    else
        fail "derper-test 启动失败"
        logrun docker logs derper-test 2>&1 | tail -10
    fi
}

start_openssl() {
    port="$1"
    info "启动 openssl s_server on $port..."
    openssl s_server -accept "$port" -cert "$CERT" -key "$KEY" -www </dev/null >/dev/null 2>&1 &
    sleep 1
}

start_socat() {
    from_port="$1"; to_port="$2"
    info "启动 socat TLS $from_port → $to_port..."
    socat OPENSSL-LISTEN:"$from_port",cert="$CERT",key="$KEY",verify=0,reuseaddr,fork TCP:127.0.0.1:"$to_port" &
    sleep 1
}

stop_derper() {
    docker stop derper-test 2>/dev/null; docker rm derper-test 2>/dev/null
    for p in "$@"; do nuke_port "$p"; done
}

# ── clean ──
cmd_clean() {
    step "清理所有服务"
    docker stop derper-test 2>/dev/null; docker rm derper-test 2>/dev/null
    docker stop derper 2>/dev/null
    pkill -9 -f 'openssl s_server' 2>/dev/null || true
    pkill -9 -f 'socat.*OPENSSL-LISTEN' 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    nuke_port 443; nuke_port 8080; nuke_port 12345
    assert_port_free 443
    assert_port_free 8080
    assert_port_free 12345
    pass "清理完成"
}

# ── status ──
cmd_status() {
    step "当前状态"
    info "--- Docker 容器 ---"
    logrun docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    log ""
    info "--- 相关端口 ---"
    logrun ss -tlnp | grep -E ':(443|8080|12345|3478)\s' || log "(无相关端口)"
}

# ── snapshot ──
cmd_snapshot() {
    step "环境快照"
    info "--- 系统 ---"
    logrun uname -a
    log ""
    info "--- IP ---"
    logrun ip -4 addr show scope global
    log ""
    info "--- 证书 ---"
    if [ -f "$CERT" ]; then
        logrun openssl x509 -in "$CERT" -noout -subject -issuer -dates
    else
        fail "证书不存在: $CERT"
    fi
    log ""
    info "--- iptables ---"
    iptables-save > "$IPT_BASELINE" 2>&1
    logrun cat "$IPT_BASELINE"
    log ""
    info "--- Tailscale ---"
    logrun tailscale status 2>&1 || log "(tailscale 未运行)"
    log ""
    cmd_status
}

# ── setup N ──
cmd_setup() {
    exp="$1"
    cmd_clean

    case "$exp" in
    1)
        step "实验 1：纯 TCP 443（无 TLS 无 derper）"
        echo "DERP_DIAG_TCP_OK" | nc -l -p 443 &
        sleep 0.5
        assert_port_held_by 443 "nc"
        ;;
    2)
        step "实验 2：openssl s_server 443（TLS 基线）"
        start_openssl 443
        assert_port_held_by 443 "openssl"
        ;;
    3)
        step "实验 3：derper 原始配置 443（Go TLS）"
        start_derper 443 true
        assert_port_held_by 443 "derper\|docker"
        # iptables 对比
        if [ -f "$IPT_BASELINE" ]; then
            iptables-save > /tmp/derp-diag-ipt-exp3.txt 2>&1
            DIFF=$(diff "$IPT_BASELINE" /tmp/derp-diag-ipt-exp3.txt 2>&1 | grep -vE '^[<>] #|^---$|^[0-9]') || true
            if [ -z "$DIFF" ]; then pass "iptables 无实质变化"; else fail "iptables 有变化:"; log "$DIFF"; fi
        fi
        ;;
    4)
        step "实验 4：openssl 443 + derper 8080（隔离 Go TLS）"
        start_derper 8080 false
        start_openssl 443
        assert_port_held_by 443 "openssl"
        assert_port_held_by 8080 "derper\|docker"
        ;;
    5|socat)
        step "实验 5 / socat 生产配置：socat 443 → derper 8080"
        start_derper 8080 true
        start_socat 443 8080
        assert_port_held_by 443 "socat"
        assert_port_held_by 8080 "derper\|docker"
        ;;
    6)
        step "实验 6：derper 8080 + nc TCP 12345"
        start_derper 8080 true
        echo "DERP_DIAG_TCP_OK" | nc -l -p 12345 &
        sleep 0.5
        assert_port_held_by 12345 "nc"
        assert_port_held_by 8080 "derper\|docker"
        ;;
    *)
        echo "未知实验: $exp (可选 1-6 或 socat)"
        return 1
        ;;
    esac

    log ""
    pass "服务端就绪，可执行客户端测试"
    cmd_status
}

# ── socat (= setup 5 的别名) ──
cmd_socat() {
    cmd_setup socat
}

# ── all: 顺序执行所有实验 ──
cmd_all() {
    : > "$LOG"
    log "时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "主机: $(hostname)"
    log "日志: $LOG"

    cmd_snapshot

    for exp in 1 2 3 4 5 6; do
        cmd_setup "$exp"
        echo ""
        echo ">>> 切到客户端终端执行实验 $exp 的测试，完成后回来按 Enter <<<"
        read -r _
        # 实验后日志
        if [ "$exp" = "3" ] || [ "$exp" = "5" ]; then
            info "--- derper 日志（实验后）---"
            logrun docker logs derper-test 2>&1 | tail -10
        fi
        log ""
    done

    cmd_clean
    step "全部完成"
    log "日志: $LOG"
}

# ── 主入口 ──
case "${1:-help}" in
    all)      cmd_all ;;
    setup)    cmd_setup "${2:?用法: setup <1-6>}" ;;
    socat)    cmd_socat ;;
    clean)    cmd_clean ;;
    status)   cmd_status ;;
    snapshot) cmd_snapshot ;;
    help|*)
        cat <<'USAGE'
DERP 中继诊断 — 服务端

用法：
  sh derp-diag-server.sh all           全部 6 个实验顺序执行
  sh derp-diag-server.sh setup <1-6>   启动单个实验的服务端环境
  sh derp-diag-server.sh socat         启动 socat+derper 生产配置 (=setup 5)
  sh derp-diag-server.sh clean         清理所有服务和端口
  sh derp-diag-server.sh status        显示当前端口和容器状态
  sh derp-diag-server.sh snapshot      输出完整环境快照

实验列表：
  1  纯 TCP 443          — 测试端口连通性
  2  openssl s_server    — TLS 基线
  3  derper Go TLS 443   — 核心问题复现
  4  openssl + derper bg — 进程隔离测试
  5  socat → derper      — 生产方案验证
  6  TCP 12345 + derper  — 交叉验证
USAGE
        ;;
esac
