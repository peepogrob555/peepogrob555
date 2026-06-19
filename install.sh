#!/bin/bash

# =================================================================
#    3X-UI ULTIMATE : KERNEL-LEVEL GAMING TUNING
#    Repository: https://github.com/peepogrob555/peepogrob555
# =================================================================

# 1. เช็คสิทธิ์ Root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root."
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "[*] Initializing System Update..."
apt-get update && apt-get upgrade -y
apt-get install -y ufw e2fsprogs sed iptables ethtool dnsutils curl

# 2. Swap Optimization
echo "[*] Configuring Swap..."
swapoff -a 2>/dev/null
rm -f /swapfile
fallocate -l 8G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

# 3. Firewall & MSS Clamping
echo "[*] Configuring Firewall..."
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
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 2053/tcp
ufw --force enable

# 4. Kernel Tuning (BBR + Cake)
echo "[*] Applying Kernel Tuning..."
modprobe sch_cake
echo "sch_cake" > /etc/modules-load.d/cake.conf

cat <<EOF > /etc/sysctl.d/99-vless-pure-optimize.conf
# Congestion Control
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

# TCP Window & Buffer
net.ipv4.tcp_base_mss = 1360
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Performance Tuning
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
vm.swappiness = 10
EOF
sysctl --system > /dev/null

# 5. NIC Hardware Optimization Script
cat <<'EOF' > /usr/local/bin/nic-optimize.sh
#!/bin/bash
IFACE=$(ip route show default | awk '/default/ {print $5}')
if [ -n "$IFACE" ]; then
    # ปิด Offload เพื่อลด Jitter (Gaming Friendly)
    ethtool -K $IFACE gso off tso off gro off lro off 2>/dev/null || true
    ip link set dev $IFACE txqueuelen 10000 2>/dev/null || true
    tc qdisc replace dev $IFACE root cake bandwidth 1000mbit ethernet 2>/dev/null || true
fi
EOF
chmod +x /usr/local/bin/nic-optimize.sh

# 6. Setup Systemd Service
cat <<EOF > /etc/systemd/system/vless-nic-optimize.service
[Unit]
Description=Network Optimization Service
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/nic-optimize.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now vless-nic-optimize.service

# 7. Install 3X-UI
echo "[*] Installing 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# Final Cleanup
systemctl stop rsyslog; systemctl disable rsyslog

echo "======================================================"
echo "    TUNING COMPLETE (ALL VALUES FORCE-LOADED)"
echo "    PLEASE REBOOT TO APPLY KERNEL CHANGES"
echo "======================================================"
