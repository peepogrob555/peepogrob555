#!/bin/bash

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0
FAIL=0
WARN=0

ok() { echo -e "  ${GREEN}[OK]${NC} $1"; PASS=$((PASS+1)); }
bad() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
section() { echo ""; echo -e "${CYAN}== $1 ==${NC}"; }

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

if [ ! -f /etc/tunnel-qos.conf ]; then
  echo -e "${RED}ไม่พบ /etc/tunnel-qos.conf — ยังไม่เคยรัน install-tunnel-qos.sh สำเร็จ${NC}"
  exit 1
fi
source /etc/tunnel-qos.conf

section "1. เวลาบูตล่าสุด (เช็คว่ารีบูตจริงหรือแค่รัน service ใหม่)"
echo "  $(who -b 2>/dev/null || uptime -s)"
echo "  uptime: $(uptime -p 2>/dev/null)"

section "2. Dropbear (SSH tunnel port)"
if systemctl is-active dropbear >/dev/null 2>&1; then
  ok "dropbear.service active"
else
  bad "dropbear.service ไม่ active — journalctl -xeu dropbear -n 30 --no-pager"
fi
ALL_PORTS="${DROPBEAR_MAIN_PORT} ${DROPBEAR_EXTRA_PORTS}"
for p in $ALL_PORTS; do
  if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
    ok "port ${p} (dropbear) กำลัง listen"
  else
    bad "port ${p} (dropbear) ไม่มีใคร listen อยู่"
  fi
done

section "3. BadVPN UDP Gateway (2 instance, แยก core)"
for s in badvpn-udpgw1 badvpn-udpgw2; do
  systemctl is-active "$s" >/dev/null 2>&1 && ok "${s} active" || bad "${s} ไม่ active"
done
for p in "$BADVPN_PORT1" "$BADVPN_PORT2"; do
  ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${p} " && ok "udpgw listen (TCP) 127.0.0.1:${p}" || bad "udpgw ไม่ listen ที่ 127.0.0.1:${p}"
done
PID1=$(systemctl show -p MainPID --value badvpn-udpgw1 2>/dev/null)
PID2=$(systemctl show -p MainPID --value badvpn-udpgw2 2>/dev/null)
if [ -n "$PID1" ] && [ "$PID1" != "0" ]; then
  AFF1=$(taskset -cp "$PID1" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ')
  echo "  badvpn-udpgw1 (pid $PID1) CPU affinity: ${AFF1:-อ่านไม่ได้}"
fi
if [ -n "$PID2" ] && [ "$PID2" != "0" ]; then
  AFF2=$(taskset -cp "$PID2" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ')
  echo "  badvpn-udpgw2 (pid $PID2) CPU affinity: ${AFF2:-อ่านไม่ได้}"
fi

section "4. UFW Firewall + DNS lock"
if systemctl is-active ufw >/dev/null 2>&1 || ufw status 2>/dev/null | grep -q "Status: active"; then
  ok "ufw active"
else
  bad "ufw ไม่ active"
fi
if ufw status 2>/dev/null | grep -q "53.*DENY"; then
  ok "ufw deny out port 53 (กัน DNS leak) มีอยู่"
else
  warn "ไม่เจอ rule deny port 53 ใน ufw status (เช็คมือ: ufw status numbered)"
fi
if ufw status 2>/dev/null | grep -q "${DNS_V4_A}.*53"; then
  ok "ufw allow DNS ไป ${DNS_V4_A}:53 มีอยู่"
else
  warn "ไม่เจอ allow rule ไป ${DNS_V4_A}:53"
fi
RESOLV=$(resolvectl dns 2>/dev/null || cat /etc/resolv.conf 2>/dev/null)
if echo "$RESOLV" | grep -q "$DNS_V4_A"; then
  ok "system DNS ใช้ ${DNS_LABEL} (${DNS_V4_A}) จริง"
else
  warn "system DNS ดูไม่ตรงกับ ${DNS_LABEL} ที่ตั้งไว้ — เช็ค: resolvectl status"
fi

section "5. MTU + MSS clamp"
CUR_MTU=$(ip -o link show dev "$IFACE" 2>/dev/null | grep -oP 'mtu \K[0-9]+')
if [ "$CUR_MTU" = "$TUNNEL_MTU" ]; then
  ok "MTU ${IFACE} = ${CUR_MTU} ตรงกับที่ตั้งไว้ (${TUNNEL_MTU})"
else
  bad "MTU ${IFACE} = ${CUR_MTU} แต่ควรเป็น ${TUNNEL_MTU} — เช็ค: systemctl status set-mtu.service"
fi
if iptables -t mangle -S FORWARD 2>/dev/null | grep -q TCPMSS; then
  ok "MSS clamp rule (mangle FORWARD) มีอยู่"
else
  bad "ไม่เจอ MSS clamp rule — เช็ค: systemctl status mss-clamp.service"
fi

section "6. Sysctl (BBR + CAKE + forwarding)"
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[ "$CC" = "bbr" ] && ok "tcp_congestion_control = bbr" || bad "tcp_congestion_control = ${CC} (ควรเป็น bbr)"
QD=$(sysctl -n net.core.default_qdisc 2>/dev/null)
[ "$QD" = "cake" ] && ok "default_qdisc = cake" || bad "default_qdisc = ${QD} (ควรเป็น cake)"
FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
[ "$FWD" = "1" ] && ok "ip_forward = 1" || bad "ip_forward = ${FWD} (ควรเป็น 1)"
BBR_LOADED=$(lsmod | grep -c tcp_bbr)
[ "$BBR_LOADED" -gt 0 ] && ok "kernel module tcp_bbr โหลดอยู่" || warn "module tcp_bbr ไม่โหลด (อาจ built-in อยู่แล้วในเคอร์เนลนี้ ไม่ต้องกังวลถ้า sysctl ข้างบน = bbr)"

section "7. Per-user Shaper (HTB root + CAKE, ทั้ง down/up)"
systemctl is-active tunnel-shaper >/dev/null 2>&1 && ok "tunnel-shaper.service active" || bad "tunnel-shaper.service ไม่ active"
if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "htb 1:"; then
  ok "HTB root qdisc มีอยู่บน ${IFACE} (ขาดาวน์โหลด)"
else
  bad "ไม่เจอ HTB root qdisc บน ${IFACE} — เช็ค: journalctl -u tunnel-shaper -n 30 --no-pager"
fi
if ip link show ifb0 >/dev/null 2>&1; then
  ok "ifb0 มีอยู่ (สำหรับ shape ขาอัพโหลด)"
  if tc qdisc show dev ifb0 2>/dev/null | grep -q "htb 1:"; then
    ok "HTB root qdisc มีอยู่บน ifb0 (ขาอัพโหลด)"
  else
    bad "ไม่เจอ HTB root qdisc บน ifb0"
  fi
else
  bad "ไม่มี interface ifb0 — โมดูล ifb อาจไม่ถูกโหลด"
fi
if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q ingress; then
  ok "ingress redirect (mirred -> ifb0) ตั้งอยู่"
else
  bad "ไม่เจอ ingress qdisc บน ${IFACE}"
fi
NUSER=$(wc -l < /var/run/tunnel-shaper/ip_classid.map 2>/dev/null || echo 0)
echo "  จำนวน user ที่ shaper กำลังคุมอยู่ตอนนี้: ${NUSER} (0 = ปกติถ้ายังไม่มีใครต่อ)"

section "8. RPS (กระจาย core)"
systemctl is-active set-rps >/dev/null 2>&1 && ok "set-rps.service active" || bad "set-rps.service ไม่ active"
RPS_SAMPLE=$(cat /sys/class/net/"${IFACE}"/queues/rx-0/rps_cpus 2>/dev/null)
if echo "$RPS_SAMPLE" | grep -qE '^0+$'; then
  warn "rps_cpus บน ${IFACE} rx-0 = ${RPS_SAMPLE:-อ่านไม่ได้} (ยังเป็น 0)"
elif [ -n "$RPS_SAMPLE" ]; then
  ok "rps_cpus บน ${IFACE} rx-0 = ${RPS_SAMPLE} (ไม่ใช่ 0 = ทำงานอยู่)"
else
  warn "rps_cpus บน ${IFACE} rx-0 อ่านไม่ได้"
fi

section "9. Safe-reboot timer"
systemctl is-active safe-reboot.timer >/dev/null 2>&1 && ok "safe-reboot.timer active" || bad "safe-reboot.timer ไม่ active"
systemctl list-timers safe-reboot.timer --no-pager 2>/dev/null | sed -n '2p' | awk '{print "  รอบถัดไป: "$0}'

section "10. udpgw-loadbalance (ถ้าเคยรัน patch นี้)"
if systemctl list-unit-files 2>/dev/null | grep -q '^udpgw-loadbalance.service'; then
  systemctl is-active udpgw-loadbalance >/dev/null 2>&1 && ok "udpgw-loadbalance.service active" || bad "udpgw-loadbalance.service ไม่ active"
  if iptables -t nat -S OUTPUT 2>/dev/null | grep -q "dport ${BADVPN_PORT1} .*nth"; then
    ok "NAT load-balance rule (${BADVPN_PORT1} -> ${BADVPN_PORT2} ครึ่งหนึ่ง) มีอยู่"
  else
    bad "ไม่เจอ NAT load-balance rule — เช็ค: iptables -t nat -L OUTPUT -n --line-numbers"
  fi
else
  warn "ยังไม่เคยรัน udpgw-loadbalance-patch.sh (ข้ามได้ถ้าตั้งใจไม่ใช้)"
fi

section "11. udp-custom (ถ้าเคยรัน post-udpcustom-patch.sh)"
if [ -n "${UDP_CUSTOM_PORT:-}" ]; then
  echo "  UDP_CUSTOM_PORT ที่บันทึกไว้ = ${UDP_CUSTOM_PORT}"
  if systemctl list-unit-files 2>/dev/null | grep -q '^udp-custom.service'; then
    systemctl is-active udp-custom >/dev/null 2>&1 && ok "udp-custom.service active" || bad "udp-custom.service ไม่ active"
  else
    warn "ไม่เจอ udp-custom.service (ชื่อ unit อาจต่างออกไป เช็คมือ: systemctl list-units | grep -i udp)"
  fi
  if ss -ulnp 2>/dev/null | grep -q ":${UDP_CUSTOM_PORT} "; then
    ok "udp-custom listen port ${UDP_CUSTOM_PORT} จริง"
  else
    bad "ไม่มีใคร listen udp port ${UDP_CUSTOM_PORT}"
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^udpgw.service'; then
    ST=$(systemctl is-enabled udpgw.service 2>/dev/null)
    [ "$ST" = "disabled" ] && ok "udpgw.service (ตัวซ้ำจาก udp-custom) ปิดอยู่แล้ว" || warn "udpgw.service ยัง enabled อยู่ (ควรปิด กันซ้ำกับ badvpn-udpgw1/2)"
  fi
else
  warn "ยังไม่เคยรัน post-udpcustom-patch.sh (UDP_CUSTOM_PORT ว่าง) — ข้ามได้ถ้าตั้งใจไม่ใช้"
fi

section "12. irqbalance (ถ้าเคยรัน patch สุดท้าย)"
if command -v irqbalance >/dev/null 2>&1; then
  systemctl is-active irqbalance >/dev/null 2>&1 && ok "irqbalance active" || warn "irqbalance ติดตั้งแล้วแต่ไม่ active"
else
  warn "ยังไม่ได้ติดตั้ง irqbalance"
fi

section "13. Conntrack / เพดานการเชื่อมต่อ"
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
CT_CUR=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
echo "  conntrack: ${CT_CUR:-?} / ${CT_MAX:-?}"

section "สรุป"
echo -e "  ${GREEN}ผ่าน: ${PASS}${NC}   ${YELLOW}เตือน: ${WARN}${NC}   ${RED}ไม่ผ่าน: ${FAIL}${NC}"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}ระบบดูปกติหลังรีบูต ไม่มี service ไหนพัง${NC}"
else
  echo -e "${RED}มี ${FAIL} รายการไม่ผ่าน ดูรายละเอียดคำสั่งที่แนะนำไว้ในแต่ละหัวข้อด้านบน${NC}"
fi
echo ""
echo "คำสั่งเสริมเช็คแบบ real-time:"
echo "  journalctl -t tunnel-shaper -f"
echo "  journalctl -t safe-reboot -f"
echo "  tc -s qdisc show dev ${IFACE}"
echo "  tc -s qdisc show dev ifb0"
echo "  watch -n2 'ss -tn state established | grep -E \":(${DROPBEAR_MAIN_PORT// /|:})\"'"
