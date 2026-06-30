#!/bin/bash
if [[ $EUID -ne 0 ]]; then
   echo "ผิดพลาด: สคริปต์นี้ต้องรันด้วยสิทธิ์ Root"
   exit 1
fi
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "===== [1/5] อัปเดตระบบ ====="
apt-get update && apt-get upgrade -y
apt-get install -y ufw e2fsprogs sed iptables ethtool dnsutils curl \
    linux-tools-common linux-tools-$(uname -r) cpufrequtils

echo "===== [2/5] ตั้งค่า Firewall ====="
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

echo "===== [3/5] ติดตั้ง 3X-UI ====="
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
systemctl stop rsyslog; systemctl disable rsyslog

echo "===== [4/5] ตั้งค่า Swap ====="
swapoff -a
rm -f /swapfile
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

echo "===== [5/5] ตั้งค่า Kernel และ Network ====="

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
sysctl --system > /dev/null

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
ExecStart=/bin/sh -c 'for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > $cpu 2>/dev/null; done'
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now disable-thp.service
systemctl enable --now cpu-performance.service
systemctl enable --now vless-nic-optimize.service

echo "======================================================"
echo "การตั้งค่าเสร็จสมบูรณ์ เครดิต: FB:Shogun | IG:peepogrob555"
echo "รีบูตเครื่อง 1 ครั้งเพื่อให้การตั้งค่ามีผลสมบูรณ์"
echo "======================================================"
