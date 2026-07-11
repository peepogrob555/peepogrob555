#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

UDP_CUSTOM_CONFIG="/root/udp/config.json"
if [ ! -f "$UDP_CUSTOM_CONFIG" ]; then
  echo -e "${RED}ไม่พบ ${UDP_CUSTOM_CONFIG} — ต้องรัน udp-custom install.sh ให้เสร็จก่อน แล้วค่อยรันไฟล์นี้${NC}"
  exit 1
fi

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
echo "Interface: $IFACE"

echo "[1/6] ติดตั้ง firewall กลับคืน (installer ของ udp-custom ลบทิ้งไปแล้ว)..."
apt-get update -qq
apt-get install -y ufw conntrack > /dev/null 2>&1

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
echo "  firewall กลับมาแล้ว"

if [ -f /etc/systemd/system/udpgw-loadbalance.service ]; then
  systemctl daemon-reload
  systemctl start udpgw-loadbalance.service > /dev/null 2>&1 || true
  echo "  ใส่กฎ load-balance ของ badvpn-udpgw กลับคืนแล้ว"
fi

echo "[2/6] อ่านพอร์ตจริงของ udp-custom จาก config.json..."
UDP_CUSTOM_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CUSTOM_CONFIG" || true)
if [ -z "$UDP_CUSTOM_PORT" ]; then
  echo -e "${YELLOW}อ่านพอร์ตจาก config.json ไม่ได้อัตโนมัติ ใส่เองด้านล่างนี้แทน${NC}"
  read -rp "ใส่พอร์ต UDP ที่ udp-custom ใช้จริง (ดูจาก 'listen' ใน /root/udp/config.json): " UDP_CUSTOM_PORT
fi
echo "  udp-custom listen port = ${UDP_CUSTOM_PORT}"

echo "[3/6] ปิดตัว udpgw.service สำรองที่ติดมากับ udp-custom (ซ้ำกับ badvpn-udpgw1/2 ที่มีอยู่แล้ว)..."
if systemctl list-unit-files 2>/dev/null | grep -q '^udpgw.service'; then
  systemctl disable --now udpgw.service > /dev/null 2>&1 || true
  echo "  ปิด udpgw.service แล้ว — ยังใช้ badvpn-udpgw1/2 ตามเดิม"
else
  echo "  ไม่พบ udpgw.service แยก ข้ามขั้นตอนนี้"
fi

echo "[4/6] ลบ auto-reboot ออกทั้งหมด..."
systemctl disable --now safe-reboot.timer > /dev/null 2>&1 || true
systemctl stop safe-reboot.service > /dev/null 2>&1 || true
rm -f /etc/systemd/system/safe-reboot.timer /etc/systemd/system/safe-reboot.service
rm -f /usr/local/sbin/safe-reboot.sh
systemctl daemon-reload
echo "  ลบเรียบร้อย ต่อไปนี้ reboot ต้องทำเองเท่านั้น"

echo "[5/6] อัปเดต shaper ให้คลุมพอร์ต UDP ของ udp-custom ด้วย..."
if [ ! -f /usr/local/sbin/qos-root-init.sh ] || [ ! -f /usr/local/sbin/user-shaper.sh ]; then
  echo -e "${RED}ไม่พบ qos-root-init.sh / user-shaper.sh — ดูเหมือนยังไม่เคยรัน install-tunnel-qos.sh มาก่อน ข้ามขั้นตอนนี้${NC}"
else
  DOWN_MBIT=$(grep '^DOWN_MBIT=' /usr/local/sbin/user-shaper.sh | head -1 | cut -d= -f2)
  UP_MBIT=$(grep '^UP_MBIT=' /usr/local/sbin/user-shaper.sh | head -1 | cut -d= -f2)
  DROPBEAR_PORTS=$(grep '^DROPBEAR_PORTS=' /usr/local/sbin/user-shaper.sh | head -1 | cut -d'"' -f2)
  if [ -z "$DOWN_MBIT" ] || [ -z "$UP_MBIT" ] || [ -z "$DROPBEAR_PORTS" ]; then
    echo -e "${RED}อ่านค่า cap เดิมจาก user-shaper.sh ไม่ได้ ข้ามขั้นตอนนี้${NC}"
  else
    echo "  ค่าที่อ่านได้: DOWN_MBIT=${DOWN_MBIT} UP_MBIT=${UP_MBIT} DROPBEAR_PORTS=\"${DROPBEAR_PORTS}\""
    cat > /usr/local/sbin/user-shaper.sh << EOF
#!/bin/bash
IFACE="${IFACE}"
DOWN_MBIT=${DOWN_MBIT}
UP_MBIT=${UP_MBIT}
DROPBEAR_PORTS="${DROPBEAR_PORTS}"
UDP_CUSTOM_PORT="${UDP_CUSTOM_PORT}"
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
    systemctl restart tunnel-shaper.service
    echo "  shaper อัปเดตแล้ว ครอบคลุมทั้ง dropbear (TCP) และ udp-custom (UDP port ${UDP_CUSTOM_PORT})"
  fi
fi

echo "[6/6] ตรวจสอบผลลัพธ์..."
echo ""
echo "=================================================="
echo -e "${GREEN}Patch เสร็จสมบูรณ์${NC}"
echo "=================================================="
for s in ufw udp-custom tunnel-shaper dropbear badvpn-udpgw1 badvpn-udpgw2 udpgw-loadbalance.service; do
  systemctl is-active "$s" > /dev/null 2>&1 && echo "$s: OK" || echo -e "${YELLOW}$s: ไม่ active${NC}"
done
echo ""
echo "ufw status:"
ufw status numbered | head -20
echo ""
echo "journalctl -t tunnel-shaper -f    # ดู log user เข้า-ออกแบบ real-time"
