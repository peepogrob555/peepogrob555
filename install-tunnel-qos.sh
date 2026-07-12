#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# ============== ค่าคอนฟิกหลัก (แก้ตรงนี้ได้ตามต้องการ) ==============
DROPBEAR_MAIN_PORT=80
DROPBEAR_EXTRA_PORTS="143 442"
BADVPN_PORT1=7300
BADVPN_PORT2=7301

SHAPE_MBIT=345            # เพดานรวม แยกคิด down/up อิสระต่อกัน (ดูหมายเหตุท้ายสคริปต์)
DOWN_MBIT_PER_USER=15
UP_MBIT_PER_USER=4
RTT_MS=60                  # ใช้คำนวณ buffer และป้อนให้ cake ตรง ๆ
TUNNEL_MTU=1360            # ลดจาก 1420 กัน fragmentation ฝั่งมือถือ — ตั้งใน HTTP Custom/UDP Custom ให้ตรงกันด้วย
CAKE_OVERHEAD=18           # margin เผื่อทั่วไป (ตรงกับค่า default ของ SQM ฝั่ง Ethernet) ไม่ใช่ค่าฟันธง

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

# ---------- เลือก DNS (กัน DNS leak) ----------
# รองรับทั้งรันตรง ๆ และรันผ่าน curl | bash (stdin ถูก pipe ไปแล้ว เลยอ่านจาก /dev/tty แทน)
if [ -z "${DNS_CHOICE:-}" ]; then
  echo ""
  echo "เลือก DNS resolver ที่จะบังคับใช้ทั้งระบบ (กัน DNS หลุดไปที่อื่น):"
  echo "  1) Cloudflare  (1.1.1.1 / 1.0.0.1)"
  echo "  2) Google      (8.8.8.8 / 8.8.4.4)"
  if [ -r /dev/tty ]; then
    read -rp "เลือก [1/2] (Enter = 1): " DNS_CHOICE < /dev/tty || DNS_CHOICE=1
  else
    echo "ไม่พบ terminal ให้กรอก (รันแบบ non-interactive) ใช้ค่า default = Cloudflare"
    DNS_CHOICE=1
  fi
fi
DNS_CHOICE=${DNS_CHOICE:-1}

if [ "$DNS_CHOICE" = "2" ]; then
  DNS_LABEL="Google"
  DNS_V4_A="8.8.8.8"; DNS_V4_B="8.8.4.4"
  DNS_V6_A="2001:4860:4860::8888"; DNS_V6_B="2001:4860:4860::8844"
else
  DNS_LABEL="Cloudflare"
  DNS_V4_A="1.1.1.1"; DNS_V4_B="1.0.0.1"
  DNS_V6_A="2606:4700:4700::1111"; DNS_V6_B="2606:4700:4700::1001"
fi
echo "  ใช้ DNS: $DNS_LABEL ($DNS_V4_A, $DNS_V4_B)"

# ---------- เขียน config กลาง ให้ทุกสคริปต์ (รวมถึง patch อีก 2 ตัว) อ่านค่าเดียวกัน ----------
# แก้ค่าทีหลังได้ที่ไฟล์นี้ไฟล์เดียว ไม่ต้องไล่แก้หลายที่ -> ลดบัคจากค่าค้าง/ไม่ตรงกัน
cat > /etc/tunnel-qos.conf << EOF
# auto-generated โดย install-tunnel-qos.sh — อย่าแก้มือถ้าไม่จำเป็น
IFACE=${IFACE}
DROPBEAR_MAIN_PORT=${DROPBEAR_MAIN_PORT}
DROPBEAR_EXTRA_PORTS="${DROPBEAR_EXTRA_PORTS}"
BADVPN_PORT1=${BADVPN_PORT1}
BADVPN_PORT2=${BADVPN_PORT2}
SHAPE_MBIT=${SHAPE_MBIT}
DOWN_MBIT_PER_USER=${DOWN_MBIT_PER_USER}
UP_MBIT_PER_USER=${UP_MBIT_PER_USER}
RTT_MS=${RTT_MS}
TUNNEL_MTU=${TUNNEL_MTU}
CAKE_OVERHEAD=${CAKE_OVERHEAD}
DNS_LABEL=${DNS_LABEL}
DNS_V4_A=${DNS_V4_A}
DNS_V4_B=${DNS_V4_B}
DNS_V6_A=${DNS_V6_A}
DNS_V6_B=${DNS_V6_B}
UDP_CUSTOM_PORT=
EOF
echo "  เขียน /etc/tunnel-qos.conf แล้ว"

echo "[1/9] ติดตั้ง dependencies..."
apt-get update -qq
apt-get install -y dropbear ufw iptables conntrack \
  build-essential cmake git ethtool iproute2 > /dev/null 2>&1

modprobe sch_cake 2>/dev/null || true
if ! tc qdisc add dev lo root cake 2>/dev/null; then
  echo -e "${RED}เคอร์เนล/iproute2 นี้ไม่รองรับ cake qdisc — เช็ค 'uname -r' (ต้องมี sch_cake) แล้วลองใหม่${NC}"
  exit 1
fi
tc qdisc del dev lo root 2>/dev/null || true
echo "  cake qdisc ใช้ได้"

echo "[2/9] ตั้งค่า dropbear..."
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

mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -EF -p ${DROPBEAR_MAIN_PORT}${EXTRA_ARGS} -c /bin/true -K 60 -I 300 -W 1048576
Nice=-5
IOSchedulingClass=1
IOSchedulingPriority=2
EOF

systemctl daemon-reload
systemctl enable dropbear > /dev/null 2>&1
systemctl restart dropbear

echo "[3/9] คอมไพล์ badvpn-udpgw..."
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
  --max-clients 512 --max-connections-for-client 40 --udp-mtu $((TUNNEL_MTU - 28))
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
  --max-clients 512 --max-connections-for-client 40 --udp-mtu $((TUNNEL_MTU - 28))
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

echo "[4/9] ตั้งค่า Firewall + DNS..."
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

# บังคับ DNS ของตัวเครื่องเองให้ตรงกับที่เลือกด้วย (systemd-resolved)
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/tunnel-dns.conf << EOF
[Resolve]
DNS=${DNS_V4_A} ${DNS_V4_B}
FallbackDNS=
DNSStubListener=yes
EOF
systemctl restart systemd-resolved 2>/dev/null || true

echo "[5/9] ตั้งค่า MTU + MSS clamp..."
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

# MSS clamp กัน PMTUD black-hole (มือถือหลายเครือข่ายดรอป ICMP frag-needed) — สำคัญกว่า cake overhead จริง ๆ
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
systemctl enable --now mss-clamp.service > /dev/null 2>&1
echo "  MTU=${TUNNEL_MTU}, MSS(v4)=${MSS_V4} clamp ติดตั้งแล้ว"

echo "[6/9] ตั้งค่า sysctl (BBR + buffer ตาม BDP จริง ไม่ใช่ยัดใหญ่มั่ว)..."
# หมายเหตุ: ต่อให้ RAM เหลือ ก็ไม่ควรยัด rmem/wmem ใหญ่เกิน BDP มาก ๆ เพราะจะกลายเป็น buffer
# ในเคอร์เนลเองที่ cake มองไม่เห็น (bufferbloat ซ่อนอยู่ก่อนถึงคิว) ปิงจะยิ่งเหวี่ยงตอน user โหลดเต็มไลน์
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tunnel.conf

BDP_BYTES=$(( DOWN_MBIT_PER_USER * 1000000 / 8 * RTT_MS / 1000 ))
RMEM_MAX=$(( BDP_BYTES * 4 ))
[ "$RMEM_MAX" -lt 2097152 ] && RMEM_MAX=2097152
[ "$RMEM_MAX" -gt 6291456 ] && RMEM_MAX=6291456

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
net.ipv4.tcp_rmem = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${RMEM_MAX}
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 600
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1 || true
echo "  RMEM/WMEM max = ${RMEM_MAX} bytes (คิดจาก BDP ที่ ${DOWN_MBIT_PER_USER}mbit x ${RTT_MS}ms x4)"

echo "[7/9] ติดตั้งระบบ per-user shaping (HTB คุมเพดานต่อคนแบบตายตัว + CAKE คุมคิว/AQM ต่อคน)..."
# ทำไมไม่ใช้ cake อย่างเดียวทั้งเส้น: cake เพียว ๆ จะแบ่งแบบ fair-share (คนน้อย = ได้เยอะกว่า cap)
# แต่ที่ตั้งไว้คือ "ห้ามเกิน 15/4 ต่อคนไม่ว่าจะมีกี่คนต่อ" -> ต้องมี HTB ครอบเป็นเพดานตายตัว
# แล้วให้ cake ทำหน้าที่ AQM/overhead-comp/RTT-aware ต่อคนอีกที (เป็น leaf ใต้ HTB class)
cat > /usr/local/sbin/qos-root-init.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf

modprobe sch_cake 2>/dev/null || true
modprobe ifb numifbs=1 2>/dev/null || true
ip link set dev ifb0 up 2>/dev/null || true

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

# ขาดาวน์โหลด (egress บน interface จริง)
tc qdisc add dev "$IFACE" root handle 1: htb default 999 r2q 10
tc class add dev "$IFACE" parent 1: classid 1:1 htb rate ${SHAPE_MBIT}mbit ceil ${SHAPE_MBIT}mbit
tc class add dev "$IFACE" parent 1:1 classid 1:999 htb rate 2mbit ceil ${SHAPE_MBIT}mbit quantum 1514
tc qdisc add dev "$IFACE" parent 1:999 handle 999: cake bandwidth ${SHAPE_MBIT}mbit rtt ${RTT_MS}ms overhead ${CAKE_OVERHEAD} besteffort

# redirect ขาอัพโหลด (ingress) ไปที่ ifb0 เพื่อ shape ได้ (kernel shape ingress ตรง ๆ ไม่ได้)
tc qdisc add dev "$IFACE" handle ffff: ingress
tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

# ขาอัพโหลด (egress บน ifb0 = ingress เดิมของ interface จริง)
tc qdisc add dev ifb0 root handle 1: htb default 999 r2q 10
tc class add dev ifb0 parent 1: classid 1:1 htb rate ${SHAPE_MBIT}mbit ceil ${SHAPE_MBIT}mbit
tc class add dev ifb0 parent 1:1 classid 1:999 htb rate 2mbit ceil ${SHAPE_MBIT}mbit quantum 1514
tc qdisc add dev ifb0 parent 1:999 handle 999: cake bandwidth ${SHAPE_MBIT}mbit rtt ${RTT_MS}ms overhead ${CAKE_OVERHEAD} besteffort
RUNTIME
chmod +x /usr/local/sbin/qos-root-init.sh

cat > /usr/local/sbin/user-shaper.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf
DROPBEAR_PORTS="${DROPBEAR_MAIN_PORT} ${DROPBEAR_EXTRA_PORTS}"

STATE_DIR=/var/run/tunnel-shaper
STATE_FILE="$STATE_DIR/ip_classid.map"
GRACE=30
mkdir -p "$STATE_DIR"
: > "$STATE_FILE"

DOWN_BURST=$(( DOWN_MBIT_PER_USER * 1000000 / 8 / 100 )); [ "$DOWN_BURST" -lt 2000 ] && DOWN_BURST=2000
UP_BURST=$(( UP_MBIT_PER_USER * 1000000 / 8 / 100 ));   [ "$UP_BURST" -lt 2000 ] && UP_BURST=2000

next_classid() {
  local max
  max=$(awk '{print $2}' "$STATE_FILE" | sort -n | tail -1)
  [ -z "$max" ] && max=99
  echo $(( max + 1 ))
}

add_user() {
  local ip="$1" cid="$2"
  # ดาวน์โหลด: จัดกลุ่มด้วย dst_ip บน interface จริง, เพดานตายตัว DOWN_MBIT_PER_USER
  tc class add dev "$IFACE" parent 1:1 classid 1:"$cid" htb rate 1mbit ceil "${DOWN_MBIT_PER_USER}"mbit burst "$DOWN_BURST" cburst "$DOWN_BURST" quantum 1514 2>/dev/null
  tc qdisc add dev "$IFACE" parent 1:"$cid" handle "$cid": cake bandwidth "${DOWN_MBIT_PER_USER}"mbit rtt "${RTT_MS}"ms overhead "${CAKE_OVERHEAD}" besteffort ack-filter 2>/dev/null
  tc filter add dev "$IFACE" parent 1: protocol ip prio 1 flower dst_ip "${ip}/32" classid 1:"$cid" 2>/dev/null

  # อัพโหลด: จัดกลุ่มด้วย src_ip บน ifb0, เพดานตายตัว UP_MBIT_PER_USER
  tc class add dev ifb0 parent 1:1 classid 1:"$cid" htb rate 512kbit ceil "${UP_MBIT_PER_USER}"mbit burst "$UP_BURST" cburst "$UP_BURST" quantum 1514 2>/dev/null
  tc qdisc add dev ifb0 parent 1:"$cid" handle "$cid": cake bandwidth "${UP_MBIT_PER_USER}"mbit rtt "${RTT_MS}"ms overhead "${CAKE_OVERHEAD}" besteffort ack-filter 2>/dev/null
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

  TCP_IPS=$(ss -tn state established "( ${PORT_FILTER} )" 2>/dev/null \
    | awk 'NR>1{print $5}' | grep -v '\[' | rev | cut -d: -f2- | rev)

  UDP_IPS=""
  if [ -n "$UDP_CUSTOM_PORT" ]; then
    UDP_IPS=$(conntrack -L -p udp --dport "$UDP_CUSTOM_PORT" 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i ~ /^src=/){print substr($i,5); break}}')
  fi

  ACTIVE_IPS=$(printf '%s\n%s\n' "$TCP_IPS" "$UDP_IPS" | grep -v '^$' | sort -u)

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

cat > /etc/systemd/system/tunnel-shaper.service << 'EOF'
[Unit]
Description=Per-user HTB/CAKE bandwidth shaper
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

echo "[8/9] ตั้งค่า RPS (กระจาย packet processing ทุก core กันปิงกระตุกตอนโหลดหนัก)..."
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
RUNTIME
chmod +x /usr/local/sbin/set-rps.sh

cat > /etc/systemd/system/set-rps.service << 'EOF'
[Unit]
Description=Spread RX packet steering across all CPU cores
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

echo "[9/9] ตั้งค่า auto-reboot ปลอดภัย (เฉพาะตอนไม่มี user online)..."
cat > /usr/local/sbin/safe-reboot.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf
DROPBEAR_PORTS="${DROPBEAR_MAIN_PORT} ${DROPBEAR_EXTRA_PORTS}"
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
echo "  MTU (client)    : ${TUNNEL_MTU}  <- ตั้งใน HTTP Custom/UDP Custom ให้ตรงกันด้วย"
echo "  DNS             : ${DNS_LABEL} (${DNS_V4_A}, ${DNS_V4_B})"
echo "  Cap ต่อ user    : ${DOWN_MBIT_PER_USER}mbps down / ${UP_MBIT_PER_USER}mbps up (บังคับที่ kernel ผ่าน HTB, ไม่ใช่แอป)"
echo "  Shape รวม       : ${SHAPE_MBIT}mbit ต่อทิศทาง (down กับ up แยกเพดานกันคนละชุด)"
echo ""
echo "--- สถานะ service ---"
for s in dropbear badvpn-udpgw1 badvpn-udpgw2 tunnel-shaper set-rps mss-clamp safe-reboot.timer; do
  systemctl is-active "$s" > /dev/null 2>&1 && echo "$s: OK" || echo -e "${RED}$s: FAIL${NC}"
done
echo ""
echo "--- เช็คการทำงานของ shaper (รอ user connect ก่อนถึงจะเห็น class) ---"
echo "  journalctl -t tunnel-shaper -f"
echo "  tc -s qdisc show dev ${IFACE}"
echo "  tc -s qdisc show dev ifb0"
echo ""
echo -e "${YELLOW}ต่อไป: รัน udpgw-loadbalance-patch.sh แล้วค่อยติดตั้ง udp-custom (ตัวติดตั้งจริงเป็นไฟล์แยกจากค่าย udp-custom เอง ไม่ใช่ไฟล์ในชุดนี้) แล้วค่อยรัน post-udpcustom-patch.sh${NC}"
echo -e "${YELLOW}แนะนำ reboot 1 ครั้งแรกหลังติดตั้ง: reboot${NC}"
