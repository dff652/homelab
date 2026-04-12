#!/bin/sh
# DERP 中继部署脚本 — bj-ali-hb2
# 最终方案：socat TLS 终结 (443) + derper HTTP (8080)
# Tailscale ACL 使用 IP 直连（无域名 SNI，绕过 ISP DPI）
#
# 部署：
#   scp scripts/deploy-derp.sh root@39.102.98.79:/tmp/
#   ssh root@39.102.98.79 'sh /tmp/deploy-derp.sh deploy'
#
# 用法：
#   sh deploy-derp.sh deploy    部署/更新 derper + socat 服务
#   sh deploy-derp.sh status    检查服务状态
#   sh deploy-derp.sh stop      停止所有服务
#   sh deploy-derp.sh restart   重启所有服务
#   sh deploy-derp.sh logs      查看 derper 日志
#   sh deploy-derp.sh cleanup   清理旧容器和残留服务
#   sh deploy-derp.sh renew     更新 socat 证书路径（证书续期后）

CERT="/etc/nginx/derp.crt"
KEY="/etc/nginx/derp.key"
DERP_IMAGE="registry.linkease.net:5443/fredliang/derper:latest"
DERP_CONTAINER="derper"
DERP_DOMAIN="gw1.wcdz.tech"
SOCAT_SERVICE="derp-tls"

pass() { echo "[ OK ]  $1"; }
fail() { echo "[FAIL]  $1"; }
info() { echo "[INFO]  $1"; }

check_cert() {
    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        fail "证书不存在: $CERT / $KEY"
        echo "请先获取证书，或从 ACME 缓存提取："
        echo "  /root/derp/certs/$DERP_DOMAIN/"
        return 1
    fi
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
    pass "证书有效期至: $EXPIRY"
}

cmd_deploy() {
    echo "══════════ DERP 中继部署 ══════════"
    echo ""

    # 检查证书
    check_cert || exit 1
    echo ""

    # 清理旧服务
    info "清理旧服务..."
    docker stop derper-test 2>/dev/null; docker rm derper-test 2>/dev/null
    docker stop "$DERP_CONTAINER" 2>/dev/null; docker rm "$DERP_CONTAINER" 2>/dev/null
    systemctl stop "$SOCAT_SERVICE" 2>/dev/null
    pkill -f 'socat.*OPENSSL-LISTEN' 2>/dev/null || true
    pkill -f 'openssl s_server' 2>/dev/null || true
    systemctl stop nginx 2>/dev/null; systemctl disable nginx 2>/dev/null
    sleep 1

    # 部署 derper (HTTP 8080 + STUN 3478)
    info "部署 derper 容器 (HTTP :8080, STUN :3478)..."
    docker run -d --name "$DERP_CONTAINER" --restart=always --network=host \
        -e DERP_DOMAIN="$DERP_DOMAIN" \
        -e DERP_CERT_MODE=letsencrypt \
        -e DERP_ADDR=:8080 \
        -e DERP_STUN=true \
        -e DERP_VERIFY_CLIENTS=false \
        "$DERP_IMAGE"
    sleep 3

    if docker ps --filter "name=$DERP_CONTAINER" --filter status=running -q | grep -q .; then
        pass "derper 容器运行中"
    else
        fail "derper 启动失败"
        docker logs "$DERP_CONTAINER" 2>&1 | tail -10
        exit 1
    fi

    # 部署 socat systemd 服务 (TLS :443 → HTTP :8080)
    info "部署 socat TLS 终结服务 (:443 → :8080)..."
    cat > /etc/systemd/system/${SOCAT_SERVICE}.service <<EOF
[Unit]
Description=DERP TLS termination (socat 443 -> derper 8080)
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/socat OPENSSL-LISTEN:443,cert=${CERT},key=${KEY},verify=0,reuseaddr,fork TCP:127.0.0.1:8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SOCAT_SERVICE"
    sleep 1

    if systemctl is-active --quiet "$SOCAT_SERVICE"; then
        pass "socat 服务运行中"
    else
        fail "socat 启动失败"
        systemctl status "$SOCAT_SERVICE" --no-pager
        exit 1
    fi

    echo ""
    cmd_status

    echo ""
    echo "══════════ 部署完成 ══════════"
    echo ""
    echo "Tailscale ACL derpMap 配置（IP 直连，无域名 SNI）："
    cat <<'ACL'
{
    "derpMap": {
        "OmitDefaultRegions": false,
        "Regions": {
            "901": {
                "RegionID": 901,
                "RegionCode": "ali-bj",
                "RegionName": "Aliyun Beijing Relay",
                "Nodes": [{
                    "Name": "1",
                    "RegionID": 901,
                    "HostName": "39.102.98.79",
                    "IPv4": "39.102.98.79",
                    "DERPPort": 443,
                    "InsecureForTests": true
                }]
            }
        }
    }
}
ACL
    echo ""
    echo "验证命令（在 gl-mt2500-3 上执行）："
    echo "  tailscale netcheck | grep ali"
    echo "  tailscale ping istoreos"
}

cmd_status() {
    echo "══════════ 服务状态 ══════════"

    info "--- derper 容器 ---"
    docker ps -a --filter "name=$DERP_CONTAINER" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo ""

    info "--- socat 服务 ---"
    systemctl is-active "$SOCAT_SERVICE" 2>/dev/null && pass "$SOCAT_SERVICE active" || fail "$SOCAT_SERVICE not active"
    echo ""

    info "--- 端口监听 ---"
    ss -tlnp | grep -E ':(443|8080|3478)\s' || echo "(无相关端口)"
    echo ""

    info "--- 证书 ---"
    check_cert
    echo ""

    info "--- derper 日志 (最后 5 行) ---"
    docker logs "$DERP_CONTAINER" 2>&1 | tail -5
}

cmd_stop() {
    info "停止 socat..."
    systemctl stop "$SOCAT_SERVICE" 2>/dev/null
    info "停止 derper..."
    docker stop "$DERP_CONTAINER" 2>/dev/null
    pass "已停止"
}

cmd_restart() {
    info "重启 derper..."
    docker restart "$DERP_CONTAINER"
    info "重启 socat..."
    systemctl restart "$SOCAT_SERVICE"
    sleep 2
    cmd_status
}

cmd_logs() {
    docker logs --tail 50 -f "$DERP_CONTAINER"
}

cmd_cleanup() {
    info "清理旧容器和残留服务..."
    # 旧的 derper-test 容器
    docker stop derper-test 2>/dev/null; docker rm derper-test 2>/dev/null
    # 旧的 derper 容器（非当前）
    # 不清理当前运行的
    # 残留 nginx
    systemctl stop nginx 2>/dev/null; systemctl disable nginx 2>/dev/null
    # 残留后台 socat/openssl
    pkill -f 'openssl s_server' 2>/dev/null || true
    pass "清理完成"
    cmd_status
}

cmd_renew() {
    info "证书续期后刷新 socat..."
    check_cert || exit 1
    systemctl restart "$SOCAT_SERVICE"
    sleep 1
    if systemctl is-active --quiet "$SOCAT_SERVICE"; then
        pass "socat 已使用新证书重启"
    else
        fail "socat 重启失败"
        systemctl status "$SOCAT_SERVICE" --no-pager
    fi
}

case "${1:-help}" in
    deploy)  cmd_deploy ;;
    status)  cmd_status ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    logs)    cmd_logs ;;
    cleanup) cmd_cleanup ;;
    renew)   cmd_renew ;;
    help|*)
        cat <<'USAGE'
DERP 中继部署脚本 — bj-ali-hb2

架构: socat TLS(:443) → derper HTTP(:8080) + STUN(:3478)
方案: Tailscale ACL 用 IP 直连 + InsecureForTests，绕过 ISP SNI DPI

用法：
  sh deploy-derp.sh deploy    部署/更新全部服务
  sh deploy-derp.sh status    检查服务状态
  sh deploy-derp.sh stop      停止所有服务
  sh deploy-derp.sh restart   重启所有服务
  sh deploy-derp.sh logs      查看 derper 实时日志
  sh deploy-derp.sh cleanup   清理旧容器和残留
  sh deploy-derp.sh renew     证书续期后刷新 socat
USAGE
        ;;
esac
