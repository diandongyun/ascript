#!/bin/bash
# 如果不是root用户，自动尝试用sudo重新运行
if [ "$(id -u)" -ne 0 ]; then
  echo "⚠️ 当前不是root用户，尝试以sudo权限重新运行..."
  exec sudo "$0" "$@"
fi

set -uo pipefail
LOCK_FILE="/tmp/wifi_optimize.lock"
BACKUP_DIR="/tmp/wifi_backups"
LOG_FILE="/var/log/wifi_optimize.log"
all_checks_passed=true

# 自动生成实例ID，避免冲突
INSTANCE_ID=1
while uci show wireless | grep -q "single_$INSTANCE_ID" 2>/dev/null; do
  INSTANCE_ID=$((INSTANCE_ID + 1))
done

# 配置参数（带实例ID）
SSID="Single-WiFi-$INSTANCE_ID"
WIFI_PASSWORD="YourWiFiPassword$INSTANCE_ID"
IP_BASE="192.168.$((10 + INSTANCE_ID)).1"
IP_CIDR="$IP_BASE/24"
FW_CHAIN="PROXY_$INSTANCE_ID"

trap 'cleanup' SIGINT SIGTERM EXIT

cleanup() {
  echo "$(date) - 中断清理..."
  [ -f "$BACKUP_DIR/config.bak" ] && (cp -r "$BACKUP_DIR/config.bak" /etc/config/ && uci commit)
  iptables -D FORWARD -s "$IP_CIDR" -j "$FW_CHAIN" 2>/dev/null
  iptables -F "$FW_CHAIN" 2>/dev/null
  iptables -X "$FW_CHAIN" 2>/dev/null
  [ -f "$LOCK_FILE" ] && rm "$LOCK_FILE"
  echo "$(date) - 清理完成" >> "$LOG_FILE"
}

[ -f "$LOCK_FILE" ] && { echo "❌ 脚本已在运行，请稍后再试"; exit 1; }
touch "$LOCK_FILE"
mkdir -p "$BACKUP_DIR" 2>/dev/null
cp -r /etc/config/ "$BACKUP_DIR/config.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || echo "⚠️  配置备份可能不完整" >> "$LOG_FILE"

retry() {
  local command=$1
  local retries=3
  local delay=5
  local attempt=0
  while [ $attempt -lt $retries ]; do
    if eval "$command"; then
      return 0
    fi
    echo "$(date) - 失败，重试 $((retries-attempt-1)) 次..." >> "$LOG_FILE"
    attempt=$((attempt+1))
    sleep $delay
  done
  return 1
}

check_proxy() {
  if [ ! -f "/etc/foreign_proxy_profile.conf" ] || [ ! -s "/etc/foreign_proxy_profile.conf" ]; then
    echo "⚠️  未找到代理配置文件，请输入："
    if ! opkg list-installed | grep -q "dialog"; then
      echo "请粘贴你的代理配置内容，按 Ctrl+D 确认："
      PROXY_CONF=$(cat)
      if [ -z "$PROXY_CONF" ]; then
        echo "❌ 输入为空"
        all_checks_passed=false
        return
      fi
    else
      PROXY_CONF=$(dialog --title "输入代理配置" --inputbox "请粘贴你的代理配置内容：" 15 60 3>&1 1>&2 2>&3)
      local DIALOG_EXIT=$?
      if [ $DIALOG_EXIT -ne 0 ] || [ -z "$PROXY_CONF" ]; then
        echo "❌ 用户取消了输入或输入为空"
        all_checks_passed=false
        return
      fi
    fi
    echo "$PROXY_CONF" > /etc/foreign_proxy_profile.conf
    chmod 600 /etc/foreign_proxy_profile.conf
    echo "✅ 代理配置已保存"
  fi
}

check_tools() {
  local tools=("bridge-utils" "dnsmasq-full" "ipset" "iptables-mod-filter" "curl" "jq" "qrencode" "iw" "ethtool" "tcpdump" "netstat-nat" "conntrack" "logrotate" "bc")
  echo "正在更新软件源..."
  opkg update >/dev/null 2>&1 || { echo "❌ 更新软件源失败，请检查网络连接"; all_checks_passed=false; return; }
  for tool in "${tools[@]}"; do
    if ! opkg list-installed | grep -q "$tool"; then
      echo "   安装工具: $tool..."
      if ! opkg install "$tool"; then
        echo "❌ 工具 $tool 安装失败"
        all_checks_passed=false
        return
      fi
    fi
  done
}

check_ipsets() {
  local update_interval=$((7*24*3600))
  local last_update=$(stat -c %Y /etc/ipset_last_update 2>/dev/null || echo 0)
  local current_time=$(date +%s)
  if [ $((current_time - last_update)) -gt $update_interval ] || [ ! -f "/etc/ipset_last_update" ]; then
    echo "正在更新IP段库..."
    ipset save > /tmp/ipset_backup_$(date +%Y%m%d).rules 2>/dev/null
    ipset destroy "cn_ip_safe" 2>/dev/null
    ipset create "cn_ip_safe" hash:net maxelem 1000000 2>/dev/null
    if ! retry "curl -sL https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt | while read -r ip; do [ -n \"$ip\" ] && ipset add \"cn_ip_safe\" \"$ip\" 2>/dev/null; done"; then
      echo "❌ 国内IP库失败"
      all_checks_passed=false
      return
    fi
    ipset destroy "global_ip_safe" 2>/dev/null
    ipset create "global_ip_safe" hash:net maxelem 2000000 2>/dev/null
    if ! retry "curl -sL https://raw.githubusercontent.com/fffonion/ipset-global/master/global.ipset | while read -r ip; do ! ipset test \"cn_ip_safe\" \"$ip\" 2>/dev/null && ipset add \"global_ip_safe\" \"$ip\" 2>/dev/null; done"; then
      echo "❌ 国外IP库失败"
      all_checks_passed=false
      return
    fi
    date +%s > /etc/ipset_last_update
  fi
}

check_ip() {
  echo "正在检查IP段 $IP_CIDR 是否可用..."
  if ping -c 1 -W 1 "$IP_BASE" 2>/dev/null; then
    echo "❌ IP $IP_BASE 被占用"
    all_checks_passed=false
    return
  fi
  if ip route show | grep -q "$IP_CIDR" 2>/dev/null; then
    echo "❌ IP段 $IP_CIDR 已存在于路由表中"
    all_checks_passed=false
    return
  fi
  if ip addr show | grep -q "$IP_CIDR" 2>/dev/null; then
    echo "❌ IP段 $IP_CIDR 已被其他接口使用"
    all_checks_passed=false
    return
  fi
}

check_dns() {
  if ! /etc/init.d/dnsmasq status | grep -q "running"; then
    echo "重启DNS服务..."
    if ! /etc/init.d/dnsmasq restart; then
      echo "❌ DNS 启动失败"
      all_checks_passed=false
      return
    fi
  fi
  if ! dnsmasq --version | grep -q "full"; then
    echo "安装完整版dnsmasq..."
    if ! opkg install --force-overwrite dnsmasq-full; then
      echo "❌ dnsmasq-full 安装失败"
      all_checks_passed=false
      return
    fi
    /etc/init.d/dnsmasq restart
  fi
}

check_net() {
  local wan_interface=$(uci get network.wan.ifname 2>/dev/null || echo "eth0")
  if ! ip link show "$wan_interface" 2>/dev/null | grep -q "UP"; then
    echo "❌ WAN 接口 $wan_interface 未启用或不存在"
    local auto_wan=$(ip -br link show | grep -v "LOOPBACK" | grep -v "DOWN" | grep -E "eth|wan" | head -n1 | awk '{print $1}')
    if [ -n "$auto_wan" ]; then
      echo "   自动检测到WAN口: $auto_wan，正在使用..."
      uci set network.wan.ifname="$auto_wan"
      uci commit network
      /etc/init.d/network restart
      sleep 5
      if ip link show "$auto_wan" 2>/dev/null | grep -q "UP"; then
        echo "   ✅ WAN口 $auto_wan 已启用"
        return
      fi
    fi
    all_checks_passed=false
  fi
}

check_proxy_health() {
  local config=$(cat /etc/foreign_proxy_profile.conf | grep -v '^#' | tr -dc '[:print:]')
  local server=$(echo "$config" | sed -E 's/.*server=([^;,"]+).*/\1/')
  local port=$(echo "$config" | sed -E 's/.*port=([0-9]+).*/\1/')
  if [ -z "$server" ] || [ -z "$port" ]; then
    echo "❌ 代理配置格式不正确"
    all_checks_passed=false
    return
  fi
  if ! nc -z -w 5 "$server" "$port"; then
    echo "❌ 代理 $server:$port 不可达"
    all_checks_passed=false
  fi
}

conf_net() {
  echo "配置网络接口..."
  uci set network.net_single_$INSTANCE_ID=interface
  uci set network.net_single_$INSTANCE_ID.proto='static'
  uci set network.net_single_$INSTANCE_ID.ipaddr="$IP_BASE"
  uci set network.net_single_$INSTANCE_ID.netmask='255.255.255.0'
  uci set network.net_single_$INSTANCE_ID.delegate='0'
  uci commit network
}

conf_dhcp() {
  echo "配置DHCP服务..."
  uci set dhcp.single_$INSTANCE_ID=dhcp
  uci set dhcp.single_$INSTANCE_ID.interface="net_single_$INSTANCE_ID"
  uci set dhcp.single_$INSTANCE_ID.start='100'
  uci set dhcp.single_$INSTANCE_ID.limit='150'
  uci set dhcp.single_$INSTANCE_ID.leasetime='12h'
  uci set dhcp.single_$INSTANCE_ID.dhcpv6='disabled'
  uci set dhcp.single_$INSTANCE_ID.dns='223.5.5.5 8.8.8.8'
  uci commit dhcp
}

conf_wifi() {
  echo "配置WiFi网络..."
  local radio_2g=$(uci show wireless 2>/dev/null | grep -E "band='2g'|htmode='HT" | cut -d '.' -f2 | head -n1)
  local radio_5g=$(uci show wireless 2>/dev/null | grep -E "band='5g'|htmode='VHT" | cut -d '.' -f2 | head -n1)
  local radio=$( [ -n "$radio_5g" ] && echo "$radio_5g" || echo "$radio_2g" )
  if [ -z "$radio" ]; then
    echo "⚠️  未检测到无线射频，尝试启用..."
    uci set wireless.radio0.disabled='0' 2>/dev/null
    uci set wireless.radio1.disabled='0' 2>/dev/null
    uci commit wireless
    /etc/init.d/wireless restart
    sleep 10
    radio_2g=$(uci show wireless 2>/dev/null | grep -E "band='2g'|htmode='HT" | cut -d '.' -f2 | head -n1)
    radio_5g=$(uci show wireless 2>/dev/null | grep -E "band='5g'|htmode='VHT" | cut -d '.' -f2 | head -n1)
    radio=$( [ -n "$radio_5g" ] && echo "$radio_5g" || echo "$radio_2g" )
    if [ -z "$radio" ]; then
      echo "❌ 无法启用无线射频"
      all_checks_passed=false
      return
    fi
  fi
  uci set wireless.single_$INSTANCE_ID=wifi-iface
  uci set wireless.single_$INSTANCE_ID.device="$radio"
  uci set wireless.single_$INSTANCE_ID.network="net_single_$INSTANCE_ID"
  uci set wireless.single_$INSTANCE_ID.mode='ap'
  uci set wireless.single_$INSTANCE_ID.ssid="$SSID"
  uci set wireless.single_$INSTANCE_ID.encryption='psk2'
  uci set wireless.single_$INSTANCE_ID.key="$WIFI_PASSWORD"
  if [ -n "$radio_5g" ]; then
    uci set wireless.single_$INSTANCE_ID.ieee80211ac='1'
    uci set wireless.single_$INSTANCE_ID.htmode='VHT80'
    uci set wireless.single_$INSTANCE_ID.channel='44'
  else
    uci set wireless.single_$INSTANCE_ID.ieee80211n='1'
    uci set wireless.single_$INSTANCE_ID.htmode='HT20'
    uci set wireless.single_$INSTANCE_ID.channel='6'
  fi
  uci commit wireless
}

conf_firewall() {
  echo "配置防IP泄露防火墙规则..."
  
  local config=$(cat /etc/foreign_proxy_profile.conf | grep -v '^#' | tr -dc '[:print:]')
  local proxy_port=$(echo "$config" | sed -E 's/.*port=([0-9]+).*/\1/')
  
  iptables -N "$FW_CHAIN" 2>/dev/null
  
  iptables -A "$FW_CHAIN" -s "$IP_CIDR" -p udp --dport 53 -j ACCEPT
  iptables -A "$FW_CHAIN" -s "$IP_CIDR" -p tcp --dport 53 -j ACCEPT
  
  iptables -A "$FW_CHAIN" -s "$IP_CIDR" -m set --match-set cn_ip_safe dst -j ACCEPT
  
  iptables -A "$FW_CHAIN" -s "$IP_CIDR" -p tcp -j REDIRECT --to-port "$proxy_port"
  iptables -A "$FW_CHAIN" -s "$IP_CIDR" -p udp -j REDIRECT --to-port "$proxy_port"
  
  iptables -A "$FW_CHAIN" -s "$IP_CIDR" -j DROP
  
  iptables -I FORWARD -s "$IP_CIDR" -j "$FW_CHAIN"
  
  echo "✅ 防IP泄露规则配置完成"
}

start() {
  echo "启动服务..."
  if ! retry "/etc/init.d/network restart"; then echo "⚠️  网络服务重启失败" >> "$LOG_FILE"; fi
  if ! retry "/etc/init.d/dnsmasq restart"; then echo "⚠️  DNS服务重启失败" >> "$LOG_FILE"; fi
  
  if ! retry "/etc/init.d/firewall restart"; then echo "⚠️  防火墙服务重启失败" >> "$LOG_FILE"; fi
  
  conf_firewall
  
  if ! retry "/etc/init.d/wireless restart"; then echo "⚠️  WiFi服务重启失败" >> "$LOG_FILE"; fi
}

main() {
  echo "📋 开始WiFi优化配置... ($(date))"
  echo "ℹ️  检测到实例ID: $INSTANCE_ID"
  check_proxy || true
  check_tools || true
  check_ipsets || true
  check_ip || true
  check_dns || true
  check_net || true
  check_proxy_health || true
  
  if [ "$all_checks_passed" = true ]; then
    conf_net
    conf_dhcp
    conf_wifi
    start
    echo -e "\n✅ 配置完成！"
    echo "WiFi名称: $SSID"
    echo "WiFi密码: $WIFI_PASSWORD"
    echo "管理IP: $IP_BASE"
    echo "$(date) - 配置完成（实例 $INSTANCE_ID）" >> "$LOG_FILE"
  else
    echo -e "\n❌ 检测失败，配置中止"
    echo "$(date) - 检测失败" >> "$LOG_FILE"
  fi
  rm -f "$LOCK_FILE"
}

main "$@"
