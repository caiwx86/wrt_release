#!/bin/bash

# Set default theme to luci-theme-argon
# uci set luci.main.mediaurlbase='/luci-static/argon'
# uci commit luci

# 添加旁路由防火墙
# echo "iptables -t nat -I POSTROUTING -o eth0 -j MASQUERADE" >> package/network/config/firewall/files/firewall.user
#iptables设置
# sed -i '/REDIRECT --to-ports 53/d' /etc/firewall.user
# echo "iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 53" >> /etc/firewall.user
# echo "iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 53" >> /etc/firewall.user

#设置fstab开启热插拔自动挂载
# uci set fstab.@global[0].anon_mount=1
# uci commit fstab

# 配置nps 
#uci set nps.@nps[0].enabled='0'
#uci set nps.@nps[0].server_addr='127.0.0.1'
#uci set nps.@nps[0].vkey='kbEwlNnKytsg28gfvseCmP5pU8Vqo0c1rrlHfsi3Q'
#uci commit nps
# dnsmasq
#uci set dhcp.@dnsmasq[0].rebind_protection='0'
#uci set dhcp.@dnsmasq[0].localservice='0'
#uci set dhcp.@dnsmasq[0].nonwildcard='0'
#if ! grep -Eq '223.5.5.5' /etc/config/dhcp;then
#  uci add_list dhcp.@dnsmasq[0].server='223.5.5.5#53'
#fi
#uci commit dhcp

# Disable IPV6 ula prefix
# sed -i 's/^[^#].*option ula/#&/' /etc/config/network

# Check file system during boot
# uci set fstab.@global[0].check_fs=1
# uci commit fstab

chmod +x /usr/bin/adguard_update_dhcp_leases.sh
# 定义要查找的Cron任务
CRON_JOB="*/15 * * * * /usr/bin/adguard_update_dhcp_leases.sh"
# 定义cron文件路径
CRON_FILE="/etc/crontabs/root"
# 检查Cron任务是否已存在
if grep -Fxq "$CRON_JOB" "$CRON_FILE"; then
    echo "Cron任务已存在，不需要添加。"
else
    echo "$CRON_JOB" >> "$CRON_FILE"
    echo "Cron任务已添加到 $CRON_FILE。"
fi
#/etc/init.d/cron start
#/etc/init.d/cron enable
exit 0