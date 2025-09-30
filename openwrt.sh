#!/bin/bash
set -euo pipefail
 
LOCK_FILE="/tmp/wifi_optimize.lock"
BACKUP_DIR="/tmp/wifi_backups"
LOG_FILE="/var/log/wifi_optimize.log"
 
trap 'handle_interrupt' SIGINT SIGTERM EXIT
 
handle_interrupt() {
echo "(date +'%Y-%m-%d %H:%M:%S') - 脚本被中断，正在清理..." >> "LOG_FILE"
if [ -f "$BACKUP_DIR/config.bak" ]; then
echo "(date +'%Y-%m-%d %H:%M:%S') - 恢复配置备份..." >> "LOG_FILE"
cp -r "$BACKUP_DIR/config.bak" /etc/config/ 2>/dev/null && uci commit 2>/dev/null
fi
[ -f "LOCK_FILE"
echo "(date +'%Y-%m-%d %H:%M:%S') - 清理完成" >> "LOG_FILE"
}

get_next_wifi_number() {
local existing_numbers=$(uci show wireless 2>/dev/null | grep -oE "TK([0-9]+)" | sed "s/TK//g" | sort -n)
[ -z "$existing_numbers" ] && echo 1 && return
local max_number=(echo "existing_numbers" | tail -n1)
echo $((max_number + 1))
}
 
retry_network_operation() {
local cmd=$1
local max_retries=3
local retry_delay=5
local retries=0
while [ $retries -lt $max_retries ]; do
if eval "$cmd"; then return 0; fi
echo "(date +'%Y-%m-%d %H:%M:%S') - 网络操作失败，((max_retries - retries - 1)) 次重试机会..." >> "$LOG_FILE"
retries=$((retries + 1)) && sleep $retry_delay
done
return 1
}

check_proxy_profile() {
echo -e "1/14 检测国外节点配置文件..."
if [ ! -f "/etc/foreign_proxy_profile.conf" ] || [ ! -s "/etc/foreign_proxy_profile.conf" ]; then
echo -e "\033[31m❌ 未找到有效国外节点配置文件！请先导入节点配置\033[0m"
all_checks_passed=false
else
chmod 600 /etc/foreign_proxy_profile.conf && echo -e "   ✅ 检测通过"
fi
}
 
check_required_tools() {
echo -e "2/14 检测必要工具..."
local tools=("bridge-utils" "dnsmasq-full" "ipset" "iptables-mod-filter" "curl" "jq" "qrencode" "iw" "ethtool" "tcpdump" "netstat-nat" "conntrack" "logrotate" "bc")
for tool in "${tools[@]}"; do
if ! opkg list-installed 2>/dev/null | grep -q "$tool"; then
echo -e "   ⚠️  安装工具$tool..."
if ! opkg install "$tool" 2>/dev/null; then
echo -e "\033[31m❌ 工具$tool安装失败\033[0m"
all_checks_passed=false && return
fi
fi
done
echo -e "   ✅ 检测通过"
}
 
check_radio_availability() {
echo -e "3/14 检测2.4G/5G射频..."
radio_2g=$(uci show wireless 2>/dev/null | grep -E "band='2g'|htmode='HT" | cut -d '.' -f2 | head -n1)
radio_5g=$(uci show wireless 2>/dev/null | grep -E "band='5g'|htmode='VHT" | cut -d '.' -f2 | head -n1)
if [ -z "radio_2g" ] || [ -z "radio_5g" ]; then
echo -e "\033[31m❌ 未识别到2.4G/5G射频！\033[0m"
all_checks_passed=false
else
echo -e "   ✅ 检测通过（2.4G：radio_2g，5G：radio_5g）"
fi
}
 
check_ip_sets() {
echo -e "4/14 检测IP段库..."
local ipset_update_interval=$((7 * 24 * 3600))
local last_update=$(stat -c %Y /etc/ipset_last_update 2>/dev/null || echo 0)
local current_time=$(date +%s)
if [ $((current_time - last_update)) -gt $ipset_update_interval ] || [ ! -f "/etc/ipset_last_update" ]; then
echo -e "   ⚠️  更新IP段库..."
ipset save > /tmp/ipset_backup_$(date +%Y%m%d).rules 2>/dev/null
ipset destroy "cn_ip_safe" 2>/dev/null
ipset create "cn_ip_safe" hash:net maxelem 1000000 2>/dev/null
if ! retry_network_operation "curl -sL https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt | while read -r ip; do [ -n "$ip" ] && ipset add "cn_ip_safe" "$ip" 2>/dev/null; done"; then
echo -e "\033[31m❌ 国内IP库下载失败\033[0m"
all_checks_passed=false && return
fi
ipset destroy "global_ip_safe" 2>/dev/null
ipset create "global_ip_safe" hash:net maxelem 2000000 2>/dev/null
if ! retry_network_operation "curl -sL https://raw.githubusercontent.com/fffonion/ipset-global/master/global.ipset | while read -r ip; do ! ipset test "cn_ip_safe" "$ip" 2>/dev/null && ipset add "global_ip_safe" "$ip" 2>/dev/null; done"; then
echo -e "\033[31m❌ 国外IP库创建失败\033[0m"
all_checks_passed=false && return
fi
date +%s > /etc/ipset_last_update
fi
echo -e "   ✅ 检测通过"
}
 
check_ip_conflict() {
echo -e "5/14 检测IP段冲突..."
local test_ips=("192.168.10.1" "192.168.20.1" "192.168.30.1" "192.168.40.1")
for ip in "${test_ips[@]}"; do
if ping -c 1 -W 1 "$ip" 2>/dev/null; then
echo -e "\033[31m❌ IP $ip 已被占用\033[0m"
all_checks_passed=false && return
fi
done
echo -e "   ✅ 检测通过"
}
 
check_dns_service() {
echo -e "6/14 检测DNS服务..."
if ! /etc/init.d/dnsmasq status 2>/dev/null | grep -q "running"; then
echo -e "   ⚠️  重启DNS服务..."
if ! /etc/init.d/dnsmasq restart 2>/dev/null; then
echo -e "\033[31m❌ DNS服务启动失败\033[0m"
all_checks_passed=false && return
fi
fi
if ! dnsmasq --version 2>/dev/null | grep -q "full"; then
echo -e "   ⚠️  安装完整版dnsmasq..."
if ! opkg install --force-overwrite dnsmasq-full 2>/dev/null; then
echo -e "\033[31m❌ dnsmasq-full安装失败\033[0m"
all_checks_passed=false && return
fi
/etc/init.d/dnsmasq restart 2>/dev/null
fi
echo -e "   ✅ 检测通过"
}
 
check_system_resources() {
echo -e "7/14 检测系统资源..."
local mem_available=$(free | grep Mem | awk '{print $7}')
local cpu_cores=$(grep -c ^processor /proc/cpuinfo)
[ "$mem_available" -lt 134217728 ] && echo -e "   ⚠️  内存不足128MB，性能可能受限"
[ "$cpu_cores" -lt 2 ] && echo -e "   ⚠️  CPU核心不足2核，高负载可能卡顿"
echo -e "   ✅ 检测通过"
}
 
check_network_interfaces() {
echo -e "8/14 检测网络接口..."
local wan_if=$(uci get network.wan.ifname 2>/dev/null || echo "eth0")
if ! ip link show "$wan_if" 2>/dev/null | grep -q "UP"; then
echo -e "\033[31m❌ WAN接口 $wan_if 未启用\033[0m"
all_checks_passed=false && return
fi
echo -e "   ✅ 检测通过"
}
 
check_proxy_health() {
echo -e "9/14 检测代理节点..."
local profile_content=$(cat /etc/foreign_proxy_profile.conf | grep -v '^#' | tr -dc '[:print:]')
local proxy_server=(echo "profile_content" | sed -E 's/.server=([^;,"]+)./\1/')
local proxy_port=(echo "profile_content" | sed -E 's/.port=([0-9]+)./\1/')
if ! nc -z -w 5 "proxy_server" "proxy_port" 2>/dev/null; then
echo -e "\033[31m❌ 代理 proxy_server:proxy_port 不可达\033[0m"
all_checks_passed=false && return
fi
echo -e "   ✅ 检测通过"
}
 
cleanup_old_rules() {
e

configure_network_interfaces() {
echo -e "\n📋 配置网络接口..."
uci delete network.net_dom_2g 2>/dev/null
uci set network.net_dom_2g=interface
uci set network.net_dom_2g.proto='static'
uci set network.net_dom_2g.ipaddr='192.168.10.1'
uci set network.net_dom_2g.netmask='255.255.255.0'
uci set network.net_dom_2g.delegate='0'
 
uci delete network.net_dom_5g 2>/dev/null
uci set network.net_dom_5g=interface
uci set network.net_dom_5g.proto='static'
uci set network.net_dom_5g.ipaddr='192.168.20.1'
uci set network.net_dom_5g.netmask='255.255.255.0'
uci set network.net_dom_5g.delegate='0'
 
uci delete network.net_for_2g 2>/dev/null
uci set network.net_for_2g=interface
uci set network.net_for_2g.proto='static'
uci set network.net_for_2g.ipaddr='192.168.30.1'
uci set network.net_for_2g.netmask='255.255.255.0'
uci set network.net_for_2g.delegate='0'
 
uci delete network.net_for_5g 2>/dev/null
uci set network.net_for_5g=interface
uci set network.net_for_5g.proto='static'
uci set network.net_for_5g.ipaddr='192.168.40.1'
uci set network.net_for_5g.netmask='255.255.255.0'
uci set network.net_for_5g.delegate='0'
uci commit network
echo -e "✅ 网络接口配置完成"
}
 
configure_dhcp_service() {
echo -e "\n📋 配置DHCP服务..."
uci delete dhcp.dom_2g 2>/dev/null
uci set dhcp.dom_2g=dhcp
uci set dhcp.dom_2g.interface='net_dom_2g'
uci set dhcp.dom_2g.start='100'
uci set dhcp.dom_2g.limit='150'
uci set dhcp.dom_2g.leasetime='12h'
uci set dhcp.dom_2g.dhcpv6='disabled'
uci set dhcp.dom_2g.dns='223.5.5.5 223.6.6.6'
 
uci delete dhcp.dom_5g 2>/dev/null
uci set dhcp.dom_5g=dhcp
uci set dhcp.dom_5g.interface='net_dom_5g'
uci set dhcp.dom_5g.start='100'
uci set dhcp.dom_5g.limit='150'
uci set dhcp.dom_5g.leasetime='12h'
uci set dhcp.dom_5g.dhcpv6='disabled'
uci set dhcp.dom_5g.dns='223.5.5.5 223.6.6.6'
 
uci delete dhcp.for_2g 2>/dev/null
uci set dhcp.for_2g=dhcp
uci set dhcp.for_2g.interface='net_for_2g'
uci set dhcp.for_2g.start='100'
uci set dhcp.for_2g.limit='150'
uci set dhcp.for_2g.leasetime='12h'
uci set dhcp.for_2g.dhcpv6='disabled'
uci set dhcp.for_2g.dns='8.8.8.8 8.8.4.4'
 
uci delete dhcp.for_5g 2>/dev/null
uci set dhcp.for_5g=dhcp
uci set dhcp.for_5g.interface='net_for_5g'
uci set dhcp.for_5g.start='100'
uci set dhcp.for_5g.limit='150'
uci set dhcp.for_5g.leasetime='12h'
uci set dhcp.for_5g.dhcpv6='disabled'
uci set dhcp.for_5g.dns='8.8.8.8 8.8.4.4'
uci commit dhcp
echo -e "✅ DHCP服务配置完成"
}
 
configure_wifi_networks() {
echo -e "\n📋 配置WiFi网络..."
uci delete wireless.dom_2g 2>/dev/null
uci set wireless.dom_2g=wifi-iface
uci set wireless.dom_2g.device="$radio_2g"
uci set wireless.dom_2g.network='net_dom_2g'
uci set wireless.dom_2g.mode='ap'
uci set wireless.dom_2g.ssid="$DOMESTIC_2G_SSID"
uci set wireless.dom_2g.encryption='psk2'
uci set wireless.dom_2g.key="$PWD"
uci set wireless.dom_2g.ieee80211n='1'
uci set wireless.dom_2g.htmode='HT20'
uci set wireless.dom_2g.channel='6'
 
uci delete wireless.dom_5g 2>/dev/null
uci set wireless.dom_5g=wifi-iface
uci set wireless.dom_5g.device="$radio_5g"
uci set wireless.dom_5g.network='net_dom_5g'
uci set wireless.dom_5g.mode='ap'
uci set wireless.dom_5g.ssid="$DOMESTIC_5G_SSID"
uci set wireless.dom_5g.encryption='psk2'
uci set wireless.dom_5g.key="$PWD"
uci set wireless.dom_5g.ieee80211ac='1'
uci set wireless.dom_5g.htmode='VHT80'
uci set wireless.dom_5g.channel='44'
 
uci delete wireless.for_2g 2>/dev/null
uci set wireless.for_2g=wifi-iface
uci set wireless.for_2g.device="$radio_2g"
uci set wireless.for_2g.network='net_for_2g'
uci set wireless.for_2g.mode='ap'
uci set wireless.for_2g.ssid="$FOREIGN_2G_SSID"
uci set wireless.for_2g.encryption='psk2'
uci set wireless.for_2g.key="$PWD"
uci set wireless.for_2g.ieee80211n='1'
uci set wireless.for_2g.htmode='HT20'
uci set wireless.for_2g.channel='11'
 
uci delete wireless.for_5g 2>/dev/null
uci set wireless.for_5g=wifi-iface
uci set wireless.for_5g.device="$radio_5g"
uci set wireless.for_5g.network='net_for_5g'
uci set wireless.for_5g.mode='ap'
uci set wireless.for_5g.ssid="$FOREIGN_5G_SSID"
uci set wireless.for_5g.encryption='psk2'
uci set wireless.for_5g.key="$PWD"
uci set wireless.for_5g.ieee80211ac='1'
uci set wireless.for_5g.htmode='VHT80'
uci set wireless.for_5g.channel='149'
uci commit wireless
echo -e "✅ WiFi网络配置完成"
}

configure_firewall_rules() {
echo -e "\n📋 配置防火墙规则..."
iptables -t filter -F CN 2>/dev/null
iptables -t filter -F GLOBAL 2>/dev/null
iptables -t filter -F PROXY 2>/dev/null
iptables -t filter -A CN -m set --match-set cn_ip_safe dst -j ACCEPT
iptables -t filter -A CN -d 192.168.0.0/16 -j ACCEPT
iptables -t filter -A CN -d 10.0.0.0/8 -j ACCEPT
iptables -t filter -A CN -d 172.16.0.0/12 -j ACCEPT
iptables -t filter -A CN -j REJECT
iptables -t filter -A GLOBAL -m set --match-set global_ip_safe dst -j ACCEPT
iptables -t filter -A GLOBAL -d 192.168.0.0/16 -j ACCEPT
iptables -t filter -A GLOBAL -d 10.0.0.0/8 -j ACCEPT
iptables -t filter -A GLOBAL -d 172.16.0.0/12 -j ACCEPT
iptables -t filter -A GLOBAL -j REJECT
iptables -t filter -I FORWARD -i br-net_dom_2g -j CN
iptables -t filter -I FORWARD -i br-net_dom_5g -j CN
iptables -t filter -I FORWARD -i br-net_for_2g -j GLOBAL
iptables -t filter -I FORWARD -i br-net_for_5g -j GLOBAL
echo -e "✅ 防火墙规则配置完成"
}
 
configure_proxy_rules() {
echo -e "\n📋 配置代理规则..."
local profile_content=$(cat /etc/foreign_proxy_profile.conf | grep -v '^#' | tr -dc '[:print:]')
local proxy_type=(echo "profile_content" | sed -E 's/.type=([^;,"]+)./\1/')
iptables -t nat -F PROXY 2>/dev/null
iptables -t nat -N PROXY
if [ "$proxy_type" = "socks5" ]; then
iptables -t nat -A PROXY -p tcp -j REDIRECT --to-ports 1080
elif [ "$proxy_type" = "http" ]; then
iptables -t nat -A PROXY -p tcp -j REDIRECT --to-ports 8118
fi
iptables -t nat -I PREROUTING -i br-net_for_2g -j PROXY
iptables -t nat -I PREROUTING -i br-net_for_5g -j PROXY
 
# 配置DNS过滤
echo "conf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/domestic.conf < /etc/dnsmasq.d/foreign.conf <<EOF_FOR
interface=br-net_for_2g
interface=br-net_for_5g
server=8.8.8.8
server=8.8.4.4
EOF_FOR
/etc/init.d/dnsmasq restart 2>/dev/null
echo -e "✅ 代理规则配置完成"
}

#!/bin/bash
set -euo pipefail
 
导入各个模块
 
source /tmp/init.sh
source /tmp/utils.sh
source /tmp/checks.sh
source /tmp/config.sh
source /tmp/rules.sh
 
主函数
 
main() {
touch "LOG_FILE"
echo "(date +'%Y-%m-%d %H:%M:%S') - 脚本开始执行" >> "LOG_FILE"
 
[ -f "(date +'%Y-%m-%d %H:%M:%S') - 已有脚本实例在运行，退出..." >> "$LOG_FILE"; exit 1; }
echo $$ > "LOCK_FILE"
 
mkdir -p "$BACKUP_DIR"
uci export 2>/dev/null > "$BACKUP_DIR/config.bak"
 
local mem_available=$(free | grep Mem | awk '{print $7}')
local min_mem=134217728
[ "mem_available" -lt "min_mem" ] && { echo "(date +'%Y-%m-%d %H:%M:%S') - 内存不足，退出..." >> "LOG_FILE"; exit 1; }
 
start_number=$(get_next_wifi_number)
DOMESTIC_2G_SSID="TK$(printf "%02d" $start_number)"
DOMESTIC_5G_SSID="TK$(printf "%02d" $((start_number + 1)))"
FOREIGN_2G_SSID="TK$(printf "%02d" $((start_number + 2)))"
FOREIGN_5G_SSID="TK$(printf "%02d" $((start_number + 3)))"
PWD="12345678"
 
echo -e "\033[32m===== 本次创建WiFi信息 =====\033[0m"
echo -e "国内2.4G：{DOMESTIC_2G_SSID} | 密码：{PWD}"
echo -e "国内5G：{DOMESTIC_5G_SSID} | 密码：{PWD}"
echo -e "国外2.4G：{FOREIGN_2G_SSID} | 密码：{PWD}"
echo -e "国外5G：{FOREIGN_5G_SSID} | 密码：{PWD}\n"
 
echo "(date +'%Y-%m-%d %H:%M:%S') - 开始全链路检测" >> "LOG_FILE"
all_checks_passed=true
radio_2g=""
radio_5g=""
 
# 执行所有检测
check_proxy_profile
check_required_tools
check_radio_availability
check_ip_sets
check_ip_conflict
check_dns_service
check_system_resources
check_network_interfaces
check_proxy_health
cleanup_old_rules
cleanup_old_interfaces
create_system_backup
check_firewall_chains
check_nat_rules
 
if [ "$all_checks_passed" = false ]; then
echo -e "\033[31m❌ 全链路检测失败，脚本退出！\033[0m"
echo "(date +'%Y-%m-%d %H:%M:%S') - 检测失败" >> "LOG_FILE"
exit 1
fi
 
echo -e "\033[32m✅ 所有检测通过，开始配置WiFi...\033[0m"
echo "(date +'%Y-%m-%d %H:%M:%S') - 开始配置" >> "LOG_FILE"
 
# 执行配置
configure_network_interfaces
configure_dhcp_service
configure_wifi_networks
configure_firewall_rules
configure_proxy_rules
 
# 重启服务
echo -e "\n📋 重启相关服务..."
/etc/init.d/network restart 2>/dev/null
/etc/init.d/wireless restart 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null
/etc/init.d/firewall restart 2>/dev/null
 
echo -e "\033[32m✅ WiFi优化配置完成！\033[0m"
echo -e "\n📱 WiFi连接信息："
echo -e "国内网络：${DOMESTIC_2G_SSID} (2.4G) / ${DOMESTIC_5G_SSID} (5G)"
echo -e "国外网络：${FOREIGN_2G_SSID} (2.4G) / ${FOREIGN_5G_SSID} (5G)"
echo -e "密码统一：${PWD}\n"
 
echo "(date +'%Y-%m-%d %H:%M:%S') - 脚本执行完成" >> "LOG_FILE"
rm -f "$LOCK_FILE"
}
 
执行主函数
 
main "$@"
