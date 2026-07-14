#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

SHAPE_MBIT="${SHAPE_MBIT:-345}"
RTT_MS="${RTT_MS:-80}"
TUNNEL_MTU="${TUNNEL_MTU:-1360}"
CAKE_OVERHEAD="${CAKE_OVERHEAD:-18}"
MAX_USERS="${MAX_USERS:-60}"
FLOWS_PER_USER="${FLOWS_PER_USER:-6}"
TCP_SAFE_BUDGET_MB="${TCP_SAFE_BUDGET_MB:-1536}"
SWAP_GB="${SWAP_GB:-2}"

UDP_CUSTOM_CONFIG="/root/udp/config.json"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

if [ ! -f "$UDP_CUSTOM_CONFIG" ]; then
  echo -e "${RED}ไม่พบ ${UDP_CUSTOM_CONFIG} — ต้องรัน install.sh ของ http-custom-udp-custom (ตัวติดตั้ง udp-custom เอง) ให้เสร็จก่อน แล้วค่อยรันสคริปต์นี้${NC}"
  exit 1
fi

OS_VER=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null || true)
if [ "$OS_VER" != "24.04" ]; then
  echo -e "${YELLOW}เตือน: สคริปต์นี้ทดสอบบน Ubuntu 24.04 แต่เครื่องนี้คือ ${OS_VER:-ไม่ทราบ} — จะรันต่อ${NC}"
fi

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
  echo -e "${RED}หา default interface ไม่เจอ ยกเลิก${NC}"
  exit 1
fi

DNS_LABEL="Cloudflare"
DNS_V4_A="1.1.1.1"; DNS_V4_B="1.0.0.1"
DNS_V6_A="2606:4700:4700::1111"; DNS_V6_B="2606:4700:4700::1001"

echo "IFACE=${IFACE} | DNS=${DNS_LABEL} (ล็อคตายตัว) | MTU=${TUNNEL_MTU} | เพดานรวม=${SHAPE_MBIT}mbit | RTT=${RTT_MS}ms | user โดยประมาณ=${MAX_USERS}"

UDP_CUSTOM_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CUSTOM_CONFIG" || true)
if [ -z "$UDP_CUSTOM_PORT" ]; then
  read -rp "ใส่พอร์ต UDP ที่ udp-custom ใช้จริง (ดูจาก 'listen' ใน ${UDP_CUSTOM_CONFIG}): " UDP_CUSTOM_PORT
fi
echo "  udp-custom listen port = ${UDP_CUSTOM_PORT}"

cat > /etc/tunnel-qos.conf << EOF
IFACE=${IFACE}
SHAPE_MBIT=${SHAPE_MBIT}
RTT_MS=${RTT_MS}
TUNNEL_MTU=${TUNNEL_MTU}
CAKE_OVERHEAD=${CAKE_OVERHEAD}
MAX_USERS=${MAX_USERS}
DNS_LABEL=${DNS_LABEL}
DNS_V4_A=${DNS_V4_A}
DNS_V4_B=${DNS_V4_B}
DNS_V6_A=${DNS_V6_A}
DNS_V6_B=${DNS_V6_B}
UDP_CUSTOM_PORT=${UDP_CUSTOM_PORT}
FAIRSHARE_MODE=1
EOF

echo "[1/10] ติดตั้ง dependencies..."
apt-get update -qq
apt-get install -y ufw iptables conntrack ethtool iproute2 jq > /dev/null 2>&1

modprobe sch_cake 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tunnel.conf

echo "[2/10] เพิ่ม swap (เครื่อง RAM 3GB เสี่ยง OOM เวลามีโหลดพร้อมกันหลาย user)..."
if ! swapon --show | grep -q .; then
  AVAIL_KB=$(df --output=avail -k / | tail -1)
  NEED_KB=$(( SWAP_GB * 1024 * 1024 ))
  if [ "$AVAIL_KB" -gt "$((NEED_KB + 2097152))" ]; then
    fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "  สร้าง swapfile ${SWAP_GB}G แล้ว"
  else
    echo -e "${YELLOW}  พื้นที่ดิสก์ไม่พอสำหรับ swap ${SWAP_GB}G ข้ามขั้นตอนนี้${NC}"
  fi
else
  echo "  มี swap อยู่แล้ว ข้ามขั้นตอนนี้"
fi

echo "[3/10] ตั้งค่า Firewall (คืนค่า ufw ที่ installer ของ udp-custom ลบทิ้งไปแล้ว)..."
ufw --force reset > /dev/null
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw default deny routed > /dev/null
for p in 21 23 25 111 135 137 138 139 445 512 513 514 1433 2049 3306 3389 5432 5900 6379 11211 27017; do
  ufw deny "${p}/tcp" > /dev/null
done
for p in 19 69 111 123 137 138 161 162 1900 3389 5353 11211; do
  ufw deny "${p}/udp" > /dev/null
done
ufw allow 1:65535/tcp > /dev/null
ufw allow 1:65535/udp > /dev/null
ufw allow out to "$DNS_V4_A" port 53 > /dev/null
ufw allow out to "$DNS_V4_B" port 53 > /dev/null
ufw allow out to "$DNS_V6_A" port 53 > /dev/null
ufw allow out to "$DNS_V6_B" port 53 > /dev/null
ufw deny out to any port 53 > /dev/null
ufw deny out to any port 853 > /dev/null
ufw --force enable > /dev/null
echo "  firewall กลับมาแล้ว — DNS ออกได้เฉพาะ ${DNS_LABEL} (${DNS_V4_A}, ${DNS_V4_B}) เท่านั้น กัน DNS/IP leak ไปที่อื่น"

echo "[4/10] ล็อค DNS resolver ของระบบเป็น ${DNS_LABEL} เท่านั้น..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/tunnel-dns.conf << EOF
[Resolve]
DNS=${DNS_V4_A} ${DNS_V4_B}
FallbackDNS=
Domains=~.
DNSStubListener=yes
EOF
systemctl restart systemd-resolved 2>/dev/null || true

echo "[5/10] ตั้งค่า MTU + MSS clamp..."
ip link set dev "$IFACE" mtu "$TUNNEL_MTU" 2>/dev/null || true
cat > /etc/systemd/system/set-mtu.service << EOF
[Unit]
Description=Set tunnel MTU
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${IFACE} mtu ${TUNNEL_MTU}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

NCPU=$(nproc)
QUEUES=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/ {print $2; exit}')
if [ -n "$QUEUES" ] && [ "$QUEUES" -gt 1 ] 2>/dev/null; then
  ethtool -L "$IFACE" combined "$NCPU" 2>/dev/null || true
fi

MSS_V4=$((TUNNEL_MTU - 40))
cat > /usr/local/sbin/mss-clamp.sh << EOF
#!/bin/bash
MSS_V4=${MSS_V4}
EOF
cat >> /usr/local/sbin/mss-clamp.sh << 'RUNTIME'
apply() {
  local table="$1" chain="$2"; shift 2
  iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
}
apply mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_V4"
apply mangle OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_V4"
if command -v ip6tables >/dev/null 2>&1; then
  MSS_V6=$((MSS_V4 - 20))
  apply6() {
    local chain="$1"; shift
    ip6tables -t mangle -C "$chain" "$@" 2>/dev/null || ip6tables -t mangle -A "$chain" "$@"
  }
  apply6 FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_V6" 2>/dev/null || true
  apply6 OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_V6" 2>/dev/null || true
fi
RUNTIME
chmod +x /usr/local/sbin/mss-clamp.sh
/usr/local/sbin/mss-clamp.sh

cat > /etc/systemd/system/mss-clamp.service << 'EOF'
[Unit]
Description=Clamp TCP MSS to match tunnel MTU
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mss-clamp.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now set-mtu.service mss-clamp.service > /dev/null 2>&1
echo "  MTU=${TUNNEL_MTU}, MSS(v4)=${MSS_V4} clamp ติดตั้งแล้ว"

echo "[6/10] ตั้งค่า sysctl (BBR + buffer + conntrack ให้พอดีกับ 2vCPU/3GB RAM/~${MAX_USERS} user)..."
RMEM_MIN=2097152
RMEM_CEILING=12582912
BDP_BYTES=$(( SHAPE_MBIT * 1000000 / 8 * RTT_MS / 1000 ))
RMEM_MAX=$(( BDP_BYTES * 4 ))
[ "$RMEM_MAX" -lt "$RMEM_MIN" ]     && RMEM_MAX=$RMEM_MIN
[ "$RMEM_MAX" -gt "$RMEM_CEILING" ] && RMEM_MAX=$RMEM_CEILING

NF_CONNTRACK_MAX=$(( MAX_USERS * 2000 ))
[ "$NF_CONNTRACK_MAX" -lt 32768 ] && NF_CONNTRACK_MAX=32768
NF_CONNTRACK_HASHSIZE=$(( NF_CONNTRACK_MAX / 4 ))

TOTAL_FLOWS=$(( MAX_USERS * FLOWS_PER_USER ))
TCP_FLOW_RMEM_MAX=$(( TCP_SAFE_BUDGET_MB * 1024 * 1024 / TOTAL_FLOWS / 2 ))
[ "$TCP_FLOW_RMEM_MAX" -gt "$RMEM_MAX" ] && TCP_FLOW_RMEM_MAX=$RMEM_MAX
[ "$TCP_FLOW_RMEM_MAX" -lt 1048576 ] && TCP_FLOW_RMEM_MAX=1048576

cat > /etc/sysctl.d/99-tunnel-optimize.conf << EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake
net.ipv4.ip_forward = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${RMEM_MAX}
net.ipv4.tcp_rmem = 4096 87380 ${TCP_FLOW_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_FLOW_RMEM_MAX}
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
fs.file-max = 524288
vm.swappiness = 10
EOF
echo "options nf_conntrack hashsize=${NF_CONNTRACK_HASHSIZE}" > /etc/modprobe.d/nf_conntrack.conf
echo "$NF_CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
sysctl --system > /dev/null 2>&1 || true
echo "  rmem/wmem max = ${RMEM_MAX} bytes | tcp per-flow ceiling = ${TCP_FLOW_RMEM_MAX} bytes | nf_conntrack_max = ${NF_CONNTRACK_MAX}"

echo "[7/10] ตั้งค่า cake fair-share QoS (triple-isolate, RTT ${RTT_MS}ms)..."
cat > /usr/local/sbin/qos-root-init.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf

modprobe sch_cake 2>/dev/null || true
modprobe ifb numifbs=1 2>/dev/null || true
ip link set dev ifb0 up 2>/dev/null || true

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

tc qdisc add dev "$IFACE" root cake \
  bandwidth "${SHAPE_MBIT}"mbit rtt "${RTT_MS}"ms overhead "${CAKE_OVERHEAD}" \
  besteffort triple-isolate ack-filter

tc qdisc add dev "$IFACE" handle ffff: ingress
tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

tc qdisc add dev ifb0 root cake \
  bandwidth "${SHAPE_MBIT}"mbit rtt "${RTT_MS}"ms overhead "${CAKE_OVERHEAD}" \
  besteffort triple-isolate ack-filter
RUNTIME
chmod +x /usr/local/sbin/qos-root-init.sh

cat > /etc/systemd/system/tunnel-shaper.service << 'EOF'
[Unit]
Description=CAKE fair-share QoS (native per-host isolation, no per-IP polling)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qos-root-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tunnel-shaper.service > /dev/null 2>&1
systemctl restart tunnel-shaper.service

echo "[8/10] ตั้งค่า RPS+XPS (กระจาย packet processing ทั้ง ${NCPU} core)..."
cat > /usr/local/sbin/set-rps.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true
NCPU=$(nproc)
MASK=$(printf '%x' $(( (1 << NCPU) - 1 )))
for rx in /sys/class/net/"${IFACE}"/queues/rx-*/rps_cpus; do
  [ -e "$rx" ] && echo "$MASK" > "$rx" 2>/dev/null || true
done
for rx in /sys/class/net/ifb0/queues/rx-*/rps_cpus; do
  [ -e "$rx" ] && echo "$MASK" > "$rx" 2>/dev/null || true
done
for tx in /sys/class/net/"${IFACE}"/queues/tx-*/xps_cpus; do
  [ -e "$tx" ] && echo "$MASK" > "$tx" 2>/dev/null || true
done
for tx in /sys/class/net/ifb0/queues/tx-*/xps_cpus; do
  [ -e "$tx" ] && echo "$MASK" > "$tx" 2>/dev/null || true
done
RUNTIME
chmod +x /usr/local/sbin/set-rps.sh

cat > /etc/systemd/system/set-rps.service << 'EOF'
[Unit]
Description=Spread RX+TX packet steering across all CPU cores
After=network-online.target tunnel-shaper.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set-rps.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now set-rps.service > /dev/null 2>&1

echo "[9/10] แก้ค่าที่ udp-custom บังคับมาให้เหมาะกับ ~${MAX_USERS} user บน 3GB RAM..."
cp "$UDP_CUSTOM_CONFIG" "${UDP_CUSTOM_CONFIG}.bak.$(date +%s)"
jq --argjson rb "$RMEM_MAX" --argjson sb "$RMEM_MAX" \
  '.receive_buffer=$rb | .stream_buffer=$sb' \
  "$UDP_CUSTOM_CONFIG" > "${UDP_CUSTOM_CONFIG}.tmp" && mv "${UDP_CUSTOM_CONFIG}.tmp" "$UDP_CUSTOM_CONFIG"
echo "  receive_buffer/stream_buffer ของ config.json ลดจาก 80MB/32MB (ค่า default เกินจริง) เหลือ ${RMEM_MAX} bytes ให้ตรงกับ kernel clamp จริง"

UDPGW_MAX_CLIENTS=$(( MAX_USERS + 20 ))
UDPGW_MAX_CONN_PER_CLIENT=20
if [ -f /etc/systemd/system/udpgw.service ]; then
  sed -i -E "s/--max-clients [0-9]+/--max-clients ${UDPGW_MAX_CLIENTS}/; s/--max-connections-for-client [0-9]+/--max-connections-for-client ${UDPGW_MAX_CONN_PER_CLIENT}/" /etc/systemd/system/udpgw.service
  echo "  udpgw.service: max-clients=${UDPGW_MAX_CLIENTS}, max-connections-for-client=${UDPGW_MAX_CONN_PER_CLIENT} (เดิม 1000/100 ใหญ่เกินไปสำหรับเครื่องนี้)"
fi

systemctl daemon-reload
systemctl restart udp-custom 2>/dev/null || true
systemctl restart udpgw 2>/dev/null || true
systemctl restart tunnel-shaper.service

echo "[10/10] ตั้งค่า auto-reboot ปลอดภัย (เช็ค session udp-custom จริงผ่าน conntrack)..."
cat > /usr/local/sbin/safe-reboot.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf

ACTIVE=0
if [ -n "${UDP_CUSTOM_PORT:-}" ] && command -v conntrack >/dev/null 2>&1; then
  ACTIVE=$(conntrack -L -p udp --dport "$UDP_CUSTOM_PORT" 2>/dev/null | wc -l)
fi

if [ "$ACTIVE" -eq 0 ]; then
  logger -t safe-reboot "no active udp-custom users - rebooting to clear RAM"
  /sbin/reboot
else
  logger -t safe-reboot "skip reboot - ${ACTIVE} udp-custom connection(s)"
fi
RUNTIME
chmod +x /usr/local/sbin/safe-reboot.sh

cat > /etc/systemd/system/safe-reboot.service << 'EOF'
[Unit]
Description=Safe reboot (only if no active udp-custom users)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/safe-reboot.sh
EOF

cat > /etc/systemd/system/safe-reboot.timer << 'EOF'
[Unit]
Description=Try safe-reboot hourly during low-traffic window

[Timer]
OnCalendar=*-*-* 03,04,05,06:00:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now safe-reboot.timer > /dev/null 2>&1

echo ""
echo "=================================================="
echo -e "${GREEN}ติดตั้ง/ปรับจูนเสร็จสมบูรณ์${NC}"
echo "=================================================="
echo "  Host              : $(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo "  MTU (client ต้องตั้งตรงกัน) : ${TUNNEL_MTU}"
echo "  DNS               : ${DNS_LABEL} เท่านั้น (${DNS_V4_A}, ${DNS_V4_B}) — กัน DNS/IP leak"
echo "  udp-custom port   : ${UDP_CUSTOM_PORT}"
echo "  เพดานรวม          : ${SHAPE_MBIT}mbit ต่อทิศทาง (fair-share ผ่าน cake triple-isolate)"
echo "  RTT ที่ใช้คำนวณ    : ${RTT_MS}ms"
echo "  rmem/wmem max     : ${RMEM_MAX} bytes"
echo "  nf_conntrack_max  : ${NF_CONNTRACK_MAX} (คิดจาก ~${MAX_USERS} user)"
echo "  swap              : $(swapon --show --noheadings 2>/dev/null | wc -l) รายการ"
echo ""
echo "--- สถานะ service ---"
for s in ufw udp-custom udpgw tunnel-shaper set-rps mss-clamp safe-reboot.timer; do
  systemctl is-active "$s" > /dev/null 2>&1 && echo "$s: OK" || echo -e "${YELLOW}$s: ไม่ active${NC}"
done
echo ""
echo "--- เช็คว่า cake ทำงานจริง ---"
echo "  tc -s qdisc show dev ${IFACE}"
echo "  tc -s qdisc show dev ifb0"
echo ""
echo "--- เช็ค RTT จริงจากมือถือไปหา VPS ---"
echo "  ping <IP VPS นี้> จากมือถือ ~20-30 ครั้งดู average แล้วเทียบกับ ${RTT_MS}ms"
echo "  ถ้าต่างมาก ให้รันใหม่ เช่น: RTT_MS=<ค่าจริง> bash $0"
echo ""
echo "--- เช็คว่า DNS ไม่หลุด ---"
echo "  resolvectl status | grep -A2 'DNS Servers'   # ต้องเห็นแค่ ${DNS_V4_A}/${DNS_V4_B}"
