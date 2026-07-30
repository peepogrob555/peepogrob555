#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

TUNNEL_QOS_CONF="/etc/tunnel-qos.conf"
if [ -f "$TUNNEL_QOS_CONF" ]; then
  # shellcheck disable=SC1090
  source "$TUNNEL_QOS_CONF"
fi
[ -z "$IFACE" ] && IFACE=$(ip route show default | awk '/default/ {print $5; exit}')

echo -e "${GREEN}[1/6] ติดตั้งแพ็กเกจเสริม${NC}"
apt-get update -qq
apt-get install -y ethtool linux-tools-common linux-tools-$(uname -r) earlyoom > /dev/null 2>&1 || \
apt-get install -y ethtool earlyoom > /dev/null 2>&1

echo -e "${GREEN}[2/6] CPU: governor performance + priority scheduling${NC}"
cat > /usr/local/sbin/cpu-boost.sh << 'RUNTIME'
#!/bin/bash
for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo performance > "$g" 2>/dev/null || true
done
for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
  [ -w "$f" ] && echo never > "$f" 2>/dev/null || true
done
RUNTIME
chmod +x /usr/local/sbin/cpu-boost.sh
/usr/local/sbin/cpu-boost.sh

cat > /etc/systemd/system/cpu-boost.service << 'EOF'
[Unit]
Description=CPU governor performance + disable THP
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cpu-boost.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cpu-boost.service > /dev/null 2>&1

mkdir -p /etc/systemd/system/udp-custom.service.d /etc/systemd/system/udpgw.service.d
cat > /etc/systemd/system/udp-custom.service.d/99-boost.conf << 'EOF'
[Service]
Nice=-10
IOSchedulingClass=best-effort
IOSchedulingPriority=0
LimitNOFILE=51200
EOF
cat > /etc/systemd/system/udpgw.service.d/99-boost.conf << 'EOF'
[Service]
Nice=-10
IOSchedulingClass=best-effort
IOSchedulingPriority=0
EOF
systemctl daemon-reload

echo -e "${GREEN}[3/6] RAM: overcommit, vfs cache, earlyoom${NC}"

systemctl enable --now earlyoom > /dev/null 2>&1 || true

cat >> /etc/security/limits.conf << 'EOF'
root soft nofile 1048576
root hard nofile 1048576
* soft nofile 1048576
* hard nofile 1048576
EOF

echo -e "${GREEN}[4/6] Network: ring buffer, offload, busy-poll, keepalive${NC}"
cat > /usr/local/sbin/nic-boost.sh << RUNTIME
#!/bin/bash
IFACE="${IFACE}"
[ -z "\$IFACE" ] && IFACE=\$(ip route show default | awk '/default/ {print \$5; exit}')
RX_MAX=\$(ethtool -g "\$IFACE" 2>/dev/null | awk '/^RX:/{print \$2; exit}')
TX_MAX=\$(ethtool -g "\$IFACE" 2>/dev/null | awk '/^TX:/{print \$2; exit}')
[ -n "\$RX_MAX" ] && [ "\$RX_MAX" != "n/a" ] && ethtool -G "\$IFACE" rx "\$RX_MAX" 2>/dev/null || true
[ -n "\$TX_MAX" ] && [ "\$TX_MAX" != "n/a" ] && ethtool -G "\$IFACE" tx "\$TX_MAX" 2>/dev/null || true
ethtool -K "\$IFACE" gro on gso on tso on 2>/dev/null || true
RUNTIME
chmod +x /usr/local/sbin/nic-boost.sh
/usr/local/sbin/nic-boost.sh

cat > /etc/systemd/system/nic-boost.service << 'EOF'
[Unit]
Description=NIC ring buffer + offload tuning
After=network-online.target
Wants=network-online.target
Before=tunnel-shaper.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nic-boost.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now nic-boost.service > /dev/null 2>&1

echo -e "${GREEN}[5/6] Sysctl เพิ่มเติม (ไม่ทับค่าเดิมใน 99-tunnel-optimize.conf)${NC}"
cat > /etc/sysctl.d/98-system-boost.conf << 'EOF'
vm.overcommit_memory = 1
vm.overcommit_ratio = 80
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.optmem_max = 65536
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 2000000
kernel.sched_autogroup_enabled = 0
kernel.numa_balancing = 0
EOF
sysctl --system > /dev/null 2>&1 || true

echo -e "${GREEN}[6/6] รีสตาร์ทเซอร์วิสที่เกี่ยวข้อง${NC}"
systemctl restart udp-custom 2>/dev/null || true
systemctl restart udpgw 2>/dev/null || true

echo ""
echo "=================================================="
echo -e "${GREEN}ปรับจูน CPU/RAM/Network เสริมเสร็จสมบูรณ์${NC}"
echo -e "governor: performance (ถ้ารองรับ) | ring buffer: max (ถ้ารองรับ) | earlyoom: $(systemctl is-active earlyoom 2>/dev/null)"
echo "=================================================="
