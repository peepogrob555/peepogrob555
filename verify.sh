#!/bin/bash
# verify-tunnel-qos.sh — เช็คสถานะจริงของทุกอย่างที่ tunnel-qos.sh ตั้งค่าไว้
# ใช้: sudo bash verify-tunnel-qos.sh

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

TUNNEL_QOS_CONF="/etc/tunnel-qos.conf"
UDP_CUSTOM_CONFIG="${UDP_CUSTOM_CONFIG:-/root/udp/config.json}"
UDPGW_SERVICE="/etc/systemd/system/udpgw.service"

ok()    { echo -e "  ${GREEN}✔${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
bad()   { echo -e "  ${RED}✘${NC} $1"; }
info()  { echo -e "  ${CYAN}ℹ${NC} $1"; }
head1() { echo ""; echo -e "${BOLD}== $1 ==${NC}"; }

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

if [ ! -f "$TUNNEL_QOS_CONF" ]; then
  bad "ไม่พบ $TUNNEL_QOS_CONF — ยังไม่เคยรัน tunnel-qos.sh"
  exit 1
fi
# shellcheck disable=SC1090
source "$TUNNEL_QOS_CONF"

echo -e "${BOLD}=================================================="
echo " TUNNEL QOS VERIFY REPORT - $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "==================================================${NC}"

head1 "1) Interface & MTU"
CUR_MTU=$(ip -o link show "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="mtu") print $(i+1)}')
info "IFACE=$IFACE"
if [ "$CUR_MTU" = "$TUNNEL_MTU" ]; then
  ok "MTU ปัจจุบัน=$CUR_MTU (ตรงกับที่ตั้งไว้)"
else
  warn "MTU ปัจจุบัน=$CUR_MTU ต่างจากที่ตั้งไว้ ($TUNNEL_MTU)"
fi
systemctl is-active --quiet set-mtu.service && ok "set-mtu.service: active" || bad "set-mtu.service: ไม่ active"

head1 "2) CAKE QoS shaping (download/upload แยกฝั่ง)"
if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q cake; then
  ok "CAKE บน $IFACE (download/egress) ทำงานอยู่:"
  tc qdisc show dev "$IFACE" | grep cake | sed 's/^/      /'
else
  bad "ไม่พบ CAKE qdisc บน $IFACE"
fi
if ip link show ifb0 &>/dev/null && tc qdisc show dev ifb0 2>/dev/null | grep -q cake; then
  ok "CAKE บน ifb0 (upload/ingress redirect) ทำงานอยู่:"
  tc qdisc show dev ifb0 | grep cake | sed 's/^/      /'
else
  bad "ไม่พบ CAKE qdisc บน ifb0 (upload shaping)"
fi
info "ตั้งไว้ใน config: Download=${DOWNLOAD_SHAPE_MBIT}mbit | Upload=${UPLOAD_SHAPE_MBIT}mbit | RTT=${RTT_MS}ms"
systemctl is-active --quiet tunnel-shaper.service && ok "tunnel-shaper.service: active" || bad "tunnel-shaper.service: ไม่ active"

head1 "3) Kernel network sysctl"
declare -A EXPECT_SYSCTL=(
  ["net.ipv4.tcp_congestion_control"]="bbr"
  ["net.core.default_qdisc"]="cake"
  ["net.ipv4.ip_forward"]="1"
)
for k in "${!EXPECT_SYSCTL[@]}"; do
  v=$(sysctl -n "$k" 2>/dev/null)
  if [ "$v" = "${EXPECT_SYSCTL[$k]}" ]; then
    ok "$k = $v"
  else
    warn "$k = $v (คาดหวัง ${EXPECT_SYSCTL[$k]})"
  fi
done
info "core.rmem_max = $(sysctl -n net.core.rmem_max 2>/dev/null) bytes"
info "core.wmem_max = $(sysctl -n net.core.wmem_max 2>/dev/null) bytes"
info "tcp_rmem = $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
info "tcp_wmem = $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
info "rps_sock_flow_entries = $(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)"

RMEM_CEILING=33554432
EXP_BDP_DOWN=$(( DOWNLOAD_SHAPE_MBIT * 1000000 / 8 * RTT_MS / 1000 ))
EXP_BDP_UP=$(( UPLOAD_SHAPE_MBIT * 1000000 / 8 * RTT_MS / 1000 ))
EXP_RMEM_MAX=$(( EXP_BDP_DOWN * 4 ))
EXP_WMEM_MAX=$(( EXP_BDP_UP * 4 ))
[ "$EXP_RMEM_MAX" -gt "$RMEM_CEILING" ] && EXP_RMEM_MAX=$RMEM_CEILING
[ "$EXP_WMEM_MAX" -gt "$RMEM_CEILING" ] && EXP_WMEM_MAX=$RMEM_CEILING
LIVE_RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null)
LIVE_WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null)
LIVE_TCP_RMEM_MAX=$(awk '{print $3}' <<< "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)")
LIVE_TCP_WMEM_MAX=$(awk '{print $3}' <<< "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)")
if [ "$LIVE_RMEM_MAX" = "$EXP_RMEM_MAX" ] && [ "$LIVE_TCP_RMEM_MAX" = "$EXP_RMEM_MAX" ]; then
  ok "ไม่มี lock: rmem ceiling = เต็ม pipe (${EXP_RMEM_MAX} bytes) ตรงทั้ง core.rmem_max และ tcp_rmem[max]"
else
  warn "rmem ceiling ไม่ตรงที่คำนวณไว้ - คาดหวัง ${EXP_RMEM_MAX} แต่ core.rmem_max=${LIVE_RMEM_MAX} tcp_rmem[max]=${LIVE_TCP_RMEM_MAX} (เช็คว่ามีอะไรมาทับทีหลังหรือเปล่า)"
fi
if [ "$LIVE_WMEM_MAX" = "$EXP_WMEM_MAX" ] && [ "$LIVE_TCP_WMEM_MAX" = "$EXP_WMEM_MAX" ]; then
  ok "ไม่มี lock: wmem ceiling = เต็ม pipe (${EXP_WMEM_MAX} bytes) ตรงทั้ง core.wmem_max และ tcp_wmem[max]"
else
  warn "wmem ceiling ไม่ตรงที่คำนวณไว้ - คาดหวัง ${EXP_WMEM_MAX} แต่ core.wmem_max=${LIVE_WMEM_MAX} tcp_wmem[max]=${LIVE_TCP_WMEM_MAX} (เช็คว่ามีอะไรมาทับทีหลังหรือเปล่า)"
fi

head1 "4) Conntrack"
CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
CT_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
info "ใช้อยู่ ${CT_COUNT} / ${CT_MAX}"
HASH=$(cat /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || echo "?")
info "hashsize=${HASH}"

head1 "5) RPS/RFS + irqbalance"
systemctl is-active --quiet irqbalance && ok "irqbalance: active" || bad "irqbalance: ไม่ active"
systemctl is-active --quiet set-rps.service && ok "set-rps.service: active" || bad "set-rps.service: ไม่ active"
for rx in /sys/class/net/"$IFACE"/queues/rx-*/rps_cpus; do
  [ -e "$rx" ] && info "$IFACE $(basename "$(dirname "$rx")") rps_cpus=$(cat "$rx")"
done
for rf in /sys/class/net/"$IFACE"/queues/rx-*/rps_flow_cnt; do
  [ -e "$rf" ] && info "$IFACE $(basename "$(dirname "$rf")") rps_flow_cnt=$(cat "$rf")"
done
if ip link show ifb0 &>/dev/null; then
  for rx in /sys/class/net/ifb0/queues/rx-*/rps_cpus; do
    [ -e "$rx" ] && info "ifb0 $(basename "$(dirname "$rx")") rps_cpus=$(cat "$rx")"
  done
fi

head1 "6) MSS clamp"
systemctl is-active --quiet mss-clamp.service && ok "mss-clamp.service: active" || bad "mss-clamp.service: ไม่ active"
if iptables -t mangle -S 2>/dev/null | grep -q TCPMSS; then
  ok "พบ iptables TCPMSS rule:"
  iptables -t mangle -S | grep TCPMSS | sed 's/^/      /'
else
  bad "ไม่พบ TCPMSS rule"
fi

head1 "7) DNS lock"
info "ตั้งไว้ใน config: ${DNS_LABEL} (${DNS_V4_A}, ${DNS_V4_B}, ${DNS_V6_A}, ${DNS_V6_B})"
if [ -f /etc/systemd/resolved.conf ]; then
  CUR_DNS=$(grep -E '^DNS=' /etc/systemd/resolved.conf | cut -d= -f2)
  if echo "$CUR_DNS" | grep -q "$DNS_V4_A"; then
    ok "resolved.conf DNS=$CUR_DNS"
  else
    warn "resolved.conf DNS=$CUR_DNS (ไม่ตรงกับที่ตั้งไว้)"
  fi
else
  bad "ไม่พบ /etc/systemd/resolved.conf"
fi
if [ -d /etc/systemd/resolved.conf.d ] && [ -z "$(ls -A /etc/systemd/resolved.conf.d 2>/dev/null)" ]; then
  ok "resolved.conf.d ว่าง (ไม่มี drop-in ค้าง)"
else
  warn "resolved.conf.d ยังมีไฟล์ค้างอยู่: $(ls /etc/systemd/resolved.conf.d 2>/dev/null | tr '\n' ' ')"
fi
if [ -f /etc/netplan/90-dns-override.yaml ]; then
  warn "ยังมีไฟล์ 90-dns-override.yaml ค้างอยู่"
else
  ok "ไม่มีไฟล์ 90-dns-override.yaml ค้าง"
fi
if grep -lE '8\.8\.4\.4|1\.0\.0\.1' /etc/netplan/*.yaml >/dev/null 2>&1; then
  warn "ยังพบ DNS IP เก่าค้างใน netplan"
else
  ok "ไม่พบ DNS IP เก่าค้างใน netplan"
fi
if [ -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ]; then
  ok "ปิด cloud-init network config แล้ว (กัน netplan ถูกเขียนทับตอน reboot)"
else
  warn "ไม่พบ /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg - netplan อาจถูกคืนค่าเดิมตอน reboot"
fi
if grep -lE '^\s*nameservers:' /etc/netplan/*.yaml >/dev/null 2>&1; then
  warn "ยังมี per-link nameservers: block ค้างใน netplan (DNS อาจโดน override เฉพาะ interface)"
else
  ok "ไม่มี per-link nameservers: block ใน netplan แล้ว"
fi
resolvectl status 2>/dev/null | grep -A2 "Current DNS Server\|DNS Servers" | sed 's/^/      /'

head1 "8) UFW"
ufw status verbose 2>/dev/null | sed -n '1,15p' | sed 's/^/      /'

head1 "9) Swap"
swapon --show 2>/dev/null | sed 's/^/      /'
free -h | sed 's/^/      /'

head1 "10) udp-custom buffer"
if [ -f "$UDP_CUSTOM_CONFIG" ]; then
  RB=$(jq -r '.receive_buffer // "N/A"' "$UDP_CUSTOM_CONFIG" 2>/dev/null)
  SB=$(jq -r '.stream_buffer // "N/A"' "$UDP_CUSTOM_CONFIG" 2>/dev/null)
  info "receive_buffer=${RB} bytes | stream_buffer=${SB} bytes"
  systemctl is-active --quiet udp-custom && ok "udp-custom: active" || warn "udp-custom: ไม่ active"
else
  bad "ไม่พบ $UDP_CUSTOM_CONFIG"
fi
UDP_CUSTOM_SERVICE="/etc/systemd/system/udp-custom.service"
if [ -f "$UDP_CUSTOM_SERVICE" ] && grep -q '99-tunnel-optimize' "$UDP_CUSTOM_SERVICE"; then
  ok "udp-custom.service มี ExecStartPost re-apply sysctl (กัน binary เขียนทับ rmem/wmem เอง)"
else
  warn "udp-custom.service ไม่มี ExecStartPost re-apply - ถ้า binary auto-tune เอง ค่า rmem/wmem อาจโดนทับกลับตอน restart"
fi
CUR_RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null)
if [ "$CUR_RMEM" != "$EXP_RMEM_MAX" ]; then
  warn "core.rmem_max ตอนนี้ (${CUR_RMEM}) ไม่ตรงที่ควรเป็น (${EXP_RMEM_MAX}) - อาจโดนทับหลัง udp-custom restart ล่าสุด ลอง: systemctl restart udp-custom แล้วรอ 5 วิค่อยเช็คซ้ำ"
fi

head1 "11) udpgw (badvpn)"
if [ -f "$UDPGW_SERVICE" ]; then
  PORT=$(grep -oP '127\.0\.0\.1:\K[0-9]+' "$UDPGW_SERVICE" | head -1)
  MC=$(grep -oP -- '--max-clients \K[0-9]+' "$UDPGW_SERVICE")
  MCC=$(grep -oP -- '--max-connections-for-client \K[0-9]+' "$UDPGW_SERVICE")
  info "listen port=${PORT} | max-clients=${MC} | max-connections-for-client=${MCC}"
  systemctl is-active --quiet udpgw && ok "udpgw: active" || warn "udpgw: ไม่ active"
else
  bad "ไม่พบ $UDPGW_SERVICE"
fi

head1 "12) Log-to-RAM"
mount | grep -q "on /var/log type tmpfs" && ok "/var/log เป็น tmpfs" || bad "/var/log ไม่ใช่ tmpfs"
STORAGE=$(grep -oP '^Storage=\K.*' /etc/systemd/journald.conf.d/ram-only.conf 2>/dev/null)
if [ "$STORAGE" = "volatile" ]; then ok "journald Storage=volatile"; else warn "journald Storage=${STORAGE:-ไม่พบ}"; fi
systemctl is-active --quiet log-clear.timer && ok "log-clear.timer: active" || warn "log-clear.timer: ไม่ active"
systemctl is-active --quiet log-watchdog.timer && ok "log-watchdog.timer: active" || warn "log-watchdog.timer: ไม่ active"

echo ""
echo -e "${BOLD}=================================================="
echo " จบรายงาน"
echo -e "==================================================${NC}"
