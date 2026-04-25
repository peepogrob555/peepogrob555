#!/bin/bash
set -e

# Auto detect interface
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Interface: $IFACE"

echo "==== [1/5] Update System ===="
apt update && apt upgrade -y

echo "==== [2/5] Install 3x-ui ===="
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

echo "==== [3/5] Sysctl Optimize ===="
cat > /etc/sysctl.conf << 'EOF'
# ==== STABLE LOW LATENCY ====
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.core.netdev_max_backlog=3000
net.ipv4.tcp_fastopen=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 65536 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.ip_forward=1
net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_no_metrics_save=1
EOF
sysctl -p

echo "==== [4/5] TC fq_codel ===="
tc qdisc del dev $IFACE root 2>/dev/null || true
tc qdisc add dev $IFACE root fq_codel target 5ms interval 100ms
ethtool -K $IFACE tso off gso off gro off 2>/dev/null || true

echo "==== [5/5] Persist fq.service ===="
cat > /etc/systemd/system/fq.service << EOF
[Unit]
Description=FQ_CODEL Optimize
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'tc qdisc del dev $IFACE root 2>/dev/null; tc qdisc add dev $IFACE root fq_codel target 5ms interval 100ms; ethtool -K $IFACE tso off gso off gro off 2>/dev/null'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable fq.service
systemctl start fq.service

echo "==== Verify ===="
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
tc qdisc show dev $IFACE
systemctl is-enabled fq.service
lsmod | grep bbr

echo ""
echo "==============================="
echo "✅ Setup เสร็จแล้ว!"
echo "==============================="
