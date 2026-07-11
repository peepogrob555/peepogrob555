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

echo "[1/3] สร้าง script อ่านพอร์ตสดใหม่ทุกครั้งที่รัน (กันปัญหาพอร์ตเปลี่ยนแล้ว service ค้างพอร์ตเก่า)..."
cat > /usr/local/sbin/udpgw-loadbalance.sh << 'RUNTIME'
#!/bin/bash
BADVPN_PORT_PUBLIC=$(grep -oP '127\.0\.0\.1:\K[0-9]+' /etc/systemd/system/badvpn-udpgw1.service | head -1)
BADVPN_PORT_BACKEND2=$(grep -oP '127\.0\.0\.1:\K[0-9]+' /etc/systemd/system/badvpn-udpgw2.service | head -1)

if [ -z "$BADVPN_PORT_PUBLIC" ] || [ -z "$BADVPN_PORT_BACKEND2" ]; then
  logger -t udpgw-loadbalance "อ่านพอร์ตจาก badvpn-udpgw1/2.service ไม่ได้ ข้าม"
  exit 0
fi

# ลบกฎเก่าทุกอันที่ตรงกับ public port นี้ก่อน (เผื่อพอร์ต backend เปลี่ยนไปจากตอนก่อนบูต)
while true; do
  OLD_RULE=$(iptables -t nat -S OUTPUT 2>/dev/null | grep -- "--dport ${BADVPN_PORT_PUBLIC} " | grep 'nth' | head -1)
  [ -z "$OLD_RULE" ] && break
  iptables -t nat -D OUTPUT $(echo "$OLD_RULE" | sed 's/^-A OUTPUT //') 2>/dev/null || break
done

iptables -t nat -A OUTPUT -p tcp --dport "$BADVPN_PORT_PUBLIC" -o lo \
  -m statistic --mode nth --every 2 --packet 0 \
  -j DNAT --to-destination "127.0.0.1:${BADVPN_PORT_BACKEND2}"

logger -t udpgw-loadbalance "ติดตั้งกฎแล้ว: ${BADVPN_PORT_PUBLIC} -> ครึ่งหนึ่งไป 127.0.0.1:${BADVPN_PORT_BACKEND2}"
RUNTIME
chmod +x /usr/local/sbin/udpgw-loadbalance.sh

echo "[2/3] ติดตั้ง systemd service (เรียก script ข้างบนแทนการฝังพอร์ตตายตัว)..."
cat > /etc/systemd/system/udpgw-loadbalance.service << 'EOF'
[Unit]
Description=Sync badvpn-udpgw load-balance NAT rule with current ports
After=network.target badvpn-udpgw1.service badvpn-udpgw2.service
Requires=badvpn-udpgw1.service badvpn-udpgw2.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/udpgw-loadbalance.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udpgw-loadbalance.service > /dev/null 2>&1

echo "[3/3] รันทันทีเพื่อใส่กฎด้วยพอร์ตปัจจุบัน..."
/usr/local/sbin/udpgw-loadbalance.sh

BADVPN_PORT_PUBLIC=$(grep -oP '127\.0\.0\.1:\K[0-9]+' /etc/systemd/system/badvpn-udpgw1.service | head -1)
BADVPN_PORT_BACKEND2=$(grep -oP '127\.0\.0\.1:\K[0-9]+' /etc/systemd/system/badvpn-udpgw2.service | head -1)

echo ""
echo -e "${GREEN}เสร็จแล้ว${NC}"
echo ""
echo "พอร์ตที่ใช้จริงตอนนี้: instance1=${BADVPN_PORT_PUBLIC} instance2=${BADVPN_PORT_BACKEND2}"
echo "Client ยังคง config Udpgw Port = ${BADVPN_PORT_PUBLIC} เหมือนเดิมทุกคน"
echo "แต่ ~ครึ่งหนึ่งของ session ใหม่ที่เข้าพอร์ต ${BADVPN_PORT_PUBLIC} จะถูกส่งไปประมวลผลที่ 127.0.0.1:${BADVPN_PORT_BACKEND2} (CPU core อื่น) อัตโนมัติ"
echo "ต่อไปนี้ถ้าไปเปลี่ยนพอร์ต badvpn-udpgw1/2 ทีหลัง ไม่ต้องรันสคริปต์นี้ซ้ำแล้ว — service จะอ่านพอร์ตสดใหม่เองทุกครั้งที่บูต"
echo ""
echo "--- ตรวจสอบว่าทำงานจริง ---"
echo "  ss -tn state established \"( dport = :${BADVPN_PORT_PUBLIC} or dport = :${BADVPN_PORT_BACKEND2} )\" | awk 'NR>1{print \$4}' | sort | uniq -c"
echo "  iptables -t nat -L OUTPUT -n --line-numbers"
echo ""
echo -e "${YELLOW}หมายเหตุ: กฎนี้เจาะจงที่ TCP dport ${BADVPN_PORT_PUBLIC} ผ่าน loopback (-o lo) เท่านั้น ไม่กระทบ traffic อื่นในเครื่อง${NC}"
