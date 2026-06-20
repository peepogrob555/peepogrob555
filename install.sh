#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "ผิดพลาด: สคริปต์นี้ต้องรันด้วยสิทธิ์ Root"
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "กำลังอัปเดตระบบ..."
apt-get update && apt-get upgrade -y
apt-get install -y ufw e2fsprogs sed iptables ethtool dnsutils curl

echo "กำลังตั้งค่า Swap..."
swapoff -a
rm -f /swapfile
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

echo "กำลังตั้งค่า Firewall..."
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

echo "กำลังปรับแต่ง Kernel..."
modprobe sch_cake
echo "sch_cake" > /etc/modules-load.d/cake.conf

cat <<EOF > /etc/sysctl.d/99-vless-pure-optimize.conf
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_base_mss = 1360
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
vm.swappiness = 10
EOF
sysctl --system > /dev/null

echo "กำลังตั้งค่า Network Optimization..."
cat <<'EOF' > /usr/local/bin/nic-optimize.sh
#!/bin/bash
IFACE=$(ip route show default | awk '/default/ {print $5}')
if [ -n "$IFACE" ]; then
    ethtool -K $IFACE gso off tso off gro off lro off 2>/dev/null
    ip link set dev $IFACE txqueuelen 10000 2>/dev/null
    tc qdisc replace dev $IFACE root cake bandwidth 1000mbit ethernet 2>/dev/null
fi
EOF
chmod +x /usr/local/bin/nic-optimize.sh

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

echo "กำลังติดตั้ง 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

systemctl stop rsyslog; systemctl disable rsyslog

echo "======================================================"
echo "การตั้งค่าเสร็จสมบูรณ์ เครดิต: FB:Shogun | IG:peepogrob555"
echo "รีบูตเครื่อง 1 ครั้งเพื่อให้การตั้งค่า Kernel มีผล"
echo "======================================================"
