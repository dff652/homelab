脚本功能清单：
自动换源：适配 24.04 最新的 DEB822 格式（清华源）。

静态 IP 配置：交互式输入，自动生成 Netplan 配置。

SSH 强化：安装并可选开启 Root 登录。

PVE 专属优化：安装 Guest Agent 并激活 fstrim。

内核调优：修改 Swappiness 以保护 SSD 并提升响应。

项目环境：一键安装 Docker 和 nvm (Node.js)。

如何使用：
在 Ubuntu 终端内创建脚本文件：
nano setup_vm.sh

将以下代码粘贴进去，按 Ctrl+O 保存，Ctrl+X 退出。

赋予执行权限并运行：
chmod +x setup_vm.sh && sudo ./setup_vm.sh