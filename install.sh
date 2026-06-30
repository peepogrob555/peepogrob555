#!/bin/bash
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root"
   exit 1
fi
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "===== [1/5] อัปเดตระบบ & ติดตั้ง Fail2ban ====="
apt-get update && apt-get upgrade -y
apt-get install -y ufw e2fsprogs sed iptables ethtool dnsutils curl \
    linux-tools-common linux-tools-$(uname -r) cpufrequtils fail2ban

echo "===== [2/5] ตั้งค่า Firewall & Cloudflare DNS ====="
cat <<EOF > /etc/ufw/before.rules
*mangle
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
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
ufw default allow incoming; ufw default allow outgoing
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp

for p in 2052 2053 2082 2083 2086 2087 2095 2096 8080 8443 8880; do
    ufw allow ${p}/tcp
done

ufw allow out to 1.1.1.1 port 53
ufw allow out to 1.0.0.1 port 53
ufw allow out to 2606:4700:4700::1111 port 53
ufw allow out to 2606:4700:4700::1001 port 53
ufw deny out to any port 53
ufw --force enable

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat <<EOF > /etc/systemd/resolved.conf.d/cloudflare-dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=
DNSStubListener=no
EOF
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
else
    chattr -i /etc/resolv.conf 2>/dev/null
    cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
    chattr +i /etc/resolv.conf 2>/dev/null
fi

echo "===== [3/5] ติดตั้ง 3X-UI (หยุดรอให้กรอกเอง) & Patch Fail2ban ====="
# คำสั่งติดตั้งแบบ Interactive ดั้งเดิม รอให้คุณกรอกหน้าจอเองตามใจชอบ
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# หลังจากคุณกรอกเสร็จ สคริปต์จะทำงานส่วนที่เหลือต่อให้อัตโนมัติ:
mkdir -p /etc/systemd/journald.conf.d
cat <<EOF > /etc/systemd/journald.conf.d/00-disable-disk-log.conf
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF
systemctl restart systemd-journald
systemctl stop rsyslog; systemctl disable rsyslog

mkdir -p /etc/fail2ban/jail.d
cat <<EOF > /etc/fail2ban/jail.d/vless-fix.local
[DEFAULT]
backend = systemd

[sshd]
enabled = true
port = 22
filter = sshd
maxretry = 5
bantime = 1h
EOF
systemctl daemon-reload
systemctl enable fail2ban
systemctl restart fail2ban

echo "===== [4/5] ตั้งค่า Swap 8GB ====="
swapoff -a 2>/dev/null
rm -f /swapfile
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

echo "===== [5/5] ตั้งค่า Kernel, Network & CPU Optimization ====="
modprobe sch_cake
echo "sch_cake" > /etc/modules-load.d/cake.conf

cat <<EOF > /etc/sysctl.d/99-vless-pure-optimize.conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_base_mss = 1360
net.core.rmem_max = 3276800
net.core.wmem_max = 3276800
net.ipv4.tcp_rmem = 4096 87380 3276800
net.ipv4.tcp_wmem = 4096 65536 3276800
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_timestamps = 1
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
vm.swappiness = 10
EOF
sysctl --system > /dev/null 2>&1

cat <<'EOF' > /etc/systemd/system/disable-thp.service
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

cat <<'EOF' > /etc/systemd/system/cpu-performance.service
[Unit]
Description=Set CPU governor to performance
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > $cpu 2>/dev/null; done; else echo "Managed by Host VPS"; fi'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

systemctl disable --now irqbalance 2>/dev/null

cat <<'EOF' > /usr/local/bin/nic-optimize.sh
#!/bin/bash
IFACE=$(ip route show default | awk '/default/ {print $5}')
if [ -n "$IFACE" ]; then
    ethtool -K $IFACE gso off tso off gro off lro off 2>/dev/null
    ethtool -G $IFACE rx 4096 tx 4096 2>/dev/null
    ip link set dev $IFACE txqueuelen 10000 2>/dev/null
    tc qdisc replace dev $IFACE root cake bandwidth 1000mbit rtt 60ms nat ack-filter ethernet 2>/dev/null
fi
EOF
chmod +x /usr/local/bin/nic-optimize.sh

cat <<EOF > /etc/systemd/system/vless-nic-optimize.service
[Unit]
Description=Network Optimization Service
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

echo "===== ฝังตัวเช็คระบบ Ultimate Version (9 จุดเช็ค) ====="
cat <<'EOF' > /usr/local/bin/syscheck.sh
#!/bin/bash
clear
echo "======================================================"
echo "          VLESS SERVER OPTIMIZATION CHECKER           "
echo "======================================================"
echo ""
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
FAIL_COUNT=0

echo "--- 1. Systemd Services Status ---"
services=("disable-thp" "cpu-performance" "vless-nic-optimize" "fail2ban")
for srv in "${services[@]}"; do
    if systemctl is-active --quiet "$srv"; then
        echo -e "  $srv: ${GREEN}Active (Running/Exited)${NC}"
    else
        echo -e "  $srv: ${RED}Inactive (Failed/Missing)${NC}"
        ((FAIL_COUNT++))
    fi
done
echo ""

echo "--- 2. Kernel & Network Tuning ---"
bbr_check=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
cake_check=$(sysctl -n net.core.default_qdisc 2>/dev/null)
if [ "$bbr_check" == "bbr" ]; then
    echo -e "  TCP Congestion Control: ${GREEN}$bbr_check${NC}"
else
    echo -e "  TCP Congestion Control: ${RED}$bbr_check (Should be bbr)${NC}"
    ((FAIL_COUNT++))
fi
if [ "$cake_check" == "cake" ]; then
    echo -e "  Default Qdisc: ${GREEN}$cake_check${NC}"
else
    echo -e "  Default Qdisc: ${RED}$cake_check (Should be cake)${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 3. Network Interface (NIC) Tweak ---"
IFACE=$(ip route show default | awk '/default/ {print $5}')
if [ -n "$IFACE" ]; then
    txq=$(cat /sys/class/net/$IFACE/tx_queue_len 2>/dev/null)
    if [ "$txq" -eq 10000 ]; then
        echo -e "  Interface ($IFACE) TxQueueLen: ${GREEN}$txq${NC}"
    else
        echo -e "  Interface ($IFACE) TxQueueLen: ${RED}$txq (Should be 10000)${NC}"
        ((FAIL_COUNT++))
    fi
    if tc qdisc show dev $IFACE | grep -q "cake"; then
        echo -e "  Traffic Control (tc): ${GREEN}CAKE Active${NC}"
    else
        echo -e "  Traffic Control (tc): ${RED}CAKE Missing${NC}"
        ((FAIL_COUNT++))
    fi
else
    echo -e "  Default Interface: ${RED}Not Found${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 4. Transparent Huge Pages (THP) ---"
if grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
    echo -e "  THP Status: ${GREEN}Disabled (never)${NC}"
else
    echo -e "  THP Status: ${RED}Enabled (Should be never)${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 5. Zero-Log Config (Journald) ---"
if grep -q "Storage=volatile" /etc/systemd/journald.conf.d/*.conf 2>/dev/null || grep -q "Storage=volatile" /etc/systemd/journald.conf 2>/dev/null; then
    echo -e "  Journald Storage: ${GREEN}Volatile (RAM Only)${NC}"
else
    echo -e "  Journald Storage: ${RED}Persistent/Auto (Writing to Disk)${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 6. Swap Space Status ---"
swap_total=$(free -m | awk '/Swap/ {print $2}')
if [ -n "$swap_total" ] && [ "$swap_total" -gt 7000 ]; then
    echo -e "  Swap Space: ${GREEN}Active (${swap_total}MB / ~8GB)${NC}"
else
    echo -e "  Swap Space: ${RED}Inactive or Incorrect Size (${swap_total}MB)${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 7. Firewall (UFW) Status ---"
if ufw status | grep -q "Status: active"; then
    echo -e "  UFW Firewall: ${GREEN}Active${NC}"
else
    echo -e "  UFW Firewall: ${RED}Inactive${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 8. 3X-UI & Xray Core Ports ---"
if ss -tulpn | grep -E 'x-ui|xray|v2ray' >/dev/null 2>&1; then
    echo -e "  Core Ports Status: ${GREEN}LISTEN (Ready)${NC}"
else
    echo -e "  Core Ports Status: ${RED}No active port listening${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "--- 9. Fail2ban SSHD Jail ---"
if fail2ban-client status sshd >/dev/null 2>&1; then
    echo -e "  Fail2ban SSHD Jail: ${GREEN}Active & Monitoring${NC}"
else
    echo -e "  Fail2ban SSHD Jail: ${RED}Inactive or Misconfigured${NC}"
    ((FAIL_COUNT++))
fi
echo ""

echo "======================================================"
if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "  ${GREEN}STATUS: ระบบจูนนิ่งสมบูรณ์แบบ 100% (SUCCESSFUL)${NC}"
else
    echo -e "  ${RED}STATUS: พบปัญหาทั้งหมด $FAIL_COUNT จุดที่ต้องตรวจสอบ${NC}"
fi
echo "======================================================"
EOF
chmod +x /usr/local/bin/syscheck.sh

echo "======================================================"
echo " การตั้งค่าเสร็จสมบูรณ์ เครดิต: FB:Shogun | IG:peepogrob555"
echo " เรียกใช้งานตัวเช็คระบบด้วยตัวเองได้ตลอดเวลาทางคำสั่ง: syscheck.sh"
echo " สั่ง 'reboot' 1 ครั้งเพื่อให้ค่าทั้งหมดเริ่มทำงานสมบูรณ์"
echo "======================================================"
sleep 2

# เรียกสคริปต์ขึ้นมาทำงานโชว์ผลลัพธ์ทันทีหลังติดตั้งเสร็จ
/usr/local/bin/syscheck.sh
