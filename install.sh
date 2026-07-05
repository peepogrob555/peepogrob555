#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Error: run as root"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

CYAN="\e[96m"; GREEN="\e[92m"; YELLOW="\e[93m"; RED="\e[91m"
BLUE="\e[94m"; MAGENTA="\e[95m"; WHITE="\e[97m"; NC="\e[0m"

logo() {
echo -e "${CYAN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       VPS OPTIMIZER - THAILAND EDITION       ║"
echo "  ║   VLESS Reality | Low Ping | High Stability  ║"
echo "  ║      เครดิต: FB:Shogun | IG:peepogrob555     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"
}

press_enter() {
    echo -e "\n${MAGENTA}กด Enter เพื่อดำเนินการต่อ...${NC}"
    read
}

ask_reboot() {
    echo -e "\n${YELLOW}รีบูตเครื่องเดี๋ยวนี้เลยไหม? (แนะนำ) ${GREEN}[y/n]${NC}"
    read reboot_choice
    [[ "$reboot_choice" =~ [Yy] ]] && systemctl reboot
}

# ===== STEP 1: UPDATE =====
step_update() {
    echo -e "\n${CYAN}===== [1/5] อัปเดตระบบ =====${NC}"
    apt-get update && apt-get upgrade -y
    apt-get install -y ufw e2fsprogs sed iptables ethtool dnsutils curl \
        linux-tools-common linux-tools-$(uname -r) cpufrequtils fail2ban \
        jq nload nethogs wget unzip zip nano net-tools haveged htop \
        iputils-ping lsb-release ca-certificates gnupg2 bash-completion
    echo -e "${GREEN}อัปเดตเสร็จสมบูรณ์${NC}"
}

# ===== STEP 2: FIREWALL + DNS =====
step_firewall() {
    echo -e "\n${CYAN}===== [2/5] ตั้งค่า Firewall & Cloudflare DNS =====${NC}"

    # MSS 1460 = MTU 1500 - IP(20) - TCP(20) → ล็อค MTU มือถือ V2BOX
    cat > /etc/ufw/before.rules << 'EOF'
*mangle
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1460
COMMIT
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-output -o lo -j ACCEPT
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
EOF

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 2222/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    for p in 2052 2053 2082 2083 2086 2087 2095 2096 8080 8443 8880; do
        ufw allow ${p}/tcp
    done

    # DNS Leak Protection - Cloudflare only (allow ก่อน deny)
    ufw allow out to 1.1.1.1 port 53
    ufw allow out to 1.0.0.1 port 53
    ufw allow out to 2606:4700:4700::1111 port 53
    ufw allow out to 2606:4700:4700::1001 port 53
    ufw deny out to any port 53
    ufw --force enable

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/cloudflare-dns.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=
DNSStubListener=no
EOF
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    else
        chattr -i /etc/resolv.conf 2>/dev/null
        printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null
    fi
    echo -e "${GREEN}Firewall & DNS เสร็จสมบูรณ์${NC}"
}

# ===== STEP 3: 3X-UI =====
step_3xui() {
    echo -e "\n${CYAN}===== [3/5] ติดตั้ง 3X-UI =====${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/00-disable-disk-log.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF
    systemctl restart systemd-journald
    systemctl stop rsyslog 2>/dev/null
    systemctl disable rsyslog 2>/dev/null

    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/vless-fix.local << 'EOF'
[DEFAULT]
backend = systemd

[sshd]
enabled = true
port = 22,2222
filter = sshd
maxretry = 5
bantime = 1h
EOF
    systemctl daemon-reload
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}3X-UI เสร็จสมบูรณ์${NC}"
}

# ===== STEP 4: SWAP (adaptive ตาม RAM) =====
step_swap() {
    echo -e "\n${CYAN}===== [4/5] ตั้งค่า Swap =====${NC}"
    RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$RAM_MB" -ge 8192 ]; then
        SWAP_SIZE="4G"
    elif [ "$RAM_MB" -ge 4096 ]; then
        SWAP_SIZE="6G"
    else
        SWAP_SIZE="8G"
    fi
    echo -e "RAM: ${RAM_MB}MB → Swap: ${SWAP_SIZE}"
    swapoff -a 2>/dev/null
    rm -f /swapfile
    fallocate -l $SWAP_SIZE /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "${GREEN}Swap ${SWAP_SIZE} เสร็จสมบูรณ์${NC}"
}

# ===== STEP 5: KERNEL + NETWORK =====
step_kernel() {
    echo -e "\n${CYAN}===== [5/5] ตั้งค่า Kernel, Network & CPU =====${NC}"

    modprobe sch_cake 2>/dev/null
    echo "sch_cake" > /etc/modules-load.d/cake.conf

    # BDP = 350Mbps x 50ms = 2.19MB → max 2.5MB (headroom ~14%)
    # tcp_base_mss = 1460 (MTU 1500 ล็อคฝั่งมือถือ V2BOX)
    cat > /etc/sysctl.d/99-vless-pure-optimize.conf << 'EOF'
fs.file-max = 67108864

net.core.default_qdisc = cake
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.optmem_max = 262144
net.core.somaxconn = 65535
net.core.rmem_max = 2621440
net.core.rmem_default = 262144
net.core.wmem_max = 2621440
net.core.wmem_default = 262144

net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_base_mss = 1460
net.ipv4.tcp_rmem = 4096 262144 2621440
net.ipv4.tcp_wmem = 4096 262144 2621440
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 0

net.ipv4.udp_mem = 65536 1048576 2621440

net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0

net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2

vm.swappiness = 10
vm.min_free_kbytes = 65536
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

kernel.panic = 1
EOF
    sysctl --system > /dev/null 2>&1

    cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
Before=basic.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes
[Install]
WantedBy=basic.target
EOF

    cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > $cpu 2>/dev/null; done; fi'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    systemctl disable --now irqbalance 2>/dev/null

    # cake 330mbit = ต่ำกว่า 350 นิดเพื่อให้ cake เป็น bottleneck ควบคุมคิวได้จริง
    # ปิด offload: บน KVM virtual NIC offload เป็น emulated อยู่แล้ว
    # ปิดแล้วลด micro-latency ของ software proxy (VLESS Reality) ได้จริง
    cat > /usr/local/bin/nic-optimize.sh << 'EOF'
#!/bin/bash
IFACE=$(ip route show default | awk '/default/ {print $5}')
if [ -n "$IFACE" ]; then
    ethtool -K $IFACE gso off tso off gro off lro off 2>/dev/null
    ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null
    ip link set dev $IFACE txqueuelen 10000 2>/dev/null
    tc qdisc replace dev $IFACE root cake bandwidth 330mbit rtt 50ms nat ack-filter ethernet 2>/dev/null
fi
EOF
    chmod +x /usr/local/bin/nic-optimize.sh

    cat > /etc/systemd/system/vless-nic-optimize.service << 'EOF'
[Unit]
Description=NIC Optimization Service
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nic-optimize.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now disable-thp.service
    systemctl enable --now cpu-performance.service
    systemctl enable --now vless-nic-optimize.service
    echo -e "${GREEN}Kernel & Network เสร็จสมบูรณ์${NC}"
}

# ===== UTIL: SSH HARDENING =====
util_ssh_hardening() {
    clear; logo
    echo -e "${MAGENTA}===== SSH Security Hardening =====${NC}\n"
    SSH_PATH="/etc/ssh/sshd_config"
    cp "$SSH_PATH" "${SSH_PATH}.bak"
    # prohibit-password: root เข้าด้วย SSH key ได้ แต่บล็อก password root login
    cat > "$SSH_PATH" << 'EOF'
Protocol 2
Port 22
Port 2222
HostKeyAlgorithms ssh-ed25519-cert-v01@openssh.com,ssh-ed25519,ecdsa-sha2-nistp256,ssh-rsa
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256,hmac-sha2-512
KexAlgorithms curve25519-sha256,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256
PermitRootLogin prohibit-password
UseDNS no
MaxSessions 20
Compression no
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 3
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel yes
X11Forwarding no
PrintMotd no
PrintLastLog yes
MaxAuthTries 5
LoginGraceTime 1m
MaxStartups 10:30:60
EOF
    systemctl restart ssh
    echo -e "${GREEN}SSH Hardening เสร็จสมบูรณ์${NC}"
    echo -e "${YELLOW}หมายเหตุ: root login ต้องใช้ SSH key เท่านั้น (password root login ถูกบล็อกแล้ว)${NC}"
    press_enter
}

# ===== UTIL: TIMEZONE =====
util_timezone() {
    clear; logo
    echo -e "${MAGENTA}===== ตั้งค่า Timezone =====${NC}\n"
    timedatectl set-timezone Asia/Bangkok
    echo -e "${GREEN}Timezone: Asia/Bangkok${NC}"
    timedatectl
    press_enter
}

# ===== UTIL: SPEEDTEST =====
util_speedtest() {
    clear; logo
    echo -e "${MAGENTA}===== Speedtest =====${NC}\n"
    if ! command -v speedtest &>/dev/null; then
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        apt-get install -y speedtest
    fi
    speedtest
    press_enter
}

# ===== UTIL: SYSCHECK =====
util_syscheck() {
    clear
    echo "======================================================"
    echo "     VLESS SERVER OPTIMIZER CHECKER - TH EDITION     "
    echo "======================================================"
    FAIL_COUNT=0

    echo -e "\n--- 1. Systemd Services ---"
    for srv in disable-thp cpu-performance vless-nic-optimize fail2ban; do
        systemctl is-active --quiet "$srv" \
            && echo -e "  $srv: ${GREEN}Active${NC}" \
            || { echo -e "  $srv: ${RED}Inactive${NC}"; ((FAIL_COUNT++)); }
    done

    echo -e "\n--- 2. Kernel Tuning ---"
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    mss=$(sysctl -n net.ipv4.tcp_base_mss 2>/dev/null)
    buf=$(sysctl -n net.core.rmem_max 2>/dev/null)
    ecn=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)
    [ "$bbr" == "bbr" ] && echo -e "  Congestion: ${GREEN}BBR${NC}" || { echo -e "  Congestion: ${RED}$bbr${NC}"; ((FAIL_COUNT++)); }
    [ "$qdisc" == "cake" ] && echo -e "  Qdisc: ${GREEN}CAKE${NC}" || { echo -e "  Qdisc: ${RED}$qdisc${NC}"; ((FAIL_COUNT++)); }
    [ "$mss" == "1460" ] && echo -e "  MSS: ${GREEN}1460 (MTU 1500 locked ✓)${NC}" || echo -e "  MSS: ${YELLOW}$mss${NC}"
    [ "$buf" == "2621440" ] && echo -e "  Buffer Max: ${GREEN}2.5MB (BDP 350Mbps×50ms ✓)${NC}" || echo -e "  Buffer Max: ${YELLOW}$buf${NC}"
    [ "$ecn" == "1" ] && echo -e "  ECN: ${GREEN}Enabled${NC}" || echo -e "  ECN: ${YELLOW}Disabled${NC}"

    echo -e "\n--- 3. NIC & CAKE ---"
    IFACE=$(ip route show default | awk '/default/ {print $5}')
    if [ -n "$IFACE" ]; then
        txq=$(cat /sys/class/net/$IFACE/tx_queue_len 2>/dev/null)
        [ "$txq" -eq 10000 ] && echo -e "  TxQueueLen: ${GREEN}$txq${NC}" || { echo -e "  TxQueueLen: ${RED}$txq${NC}"; ((FAIL_COUNT++)); }
        if tc qdisc show dev $IFACE | grep -q "cake"; then
            info=$(tc qdisc show dev $IFACE | grep -o 'bandwidth [^ ]* rtt [^ ]*' | head -1)
            echo -e "  CAKE: ${GREEN}Active | $info${NC}"
        else
            echo -e "  CAKE: ${RED}Missing${NC}"; ((FAIL_COUNT++))
        fi
        gso=$(ethtool -k $IFACE 2>/dev/null | grep "generic-segmentation-offload" | awk '{print $2}')
        [ "$gso" == "off" ] && echo -e "  Offload (GSO/TSO/GRO): ${GREEN}Off (low latency mode ✓)${NC}" || echo -e "  Offload: ${YELLOW}On${NC}"
    fi

    echo -e "\n--- 4. THP & CPU ---"
    grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
        && echo -e "  THP: ${GREEN}Disabled${NC}" || { echo -e "  THP: ${RED}Enabled${NC}"; ((FAIL_COUNT++)); }
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "managed by host")
    echo -e "  CPU Governor: ${GREEN}$gov${NC}"

    echo -e "\n--- 5. Memory & Storage ---"
    grep -q "Storage=volatile" /etc/systemd/journald.conf.d/*.conf 2>/dev/null \
        && echo -e "  Journald: ${GREEN}Volatile (RAM Only)${NC}" || { echo -e "  Journald: ${RED}Persistent${NC}"; ((FAIL_COUNT++)); }
    swap_total=$(free -m | awk '/Swap/ {print $2}')
    [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ] \
        && echo -e "  Swap: ${GREEN}${swap_total}MB${NC}" || { echo -e "  Swap: ${RED}None${NC}"; ((FAIL_COUNT++)); }

    echo -e "\n--- 6. Firewall & DNS Leak Protection ---"
    ufw status | grep -q "Status: active" \
        && echo -e "  UFW: ${GREEN}Active (default deny incoming ✓)${NC}" || { echo -e "  UFW: ${RED}Inactive${NC}"; ((FAIL_COUNT++)); }
    ufw status | grep -q "1.1.1.1" \
        && echo -e "  CF DNS Lock: ${GREEN}Active (port 53 blocked except Cloudflare)${NC}" \
        || { echo -e "  CF DNS Lock: ${RED}Missing${NC}"; ((FAIL_COUNT++)); }

    echo -e "\n--- 7. 3X-UI & Fail2ban ---"
    ss -tulpn | grep -E 'x-ui|xray|v2ray' >/dev/null 2>&1 \
        && echo -e "  3X-UI Core: ${GREEN}LISTEN${NC}" || { echo -e "  3X-UI Core: ${RED}Not Running${NC}"; ((FAIL_COUNT++)); }
    fail2ban-client status sshd >/dev/null 2>&1 \
        && echo -e "  Fail2ban: ${GREEN}Active${NC}" || { echo -e "  Fail2ban: ${RED}Inactive${NC}"; ((FAIL_COUNT++)); }

    echo -e "\n--- 8. SSH Security ---"
    grep -q "Port 2222" /etc/ssh/sshd_config \
        && echo -e "  Port 2222: ${GREEN}Configured${NC}" || echo -e "  Port 2222: ${YELLOW}Not set${NC}"
    grep -q "prohibit-password" /etc/ssh/sshd_config \
        && echo -e "  Root Login: ${GREEN}Key-only (prohibit-password ✓)${NC}" \
        || echo -e "  Root Login: ${YELLOW}Check sshd_config${NC}"
    grep -q "Compression no" /etc/ssh/sshd_config \
        && echo -e "  Compression: ${GREEN}Off (low latency)${NC}" || echo -e "  Compression: ${YELLOW}On${NC}"

    echo ""
    echo "======================================================"
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "  ${GREEN}STATUS: สมบูรณ์แบบ 100% ✓${NC}"
    else
        echo -e "  ${RED}STATUS: พบปัญหา $FAIL_COUNT จุด${NC}"
    fi
    echo "======================================================"
    press_enter
}

install_syscheck_cmd() {
    cp /usr/local/bin/nic-optimize.sh /usr/local/bin/nic-optimize.sh 2>/dev/null
    cat > /usr/local/bin/syscheck.sh << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
clear
echo "======================================================"
echo "     VLESS SERVER OPTIMIZER CHECKER - TH EDITION     "
echo "======================================================"
FAIL_COUNT=0
for srv in disable-thp cpu-performance vless-nic-optimize fail2ban; do
    systemctl is-active --quiet "$srv" && echo -e "  $srv: ${GREEN}OK${NC}" || { echo -e "  $srv: ${RED}FAIL${NC}"; ((FAIL_COUNT++)); }
done
bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
[ "$bbr" == "bbr" ] && echo -e "  BBR: ${GREEN}OK${NC}" || { echo -e "  BBR: ${RED}$bbr${NC}"; ((FAIL_COUNT++)); }
[ "$qdisc" == "cake" ] && echo -e "  CAKE: ${GREEN}OK${NC}" || { echo -e "  CAKE: ${RED}$qdisc${NC}"; ((FAIL_COUNT++)); }
grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && echo -e "  THP: ${GREEN}Disabled${NC}" || { echo -e "  THP: ${RED}Enabled${NC}"; ((FAIL_COUNT++)); }
ufw status | grep -q "Status: active" && echo -e "  UFW: ${GREEN}Active${NC}" || { echo -e "  UFW: ${RED}Inactive${NC}"; ((FAIL_COUNT++)); }
echo "======================================================"
[ $FAIL_COUNT -eq 0 ] && echo -e "  ${GREEN}OK 100% ✓${NC}" || echo -e "  ${RED}พบปัญหา $FAIL_COUNT จุด${NC}"
echo "======================================================"
EOF
    chmod +x /usr/local/bin/syscheck.sh
}

# ===== FULL AUTO SETUP =====
run_full_setup() {
    clear; logo
    echo -e "${YELLOW}เริ่มติดตั้งอัตโนมัติ...${NC}\n"
    step_update
    step_firewall
    step_3xui
    step_swap
    step_kernel
    install_syscheck_cmd
    timedatectl set-timezone Asia/Bangkok
    clear; logo
    echo -e "${GREEN}======================================================"
    echo " การตั้งค่าเสร็จสมบูรณ์"
    echo " เรียกเช็คระบบด้วยคำสั่ง: syscheck.sh"
    echo " สั่ง 'reboot' 1 ครั้งเพื่อให้ค่าทั้งหมดมีผล"
    echo -e "======================================================${NC}"
    sleep 2
    util_syscheck
    ask_reboot
}

# ===== MAIN MENU =====
while true; do
    clear; logo
    echo -e "\e[93m╔═══════════════════════════════════════╗\e[0m"
    echo -e "\e[93m║              MAIN MENU                ║\e[0m"
    echo -e "\e[93m╚═══════════════════════════════════════╝\e[0m\n"
    echo -e "${GREEN} 1)${NC} ติดตั้งและตั้งค่าทั้งหมด (Auto Setup)"
    echo ""
    echo -e "${GREEN} 2)${NC} เช็คสถานะระบบ (Syscheck)"
    echo -e "${GREEN} 3)${NC} SSH Security Hardening"
    echo -e "${GREEN} 4)${NC} ตั้งค่า Timezone (Asia/Bangkok)"
    echo -e "${GREEN} 5)${NC} Speedtest"
    echo ""
    echo -e "${GREEN} 0)${NC} ออก"
    echo ""
    echo -ne "${YELLOW}เลือก: ${NC}"
    read -r choice
    case $choice in
        1) run_full_setup ;;
        2) util_syscheck ;;
        3) util_ssh_hardening ;;
        4) util_timezone ;;
        5) util_speedtest ;;
        0) echo -e "${RED}ออกจากโปรแกรม${NC}"; exit 0 ;;
        *) echo -e "${RED}กรุณาเลือก 0-5${NC}"; sleep 1 ;;
