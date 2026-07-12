#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

if [ ! -f /etc/tunnel-qos.conf ]; then
  echo -e "${RED}ไม่พบ /etc/tunnel-qos.conf — ต้องรัน install-tunnel-qos.sh ให้เสร็จก่อน แล้วค่อยรันไฟล์นี้${NC}"
  exit 1
fi
source /etc/tunnel-qos.conf
echo "ใช้ค่าจาก install-tunnel-qos.sh: IFACE=${IFACE} DNS=${DNS_LABEL} MTU=${TUNNEL_MTU} SHAPE=${SHAPE_MBIT}mbit/ทิศทาง"

UDP_CUSTOM_CONFIG="/root/udp/config.json"
if [ ! -f "$UDP_CUSTOM_CONFIG" ]; then
  echo -e "${RED}ไม่พบ ${UDP_CUSTOM_CONFIG} — ต้องรัน udp-custom install.sh ให้เสร็จก่อน แล้วค่อยรันไฟล์นี้${NC}"
  exit 1
fi

echo "[1/8] อ่านพอร์ตจริงของ udp-custom จาก config.json..."
UDP_CUSTOM_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CUSTOM_CONFIG" || true)
if [ -z "$UDP_CUSTOM_PORT" ]; then
  echo -e "${YELLOW}อ่านพอร์ตจาก config.json ไม่ได้อัตโนมัติ ใส่เองด้านล่างนี้แทน${NC}"
  read -rp "ใส่พอร์ต UDP ที่ udp-custom ใช้จริง (ดูจาก 'listen' ใน /root/udp/config.json): " UDP_CUSTOM_PORT
fi
echo "  udp-custom listen port = ${UDP_CUSTOM_PORT}"

echo "[2/8] บันทึกพอร์ตนี้ลง /etc/tunnel-qos.conf (ให้ shaper กับ safe-reboot อ่านค่าเดียวกันตลอด ไม่ต้องแก้หลายที่)..."
if grep -q '^UDP_CUSTOM_PORT=' /etc/tunnel-qos.conf; then
  sed -i "s/^UDP_CUSTOM_PORT=.*/UDP_CUSTOM_PORT=${UDP_CUSTOM_PORT}/" /etc/tunnel-qos.conf
else
  echo "UDP_CUSTOM_PORT=${UDP_CUSTOM_PORT}" >> /etc/tunnel-qos.conf
fi

echo "[3/8] ติดตั้ง firewall กลับคืน (installer ของ udp-custom ลบทิ้งไปแล้ว) โดยใช้ DNS เดียวกับที่เลือกไว้ตอน install (${DNS_LABEL}) ไม่ใช่ค่าตายตัว..."
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
ufw allow out to "$DNS_V4_A" port 53 > /dev/null
ufw allow out to "$DNS_V4_B" port 53 > /dev/null
ufw allow out to "$DNS_V6_A" port 53 > /dev/null
ufw allow out to "$DNS_V6_B" port 53 > /dev/null
ufw deny out to any port 53 > /dev/null
ufw deny out to any port 853 > /dev/null
ufw --force enable > /dev/null
echo "  firewall กลับมาแล้ว (DNS บังคับ = ${DNS_LABEL}: ${DNS_V4_A}, ${DNS_V4_B}) — กัน DNS/IP leak ไปที่ resolver อื่น"

if [ -f /etc/systemd/system/udpgw-loadbalance.service ]; then
  systemctl daemon-reload
  systemctl start udpgw-loadbalance.service > /dev/null 2>&1 || true
  echo "  ใส่กฎ load-balance ของ badvpn-udpgw กลับคืนแล้ว"
fi

echo "[4/8] ยืนยัน MTU/MSS clamp ยังตรงกับ install-tunnel-qos.sh (เผื่อ installer ของ udp-custom ไปยุ่งกับ interface)..."
ip link set dev "$IFACE" mtu "$TUNNEL_MTU" 2>/dev/null || true
systemctl restart set-mtu.service 2>/dev/null || true
if [ -x /usr/local/sbin/mss-clamp.sh ]; then
  /usr/local/sbin/mss-clamp.sh
  systemctl restart mss-clamp.service 2>/dev/null || true
fi
echo "  MTU=${TUNNEL_MTU} ยืนยันแล้ว (ตั้งใน HTTP Custom/UDP Custom ฝั่ง client ให้ตรงกันด้วย)"

echo "[5/8] ปิดตัว udpgw.service สำรองที่ติดมากับ udp-custom (ซ้ำกับ badvpn-udpgw1/2 ที่มีอยู่แล้ว)..."
if systemctl list-unit-files 2>/dev/null | grep -q '^udpgw.service'; then
  systemctl disable --now udpgw.service > /dev/null 2>&1 || true
  echo "  ปิด udpgw.service แล้ว — ยังใช้ badvpn-udpgw1/2 ตามเดิม"
else
  echo "  ไม่พบ udpgw.service แยก ข้ามขั้นตอนนี้"
fi

echo "[6/8] แก้ safe-reboot ให้รู้จัก session ของ udp-custom ด้วย (ของเดิมเช็คแค่ dropbear TCP — ถ้ามีคนต่อผ่าน udp-custom ล้วน ๆ โดยไม่มี dropbear session จะโดนรีบูตทับได้)..."
if [ -f /usr/local/sbin/safe-reboot.sh ]; then
  cat > /usr/local/sbin/safe-reboot.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf
DROPBEAR_PORTS="${DROPBEAR_MAIN_PORT} ${DROPBEAR_EXTRA_PORTS}"
PORT_FILTER=""
for p in $DROPBEAR_PORTS; do PORT_FILTER="${PORT_FILTER} or sport = :${p}"; done
PORT_FILTER="${PORT_FILTER# or }"

ACTIVE_TCP=$(ss -tn state established "( ${PORT_FILTER} )" 2>/dev/null | tail -n +2 | wc -l)

ACTIVE_UDP=0
if [ -n "${UDP_CUSTOM_PORT:-}" ] && command -v conntrack >/dev/null 2>&1; then
  ACTIVE_UDP=$(conntrack -L -p udp --dport "$UDP_CUSTOM_PORT" 2>/dev/null | wc -l)
fi

ACTIVE=$(( ACTIVE_TCP + ACTIVE_UDP ))
if [ "$ACTIVE" -eq 0 ]; then
  logger -t safe-reboot "no active users (tcp+udp) - rebooting to clear RAM"
  /sbin/reboot
else
  logger -t safe-reboot "skip reboot - ${ACTIVE_TCP} tcp + ${ACTIVE_UDP} udp-custom connection(s)"
fi
RUNTIME
  chmod +x /usr/local/sbin/safe-reboot.sh
  echo "  แก้แล้ว: safe-reboot จะนับ user ของ udp-custom (ผ่าน conntrack) ด้วย ไม่ใช่แค่ dropbear เหมือนเดิม"
else
  echo -e "${YELLOW}  ไม่พบ /usr/local/sbin/safe-reboot.sh ข้ามขั้นตอนนี้ (เช็คว่ารัน install-tunnel-qos.sh ครบหรือยัง)${NC}"
fi

echo "[7/8] รีสตาร์ท shaper ให้อ่านพอร์ต udp-custom ใหม่ (cake/HTB ต่อ user จะครอบคลุมถึง udp-custom ด้วย ไม่ใช่แค่ dropbear)..."
if systemctl list-unit-files 2>/dev/null | grep -q '^tunnel-shaper.service'; then
  systemctl restart tunnel-shaper.service
  echo "  tunnel-shaper รีสตาร์ทแล้ว ครอบคลุมทั้ง dropbear (TCP) และ udp-custom (UDP port ${UDP_CUSTOM_PORT})"
else
  echo -e "${RED}  ไม่พบ tunnel-shaper.service — ดูเหมือนยังไม่เคยรัน install-tunnel-qos.sh มาก่อน${NC}"
fi

echo "[8/8] ติดตั้ง irqbalance เสริม (กระจาย IRQ การ์ดเน็ตให้ทั่วทุก core เพิ่มจาก RPS เดิม — แลก CPU/RAM นิดหน่อยแลกปิงนิ่งขึ้นตอนโหลดเยอะ)..."
apt-get install -y irqbalance > /dev/null 2>&1 || true
systemctl enable --now irqbalance > /dev/null 2>&1 || true
systemctl is-active irqbalance > /dev/null 2>&1 && echo "  irqbalance: OK" || echo -e "${YELLOW}  irqbalance: ไม่ active (ข้ามได้ ไม่กระทบการทำงานหลัก)${NC}"

echo ""
echo "=================================================="
echo -e "${GREEN}Patch เสร็จสมบูรณ์${NC}"
echo "=================================================="
echo ""
echo "  DNS             : ${DNS_LABEL} (${DNS_V4_A}, ${DNS_V4_B}) — ใช้ค่าที่เลือกไว้ตอน install-tunnel-qos.sh ไม่ถามซ้ำ"
echo "  MTU             : ${TUNNEL_MTU}"
echo "  udp-custom port : ${UDP_CUSTOM_PORT}"
echo "  Shape รวม       : ${SHAPE_MBIT}mbit ต่อทิศทาง (down/up แยกเพดานกันคนละชุด)"
echo "  Cap ต่อ user    : ${DOWN_MBIT_PER_USER}mbps down / ${UP_MBIT_PER_USER}mbps up"
echo ""
for s in ufw udp-custom tunnel-shaper dropbear badvpn-udpgw1 badvpn-udpgw2 udpgw-loadbalance.service safe-reboot.timer irqbalance; do
  systemctl is-active "$s" > /dev/null 2>&1 && echo "$s: OK" || echo -e "${YELLOW}$s: ไม่ active${NC}"
done
echo ""
echo "ufw status:"
ufw status numbered | head -20
echo ""
echo "journalctl -t tunnel-shaper -f    # ดู log user เข้า-ออกแบบ real-time (ครอบคลุม udp-custom แล้ว)"
echo "journalctl -t safe-reboot -f      # ดู log auto-reboot (ตอนนี้รู้จัก udp-custom แล้ว ไม่รีบูตทับ)"
