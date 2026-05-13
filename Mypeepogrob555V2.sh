#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║              VPS TUNE SCRIPT — File 2/2                         ║
# ║  Ubuntu 22.04 | Xver Cloud TH | VLESS Reality                   ║
# ║  Profile: AIS 4G/5G 128kbps | 2 Users | Low-Latency First       ║
# ╚══════════════════════════════════════════════════════════════════╝
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR/REPO/main/tune.sh)
#
# ⚠️  ต้องรัน setup.sh ก่อน — tune.sh จะไม่ติดตั้ง package ใหม่

set -euo pipefail

# ─────────────────────────────────────────
#  COLORS & HELPERS
# ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/var/log/vps-tune.log"
exec > >(tee -a "$LOG_FILE") 2>&1

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}━━━ $* ${NC}"; }
pause() {
  echo -e "\n${YELLOW}▶ กด [Enter] เพื่อดำเนินการต่อ — [Ctrl+C] เพื่อหยุด${NC}"
  read -r
}

# ─────────────────────────────────────────
#  ROOT CHECK
# ─────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && err "ต้องรันด้วย root: sudo bash tune.sh"

# ─────────────────────────────────────────
#  DETECT INTERFACE
# ─────────────────────────────────────────
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$IFACE" ] && err "ไม่พบ default network interface"

# ─────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
 ████████╗██╗   ██╗███╗   ██╗███████╗    ███████╗██╗  ██╗
    ██╔══╝██║   ██║████╗  ██║██╔════╝    ██╔════╝██║  ██║
    ██║   ██║   ██║██╔██╗ ██║█████╗      ███████╗███████║
    ██║   ██║   ██║██║╚██╗██║██╔══╝      ╚════██║██╔══██║
    ██║   ╚██████╔╝██║ ╚████║███████╗    ███████║██║  ██║
    ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚══════╝    ╚══════╝╚═╝  ╚═╝
BANNER
echo -e "${NC}"
echo -e "${CYAN}  Kernel Tune: BBR + CAKE + Sysctl — Low Latency Profile${NC}"
echo -e "${CYAN}  Interface: ${BOLD}$IFACE${NC}"
echo -e "  $(date)"
echo ""

# ─────────────────────────────────────────
#  PRE-FLIGHT CHECK
# ─────────────────────────────────────────
step "PRE-FLIGHT — ตรวจสอบระบบ"

KERNEL_VER=$(uname -r)
info "Kernel: $KERNEL_VER"
info "Interface: $IFACE"
info "Virtualization: $(systemd-detect-virt 2>/dev/null || echo 'unknown')"

# ตรวจ CAKE support
CAKE_OK=false
if modprobe sch_cake 2>/dev/null; then
  CAKE_OK=true
  ok "CAKE module: พร้อมใช้งาน"
else
  warn "CAKE module: ไม่พบ — จะใช้ fq_codel แทน"
fi

# ตรวจ IFB support  
IFB_OK=false
if modprobe ifb numifbs=1 2>/dev/null; then
  IFB_OK=true
  ok "IFB module: พร้อมใช้งาน (Ingress shaping enabled)"
else
  warn "IFB module: ไม่พบ — จะ skip ingress shaping"
fi

# ตรวจ BBR
BBR_OK=false
if modprobe tcp_bbr 2>/dev/null; then
  BBR_OK=true
  ok "BBR module: พร้อมใช้งาน"
else
  warn "BBR module: ไม่พบ — จะใช้ cubic แทน"
fi

echo ""
echo -e "${BOLD}สรุปก่อนเริ่ม:${NC}"
echo -e "  BBR   : $($BBR_OK  && echo -e "${GREEN}✅ Active${NC}" || echo -e "${YELLOW}⚠️  Fallback cubic${NC}")"
echo -e "  CAKE  : $($CAKE_OK && echo -e "${GREEN}✅ Active${NC}" || echo -e "${YELLOW}⚠️  Fallback fq_codel${NC}")"
echo -e "  IFB   : $($IFB_OK  && echo -e "${GREEN}✅ Active${NC}" || echo -e "${YELLOW}⚠️  Skip ingress${NC}")"

echo ""
echo -e "${YELLOW}Script จะทำการปรับแต่ง Kernel parameter และ QDisc${NC}"
echo -e "${YELLOW}การตั้งค่าทั้งหมดจะ persist หลัง reboot ผ่าน systemd service${NC}"
pause

# ─────────────────────────────────────────
#  PHASE 1 — BBR ACTIVATION
# ─────────────────────────────────────────
step "PHASE 1/4 — BBR Congestion Control"
info "เปิดใช้งาน BBR — ลด buffer bloat, เพิ่มประสิทธิภาพบน 128kbps"
info "BBR ทำงานโดยประมาณ bandwidth และ RTT แทนการรอ packet loss"

if $BBR_OK; then
  # Load module
  modprobe tcp_bbr

  # Persist module
  if ! grep -q "^tcp_bbr" /etc/modules-load.d/modules.conf 2>/dev/null; then
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
  fi
  echo "tcp_bbr" > /etc/modules-load.d/99-bbr.conf

  # Activate
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  sysctl -w net.core.default_qdisc=cake 2>/dev/null || \
    sysctl -w net.core.default_qdisc=fq_codel

  CC_NOW=$(sysctl -n net.ipv4.tcp_congestion_control)
  ok "Congestion Control: $CC_NOW"
else
  warn "BBR ไม่พร้อม — ใช้ cubic (ประสิทธิภาพต่ำกว่า แต่ยังทำงานได้)"
fi

# ─────────────────────────────────────────
#  PHASE 2 — SYSCTL KERNEL TUNING
# ─────────────────────────────────────────
step "PHASE 2/4 — Kernel Sysctl (Low-Latency Profile)"
info "จูน TCP buffer, ECN, Pacing, Keepalive สำหรับ VLESS 128kbps"
info ""
info "📐 BDP Calculation:"
info "   Bandwidth = 128,000 bps | RTT = 20ms (worst case)"
info "   BDP = 128000 × 0.020 = 2,560 bytes"
info "   TCP buffer ตั้งไว้ใหญ่กว่า BDP ~1600x เพื่อรองรับ burst"
pause

SYSCTL_FILE="/etc/sysctl.d/99-vps-latency.conf"

# Backup ถ้ามีอยู่แล้ว
[ -f "$SYSCTL_FILE" ] && \
  cp "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%s)" && \
  info "Backup เดิมไว้แล้ว"

cat > "$SYSCTL_FILE" << 'SYSCTL_EOF'
# ══════════════════════════════════════════════════════
#  VPS Latency-First Profile
#  Xver Cloud TH | Kernel 5.15.x | 2 users | 128kbps
#  Profile: VLESS Reality :443 | AIS 4G/5G
# ══════════════════════════════════════════════════════

# ── Congestion Control ──────────────────────────────
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake

# ── BBR Pacing ──────────────────────────────────────
# สำหรับ 128kbps: ลด burst ให้น้อยลง
# pacing_ss_ratio: slow-start pace rate (200 = 2x BW estimate)
# pacing_ca_ratio: cong-avoid pace rate (120 = 1.2x BW estimate)
# ⚠️ อย่าเพิ่ม pacing_ca_ratio > 150 — burst จะไปพองที่ AIS buffer
net.ipv4.tcp_pacing_ss_ratio = 200
net.ipv4.tcp_pacing_ca_ratio = 120

# ── TCP Buffers ─────────────────────────────────────
# min(4KB) / default(128KB) / max(4MB)
# default ตั้ง 128KB ให้พอสำหรับ 2 users concurrent
# max ตั้ง 4MB ให้ kernel จัดการ burst ได้
net.ipv4.tcp_rmem = 4096 131072 4194304
net.ipv4.tcp_wmem = 4096 131072 4194304
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.optmem_max = 65536

# ── notsent_lowat ───────────────────────────────────
# KEY SETTING: จำกัด unsent data ใน send buffer
# ลด application latency (VLESS payload รอส่งน้อยลง)
# 16384 = 16KB — เหมาะกับ 128kbps (ส่งได้ ~1วินาที)
# ⚠️ ค่าต่ำกว่า 8192 อาจทำให้ throughput ลดลง
net.ipv4.tcp_notsent_lowat = 16384

# ── TCP Features ────────────────────────────────────
net.ipv4.tcp_fastopen = 3           # TFO client+server (ลด 1 RTT handshake)
net.ipv4.tcp_window_scaling = 1     # Large window support
net.ipv4.tcp_timestamps = 1         # PAWS + accurate RTT measurement
net.ipv4.tcp_sack = 1               # Selective ACK (recovery เร็ว)
net.ipv4.tcp_dsack = 1              # Duplicate SACK
net.ipv4.tcp_fack = 0               # ปิด FACK (ไม่เข้ากับ BBR)
net.ipv4.tcp_low_latency = 1        # Prefer low latency over throughput

# ── ECN (สำคัญมากสำหรับ CAKE) ───────────────────────
# CAKE ใช้ ECN signal แทน packet drop
# → queue สั้นลง, latency ต่ำลง โดยไม่ต้อง drop packet
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1       # Fallback ถ้า peer ไม่รองรับ

# ── Connection Handling ─────────────────────────────
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_syn_retries = 3        # ลดจาก 6 default
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_max_tw_buckets = 32768

# ── Keepalive (VLESS long-lived connections) ────────
# VLESS Reality connection ค้างได้นาน
# ตั้ง keepalive สั้น → detect dead connection เร็ว
net.ipv4.tcp_keepalive_time = 60    # เริ่ม probe หลัง 60s idle
net.ipv4.tcp_keepalive_intvl = 10   # probe interval
net.ipv4.tcp_keepalive_probes = 5   # max probe count

# ── Timeout Optimization ────────────────────────────
net.ipv4.tcp_fin_timeout = 15       # ลด TIME_WAIT จาก 60s default
net.ipv4.tcp_tw_reuse = 1           # Reuse TIME_WAIT sockets

# ── Memory ──────────────────────────────────────────
# สำหรับ 1GB RAM (262144 pages × 4096 bytes = 1GB)
# min/pressure/max
net.ipv4.tcp_mem = 32768 65536 131072

# ── Network Device ──────────────────────────────────
net.core.netdev_budget = 600        # packets per NAPI poll
net.core.netdev_budget_usecs = 8000 # max μs per NAPI poll

# ── IP Forward (routing / tproxy) ───────────────────
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ── IPv6 ────────────────────────────────────────────
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0

# ── ARP Cache (ลด overhead เล็กน้อย) ────────────────
net.ipv4.neigh.default.gc_thresh1 = 64
net.ipv4.neigh.default.gc_thresh2 = 256
net.ipv4.neigh.default.gc_thresh3 = 512

# ── Swap (ป้องกัน OOM บน 1GB RAM) ──────────────────
vm.swappiness = 10
vm.vfs_cache_pressure = 50
SYSCTL_EOF

# Apply
sysctl -p "$SYSCTL_FILE" 2>&1 | grep -E "^net|^vm" | while read -r line; do
  ok "$line"
done

# Verify key values
echo ""
echo -e "${BOLD}KEY VALUES:${NC}"
printf "  %-35s %s\n" "tcp_congestion_control:" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "  %-35s %s\n" "tcp_ecn:" "$(sysctl -n net.ipv4.tcp_ecn)"
printf "  %-35s %s\n" "tcp_fastopen:" "$(sysctl -n net.ipv4.tcp_fastopen)"
printf "  %-35s %s\n" "tcp_notsent_lowat:" "$(sysctl -n net.ipv4.tcp_notsent_lowat) bytes"
printf "  %-35s %s\n" "tcp_keepalive_time:" "$(sysctl -n net.ipv4.tcp_keepalive_time)s"

# ─────────────────────────────────────────
#  PHASE 3 — CAKE QDISC
# ─────────────────────────────────────────
step "PHASE 3/4 — CAKE QDisc Configuration"
info "Interface: $IFACE"
info ""
info "📦 CAKE Parameters (สำหรับ VPS ไทย, Client 128kbps):"
info "   bandwidth  90Mbit  → บังคับ queue ที่ CAKE ไม่ใช่ AIS buffer"
info "   triple-isolate      → Fair share สำหรับ 2 users"
info "   rtt 20ms            → Target RTT สำหรับ VPS ไทย↔Client AIS"
info "   overhead 84         → VLESS + TLS 1.3 + TCP + IPv4 header"
info "   wash                → ลบ DSCP ที่ ISP อาจใช้ detect/throttle"
info "   ecn                 → ใช้ ECN signal แทน drop"
info "   nat                 → แก้ IP ก่อน classify (IFB ingress)"
pause

# ─── Cleanup เดิม ─────────────────────────────────────
info "กำลัง cleanup qdisc เดิม..."
tc qdisc del dev "$IFACE" root 2>/dev/null    && info "ลบ egress qdisc เดิม" || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null && info "ลบ ingress qdisc เดิม" || true

if ip link show ifb0 &>/dev/null 2>&1; then
  tc qdisc del dev ifb0 root 2>/dev/null || true
  ip link set ifb0 down 2>/dev/null || true
fi

# ─── EGRESS CAKE ──────────────────────────────────────
info "ตั้งค่า EGRESS CAKE (VPS → Client)..."

if $CAKE_OK; then
  tc qdisc add dev "$IFACE" root cake \
    bandwidth 90Mbit \
    triple-isolate \
    nat \
    wash \
    split-gso \
    overhead 84 \
    mpu 64 \
    rtt 20ms \
    ecn \
    memlimit 32m \
    && ok "CAKE egress: ✅ ตั้งค่าสำเร็จ" \
    || { warn "CAKE egress ล้มเหลว — fallback fq_codel"
         tc qdisc add dev "$IFACE" root fq_codel \
           limit 1024 flows 1024 target 5ms interval 100ms ecn \
           && ok "fq_codel egress: ✅ fallback สำเร็จ"; }
else
  info "ใช้ fq_codel แทน CAKE..."
  tc qdisc add dev "$IFACE" root fq_codel \
    limit 1024 flows 1024 target 5ms interval 100ms ecn
  ok "fq_codel egress: ✅ ตั้งค่าสำเร็จ"
fi

# ─── INGRESS CAKE via IFB ─────────────────────────────
if $IFB_OK && $CAKE_OK; then
  info "ตั้งค่า INGRESS CAKE via IFB (Client → VPS)..."

  ip link add ifb0 type ifb 2>/dev/null || true
  ip link set ifb0 up

  tc qdisc add dev "$IFACE" handle ffff: ingress

  tc filter add dev "$IFACE" parent ffff: \
    protocol all \
    u32 match u32 0 0 \
    action mirred egress redirect dev ifb0 \
    && info "Traffic redirect: eth0 → ifb0" || warn "redirect filter ล้มเหลว"

  tc qdisc add dev ifb0 root cake \
    bandwidth 90Mbit \
    triple-isolate \
    nat \
    wash \
    ingress \
    split-gso \
    overhead 84 \
    mpu 64 \
    rtt 20ms \
    ecn \
    memlimit 32m \
    && ok "CAKE ingress (ifb0): ✅ ตั้งค่าสำเร็จ" \
    || warn "CAKE ingress ล้มเหลว — ใช้ egress-only mode"

  # Persist IFB
  grep -q "^ifb" /etc/modules-load.d/99-bbr.conf 2>/dev/null || \
    echo "ifb" >> /etc/modules-load.d/99-bbr.conf
else
  info "ข้าม ingress shaping (IFB หรือ CAKE ไม่พร้อม)"
fi

# ─── Verify QDisc ─────────────────────────────────────
echo ""
echo -e "${BOLD}QDisc Status:${NC}"
tc qdisc show dev "$IFACE"
ip link show ifb0 &>/dev/null && tc qdisc show dev ifb0 || true

# ─────────────────────────────────────────
#  PHASE 4 — SYSTEMD PERSISTENCE
# ─────────────────────────────────────────
step "PHASE 4/4 — Systemd Auto-Restore Service"
info "สร้าง service ให้ CAKE กลับมาหลัง reboot อัตโนมัติ"
pause

# ─── Restore Script ───────────────────────────────────
cat > /usr/local/bin/vps-tune-restore.sh << RESTORE_SCRIPT
#!/usr/bin/env bash
# Auto-restore CAKE/BBR on boot
# Generated by tune.sh

IFACE="$IFACE"
LOG="/var/log/vps-tune.log"
CAKE_OK="$CAKE_OK"
IFB_OK="$IFB_OK"

exec >> "\$LOG" 2>&1
echo "[\\$(date)] === Auto-restore CAKE ==="

# Load modules
modprobe tcp_bbr 2>/dev/null   && echo "[OK] tcp_bbr"
modprobe sch_cake 2>/dev/null  && echo "[OK] sch_cake"
modprobe ifb numifbs=1 2>/dev/null && echo "[OK] ifb"

# Apply sysctl
sysctl -p /etc/sysctl.d/99-vps-latency.conf >> "\$LOG" 2>&1

# Cleanup old
tc qdisc del dev "\$IFACE" root 2>/dev/null || true
tc qdisc del dev "\$IFACE" ingress 2>/dev/null || true
ip link show ifb0 &>/dev/null && {
  tc qdisc del dev ifb0 root 2>/dev/null || true
  ip link set ifb0 down 2>/dev/null || true
}

# Egress
if modprobe sch_cake 2>/dev/null; then
  tc qdisc add dev "\$IFACE" root cake \\
    bandwidth 90Mbit triple-isolate nat wash \\
    split-gso overhead 84 mpu 64 rtt 20ms ecn memlimit 32m
  echo "[OK] CAKE egress restored"
else
  tc qdisc add dev "\$IFACE" root fq_codel \\
    limit 1024 flows 1024 target 5ms interval 100ms ecn
  echo "[OK] fq_codel egress restored (CAKE fallback)"
fi

# Ingress via IFB
if modprobe ifb numifbs=1 2>/dev/null && modprobe sch_cake 2>/dev/null; then
  ip link add ifb0 type ifb 2>/dev/null || true
  ip link set ifb0 up
  tc qdisc add dev "\$IFACE" handle ffff: ingress
  tc filter add dev "\$IFACE" parent ffff: protocol all \\
    u32 match u32 0 0 \\
    action mirred egress redirect dev ifb0
  tc qdisc add dev ifb0 root cake \\
    bandwidth 90Mbit triple-isolate nat wash ingress \\
    split-gso overhead 84 mpu 64 rtt 20ms ecn memlimit 32m
  echo "[OK] CAKE ingress restored"
fi

echo "[\\$(date)] Restore complete"
RESTORE_SCRIPT

chmod +x /usr/local/bin/vps-tune-restore.sh
ok "Restore script: /usr/local/bin/vps-tune-restore.sh"

# ─── Systemd Service ──────────────────────────────────
cat > /etc/systemd/system/vps-tune.service << 'SERVICE_EOF'
[Unit]
Description=VPS Tune — CAKE QDisc + BBR Restore
Documentation=https://github.com/YOUR/REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-tune-restore.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
TimeoutSec=30

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable vps-tune.service --quiet
systemctl start vps-tune.service

if systemctl is-active --quiet vps-tune.service; then
  ok "vps-tune.service: ✅ Active"
else
  warn "vps-tune.service ไม่ active — ตรวจ: journalctl -u vps-tune.service"
fi

# ─────────────────────────────────────────
#  FINAL STATUS REPORT
# ─────────────────────────────────────────
step "FINAL STATUS REPORT"
echo ""

# BBR
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
printf "  %-30s" "Congestion Control:"
[ "$CC" = "bbr" ] && echo -e "${GREEN}BBR ✅${NC}" || echo -e "${YELLOW}$CC ⚠️${NC}"

# CAKE
QDISC=$(tc qdisc show dev "$IFACE" 2>/dev/null)
printf "  %-30s" "QDisc Egress:"
echo "$QDISC" | grep -q cake  && echo -e "${GREEN}CAKE ✅${NC}" || \
echo "$QDISC" | grep -q codel && echo -e "${YELLOW}fq_codel ⚠️${NC}" || \
echo -e "${RED}ไม่พบ ❌${NC}"

# IFB ingress
printf "  %-30s" "QDisc Ingress (IFB):"
if ip link show ifb0 &>/dev/null 2>&1; then
  tc qdisc show dev ifb0 2>/dev/null | grep -q cake && \
    echo -e "${GREEN}CAKE ✅${NC}" || echo -e "${YELLOW}ไม่มี qdisc ⚠️${NC}"
else
  echo -e "${YELLOW}ไม่มี IFB (egress-only mode)${NC}"
fi

# ECN
printf "  %-30s" "ECN:"
[ "$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)" = "1" ] && \
  echo -e "${GREEN}Enabled ✅${NC}" || echo -e "${YELLOW}Disabled ⚠️${NC}"

# TFO
printf "  %-30s" "TCP Fast Open:"
TFO=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
[ "$TFO" = "3" ] && echo -e "${GREEN}Client+Server ✅${NC}" || echo -e "${YELLOW}$TFO${NC}"

# notsent_lowat
printf "  %-30s" "notsent_lowat:"
echo -e "${GREEN}$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null) bytes ✅${NC}"

# Service
printf "  %-30s" "vps-tune.service:"
systemctl is-active --quiet vps-tune.service && \
  echo -e "${GREEN}Active (auto-restore) ✅${NC}" || echo -e "${YELLOW}ไม่ active ⚠️${NC}"

# Memory
echo ""
echo -e "${BOLD}Memory:${NC}"
free -h | grep -E "Mem|Swap" | while read -r line; do echo "  $line"; done

# ─────────────────────────────────────────
#  3x-ui XRAY SOCKOPT REMINDER
# ─────────────────────────────────────────
echo ""
echo -e "${BOLD}${YELLOW}📋 3x-ui Config Recommendation:${NC}"
cat << 'XRAY_TIP'
  ใน Panel → Inbound → VLESS Reality → เพิ่ม sockopt:
  ┌─────────────────────────────────────────────────────┐
  │  "sockopt": {                                        │
  │    "tcpFastOpen": true,       ← ตรงกับ sysctl       │
  │    "tcpKeepAliveIdle": 60,    ← ตรงกับ keepalive    │
  │    "tcpKeepAliveInterval": 10,                       │
  │    "tcpKeepAliveRetry": 5,                           │
  │    "domainStrategy": "IPIfNonMatch"                  │
  │  }                                                   │
  └─────────────────────────────────────────────────────┘
XRAY_TIP

# ─────────────────────────────────────────
#  COMPLETE
# ─────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           ✅  TUNE COMPLETE — File 2/2                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Reboot แนะนำ เพื่อให้ทุกค่ามีผลเต็มรูปแบบ             ║"
echo "║  หลัง reboot: vps-tune.service จะ restore CAKE อัตโนมัติ ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  ตรวจสอบหลัง reboot:                                    ║"
echo "║    tc qdisc show dev eth0                                ║"
echo "║    sysctl net.ipv4.tcp_congestion_control                ║"
echo "║    systemctl status vps-tune.service                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo "[$(date)] tune.sh complete" >> "$LOG_FILE"
