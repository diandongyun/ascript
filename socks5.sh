#!/bin/bash

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                      SOCKS5节点一键搭建脚本 v1.0                            ║
# ║                   基于Dante服务器的高性能SOCKS5代理                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

# Transfer配置
TRANSFER_BIN="/usr/local/bin/transfer"

# 图标定义
ICON_SUCCESS="✅"
ICON_ERROR="❌"
ICON_WARNING="⚠️"
ICON_INFO="ℹ️"
ICON_ROCKET="🚀"
ICON_FIRE="🔥"
ICON_STAR="⭐"
ICON_SHIELD="🛡️"
ICON_NETWORK="🌐"
ICON_SPEED="⚡"
ICON_CONFIG="⚙️"
ICON_DOWNLOAD="📥"
ICON_UPLOAD="📤"

# 全局变量
SYSTEM=""
SYSTEM_VERSION=""
PUBLIC_IP=""
PRIVATE_IP=""
up_speed=100
down_speed=100
SOCKS_PORT=""
SOCKS_USER=""
SOCKS_PASS=""

# ========== 日志函数 ==========
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# ========== 进度条函数 ==========
show_progress() {
    local current=$1
    local total=$2
    local desc="$3"
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))

    printf "\r${CYAN}${BOLD}[${NC}"
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
    printf "${CYAN}${BOLD}] ${percent}%% ${WHITE}${desc}${NC}"
}

complete_progress() {
    local desc="$1"
    printf "\r${GREEN}${BOLD}[##################################################] 100%% ${ICON_SUCCESS} ${desc}${NC}\n"
}

# 动态进度条函数 - 根据进程状态显示
show_dynamic_progress() {
    local pid=$1
    local message=$2
    local progress=0
    local bar_length=50
    local spin_chars="/-\|"

    echo -e "${YELLOW}${message}${NC}"

    while kill -0 $pid 2>/dev/null; do
        local spin_index=$((progress % 4))
        local spin_char=${spin_chars:$spin_index:1}

        # 计算进度条 (基于时间的估算)
        local filled=$((progress % bar_length))
        local empty=$((bar_length - filled))

        printf "\r["
        printf "%${filled}s" | tr ' ' '='
        printf "%${empty}s" | tr ' ' ' '
        printf "] %s 进行中..." "$spin_char"

        sleep 0.2
        progress=$((progress + 1))
    done

    # 进程结束后显示100%完成
    printf "\r["
    printf "%${bar_length}s" | tr ' ' '='
    printf "] 100%%"
    echo -e "\n${GREEN}完成！${NC}"
}

# 固定时长进度条函数
show_timed_progress() {
    local duration=$1
    local message=$2
    local progress=0
    local bar_length=50

    echo -e "${YELLOW}${message}${NC}"

    while [ $progress -le $duration ]; do
        local filled=$((progress * bar_length / duration))
        local empty=$((bar_length - filled))

        printf "\r["
        printf "%${filled}s" | tr ' ' '='
        printf "%${empty}s" | tr ' ' ' '
        printf "] %d%%" $((progress * 100 / duration))

        sleep 0.1
        progress=$((progress + 1))
    done
    echo -e "\n${GREEN}完成！${NC}"
}

# ========== 系统检测函数 ==========
detect_system() {
    log_info "检测系统类型..."

    # 检查是否为Ubuntu系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ]; then
            log_error "此脚本仅支持Ubuntu系统，当前系统：$ID"
            exit 1
        fi
        SYSTEM="Ubuntu"
        SYSTEM_VERSION="$VERSION_ID"
        log_info "检测到系统类型: $SYSTEM $SYSTEM_VERSION"
    else
        log_error "无法检测系统类型"
        exit 1
    fi

    # 检查架构
    local arch=$(uname -m)
    if [ "$arch" != "x86_64" ]; then
        log_error "此脚本仅支持x86_64架构，当前架构：$arch"
        exit 1
    fi

    log_info "系统检测通过: Ubuntu $SYSTEM_VERSION (x86_64)"
}

# ========== IP地址检测函数 ==========
detect_ip_addresses() {
    log_info "检测服务器IP地址..."

    # 检测公网IP (仅IPv4)
    PUBLIC_IP=$(curl -4 -s --connect-timeout 10 ifconfig.me 2>/dev/null || \
                curl -4 -s --connect-timeout 10 ipinfo.io/ip 2>/dev/null || \
                curl -4 -s --connect-timeout 10 icanhazip.com 2>/dev/null || \
                echo "")

    if [[ -n "$PUBLIC_IP" ]]; then
        log_info "检测到公网IPv4地址: $PUBLIC_IP"
    else
        log_warn "未检测到公网IPv4地址"
    fi

    # 检测内网IP (仅IPv4)
    PRIVATE_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || \
                 hostname -I 2>/dev/null | awk '{print $1}' || \
                 echo "")

    if [[ -n "$PRIVATE_IP" ]]; then
        log_info "检测到内网IPv4地址: $PRIVATE_IP"
    else
        log_warn "未检测到内网IPv4地址"
    fi

    # 检查IP配置兼容性
    if [[ -n "$PUBLIC_IP" && -n "$PRIVATE_IP" ]]; then
        log_info "服务器同时具有公网IPv4和内网IPv4地址"
    elif [[ -n "$PUBLIC_IP" && -z "$PRIVATE_IP" ]]; then
        log_info "服务器只有公网IPv4地址，没有内网IPv4地址"
        PRIVATE_IP="$PUBLIC_IP"
    else
        log_error "无法获取有效的IPv4地址"
        exit 1
    fi
}

# ========== 网络速度测试函数 ==========
speed_test() {
    echo -e "${YELLOW}${ICON_SPEED} 进行网络速度测试...${NC}"

    # 检查并安装speedtest-cli
    if ! command -v speedtest &>/dev/null && ! command -v speedtest-cli &>/dev/null; then
        echo -e "${YELLOW}安装speedtest-cli中...${NC}"
        apt-get update >/dev/null 2>&1 &
        update_pid=$!
        show_timed_progress 20 "更新软件包列表..."
        wait $update_pid

        apt-get install -y speedtest-cli >/dev/null 2>&1 &
        install_pid=$!
        show_timed_progress 30 "安装speedtest-cli..."
        wait $install_pid
        echo -e "${GREEN}speedtest-cli 安装完成！${NC}"
    fi

    # 创建临时文件存储结果
    local temp_file="/tmp/speedtest_result_$$"

    # 在后台运行测速命令
    (
        if command -v speedtest &>/dev/null; then
            speedtest --simple 2>/dev/null > "$temp_file"
        elif command -v speedtest-cli &>/dev/null; then
            speedtest-cli --simple 2>/dev/null > "$temp_file"
        fi
    ) &
    speedtest_pid=$!

    # 使用动态进度条
    show_dynamic_progress $speedtest_pid "正在测试网络速度，请稍候..."

    # 等待测速完成
    wait $speedtest_pid
    speedtest_exit_code=$?

    # 读取测速结果
    if [ $speedtest_exit_code -eq 0 ] && [ -f "$temp_file" ]; then
        speed_output=$(cat "$temp_file")
        rm -f "$temp_file"

        if [[ -n "$speed_output" ]]; then
            down_speed=$(echo "$speed_output" | grep "Download" | awk '{print int($2)}')
            up_speed=$(echo "$speed_output" | grep "Upload" | awk '{print int($2)}')

            # 验证结果是否有效
            if [[ -n "$down_speed" && -n "$up_speed" && "$down_speed" -gt 0 && "$up_speed" -gt 0 ]]; then
                [[ $down_speed -lt 10 ]] && down_speed=10
                [[ $up_speed -lt 5 ]] && up_speed=5
                [[ $down_speed -gt 1000 ]] && down_speed=1000
                [[ $up_speed -gt 500 ]] && up_speed=500
                echo -e "${GREEN}${ICON_SUCCESS} 测速完成：下载 ${down_speed} Mbps，上传 ${up_speed} Mbps${NC}"
            else
                echo -e "${YELLOW}测速结果异常，使用默认值${NC}"
                down_speed=100
                up_speed=20
            fi
        else
            echo -e "${YELLOW}测速失败，使用默认值${NC}"
            down_speed=100
            up_speed=20
        fi
    else
        rm -f "$temp_file"
        echo -e "${YELLOW}测速失败，使用默认值${NC}"
        down_speed=100
        up_speed=20
    fi
}

# ========== 防火墙配置函数 ==========
configure_firewall() {
    log_info "配置防火墙..."
    local port=$1

    # 安装ufw
    if ! command -v ufw &>/dev/null; then
        apt-get install -y ufw >/dev/null 2>&1
    fi

    echo "y" | ufw reset >/dev/null 2>&1
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow ${port}/udp >/dev/null 2>&1
    ufw allow ${port}/tcp >/dev/null 2>&1
    echo "y" | ufw enable >/dev/null 2>&1

    log_info "防火墙配置完成，已开放SSH(22)和服务端口($port)"
}

# ========== 网络优化函数 ==========
optimize_network() {
    log_info "优化网络参数..."

    # 网络优化配置
    cat >> /etc/sysctl.conf <<EOF

# SOCKS5节点网络优化
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.netdev_max_backlog = 5000
net.ipv4.udp_mem = 102400 873800 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 5000

# BBR拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p >/dev/null 2>&1
    log_info "网络优化完成"
}

# ========== 生成随机端口 ==========
generate_random_port() {
    echo $(( RANDOM % 7001 + 2000 ))
}

# ========== 生成密码 ==========
generate_password() {
    local length=${1:-16}
    tr -dc A-Za-z0-9 </dev/urandom | head -c "$length"
}

# ========== 检查root权限 ==========
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "请使用 root 权限执行脚本"
        exit 1
    fi
}

# ========== 显示横幅 ==========
show_banner() {
    local title="$1"
    clear
    echo -e "${GREEN}"
    echo "=================================="
    echo "   $title"
    echo "=================================="
    echo -e "${NC}"
}

# ========== 安装Dante SOCKS服务器 ==========
install_dante_server() {
    log_info "安装Dante SOCKS服务器..."

    apt-get update >/dev/null 2>&1 &
    update_pid=$!
    show_dynamic_progress $update_pid "更新软件包列表..."
    wait $update_pid

    apt-get install -y dante-server >/dev/null 2>&1 &
    install_pid=$!
    show_dynamic_progress $install_pid "安装Dante服务器..."
    wait $install_pid

    if ! command -v danted &>/dev/null; then
        log_error "Dante服务器安装失败"
        exit 1
    fi

    log_info "Dante SOCKS服务器安装完成"
}

# ========== 配置Dante服务器 ==========
configure_dante() {
    log_info "配置Dante SOCKS服务器..."

    # 生成配置参数
    SOCKS_PORT=$(generate_random_port)
    SOCKS_USER="user$(openssl rand -hex 3)"
    SOCKS_PASS=$(generate_password 12)

    # 创建系统用户（如果不存在）
    if ! id "$SOCKS_USER" &>/dev/null; then
        useradd -r -s /bin/false "$SOCKS_USER" >/dev/null 2>&1
    fi
    echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd

    log_info "生成的认证信息："
    log_info "  用户名: $SOCKS_USER"
    log_info "  密码: $SOCKS_PASS"
    log_info "  端口: $SOCKS_PORT"

    # 创建Dante配置文件
    cat > /etc/danted.conf << EOF
# Dante SOCKS5 服务器配置
# 生成时间: $(date)

logoutput: /var/log/danted.log

# 监听配置
internal: 0.0.0.0 port = $SOCKS_PORT
external: $PRIVATE_IP

# 认证方法
socksmethod: username
clientmethod: none

# 用户规则 - 允许所有用户连接
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

# SOCKS规则 - 需要用户名认证
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect error
    socksmethod: username
}
EOF

    # 创建日志文件
    touch /var/log/danted.log
    chmod 644 /var/log/danted.log

    # 配置防火墙
    configure_firewall $SOCKS_PORT

    log_info "Dante服务器配置完成"
}

# ========== 启动Dante服务 ==========
start_dante_service() {
    log_info "启动Dante SOCKS服务..."

    # 创建运行目录
    mkdir -p /var/run/danted
    mkdir -p /var/log/danted

    # 创建systemd服务文件
    cat > /etc/systemd/system/danted.service << EOF
[Unit]
Description=Dante SOCKS5 Server
After=network.target

[Service]
Type=forking
PIDFile=/var/run/danted/danted.pid
ExecStart=/usr/sbin/danted -D -f /etc/danted.conf -p /var/run/danted/danted.pid
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
User=root
Group=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable danted.service >/dev/null 2>&1
    
    # 测试配置文件
    log_info "验证Dante配置文件..."
    if ! /usr/sbin/danted -V -f /etc/danted.conf; then
        log_error "Dante配置文件验证失败"
        exit 1
    fi
    
    # 启动服务
    systemctl start danted.service >/dev/null 2>&1

    # 检查服务状态
    sleep 5
    if systemctl is-active --quiet danted.service; then
        log_info "Dante SOCKS服务启动成功"
    else
        log_error "Dante SOCKS服务启动失败"
        echo "详细错误信息："
        journalctl -u danted.service --no-pager -n 20
        echo ""
        echo "配置文件内容："
        cat /etc/danted.conf
        exit 1
    fi
}

# ========== 保存配置信息到JSON文件 ==========
save_config_to_json() {
    log_info "保存SOCKS5配置信息到JSON文件..."

    # 确保/opt目录存在
    mkdir -p /opt

    # 创建JSON配置文件
    cat > /opt/socks5_config.json << EOF
{
    "socks5_server": {
        "server_ip": "$PUBLIC_IP",
        "server_port": $SOCKS_PORT,
        "username": "$SOCKS_USER",
        "password": "$SOCKS_PASS",
        "protocol": "socks5",
        "authentication": true,
        "udp_support": true,
        "bandwidth": {
            "upload_mbps": $up_speed,
            "download_mbps": $down_speed
        }
    },
    "server_info": {
        "public_ip": "$PUBLIC_IP",
        "private_ip": "$PRIVATE_IP",
        "system": "$SYSTEM",
        "version": "$SYSTEM_VERSION",
        "architecture": "x86_64"
    },
    "deployment_info": {
        "deployment_time": "$(date '+%Y-%m-%d %H:%M:%S %Z')",
        "script_version": "v1.0",
        "config_file": "/etc/danted.conf",
        "service_name": "danted.service"
    },
    "client_configuration": {
        "proxy_url": "socks5://$SOCKS_USER:$SOCKS_PASS@$PUBLIC_IP:$SOCKS_PORT",
        "example_curl": "curl -x socks5://$SOCKS_USER:$SOCKS_PASS@$PUBLIC_IP:$SOCKS_PORT http://example.com",
        "example_wget": "wget -e \"use_proxy=yes\" -e \"http_proxy=$PUBLIC_IP:$SOCKS_PORT\" --proxy-user=$SOCKS_USER --proxy-password=$SOCKS_PASS http://example.com"
    }
}
EOF

    # 设置适当的权限
    chmod 644 /opt/socks5_config.json

    log_info "SOCKS5配置已保存到: /opt/socks5_config.json"
    
    # 显示JSON文件内容
    echo -e "${GREEN}${BOLD}JSON配置文件内容：${NC}"
    cat /opt/socks5_config.json
    echo ""
}

# ========== 显示最终结果 ==========
show_final_result() {
    clear
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║                                                                              ║${NC}"
    echo -e "${GREEN}${BOLD}║              ${YELLOW}${ICON_ROCKET} SOCKS5 代理服务器部署完成！${ICON_ROCKET}${GREEN}${BOLD}                             ║${NC}"
    echo -e "${GREEN}${BOLD}║                                                                              ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${WHITE}${BOLD}📊 服务器信息：${NC}"
    echo -e "  ${CYAN}服务器IP：${YELLOW}${PUBLIC_IP}${NC}"
    echo -e "  ${CYAN}SOCKS5端口：${YELLOW}${SOCKS_PORT}${NC}"
    echo -e "  ${CYAN}用户名：${YELLOW}${SOCKS_USER}${NC}"
    echo -e "  ${CYAN}密码：${YELLOW}${SOCKS_PASS}${NC}"
    echo -e "  ${CYAN}协议：${YELLOW}SOCKS5 (支持UDP)${NC}"
    echo -e "  ${CYAN}上传带宽：${YELLOW}${up_speed} Mbps${NC}"
    echo -e "  ${CYAN}下载带宽：${YELLOW}${down_speed} Mbps${NC}\n"

    echo -e "${WHITE}${BOLD}📁 配置文件：${NC}"
    echo -e "  ${CYAN}服务器配置：${YELLOW}/etc/danted.conf${NC}"
    echo -e "  ${CYAN}JSON配置信息：${YELLOW}/opt/socks5_config.json${NC}\n"

    echo -e "${WHITE}${BOLD}🛠️ 管理命令：${NC}"
    echo -e "  ${CYAN}查看状态：${YELLOW}systemctl status danted${NC}"
    echo -e "  ${CYAN}重启服务：${YELLOW}systemctl restart danted${NC}"
    echo -e "  ${CYAN}查看日志：${YELLOW}journalctl -u danted -f${NC}\n"

    echo -e "${GREEN}${BOLD}🔧 优化特性：${NC}"
    echo -e "  ${GREEN}${ICON_SUCCESS} 用户认证安全保护${NC}"
    echo -e "  ${GREEN}${ICON_SUCCESS} UDP协议支持${NC}"
    echo -e "  ${GREEN}${ICON_SUCCESS} 网络参数优化${NC}"
    echo -e "  ${GREEN}${ICON_SUCCESS} 防火墙规则配置${NC}"

    echo -e "${BLUE}${BOLD}${ICON_INFO} 部署完成时间：${YELLOW}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════════════════════════${NC}\n"

    # 生成客户端配置信息
    echo -e "${WHITE}${BOLD}📱 客户端配置信息：${NC}"
    echo -e "  ${CYAN}服务器地址：${YELLOW}${PUBLIC_IP}${NC}"
    echo -e "  ${CYAN}端口：${YELLOW}${SOCKS_PORT}${NC}"
    echo -e "  ${CYAN}用户名：${YELLOW}${SOCKS_USER}${NC}"
    echo -e "  ${CYAN}密码：${YELLOW}${SOCKS_PASS}${NC}"
    echo -e "  ${CYAN}代理类型：${YELLOW}SOCKS5${NC}\n"

    # 显示JSON文件路径
    echo -e "${WHITE}${BOLD}💾 JSON配置文件：${NC}"
    echo -e "  ${CYAN}文件位置：${YELLOW}/opt/socks5_config.json${NC}"
    echo -e "  ${CYAN}查看内容：${YELLOW}cat /opt/socks5_config.json${NC}"
    echo -e "  ${CYAN}格式化查看：${YELLOW}cat /opt/socks5_config.json | jq .${NC} (需要安装jq工具)\n"
}

# ========== 清理临时文件 ==========
cleanup() {
    rm -f /tmp/speedtest_result_*
}

# ========== 主函数 ==========
main() {
    # 检查root权限
    check_root

    show_banner "SOCKS5 代理服务器部署脚本"

    # 执行主要流程
    detect_system
    detect_ip_addresses
    speed_test
    optimize_network
    install_dante_server
    configure_dante
    start_dante_service
    save_config_to_json
    show_final_result

    log_info "所有部署步骤已完成！"
}

# 捕获退出信号进行清理
trap cleanup EXIT

# 执行主函数
main "$@"
