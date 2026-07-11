#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

for s in badvpn-udpgw1 badvpn-udpgw2; do
  systemctl is-active "$s" > /dev/null 2>&1 || {
    echo -e "${RED}${s} ไม่ได้รันอยู่ ต้องรัน install-tunnel-qos.sh ให้เสร็จก่อน${NC}"
    exit 1
  }
done

BADVPN_PORT_PUBLIC=$(grep -oP '127\.0\.0\.1:\K[0-9]+' /etc/systemd/system/badvpn-udpgw1.service | head -1)
BADVPN_PORT_BACKEND2=$(grep -oP '127\.0\.0\.1:\K[0-9]+' /etc/systemd/system/badvpn-udpgw2.service | head -1)
if [ -z "$BADVPN_PORT_PUBLIC" ] || [ -z "$BADVPN_PORT_BACKEND2" ]; then
  echo -e "${RED}อ่านพอร์ตจาก badvpn-udpgw1/2.service ไม่ได้ ยกเลิก${NC}"
  exit 1
fi
echo "พอร์ตที่อ่านได้: instance1=${BADVPN_PORT_PUBLIC} instance2=${BADVPN_PORT_BACKEND2}"

echo "[1/2] ลบกฎ nth load-balance เก่า (ถ้ามี) กันซ้ำตอนรันสคริปต์นี้ซ้ำ..."
while iptables -t nat -C OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
  -m statistic --mode nth --every 2 --packet 0 \
  -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}" 2>/dev/null; do
  iptables -t nat -D OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
    -m statistic --mode nth --every 2 --packet 0 \
    -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}"
done

echo "[2/2] ติดตั้งกฎ load-balance ใหม่..."
iptables -t nat -A OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
  -m statistic --mode nth --every 2 --packet 0 \
  -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}"

cat > /etc/systemd/system/udpgw-loadbalance.service << EOF
[Unit]
Description=Persist badvpn-udpgw load-balance NAT rule
After=network.target badvpn-udpgw1.service badvpn-udpgw2.service
Requires=badvpn-udpgw1.service badvpn-udpgw2.service

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A OUTPUT -p tcp --dport ${BADVPN_PORT_PUBLIC} -o lo -m statistic --mode nth --every 2 --packet 0 -j DNAT --to-destination 127.0.0.1:${BADVPN_PORT_BACKEND2}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable udpgw-loadbalance.service > /dev/null 2>&1

echo ""
echo -e "${GREEN}เสร็จแล้ว${NC}"
echo ""
echo "Client ยังคง config Udpgw Port = ${BADVPN_PORT_PUBLIC} เหมือนเดิมทุกคน"
echo "แต่ ~ครึ่งหนึ่งของ session ใหม่จะถูกส่งไปประมวลผลที่ instance 2 (CPU core อื่น) อัตโนมัติ"
echo "กฎนี้จะถูกใส่กลับให้อัตโนมัติทุกครั้งที่บูตเครื่อง ผ่าน udpgw-loadbalance.service"
echo ""
echo "--- ตรวจสอบว่าทำงานจริง ---"
echo "  ss -tn state established '( dport = :${BADVPN_PORT_PUBLIC} or dport = :${BADVPN_PORT_BACKEND2} )' | awk 'NR>1{print \$4}' | sort | uniq -c"
echo "  top"
echo ""
echo -e "${YELLOW}หมายเหตุ: กฎนี้เจาะจงที่ TCP dport ${BADVPN_PORT_PUBLIC} ผ่าน loopback (-o lo) เท่านั้น ไม่กระทบ traffic อื่นในเครื่อง${NC}"
