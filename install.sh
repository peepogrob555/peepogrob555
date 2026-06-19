#!/bin/bash

echo "======================================================"
echo "    3X-UI PURE SETUP (MSS 1440 + RAM LOG + PERSIST)   "
echo "======================================================"

echo "▶ STEP 1 — Updating System..."
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y

echo "▶ STEP 2 — Configuring Firewall & Clamping TCP MSS to 1440..."
apt-get install ufw -y

cat <<EOF > /etc/ufw/before.rules
*mangle
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440
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

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2053/tcp
ufw --force enable

echo "▶ STEP 3 — Installing Official 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

echo "▶ STEP 4 — Loading CAKE Module & Applying Kernel Tune..."

apt-get install -y linux-modules-extra-$(uname -r)

modprobe sch_cake

if ! grep -q "sch_cake" /etc/modules; then
    echo "sch_cake" | tee -a /etc/modules
fi

cat <<EOF > /etc/sysctl.d/99-vless-pure-optimize.conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

net.ipv4.tcp_base_mss = 1440

net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.tcp_rmem = 2097152 4194304 8388608
net.ipv4.tcp_wmem = 2097152 4194304 8388608
net.ipv4.tcp_mem = 98304 131072 196608

net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_reordering = 6
net.ipv4.tcp_frto = 2
net.ipv4.tcp_recovery = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_no_metrics_save = 1

net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
fs.file-max = 1048576
fs.nr_open = 1048576
EOF

sysctl --system

echo "▶ STEP 5 — Moving All Logs to RAM (Volatile Mode)..."

systemctl stop rsyslog
systemctl disable rsyslog

mkdir -p /etc/systemd/journald.conf.d
cat <<EOF > /etc/systemd/journald.conf.d/ram-log.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
ForwardToSyslog=no
EOF

systemctl restart systemd-journald

echo "======================================================"
echo "   เสร็จสมบูรณ์! ทุกอย่างล็อกถาวร / MSS 1440 / Log อยู่บน RAM  "
echo "======================================================"
