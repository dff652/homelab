#!/bin/bash

# ==========================================================
# Ubuntu 24.04 PVE VM 基础优化一键脚本 
# ==========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 sudo 或 root 权限运行此脚本!${NC}"
   exit 1
fi

show_menu() {
    clear
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}    Ubuntu 24.04 PVE 虚拟机初始化交互菜单    ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "1. 一键换源 (清华源 - 适配 24.04 DEB822)"
    echo -e "2. 配置静态 IP (Netplan)"
    echo -e "3. SSH 设置 (安装及开启远程登录)"
    echo -e "4. 安装 PVE Guest Agent & 开启 TRIM"
    echo -e "5. 优化 Swappiness (针对 6GB 内存/SSD)"
    echo -e "6. 安装 Docker (阿里云加速)"
    echo -e "7. 安装 Node.js LTS (OpenClaw 需求)"
    echo -e "8. 执行全部优化 (1, 3, 4, 5)"
    echo -e "0. 退出脚本"
    echo -e "${GREEN}=============================================${NC}"
}

change_sources() {
    echo -e "${YELLOW}正在备份并修改软件源...${NC}"
    SOURCE_FILE="/etc/apt/sources.list.d/ubuntu.sources"
    [ -f "$SOURCE_FILE" ] && cp "$SOURCE_FILE" "${SOURCE_FILE}.bak"
    sed -i 's/archive.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' "$SOURCE_FILE"
    sed -i 's/security.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' "$SOURCE_FILE"
    apt update && echo -e "${GREEN}换源成功!${NC}"
    sleep 2
}

set_static_ip() {
    echo -e "${YELLOW}当前网卡信息如下:${NC}"
    ip -br addr
    read -p "请输入网卡名称 (例如 enp1s0): " IFACE
    read -p "请输入静态 IP (例如 192.168.1.100/24): " IP_ADDR
    read -p "请输入网关 (例如 192.168.1.1): " GW
    read -p "请输入 DNS (用空格隔开, 如 223.5.5.5 114.114.114.114): " DNS_ADDR
    
    if [[ -z "$IFACE" || -z "$IP_ADDR" || -z "$GW" || -z "$DNS_ADDR" ]]; then
        echo -e "${RED}输入不能为空，静态 IP 配置已跳过!${NC}"
        sleep 2
        return
    fi
    
    # 格式化 DNS 数组
    DNS_FMT=$(echo $DNS_ADDR | sed 's/[[:space:]]\+/, /g')

    cat <<EOF > /etc/netplan/99-static-ip.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $IFACE:
      dhcp4: no
      addresses: [$IP_ADDR]
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$DNS_FMT]
EOF
    chmod 600 /etc/netplan/99-static-ip.yaml
    netplan apply
    echo -e "${GREEN}静态 IP 配置已应用!${NC}"
    sleep 2
}

setup_ssh() {
    echo -e "${YELLOW}准备安装并配置 SSH...${NC}"
    read -p "是否先更新软件包列表(apt update)以防依赖冲突? (y/n, 推荐 y): " UPDATE_APT
    if [[ "$UPDATE_APT" != "n" && "$UPDATE_APT" != "N" ]]; then
        echo -e "${YELLOW}正在更新软件包列表...${NC}"
        apt update
    fi

    export DEBIAN_FRONTEND=noninteractive
    echo -e "${YELLOW}开始安装 openssh-server...${NC}"
    if ! apt install openssh-server -y; then
        echo -e "${RED}SSH 安装失败！检测到依赖冲突。${NC}"
        read -p "是否自动修复依赖 (apt --fix-broken install) 并重试? (y/n): " FIX_APT
        if [[ "$FIX_APT" == "y" || "$FIX_APT" == "Y" ]]; then
            apt --fix-broken install -y
            apt install openssh-server -y
        else
            echo -e "${RED}已跳过 SSH 安装。${NC}"
            sleep 2
            return
        fi
    fi
    systemctl enable --now ssh
    read -p "是否允许 Root 远程登录? (y/n): " ROOT_SSH
    if [[ "$ROOT_SSH" == "y" ]]; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        systemctl restart ssh
    fi
    echo -e "${GREEN}SSH 配置完成!${NC}"
    sleep 2
}

pve_optim() {
    echo -e "${YELLOW}准备安装 QEMU Guest Agent & 开启 TRIM...${NC}"
    read -p "是否先更新软件包列表(apt update)以防依赖冲突? (y/n, 推荐 y): " UPDATE_APT
    if [[ "$UPDATE_APT" != "n" && "$UPDATE_APT" != "N" ]]; then
        echo -e "${YELLOW}正在更新软件包列表...${NC}"
        apt update
    fi

    export DEBIAN_FRONTEND=noninteractive
    echo -e "${YELLOW}开始安装 qemu-guest-agent...${NC}"
    if ! apt install qemu-guest-agent -y; then
        echo -e "${RED}QEMU Guest Agent 安装失败！检测到依赖冲突。${NC}"
        read -p "是否自动修复依赖 (apt --fix-broken install) 并重试? (y/n): " FIX_APT
        if [[ "$FIX_APT" == "y" || "$FIX_APT" == "Y" ]]; then
            apt --fix-broken install -y
            apt install qemu-guest-agent -y
        else
            echo -e "${RED}已跳过 PVE 优化。${NC}"
            sleep 2
            return
        fi
    fi
    systemctl enable --now qemu-guest-agent
    systemctl enable --now fstrim.timer
    fstrim -av
    echo -e "${GREEN}PVE 优化完成! 请确保在 PVE 选项中开启了 Guest Agent。${NC}"
    sleep 2
}

optimize_swap() {
    echo -e "${YELLOW}正在优化 Swappiness...${NC}"
    sysctl vm.swappiness=10
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo -e "${GREEN}Swappiness 已设为 10，降低了硬盘交换频率。${NC}"
    sleep 2
}

install_docker() {
    echo -e "${YELLOW}安装 Docker...${NC}"
    curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    usermod -aG docker ${SUDO_USER:-$USER}
    echo -e "${GREEN}Docker 安装完成，普通用户需重新登录以生效权限。${NC}"
    sleep 2
}

install_node() {
    echo -e "${YELLOW}安装全局 Node.js LTS (通过 NodeSource)...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    if ! apt install -y nodejs; then
        echo -e "${RED}Node.js 安装失败！检测到依赖冲突。${NC}"
        read -p "是否自动修复依赖 (apt --fix-broken install) 并重试? (y/n): " FIX_APT
        if [[ "$FIX_APT" == "y" || "$FIX_APT" == "Y" ]]; then
            apt --fix-broken install -y
            apt install -y nodejs
        else
            echo -e "${RED}已跳过 Node.js 安装。${NC}"
            sleep 2
            return
        fi
    fi
    echo -e "${GREEN}Node.js 安装完成!${NC}"
    sleep 2
}

while true; do
    show_menu
    read -p "请输入选项 [0-8]: " choice
    case $choice in
        1) change_sources ;;
        2) set_static_ip ;;
        3) setup_ssh ;;
        4) pve_optim ;;
        5) optimize_swap ;;
        6) install_docker ;;
        7) install_node ;;
        8) 
           change_sources
           setup_ssh
           pve_optim
           optimize_swap
           echo -e "${GREEN}基础全自动化优化已完成!${NC}"
           sleep 3
           ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项!${NC}" ; sleep 1 ;;
    esac
done