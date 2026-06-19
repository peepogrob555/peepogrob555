#!/bin/bash

echo "======================================================"
echo "    3X-UI SETUP : G-ENGINE 16MB + PERMANENT PERSIST   "
echo "======================================================"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update && apt-get upgrade -y

apt-get install ufw e2fsprogs sed iptables ethtool -y

swapoff -a 2>/dev/null
rm -f /swapfile
fallocate -l 8192M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=8192
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

ip6tables -P INPUT DROP 2>/dev/null
ip6tables -P FORWARD DROP 2>/dev/null
ip6tables -P OUTPUT DROP 2>/dev/null

sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw

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

ufw default deny incoming
ufw default deny outgoing
ufw default deny routed

ufw deny in 21/tcp
ufw deny in 23/tcp
ufw deny in 135/tcp
ufw deny in 137:139/udp
ufw deny in 445/tcp
ufw deny in 1900/udp
ufw deny in 3389/tcp

ufw deny out 21/tcp
ufw deny out 23/tcp
ufw deny out 135/tcp
ufw deny out 137:139/udp
ufw deny out 445/tcp
ufw deny out 1900/udp
ufw deny out 3389/tcp

ufw allow out on lo
ufw allow in on lo

ufw allow out to 1.1.1.1 port 53 proto udp
ufw allow out to 1.0.0.1 port 53 proto udp
ufw allow out to 8.8.8.8 port 53 proto udp
ufw allow out to 8.8.4.4 port 53 proto udp
ufw allow out to 1.1.1.1 port 53 proto tcp
ufw allow out to 1.0.0.1 port 53 proto tcp
ufw allow out to 8.8.8.8 port 53 proto tcp
ufw allow out to 8.8.4.4 port 53 proto tcp

ufw allow out 123/udp

ufw allow out 80/tcp
ufw allow out 443/tcp
ufw allow out 443/udp

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 2053/tcp
ufw allow 2053/udp

ufw --force enable

bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

apt-get install -y linux-modules-extra-$(uname -r)

modprobe sch_cake

if ! grep -q "sch_cake" /etc/modules; then
    echo "sch_cake" | tee -a /etc/modules
fi

cat <<EOF > /etc/sysctl.d/99-vless-pure-optimize.conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

net.ipv4.tcp_base_mss = 1360

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 262144 524288 1048576

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_reordering = 8
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
net.ipv4.tcp_autotransmit_threshold = 1
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_no_metrics_save = 1

net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_max_orphans = 262144

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
net.core.netdev_budget = 1000
net.core.netdev_budget_usecs = 2000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1

net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_low_latency = 1

vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
fs.file-max = 2097152
fs.nr_open = 2097152
EOF

sysctl --system

cat <<EOF > /usr/local/bin/nic-optimize.sh
#!/bin/bash
IFACE=\$(ip route show default | awk '/default/ {print \$5}')
if [ -n "\$IFACE" ]; then
    ip link set dev \$IFACE txqueuelen 10000
    tc qdisc replace dev \$IFACE root cake ptt mpu 64 ack-filter besteffort
    ethtool -K \$IFACE gso on tso on gro on 2>/dev/null
fi
EOF
chmod +x /usr/local/bin/nic-optimize.sh

cat <<EOF > /etc/systemd/system/vless-nic-optimize.service
[Unit]
Description=Network Interface Optimization for VLESS Gaming
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/nic-optimize.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vless-nic-optimize.service
systemctl start vless-nic-optimize.service

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

systemctl stop systemd-resolved
systemctl disable systemd-resolved
chattr -i /etc/resolv.conf 2>/dev/null
rm -f /etc/resolv.conf
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 1.0.0.1\nnameserver 8.8.4.4" > /etc/resolv.conf
chattr +i /etc/resolv.conf

echo "======================================================"
echo "    VERIFYING OPTIMIZATION STATUS                     "
echo "======================================================"

echo -n "3X-UI Service Status: "
systemctl is-active x-ui

echo -n "TCP Congestion Control Engine: "
sysctl net.ipv4.tcp_congestion_control | awk '{print $3}'

echo -n "Default Queue Discipline: "
sysctl net.core.default_qdisc | awk '{print $3}'

IFACE=$(ip route show default | awk '/default/ {print $5}')
echo -n "Network Card Queue Length: "
cat /sys/class/net/$IFACE/tx_queue_len

echo -n "TCP Base MSS Size: "
sysctl net.ipv4.tcp_base_mss | awk '{print $3}'

echo -n "TCP Max Buffer Capacity: "
sysctl net.core.rmem_max | awk '{print $3}'

echo -n "UDP Minimum Read Buffer: "
sysctl net.ipv4.udp_rmem_min | awk '{print $3}'

echo -n "IPv6 Disabled State (1=True): "
sysctl net.ipv6.conf.all.disable_ipv6 | awk '{print $3}'

echo -n "Active Qdisc Algorithm: "
tc qdisc show dev $IFACE | head -n 1 | awk '{print $3}'

echo -n "Firewall Security Status: "
ufw status | head -n 1 | awk '{print $2}'

echo "Active Swap Space Allocation:"
free -h | grep -i swap

echo "======================================================"
echo "    ALL PROCESSES AND VERIFICATIONS COMPLETE          "
echo "======================================================"
