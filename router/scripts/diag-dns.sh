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
