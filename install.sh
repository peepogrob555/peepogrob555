#!/bin/bash

echo "======================================================"
echo "    3X-UI ULTIMATE : KERNEL-LEVEL GAMING TUNING       "
echo "======================================================"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update && apt-get upgrade -y

apt-get install ufw e2fsprogs sed iptables ethtool dnsutils -y

# 1. Swap Optimization
swapoff -a 2>/dev/null
rm -f /swapfile
fallocate -l 8192M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

# 2. Firewall with MSS Clamping (ระดับ Kernel จะ Clamp แพ็กเก็ตให้ 1360 ทั้งหมด)
cat <<EOF > /etc/ufw/before.rules
*mangle
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
COMMIT
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-output -o lo -j ACCEPT
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
COMMIT
EOF

ufw --force reset
ufw default allow incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2053/tcp
ufw --force enable

# 3. Install 3X-UI
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# 4. Kernel Tuning (Force OS-Level for 3X-UI to inherit)
apt-get install -y linux-modules-extra-$(uname -r)
modprobe sch_cake
if ! grep -q "sch_cake" /etc/modules; then
    echo "sch_cake" | tee -a /etc/modules
fi

cat <<EOF > /etc/sysctl.d/99-vless-pure-optimize.conf
# Queue Discipline & Congestion
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

# MSS & Window Scaling (OS-Level Force)
net.ipv4.tcp_base_mss = 1360
net.ipv4.tcp_window_scaling = 1

# Buffer (16MB)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Keepalive (OS-Level for 3X-UI)
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# TCP Fast Open (Level 3 = Both)
net.ipv4.tcp_fastopen = 3

# Latency & Throughput
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_ecn = 1
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
vm.swappiness = 10
EOF

sysctl --system

# 5. NIC Hardware Optimization
cat <<EOF > /usr/local/bin/nic-optimize.sh
#!/bin/bash
IFACE=\$(ip route show default | awk '/default/ {print \$5}')
if [ -n "\$IFACE" ]; then
    ethtool -K \$IFACE gso on tso on gro on lro on tx on rx on 2>/dev/null
    ip link set dev \$IFACE txqueuelen 10000
    tc qdisc replace dev \$IFACE root cake ptt mpu 64 ack-filter besteffort
fi
EOF
chmod +x /usr/local/bin/nic-optimize.sh

systemctl enable vless-nic-optimize.service
systemctl restart vless-nic-optimize.service
systemctl stop rsyslog
systemctl disable rsyslog

echo "======================================================"
echo "    TUNING COMPLETE (ALL VALUES FORCE-LOADED)         "
echo "======================================================"
