#!/bin/bash
# ============================================================
#  VPS Setup Verifier — VMESS WS | BBR | CAKE | 3x-ui
#  รันด้วย: sudo bash check-vps.sh
# ============================================================
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
M='\033[0;35m'; B='\033[1m'; N='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()   { echo -e "  ${G}✔${N}  $1"; ((PASS++)); }
fail() { echo -e "  ${R}✘${N}  $1"; ((FAIL++)); }
warn() { echo -e "  ${Y}⚠${N}  $1"; ((WARN++)); }
sec()  {
  echo ""
  echo -e "${B}${C}┌─────────────────────────────────────────┐${N}"
  printf "${B}${C}│  %-39s│${N}\n" "$1"
  echo -e "${B}${C}└─────────────────────────────────────────┘${N}"
}
chk() {
  # chk "label" <condition 0=pass>
  local label="$1"; shift
  if "$@" &>/dev/null; then ok "$label"; else fail "$label"; fi
}

[[ $EUID -ne 0 ]] && { echo "รันด้วย: sudo bash $0"; exit 1; }

ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
PUBIP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${B}${C}  ╔══════════════════════════════════════════╗${N}"
echo -e "${B}${C}  ║      VPS SETUP VERIFIER v1.0             ║${N}"
echo -e "${B}${C}  ╚══════════════════════════════════════════╝${N}"
echo -e "  Interface : ${Y}${ETH:-unknown}${N}  |  IP: ${Y}${PUBIP}${N}"
echo ""

# ──────────────────────────────────────────────
sec "1 · SWAP"
# ──────────────────────────────────────────────
if swapon --show | grep -q /swapfile; then
  SWAPSZ=$(swapon --show --bytes | awk '/swapfile/{printf "%.0fMB", $3/1024/1024}')
  ok "Swap active: $SWAPSZ"
else
  fail "Swap ไม่ได้ active"
fi
grep -q '/swapfile' /etc/fstab && ok "Swap ใน /etc/fstab (persistent)" || fail "Swap ไม่มีใน /etc/fstab"

# ──────────────────────────────────────────────
sec "2 · FIREWALL & PORTS"
# ──────────────────────────────────────────────
PORTS=(80 443 2053 2083 2087 2096 8080 8443 54321)
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  for p in "${PORTS[@]}"; do
    ufw status | grep -q "$p" && ok "UFW: $p open" || warn "UFW: $p ไม่พบ rule (อาจเปิดอยู่แล้ว)"
  done
else
  warn "UFW inactive หรือไม่ติดตั้ง"
fi
for p in "${PORTS[@]}"; do
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && ok "iptables: $p ACCEPT" || warn "iptables: $p ไม่มี rule"
done

# ──────────────────────────────────────────────
sec "3 · 3x-ui SERVICE"
# ──────────────────────────────────────────────
systemctl is-active --quiet x-ui && ok "x-ui: active (running)" || fail "x-ui: ไม่ได้ running"
systemctl is-enabled --quiet x-ui && ok "x-ui: enabled (auto-start)" || warn "x-ui: ไม่ได้ enable"

XRAY_PID=$(pgrep -x xray 2>/dev/null | head -1 || true)
if [[ -n "$XRAY_PID" ]]; then
  ok "xray: running (pid=$XRAY_PID)"
  # taskset
  CPUMASK=$(taskset -cp "$XRAY_PID" 2>/dev/null | grep -oE '[0-9,-]+$' || echo "?")
  [[ "$CPUMASK" == "0" ]] && ok "xray taskset: CPU0 only" || warn "xray taskset: $CPUMASK (ควรเป็น 0)"
  # ionice
  IONC=$(ionice -p "$XRAY_PID" 2>/dev/null || echo "?")
  echo "$IONC" | grep -qi "realtime" && ok "xray ionice: realtime" || warn "xray ionice: $IONC"
else
  fail "xray: process ไม่พบ"
fi

PANEL_PORT=$(x-ui settings 2>/dev/null | grep -i "port" | grep -oE '[0-9]{2,5}' | head -1 || echo "54321")
PANEL_PORT=${PANEL_PORT:-54321}
ss -tlnp | grep -q ":$PANEL_PORT " && ok "x-ui panel port $PANEL_PORT: listening" || warn "panel port $PANEL_PORT: ไม่พบ (อาจใช้ port อื่น)"

# ──────────────────────────────────────────────
sec "4 · SYSTEM LIMITS"
# ──────────────────────────────────────────────
HN=$(ulimit -Hn 2>/dev/null || echo 0)
SN=$(ulimit -Sn 2>/dev/null || echo 0)
[[ "$HN" -ge 1000000 ]] && ok "hard nofile: $HN" || fail "hard nofile: $HN (ต้องการ ≥1000000 — มีผลหลัง reboot)"
[[ "$SN" -ge 1000000 ]] && ok "soft nofile: $SN" || warn "soft nofile: $SN (มีผลหลัง reboot)"

FM=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
[[ "$FM" -ge 1000000 ]] && ok "fs.file-max: $FM" || fail "fs.file-max: $FM"

[[ -f /etc/security/limits.d/99-xui.conf ]] && ok "limits.d/99-xui.conf: มีไฟล์" || fail "limits.d/99-xui.conf: ไม่มี"
[[ -f /etc/systemd/system/x-ui.service.d/limits.conf ]] && ok "x-ui systemd limits.conf: มีไฟล์" || fail "x-ui systemd limits.conf: ไม่มี"

# ──────────────────────────────────────────────
sec "5 · SYSCTL — TCP/BBR/BUFFER"
# ──────────────────────────────────────────────
chk_sysctl() {
  local key="$1" want="$2"
  local got
  got=$(sysctl -n "$key" 2>/dev/null || echo "NOT_FOUND")
  if [[ "$got" == "$want" ]]; then
    ok "$key = $got"
  else
    fail "$key = $got (ต้องการ: $want)"
  fi
}
chk_sysctl net.ipv4.tcp_congestion_control bbr
chk_sysctl net.core.default_qdisc fq
chk_sysctl net.core.rmem_max 67108864
chk_sysctl net.core.wmem_max 67108864
chk_sysctl net.ipv4.tcp_fastopen 3
chk_sysctl net.ipv4.tcp_keepalive_time 8
chk_sysctl net.ipv4.tcp_keepalive_intvl 2
chk_sysctl net.ipv4.tcp_keepalive_probes 4
chk_sysctl net.ipv4.tcp_limit_output_bytes 655360
chk_sysctl net.ipv4.tcp_mtu_probing 1
chk_sysctl net.ipv4.tcp_notsent_lowat 32768
chk_sysctl net.ipv4.tcp_autocorking 0
chk_sysctl net.ipv4.tcp_slow_start_after_idle 0
chk_sysctl net.core.somaxconn 65535
chk_sysctl net.ipv4.tcp_tw_reuse 1
chk_sysctl net.ipv4.tcp_fin_timeout 5
chk_sysctl net.ipv4.ip_forward 1
chk_sysctl vm.swappiness 5
chk_sysctl net.ipv4.tcp_sack 1
chk_sysctl net.ipv4.tcp_ecn 1

HGP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "?")
echo "$HGP" | grep -q "\[madvise\]" && ok "transparent_hugepage: madvise" || fail "transparent_hugepage: $HGP"

lsmod | grep -q tcp_bbr && ok "module tcp_bbr: loaded" || warn "tcp_bbr: ไม่โหลดเป็น module (อาจ built-in)"

[[ -f /etc/sysctl.d/99-ais-vmess.conf ]] && ok "sysctl config: /etc/sysctl.d/99-ais-vmess.conf มีไฟล์" || fail "sysctl config: ไม่มีไฟล์"

# ──────────────────────────────────────────────
sec "6 · ETHTOOL OFFLOAD"
# ──────────────────────────────────────────────
if command -v ethtool &>/dev/null && [[ -n "$ETH" ]]; then
  FEAT=$(ethtool -k "$ETH" 2>/dev/null || true)
  echo "$FEAT" | grep -q "generic-receive-offload: off" && ok "GRO: off" || warn "GRO: อาจยังเปิดอยู่ (virtio อาจไม่ support)"
  echo "$FEAT" | grep -q "large-receive-offload: off" && ok "LRO: off" || warn "LRO: อาจยังเปิดอยู่"
  echo "$FEAT" | grep -q "tcp-segmentation-offload: on" && ok "TSO: on" || warn "TSO: off หรือไม่ support"
  echo "$FEAT" | grep -q "generic-segmentation-offload: on" && ok "GSO: on" || warn "GSO: off หรือไม่ support"
  [[ -f /etc/networkd-dispatcher/routable.d/51-ethtool ]] && ok "ethtool persistence: มีไฟล์" || fail "ethtool persistence: ไม่มีไฟล์"
else
  warn "ethtool ไม่พบ หรือ ETH interface ไม่ชัดเจน"
fi

# ──────────────────────────────────────────────
sec "7 · QDISC (CAKE / fq_codel)"
# ──────────────────────────────────────────────
QDISC=$(tc qdisc show dev "$ETH" 2>/dev/null || echo "")
if echo "$QDISC" | grep -q "cake"; then
  ok "qdisc: CAKE active"
  echo "$QDISC" | grep -q "500Mbit" && ok "CAKE bandwidth: 500Mbit" || fail "CAKE bandwidth: ไม่ใช่ 500Mbit"
  echo "$QDISC" | grep -q "rtt 25ms" && ok "CAKE rtt: 25ms" || fail "CAKE rtt: ไม่ใช่ 25ms"
  echo "$QDISC" | grep -q "besteffort" && ok "CAKE mode: besteffort" || warn "CAKE mode: ไม่ใช่ besteffort"
elif echo "$QDISC" | grep -q "fq_codel"; then
  warn "qdisc: fq_codel (fallback — sch_cake อาจไม่ available ใน kernel นี้)"
  echo "$QDISC" | grep -q "target 1ms" && ok "fq_codel target: 1ms" || warn "fq_codel target: ไม่ตรง"
else
  fail "qdisc: ไม่มี CAKE หรือ fq_codel (got: $QDISC)"
fi

TXQ=$(ip link show "$ETH" 2>/dev/null | grep -oE 'qlen [0-9]+' | awk '{print $2}' || echo 0)
[[ "$TXQ" -ge 4096 ]] && ok "txqueuelen: $TXQ" || warn "txqueuelen: $TXQ (ต้องการ ≥4096)"

# persistence files
[[ -f /etc/networkd-dispatcher/routable.d/50-cake ]] && ok "CAKE networkd-dispatcher: มีไฟล์" || fail "CAKE networkd-dispatcher: ไม่มีไฟล์"
systemctl is-enabled --quiet cake-qdisc.service 2>/dev/null && ok "cake-qdisc.service: enabled" || fail "cake-qdisc.service: ไม่ได้ enable"
grep -q "50-cake" /etc/rc.local 2>/dev/null && ok "rc.local fallback: มี" || warn "rc.local fallback: ไม่มี"
[[ -f /etc/network/if-up.d/cake ]] && ok "if-up.d/cake: มีไฟล์" || warn "if-up.d/cake: ไม่มีไฟล์"

# ──────────────────────────────────────────────
sec "8 · VMESS WS SOCKOPT PATCHER"
# ──────────────────────────────────────────────
[[ -f /usr/local/bin/xui-ws-patch.py ]] && ok "xui-ws-patch.py: มีไฟล์" || fail "xui-ws-patch.py: ไม่มีไฟล์"
[[ -f /etc/systemd/system/x-ui.service.d/ws-patch.conf ]] && ok "ws-patch.conf: มีไฟล์" || fail "ws-patch.conf: ไม่มีไฟล์"

# ตรวจ config จริงที่ xray ใช้
CFG_PATHS=(
  "/usr/local/x-ui/bin/config.json"
  "/etc/x-ui/config.json"
  "/root/x-ui/bin/config.json"
)
CFG_FOUND=""
for p in "${CFG_PATHS[@]}"; do
  [[ -f "$p" ]] && CFG_FOUND="$p" && break
done

if [[ -n "$CFG_FOUND" ]]; then
  ok "xray config: $CFG_FOUND"
  python3 - "$CFG_FOUND" << 'PYEOF'
import json, sys
path = sys.argv[1]
WANT = {
    "tcpNoDelay": True,
    "tcpKeepAliveIdle": 8,
    "tcpKeepAliveInterval": 2,
    "tcpFastOpen": True,
    "tcpMaxSeg": 1360,
}
G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
try:
    cfg = json.load(open(path))
    inbounds = cfg.get("inbounds") or []
    if not inbounds:
        print(f"  {R}✘{N}  config: ไม่มี inbounds (ยังไม่ได้ตั้งค่าใน panel)")
        sys.exit(0)
    for i, ib in enumerate(inbounds):
        so = ib.get("streamSettings", {}).get("sockopt", {})
        for k, v in WANT.items():
            got = so.get(k)
            if got == v:
                print(f"  {G}✔{N}  inbound[{i}] sockopt.{k} = {got}")
            else:
                print(f"  {R}✘{N}  inbound[{i}] sockopt.{k} = {got!r} (ต้องการ {v!r})")
except Exception as e:
    print(f"  {R}✘{N}  อ่าน config ไม่ได้: {e}")
PYEOF
else
  warn "xray config.json ยังไม่มี (ปกติถ้ายังไม่ได้สร้าง inbound ใน panel)"
fi

GOMAXPROCS=$(grep -r "GOMAXPROCS" /etc/systemd/system/x-ui.service.d/ 2>/dev/null | grep -oE 'GOMAXPROCS=[0-9]+' | head -1 || echo "NOT_SET")
[[ "$GOMAXPROCS" == "GOMAXPROCS=1" ]] && ok "GOMAXPROCS=1" || fail "GOMAXPROCS: $GOMAXPROCS"

# ──────────────────────────────────────────────
sec "9 · CPU / IRQ"
# ──────────────────────────────────────────────
ETH_IRQ=$(grep "$ETH" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1 || true)
if [[ -n "$ETH_IRQ" ]]; then
  AFFINITY=$(cat /proc/irq/$ETH_IRQ/smp_affinity 2>/dev/null || echo "?")
  [[ "$AFFINITY" == "1" ]] && ok "NIC IRQ $ETH_IRQ affinity: CPU0 (0x1)" || warn "NIC IRQ affinity: $AFFINITY"
else
  warn "ไม่พบ dedicated NIC IRQ (virtio/KVM — ปกติ)"
fi

if ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null | grep -q governor; then
  GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
  [[ "$GOV" == "performance" ]] && ok "CPU governor: $GOV" || warn "CPU governor: $GOV (ต้องการ performance)"
else
  warn "scaling_governor ไม่พบ (host controls — ปกติสำหรับ VPS)"
fi

# ──────────────────────────────────────────────
sec "10 · LISTENING PORTS"
# ──────────────────────────────────────────────
for p in "${PORTS[@]}"; do
  ss -tlnp 2>/dev/null | grep -q ":$p " && ok "port $p: listening" || warn "port $p: ไม่ได้ listen (อาจยังไม่ได้ตั้ง inbound)"
done

# ──────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────
TOTAL=$((PASS + FAIL + WARN))
PCT=$((PASS * 100 / TOTAL))

echo ""
echo -e "${B}${C}╔══════════════════════════════════════════╗${N}"
echo -e "${B}${C}║              SUMMARY                    ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════╝${N}"
echo ""
echo -e "  ${G}✔ PASS${N}  : ${B}$PASS${N} / $TOTAL"
echo -e "  ${Y}⚠ WARN${N}  : ${B}$WARN${N}  (ไม่ใช่ error — ตรวจสอบเอง)"
echo -e "  ${R}✘ FAIL${N}  : ${B}$FAIL${N}"
echo ""

if   [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
  echo -e "  ${G}${B}★ 100% พร้อม deploy ไม่มีปัญหาเลย!${N}"
elif [[ $FAIL -eq 0 ]]; then
  echo -e "  ${G}${B}✔ PASS ทุก critical check — WARN บางตัวไม่กระทบการทำงาน${N}"
elif [[ $FAIL -le 3 ]]; then
  echo -e "  ${Y}${B}⚠ มี $FAIL ข้อที่ FAIL — ควรแก้ก่อนใช้งาน production${N}"
else
  echo -e "  ${R}${B}✘ มี $FAIL ข้อ FAIL — script อาจยังทำงานไม่สมบูรณ์${N}"
fi

echo ""
echo -e "  ${Y}▸ panel   : http://${PUBIP}:${PANEL_PORT}${N}"
echo -e "  ${Y}▸ หลัง reboot ค่อยรัน script นี้ใหม่ เพื่อตรวจ nofile${N}"
echo ""
