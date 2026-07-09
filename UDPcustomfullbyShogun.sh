#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# แก้แค่นี้ก่อนรัน แล้วไม่ต้องพิมพ์อะไรเพิ่มอีก
# ============================================================
DROPBEAR_MAIN_PORT=80
DROPBEAR_EXTRA_PORTS="143 442"     # เว้นวรรคคั่น ใส่กี่พอร์ตก็ได้
BADVPN_PORT=7300
# ============================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

echo "[1/5] ติดตั้ง dropbear..."
apt-get update -qq
apt-get install -y dropbear ufw iptables-persistent netfilter-persistent build-essential cmake git > /dev/null 2>&1

EXTRA_ARGS=""
for p in $DROPBEAR_EXTRA_PORTS; do
  EXTRA_ARGS="${EXTRA_ARGS} -p ${p}"
done

cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=${DROPBEAR_MAIN_PORT}
DROPBEAR_EXTRA_ARGS="${EXTRA_ARGS}"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF

systemctl restart dropbear
systemctl enable dropbear > /dev/null 2>&1

echo "[2/5] ติดตั้ง badvpn-udpgw..."
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

cat > /etc/systemd/system/badvpn-udpgw.service << EOF
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${BADVPN_PORT} --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now badvpn-udpgw > /dev/null 2>&1

echo "[3/5] ตั้งค่า Firewall (เปิด TCP/UDP ทั้งหมด แล้วบล็อกพอร์ตอันตราย)..."
ufw --force reset > /dev/null
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw

ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw default deny routed > /dev/null

ufw allow 1:65535/tcp > /dev/null
ufw allow 1:65535/udp > /dev/null

for p in 21 23 25 111 135 137 138 139 445 512 513 514 1433 2049 3306 3389 5432 5900 6379 11211 27017; do
  ufw deny "${p}/tcp" > /dev/null
done

for p in 19 69 111 123 137 138 161 162 1900 3389 5353 11211; do
  ufw deny "${p}/udp" > /dev/null
done

ufw allow out to 1.1.1.1 port 53 > /dev/null
ufw allow out to 1.0.0.1 port 53 > /dev/null
ufw allow out to 2606:4700:4700::1111 port 53 > /dev/null
ufw allow out to 2606:4700:4700::1001 port 53 > /dev/null
ufw deny out to any port 53 > /dev/null
ufw deny out to any port 853 > /dev/null

ufw --force enable > /dev/null

echo "[4/5] ปรับแต่ง Network (BBR + fq_codel)..."
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
cat > /etc/sysctl.d/99-tunnel-optimize.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_codel
net.ipv4.ip_forward = 1
net.core.somaxconn = 8192
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1 || true
netfilter-persistent save > /dev/null 2>&1

echo "[5/5] ตรวจสอบผลลัพธ์..."
sleep 1

echo ""
echo "=================================================="
echo -e "${GREEN}ติดตั้งเสร็จสมบูรณ์${NC}"
echo "=================================================="
echo ""
echo "ใส่ค่านี้ในแอป (SSH-Payload):"
echo "  SSH Host      : $(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo "  SSH Port      : ${DROPBEAR_MAIN_PORT}  (สำรอง: ${DROPBEAR_EXTRA_PORTS})"
echo "  Udpgw Port    : ${BADVPN_PORT}"
echo "  SSH Username  : ใช้ user ที่มีอยู่แล้วในเครื่อง (root หรือ user เดิมที่คุณสร้างไว้)"
echo ""
echo "--- สถานะ service ---"
systemctl is-active dropbear && echo "dropbear: OK" || echo -e "${RED}dropbear: FAIL${NC}"
systemctl is-active badvpn-udpgw && echo "badvpn-udpgw: OK" || echo -e "${RED}badvpn-udpgw: FAIL${NC}"
ss -tlnp | grep -E ":(${DROPBEAR_MAIN_PORT})\b"
echo ""
echo -e "${YELLOW}แนะนำ reboot 1 ครั้ง: reboot${NC}"
