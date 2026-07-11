#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

DROPBEAR_MAIN_PORT=80
DROPBEAR_EXTRA_PORTS="143 442"
BADVPN_PORT1=7300
BADVPN_PORT2=7301

SHAPE_MBIT=350
DOWN_MBIT_PER_USER=15
UP_MBIT_PER_USER=4
TUNNEL_MTU=1420

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
  echo -e "${RED}หา default interface ไม่เจอ ยกเลิก${NC}"
  exit 1
fi
echo "ตรวจพบ interface: $IFACE"

echo "[1/8] ติดตั้ง dependencies..."
apt-get update -qq
apt-get install -y dropbear ufw \
  build-essential cmake git ethtool iproute2 > /dev/null 2>&1

echo "[2/8] ตั้งค่า dropbear..."
EXTRA_ARGS=""
for p in $DROPBEAR_EXTRA_PORTS; do
  EXTRA_ARGS="${EXTRA_ARGS} -p ${p}"
done

cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=${DROPBEAR_MAIN_PORT}
DROPBEAR_EXTRA_ARGS="${EXTRA_ARGS} -c /bin/true -K 60 -I 300"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=1048576
EOF
systemctl restart dropbear
systemctl enable dropbear > /dev/null 2>&1

echo "[3/8] คอมไพล์ badvpn-udpgw..."
if ! command -v badvpn-udpgw >/dev/null 2>&1; then
  rm -rf /usr/local/src/badvpn
  git clone --depth 1 https://github.com/ambrop72/badvpn /usr/local/src/badvpn > /dev/null 2>&1
  mkdir -p /usr/local/src/badvpn/build
  cd /usr/local/src/badvpn/build
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
  make -j"$(nproc)" > /dev/null 2>&1
  cp udpgw/badvpn-udpgw /usr/local/bin/
  cd - > /dev/null
fi

NCPU=$(nproc)
CPU0=0
CPU1=$(( NCPU > 1 ? 1 : 0 ))

cat > /etc/systemd/system/badvpn-udpgw1.service << EOF
[Unit]
Description=BadVPN UDP Gateway (instance 1)
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${BADVPN_PORT1} \
  --max-clients 200 --max-connections-for-client 20 --udp-mtu $((TUNNEL_MTU - 28))
Restart=always
RestartSec=3
LimitNOFILE=1048576
Nice=-5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=20
CPUAffinity=${CPU0}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/badvpn-udpgw2.service << EOF
[Unit]
Description=BadVPN UDP Gateway (instance 2)
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${BADVPN_PORT2} \
  --max-clients 200 --max-connections-for-client 20 --udp-mtu $((TUNNEL_MTU - 28))
Restart=always
RestartSec=3
LimitNOFILE=1048576
Nice=-5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=20
CPUAffinity=${CPU1}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now badvpn-udpgw1 badvpn-udpgw2 > /dev/null 2>&1

echo "[4/8] ตั้งค่า Firewall..."
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
ufw allow out to 1.1.1.1 port 53 > /dev/null
ufw allow out to 1.0.0.1 port 53 > /dev/null
ufw allow out to 2606:4700:4700::1111 port 53 > /dev/null
ufw allow out to 2606:4700:4700::1001 port 53 > /dev/null
ufw deny out to any port 53 > /dev/null
ufw deny out to any port 853 > /dev/null
ufw --force enable > /dev/null

echo "[5/8] ตั้งค่า MTU..."
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
systemctl daemon-reload
systemctl enable set-mtu.service > /dev/null 2>&1

QUEUES=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/ {print $2; exit}')
if [ -n "$QUEUES" ] && [ "$QUEUES" -gt 1 ] 2>/dev/null; then
  ethtool -L "$IFACE" combined "$NCPU" 2>/dev/null || true
fi

echo "[6/8] ตั้งค่า sysctl (BBR + buffer sizing ตาม per-user cap)..."
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tunnel.conf

BDP_BYTES=$(( DOWN_MBIT_PER_USER * 1000000 / 8 * 60 / 1000 ))
RMEM_MAX=$(( BDP_BYTES * 4 ))
[ "$RMEM_MAX" -lt 1048576 ] && RMEM_MAX=1048576
[ "$RMEM_MAX" -gt 4194304 ] && RMEM_MAX=4194304

cat > /etc/sysctl.d/99-tunnel-optimize.conf << EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_codel
net.ipv4.ip_forward = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${RMEM_MAX}
net.ipv4.tcp_rmem = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${RMEM_MAX}
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1 || true

echo "[7/8] ติดตั้งระบบ per-user hard-cap shaping (HTB + fq_codel)..."

cat > /usr/local/sbin/qos-root-init.sh << EOF
#!/bin/bash
IFACE="${IFACE}"
SHAPE_MBIT=${SHAPE_MBIT}
EOF
cat >> /usr/local/sbin/qos-root-init.sh << 'RUNTIME'
modprobe ifb numifbs=1 2>/dev/null || true
ip link set dev ifb0 up 2>/dev/null || true

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

tc qdisc add dev "$IFACE" root handle 1: htb default 999 r2q 10
tc class add dev "$IFACE" parent 1: classid 1:1 htb rate ${SHAPE_MBIT}mbit ceil ${SHAPE_MBIT}mbit
tc class add dev "$IFACE" parent 1:1 classid 1:999 htb rate 2mbit ceil ${SHAPE_MBIT}mbit quantum 1514
tc qdisc add dev "$IFACE" parent 1:999 handle 999: fq_codel limit 1024 target 5ms interval 100ms

tc qdisc add dev "$IFACE" handle ffff: ingress
tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

tc qdisc add dev ifb0 root handle 1: htb default 999 r2q 10
tc class add dev ifb0 parent 1: classid 1:1 htb rate ${SHAPE_MBIT}mbit ceil ${SHAPE_MBIT}mbit
tc class add dev ifb0 parent 1:1 classid 1:999 htb rate 2mbit ceil ${SHAPE_MBIT}mbit quantum 1514
tc qdisc add dev ifb0 parent 1:999 handle 999: fq_codel limit 1024 target 5ms interval 100ms
RUNTIME
chmod +x /usr/local/sbin/qos-root-init.sh

cat > /usr/local/sbin/user-shaper.sh << EOF
#!/bin/bash
IFACE="${IFACE}"
DOWN_MBIT=${DOWN_MBIT_PER_USER}
UP_MBIT=${UP_MBIT_PER_USER}
DROPBEAR_PORTS="${DROPBEAR_MAIN_PORT} ${DROPBEAR_EXTRA_PORTS}"
EOF
cat >> /usr/local/sbin/user-shaper.sh << 'RUNTIME'
STATE_DIR=/var/run/tunnel-shaper
STATE_FILE="$STATE_DIR/ip_classid.map"
GRACE=30
mkdir -p "$STATE_DIR"
: > "$STATE_FILE"

DOWN_BURST=$(( DOWN_MBIT * 1000000 / 8 / 100 )); [ "$DOWN_BURST" -lt 2000 ] && DOWN_BURST=2000
UP_BURST=$(( UP_MBIT * 1000000 / 8 / 100 ));   [ "$UP_BURST" -lt 2000 ] && UP_BURST=2000

next_classid() {
  local max
  max=$(awk '{print $2}' "$STATE_FILE" | sort -n | tail -1)
  [ -z "$max" ] && max=99
  echo $(( max + 1 ))
}

add_user() {
  local ip="$1" cid="$2"
  tc class add dev "$IFACE" parent 1:1 classid 1:"$cid" htb rate 1mbit ceil "${DOWN_MBIT}"mbit burst "$DOWN_BURST" cburst "$DOWN_BURST" quantum 1514 2>/dev/null
  tc qdisc add dev "$IFACE" parent 1:"$cid" handle "$cid": fq_codel limit 300 target 5ms interval 100ms 2>/dev/null
  tc filter add dev "$IFACE" parent 1: protocol ip prio 1 flower dst_ip "${ip}/32" classid 1:"$cid" 2>/dev/null

  tc class add dev ifb0 parent 1:1 classid 1:"$cid" htb rate 512kbit ceil "${UP_MBIT}"mbit burst "$UP_BURST" cburst "$UP_BURST" quantum 1514 2>/dev/null
  tc qdisc add dev ifb0 parent 1:"$cid" handle "$cid": fq_codel limit 300 target 5ms interval 100ms 2>/dev/null
  tc filter add dev ifb0 parent 1: protocol ip prio 1 flower src_ip "${ip}/32" classid 1:"$cid" 2>/dev/null
}

del_user() {
  local ip="$1" cid="$2"
  tc filter del dev "$IFACE" parent 1: protocol ip prio 1 flower dst_ip "${ip}/32" 2>/dev/null || true
  tc qdisc del dev "$IFACE" parent 1:"$cid" handle "$cid": 2>/dev/null || true
  tc class del dev "$IFACE" classid 1:"$cid" 2>/dev/null || true
  tc filter del dev ifb0 parent 1: protocol ip prio 1 flower src_ip "${ip}/32" 2>/dev/null || true
  tc qdisc del dev ifb0 parent 1:"$cid" handle "$cid": 2>/dev/null || true
  tc class del dev ifb0 classid 1:"$cid" 2>/dev/null || true
}

declare -A LAST_SEEN

while true; do
  PORT_FILTER=""
  for p in $DROPBEAR_PORTS; do PORT_FILTER="${PORT_FILTER} or sport = :${p}"; done
  PORT_FILTER="${PORT_FILTER# or }"

  ACTIVE_IPS=$(ss -tn state established "( ${PORT_FILTER} )" 2>/dev/null \
    | awk 'NR>1{print $5}' | grep -v '\[' | rev | cut -d: -f2- | rev | sort -u)

  NOW=$(date +%s)
  for ip in $ACTIVE_IPS; do
    [ -z "$ip" ] && continue
    LAST_SEEN["$ip"]=$NOW
    if ! grep -q "^${ip} " "$STATE_FILE" 2>/dev/null; then
      cid=$(next_classid)
      echo "${ip} ${cid}" >> "$STATE_FILE"
      add_user "$ip" "$cid"
      logger -t tunnel-shaper "add ${ip} -> class ${cid}"
    fi
  done

  while read -r ip cid; do
    [ -z "$ip" ] && continue
    seen=${LAST_SEEN["$ip"]:-0}
    if [ $(( NOW - seen )) -gt "$GRACE" ]; then
      del_user "$ip" "$cid"
      grep -v "^${ip} " "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE"
      unset "LAST_SEEN[$ip]"
      logger -t tunnel-shaper "remove ${ip} (idle)"
    fi
  done < "$STATE_FILE"

  sleep 3
done
RUNTIME
chmod +x /usr/local/sbin/user-shaper.sh

cat > /etc/systemd/system/tunnel-shaper.service << EOF
[Unit]
Description=Per-user HTB/fq_codel bandwidth shaper
After=network-online.target dropbear.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/qos-root-init.sh
ExecStart=/usr/local/sbin/user-shaper.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tunnel-shaper.service > /dev/null 2>&1

echo "[8/8] ตั้งค่า auto-reboot ปลอดภัย (เฉพาะตอนไม่มี user online)..."
cat > /usr/local/sbin/safe-reboot.sh << EOF
#!/bin/bash
DROPBEAR_PORTS="${DROPBEAR_MAIN_PORT} ${DROPBEAR_EXTRA_PORTS}"
EOF
cat >> /usr/local/sbin/safe-reboot.sh << 'RUNTIME'
PORT_FILTER=""
for p in $DROPBEAR_PORTS; do PORT_FILTER="${PORT_FILTER} or sport = :${p}"; done
PORT_FILTER="${PORT_FILTER# or }"
ACTIVE=$(ss -tn state established "( ${PORT_FILTER} )" 2>/dev/null | tail -n +2 | wc -l)
if [ "$ACTIVE" -eq 0 ]; then
  logger -t safe-reboot "no active users - rebooting to clear RAM"
  /sbin/reboot
else
  logger -t safe-reboot "skip reboot - ${ACTIVE} active connection(s)"
fi
RUNTIME
chmod +x /usr/local/sbin/safe-reboot.sh

cat > /etc/systemd/system/safe-reboot.service << 'EOF'
[Unit]
Description=Safe reboot (only if no active tunnel users)

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
echo -e "${GREEN}ติดตั้งเสร็จสมบูรณ์${NC}"
echo "=================================================="
echo ""
echo "ใส่ค่านี้ในแอป:"
echo "  SSH Host        : $(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo "  SSH Port        : ${DROPBEAR_MAIN_PORT}  (สำรอง: ${DROPBEAR_EXTRA_PORTS})"
echo "  Udpgw Port      : ${BADVPN_PORT1}  (สำรอง: ${BADVPN_PORT2})"
echo "  MTU (client)    : ${TUNNEL_MTU}"
echo "  Cap ต่อ user    : ${DOWN_MBIT_PER_USER}mbps down / ${UP_MBIT_PER_USER}mbps up (บังคับที่ kernel ไม่ใช่แอป)"
echo ""
echo "--- สถานะ service ---"
for s in dropbear badvpn-udpgw1 badvpn-udpgw2 tunnel-shaper safe-reboot.timer; do
  systemctl is-active "$s" > /dev/null 2>&1 && echo "$s: OK" || echo -e "${RED}$s: FAIL${NC}"
done
echo ""
echo "--- เช็คการทำงานของ shaper (รอ user connect ก่อนถึงจะเห็น class) ---"
echo "  journalctl -t tunnel-shaper -f"
echo "  tc -s class show dev ${IFACE}"
echo ""
echo -e "${YELLOW}แนะนำ reboot 1 ครั้งแรกหลังติดตั้ง: reboot${NC}"reboot${NC}"
