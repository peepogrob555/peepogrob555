#!/usr/bin/env bash
set -euo pipefail

NIC=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
NIC="${NIC:-eth0}"

echo ">>> [1/6] UPDATE & DEPS"
apt-get update -y
apt-get install -y curl ufw ethtool

echo ">>> [2/6] FIREWALL"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
for port in 80 443 2053 2083 2087 2096 8080 8443 54321; do
    ufw allow "$port"/tcp
done
ufw --force enable
ufw status verbose

echo ">>> [3/6] INSTALL 3X-UI"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

echo ">>> [4/6] CHANGE PANEL PORT TO 2053"
x-ui stop
x-ui setting -port 2053
x-ui start

echo ">>> [5/6] KERNEL + TCP TUNE"

cat > /etc/sysctl.d/99-tune.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_limit_output_bytes = 1572864

net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1440
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_tw_reuse = 1

net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 65536

net.core.optmem_max = 65536

kernel.sched_min_granularity_ns = 3000000
kernel.sched_wakeup_granularity_ns = 4000000
kernel.sched_autogroup_enabled = 0

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

vm.swappiness = 5
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

sysctl -p /etc/sysctl.d/99-tune.conf

echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

cat > /etc/systemd/system/thp-disable.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable thp-disable.service

echo ">>> [6/6] NIC + SYSTEM LIMITS + SERVICE TUNE"

ethtool -G "${NIC}" rx 4096 tx 4096 2>/dev/null || true
ethtool -K "${NIC}" gro off lro off tso on gso on 2>/dev/null || true
ethtool -C "${NIC}" rx-usecs 50 2>/dev/null || true

mkdir -p /etc/networkd-dispatcher/routable.d
cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << EOF
#!/usr/bin/env bash
ethtool -G ${NIC} rx 4096 tx 4096 2>/dev/null || true
ethtool -K ${NIC} gro off lro off tso on gso on 2>/dev/null || true
ethtool -C ${NIC} rx-usecs 50 2>/dev/null || true
EOF
chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

cat > /etc/security/limits.d/99-limits.conf << 'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

grep -qxF 'session required pam_limits.so' /etc/pam.d/common-session \
  || echo 'session required pam_limits.so' >> /etc/pam.d/common-session

mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65535
LimitNPROC=65535
Restart=always
RestartSec=3
Environment=GOMAXPROCS=1
EOF

cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $f 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cpu-performance.service
systemctl start cpu-performance.service
systemctl restart x-ui

echo ""
echo "============================================"
echo " DONE"
echo "============================================"
echo " Panel  : http://$(curl -s ifconfig.me):2053"
echo " BBR    : $(sysctl -n net.ipv4.tcp_congestion_control)"
echo " Qdisc  : $(sysctl -n net.core.default_qdisc)"
echo " THP    : $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo " x-ui   : $(systemctl is-active x-ui)"
echo "============================================"
