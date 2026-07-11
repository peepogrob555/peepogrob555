#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

BADVPN_PORT_PUBLIC=7300   # << พอร์ตเดียวที่บอก client ทุกคน (ห้ามเปลี่ยนถ้าแจกไปแล้ว)
BADVPN_PORT_BACKEND2=7301 # << instance ที่ 2 (internal ล้วน ไม่ต้องบอกใคร)

for s in badvpn-udpgw1 badvpn-udpgw2; do
  systemctl is-active "$s" > /dev/null 2>&1 || {
    echo -e "${RED}${s} ไม่ได้รันอยู่ ต้องรัน install-tunnel-qos.sh ให้เสร็จก่อน${NC}"
    exit 1
  }
done

echo "[1/2] ลบกฎ nth load-balance เก่า (ถ้ามี) กันซ้ำตอนรันสคริปต์นี้ซ้ำ..."
while iptables -t nat -C OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
  -m statistic --mode nth --every 2 --packet 0 \
  -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}" 2>/dev/null; do
  iptables -t nat -D OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
    -m statistic --mode nth --every 2 --packet 0 \
    -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}"
done

echo "[2/2] ติดตั้งกฎ load-balance ใหม่..."
# NEW connection ทุกตัวที่ 2 (ตามลำดับที่เข้ามาใหม่) ถูกสลับไปหา instance 2 แทน
# conntrack จะจำการแปลนี้ไว้ตลอดอายุ connection นั้น ไม่มีทางสลับ backend กลางทาง
iptables -t nat -A OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
  -m statistic --mode nth --every 2 --packet 0 \
  -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}"

netfilter-persistent save > /dev/null 2>&1

echo ""
echo -e "${GREEN}เสร็จแล้ว${NC}"
echo ""
echo "Client ยังคง config Udpgw Port = ${BADVPN_PORT_PUBLIC} เหมือนเดิมทุกคน"
echo "แต่ ~ครึ่งหนึ่งของ session ใหม่จะถูกส่งไปประมวลผลที่ instance 2 (CPU core อื่น) อัตโนมัติ"
echo ""
echo "--- ตรวจสอบว่าทำงานจริง ---"
echo "  # ดูว่ามี process ต่ออยู่ที่ port ไหนบ้าง (ควรเห็นทั้ง 7300 และ 7301 พร้อมกันตอนมี user เยอะ)"
echo "  ss -tn state established '( dport = :7300 or dport = :7301 )' | awk 'NR>1{print \$4}' | sort | uniq -c"
echo ""
echo "  # ดู CPU load แยกราย core ตอนพีค (กด 1 ใน top เพื่อแยกดูราย core)"
echo "  top"
echo ""
echo -e "${YELLOW}หมายเหตุ: กฎนี้เจาะจงที่ TCP dport ${BADVPN_PORT_PUBLIC} ผ่าน loopback (-o lo) เท่านั้น ไม่กระทบ traffic อื่นในเครื่อง${NC}"
