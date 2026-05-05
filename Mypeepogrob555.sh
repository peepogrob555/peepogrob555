#!/bin/bash
set -e

IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Interface: $IFACE"

echo "==== [1/5] Update System ===="
apt update && apt upgrade -y

echo "==== [2/5] Install 3x-ui ===="
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

echo "==== [3/5] Sysctl Optimize ===="
cat > /etc/sysctl.conf << 'EOF'
# TCP Congestion
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# Buffer (เหมาะ 2 คน)
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.tcp_rmem=4096 131072 67108864
net.ipv4.tcp_wmem=4096 131072 67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192

# Latency (จูนสำหรับ ping ต่ำสุด)
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_notsent_lowat=8192
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1

# Connection
net.core.somaxconn=4096
net.core.netdev_max_backlog=3000
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_max_tw_buckets=500000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=5
net.ipv4.tcp_keepalive_time=30
net.ipv4.tcp_keepalive_intvl=5
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_syn_retries=2

# Forward
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Security
net.ipv4.conf.all.rp_filter=1
net.ipv4.tcp_syncookies=1
EOF
sysctl -p

echo "==== [4/5] TC Priority ===="
tc qdisc del dev $IFACE root 2>/dev/null || true
tc qdisc add dev $IFACE root handle 1: prio bands 3 priomap 0 0 0 0 1 1 1 1 2 2 2 2 2 2 2 2
tc qdisc add dev $IFACE parent 1:1 handle 10: fq maxrate 1gbit
tc qdisc add dev $IFACE parent 1:2 handle 20: fq maxrate 1gbit
tc qdisc add dev $IFACE parent 1:3 handle 30: fq maxrate 1gbit
tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip dport 443 0xffff flowid 1:1
tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip sport 443 0xffff flowid 1:1
ip link set $IFACE txqueuelen 1000
ethtool -K $IFACE tso off gso off gro off 2>/dev/null || true

echo "==== [5/5] Persist fq.service ===="
cat > /etc/systemd/system/fq.service << EOF
[Unit]
Description=FQ Optimize
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  tc qdisc del dev $IFACE root 2>/dev/null; \
  tc qdisc add dev $IFACE root handle 1: prio bands 3 priomap 0 0 0 0 1 1 1 1 2 2 2 2 2 2 2 2; \
  tc qdisc add dev $IFACE parent 1:1 handle 10: fq maxrate 1gbit; \
  tc qdisc add dev $IFACE parent 1:2 handle 20: fq maxrate 1gbit; \
  tc qdisc add dev $IFACE parent 1:3 handle 30: fq maxrate 1gbit; \
  tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip dport 443 0xffff flowid 1:1; \
  tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip sport 443 0xffff flowid 1:1; \
  ip link set $IFACE txqueuelen 1000; \
  ethtool -K $IFACE tso off gso off gro off 2>/dev/null'
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
