#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  VMESS WS (no TLS) + CloudFront — REMASTER 2.0 — Ubuntu 24.04 LTS
#  สร้างโดย: Claude | เป้าหมาย: ความเป็นส่วนตัวสูงสุด + เสถียรผ่าน CDN
#  Transport: WebSocket | Security: none (TLS terminate ที่ CloudFront)
#  เหตุผลเปลี่ยนจาก VLESS Reality → VMess WS:
#    Reality พึ่ง TLS fingerprint ของ server เองตรงๆ ไม่ผ่าน CDN ชั้นกลาง
#    ส่วน VMess+WS+CloudFront ให้ CloudFront เป็นเลเยอร์ TLS/CDN แทน
#    เหมาะกับเคสที่ Reality เริ่มถูกตรวจจับ/ไม่เสถียรหลังใช้ไปสักพัก
#
#  ⚠ ขอบเขตของสคริปต์นี้ (ตามที่ระบุ):
#    - จะไม่ติดตั้ง/ตั้งค่า 3x-ui installer ใดๆ ทั้งสิ้น
#    - จะไม่สร้าง/แก้ inbound, client, หรือ sockopt ใดๆ ใน x-ui.db
#    - ทุกอย่างที่เกี่ยวกับ VMess inbound (path, port ภายใน xray, UUID,
#      sockopt ฯลฯ) ผู้ใช้ตั้งเองทั้งหมดผ่าน panel — สคริปต์นี้แค่
#      เตรียม "พื้นที่" (firewall, kernel, privacy, CDN-facing port)
#      ให้พร้อมใช้งาน แล้วแนะนำค่าที่ควรตั้งไว้ตอนจบสคริปต์เท่านั้น
#
#  MTU/MSS: ออกแบบให้เข้ากับ MTU 1500 ฝั่ง v2box (mobile client) —
#  clamp TCP MSS ที่ระดับ iptables (เสถียรกว่า sysctl base_mss อย่างเดียว
#  เพราะ base_mss เป็นแค่ค่า "เริ่มต้น" ตอน SYN แรกของฝั่งเรา ไม่บังคับ
#  ทุก connection ที่วิ่งผ่านจริง ส่วน iptables --clamp-mss-to-pmtu
#  บังคับทุก SYN/SYN-ACK ที่ผ่าน firewall ให้ไม่เกิน ceiling ที่ตั้งไว้
#  ป้องกัน fragmentation ที่มักเกิดจาก overhead เพิ่มของ WS+CloudFront)
#
#  รันเสร็จ → reboot 1 ครั้ง → ไปตั้ง inbound เองใน 3x-ui ตามค่าแนะนำท้ายสคริปต์
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
export LANG=C

# ── สี ──────────────────────────────────────────────────────────────
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

# ── log ─────────────────────────────────────────────────────────────
STATE_DIR="/var/lib/vmess-setup"
LOG_FILE="${STATE_DIR}/setup.log"
mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

sep()  { echo -e "${DIM}${CYN}──────────────────────────────────────────────────────${RST}"; }
hdr()  { echo -e "\n${BLD}${CYN}▶  $1${RST}"; sep; }
ok()   { echo -e "  ${GRN}✔${RST}  $1"; }
warn() { echo -e "  ${YEL}⚠${RST}  $1"; }
info() { echo -e "  ${CYN}ℹ${RST}  $1"; }
die()  { echo -e "\n${RED}${BLD}✘  $1${RST}\n"; exit 1; }
ask()  { echo -e "\n  ${BLD}${YEL}▷  $1${RST}"; }

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root (sudo bash vmess-ws-setup.sh)"

# ── ตรวจ Ubuntu version (non-fatal — แค่เตือน) ───────────────────────
OS_ID=""; OS_VER=""
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
if [ "$OS_ID" != "ubuntu" ] || [ "$OS_VER" != "24.04" ]; then
  warn "สคริปต์นี้ปรับสำหรับ Ubuntu 24.04 — ตรวจพบระบบ: ${OS_ID:-unknown} ${OS_VER:-?}"
  warn "ยังรันต่อได้ แต่บางคำสั่ง (GRUB path / เวอร์ชัน package) อาจต่างจากที่ทดสอบไว้"
else
  ok "ตรวจพบ Ubuntu 24.04 ตรงตามที่สคริปต์ออกแบบไว้"
fi

# ═══════════════════════════════════════════════════════════════════
#  ตั้งค่าหลัก — แก้ค่าด้านล่างนี้ก่อนรัน ถ้าจำเป็น
# ═══════════════════════════════════════════════════════════════════
PANEL_PORT=2053
VMESS_WS_PORT=80          # origin port ที่ CloudFront ยิงเข้ามา (HTTP)
SWAP_SIZE_MB=512
TCP_MSS_CEIL=1440          # ตามที่ขอ: เข้ากับ MTU 1500 ฝั่ง v2box

# ⚠ แก้ตรงนี้เป็น IP จริงของคุณก่อนรัน! ใช้จำกัดการเข้าถึง panel port
# วิธีหา IP ตัวเอง: เปิดเบราว์เซอร์จากเครื่องที่จะใช้เข้า panel แล้วเข้า
# https://ifconfig.me หรือรัน `curl ifconfig.me` จากเครื่องนั้น
# ถ้าใช้เน็ตมือถือที่ IP เปลี่ยนบ่อย ใส่เป็น CIDR กว้างขึ้นได้ เช่น
# 203.0.113.0/24 (แต่ยิ่งกว้างยิ่งปลอดภัยน้อยลง)
ALLOWED_PANEL_IP="CHANGE_ME_TO_YOUR_IP"

_detect_nic() {
  ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}
NIC=$(_detect_nic)
[ -z "$NIC" ] && NIC=$(ip link show | awk -F': ' '/^[0-9]+: / && !/lo:/ {print $2}' | head -1 | cut -d@ -f1)
[ -z "$NIC" ] && NIC="eth0"

RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
VCPU=$(nproc)
PUB_IP=$(curl -sf --max-time 8 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 8 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VMESS WS (no TLS) + CloudFront — REMASTER 2.0            ║${RST}"
echo -e "${BLD}${CYN}║  Transport: WS | Security: none | CDN: CloudFront         ║${RST}"
echo -e "${BLD}${CYN}║  Origin Port: ${VMESS_WS_PORT} | Panel: ${PANEL_PORT} | IPv6: OFF              ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
info "Server IP : ${PUB_IP}"
info "NIC       : ${NIC}"
info "RAM       : ${RAM_MB}MB  vCPU: ${VCPU}"
echo ""

if [ "$ALLOWED_PANEL_IP" = "CHANGE_ME_TO_YOUR_IP" ]; then
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "  ALLOWED_PANEL_IP ยังไม่ถูกแก้! ยังเป็นค่า placeholder อยู่"
  warn "  ถ้าปล่อยแบบนี้ panel port ${PANEL_PORT} จะถูกบล็อกทุก IP"
  warn "  (ปลอดภัยไว้ก่อน แต่คุณจะเข้า panel เองไม่ได้เช่นกัน)"
  warn "  แก้ตัวแปรนี้ในไฟล์สคริปต์ก่อนรัน แล้วรันใหม่"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ask "กด ENTER เพื่อรันต่อแบบ panel port ถูกบล็อกทุก IP ไปก่อน (Ctrl+C เพื่อยกเลิกไปแก้ก่อน)..."
  read -r
fi

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 1 — อัปเดตระบบ + ติดตั้งแพ็กเกจ + ตั้ง Firewall"
# ═══════════════════════════════════════════════════════════════════

# ── 1.1 รอ lock apt ─────────────────────────────────────────────────
info "1.1 หยุด unattended-upgrades + รอ apt lock..."
systemctl stop    unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
systemctl kill --kill-who=all unattended-upgrades 2>/dev/null || true
waited=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
            /var/cache/apt/archives/lock &>/dev/null; do
  [ "$waited" -ge 90 ] && {
    fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
             /var/cache/apt/archives/lock 2>/dev/null || true
    sleep 3; break
  }
  info "รอ apt lock... ${waited}s"
  sleep 5; waited=$((waited+5))
done
dpkg --configure -a
ok "apt พร้อมแล้ว"

# ── 1.2 Update + Upgrade ────────────────────────────────────────────
info "1.2 apt update + upgrade..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
ok "update + upgrade เสร็จ"

# ── 1.3 ติดตั้งแพ็กเกจที่จำเป็น ─────────────────────────────────────
# หมายเหตุ: ใส่ iptables ตรงๆ เพราะใช้ทำ MSS clamp ใน STEP 3 ด้วย
# (ไม่ใช่แค่กัน ip6tables ขาดเหมือนสคริปต์เดิม)
info "1.3 ติดตั้ง dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ufw nftables iptables sqlite3 ethtool iproute2 \
  fail2ban auditd \
  python3 libcap2-bin irqbalance \
  unattended-upgrades
ok "ติดตั้งแพ็กเกจเสร็จ"

# ── 1.4 Firewall (UFW) ──────────────────────────────────────────────
info "1.4 ตั้ง UFW Firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

# เปิดเฉพาะ TCP ที่จำเป็น
ufw limit   22/tcp              comment "SSH"
ufw allow   80/tcp              comment "VMess WS origin (CloudFront -> here)"

# Panel port: จำกัดเฉพาะ IP ที่กำหนด (ถ้ายังเป็น placeholder จะไม่เปิดให้ใครเลย)
if [ "$ALLOWED_PANEL_IP" != "CHANGE_ME_TO_YOUR_IP" ]; then
  ufw allow from "${ALLOWED_PANEL_IP}" to any port "${PANEL_PORT}" proto tcp comment "3x-ui panel (restricted)"
  ok "Panel port ${PANEL_PORT} เปิดเฉพาะจาก ${ALLOWED_PANEL_IP}"
else
  warn "Panel port ${PANEL_PORT} ไม่ถูกเปิดให้ใคร (ALLOWED_PANEL_IP ยังไม่ถูกแก้)"
  warn "แก้ตัวแปรในสคริปต์แล้วรันคำสั่งนี้เองทีหลังได้:"
  warn "  ufw allow from <YOUR_IP> to any port ${PANEL_PORT} proto tcp"
fi

# ⚠ หมายเหตุ UDP:
# ไม่ block UDP ทั้งหมด เพราะ Xray ต้องใช้ relay UDP ให้ client ได้
# (เกมอย่าง Roblox / RoV / เกมอื่นๆ ที่พึ่ง UDP จะเล่นไม่ได้ถ้า block)
# DNS leak ถูกกันด้วยวิธีอื่นแทน: DoT (port 853) + nftables block port 53
# ซึ่งแม่นยำกว่าการ block UDP ทั้งหมด

# ปิด port อันตราย
ufw deny    23/tcp
ufw deny    25/tcp
ufw deny    3389/tcp

# ปิด IPv6 ใน UFW
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true

ufw --force enable
ufw status verbose
ok "UFW Firewall เปิดแล้ว: 22 (limit) / 80 TCP เปิดกว้าง | ${PANEL_PORT} TCP จำกัด IP | UDP relay เปิด"

# ── 1.5 Swap ────────────────────────────────────────────────────────
info "1.5 สร้าง Swap ${SWAP_SIZE_MB}MB..."
if swapon --show | grep -q '/swapfile'; then
  info "swapfile มีอยู่แล้ว"
else
  [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile \
    || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon --show
ok "Swap พร้อม"

ok "═══ STEP 1 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 2 — ตรวจสอบ 3x-ui (ไม่ติดตั้ง / ไม่แก้ inbound ใดๆ)"
# ═══════════════════════════════════════════════════════════════════
# ตามที่ตกลง: สคริปต์นี้จะไม่รัน 3x-ui installer, ไม่สร้าง/แก้ inbound,
# ไม่แตะ client หรือ sockopt ใดๆ ทั้งสิ้น — ผู้ใช้จัดการส่วนนี้เองทั้งหมด
# ขั้นตอนนี้แค่เช็คว่า service มีอยู่หรือยัง เพื่อให้ verify ท้ายสคริปต์
# ทำงานได้ถูกต้อง (ถ้ายังไม่ติดตั้งก็ข้ามแบบไม่ error)

if command -v x-ui &>/dev/null || [ -x /usr/local/x-ui/x-ui ]; then
  ok "พบ 3x-ui ติดตั้งอยู่แล้วในระบบ"
  systemctl is-active x-ui &>/dev/null && ok "x-ui service active" || warn "x-ui ติดตั้งแล้วแต่ service ยังไม่ active — ไปเช็คเองที่: systemctl status x-ui"
else
  info "ยังไม่พบ 3x-ui ในระบบ — ข้ามขั้นตอนนี้ตามที่ตกลง (ไม่ติดตั้งให้)"
  info "ติดตั้งเองได้จาก: https://github.com/mhsanaei/3x-ui"
fi

echo ""
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  ค่าที่แนะนำให้ตั้งตอนสร้าง VMess inbound เอง (ดูสรุปท้ายสคริปต์ด้วย):"
warn "  - Protocol     : VMess"
warn "  - Network      : WS (WebSocket)"
warn "  - Port         : ${VMESS_WS_PORT} (origin ที่ firewall เปิดให้ CloudFront ยิงเข้ามา)"
warn "  - Security     : none (TLS terminate ที่ CloudFront แล้ว ไม่ต้อง TLS ซ้อนที่ server)"
warn "  - Path         : ตั้งเอง ให้ตรงกับ CloudFront origin path ทุกตัวอักษร"
warn "  - Host header   : ให้ตรงกับ domain ที่ผูกกับ CloudFront distribution"
warn "  - Sniffing     : ปิดทั้งหมด (เพิ่ม privacy — ไม่ให้ xray sniff destination)"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ok "═══ STEP 2 เสร็จสมบูรณ์ (ไม่มีการแก้ไข 3x-ui/inbound) ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 3 — Optimize: Kernel / Network / TCP (ปิงต่ำ + throughput สูง)"
# ═══════════════════════════════════════════════════════════════════

# ── 3.1 BBR + TCP Tune ──────────────────────────────────────────────
info "3.1 โหลด BBR + ตั้งค่า TCP/network..."
modprobe tcp_bbr     2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

# ตรวจ BBR
CC="bbr"
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
  || { warn "BBR ไม่มี — ใช้ cubic"; CC="cubic"; }

# ตรวจ fq
QDISC="fq"
modinfo sch_fq &>/dev/null || { warn "fq ไม่มี — ใช้ fq_codel"; QDISC="fq_codel"; }

# ── ค่าบัฟเฟอร์ — เน้น latency ต่ำ/ไม่แลคบนมือถือ (anti-bufferbloat)
# ceiling ต่อ socket 8MB + default เล็ก 128KB ให้ tcp_moderate_rcvbuf
# auto-tune เอง ไม่ commit memory ตั้งแต่ต้น (ค่าอ้างอิงจากสคริปต์เดิม)
RMEM_MAX=8388608
WMEM_MAX=8388608
RMEM_DEF=131072
WMEM_DEF=131072

cat > /etc/sysctl.d/99-vmess-perf.conf << EOF
# ── BBR + FQ ──────────────────────────────────────────────────────
net.ipv4.tcp_congestion_control        = ${CC}
net.core.default_qdisc                 = ${QDISC}

# ── Buffer (ปรับเน้น low-latency / anti-bufferbloat) ───────────────
net.core.rmem_max                      = ${RMEM_MAX}
net.core.wmem_max                      = ${WMEM_MAX}
net.core.rmem_default                  = ${RMEM_DEF}
net.core.wmem_default                  = ${WMEM_DEF}
net.ipv4.tcp_rmem                      = 4096 ${RMEM_DEF} ${RMEM_MAX}
net.ipv4.tcp_wmem                      = 4096 ${WMEM_DEF} ${WMEM_MAX}
net.ipv4.tcp_mem                       = 65536 98304 131072
net.ipv4.tcp_moderate_rcvbuf           = 1
net.ipv4.tcp_adv_win_scale             = 1
net.ipv4.tcp_notsent_lowat             = 131072

# ── Loss recovery / re-ordering (ฟรี ไม่กิน CPU เพิ่ม) ─────────────
net.ipv4.tcp_reordering                = 6
net.ipv4.tcp_frto                      = 2
net.ipv4.tcp_recovery                  = 1

# ── TCP Fast ──────────────────────────────────────────────────────
net.ipv4.tcp_fastopen                  = 3
net.ipv4.tcp_window_scaling            = 1
net.ipv4.tcp_timestamps                = 1
net.ipv4.tcp_sack                      = 1
net.ipv4.tcp_dsack                     = 1
net.ipv4.tcp_ecn                       = 1
net.ipv4.tcp_mtu_probing               = 1
# base_mss ตั้งคู่กับ iptables clamp ด้านล่าง (STEP 3.1b) — base_mss
# เป็นค่าเริ่มต้นตอน SYN แรกของฝั่งเรา ส่วน iptables clamp คือตัวบังคับ
# จริงกับทุก connection ที่วิ่งผ่าน เข้ากับ MTU 1500 ฝั่ง v2box
net.ipv4.tcp_base_mss                  = ${TCP_MSS_CEIL}
net.ipv4.tcp_slow_start_after_idle     = 0
net.ipv4.tcp_autocorking               = 0
net.ipv4.tcp_thin_linear_timeouts      = 1
net.ipv4.tcp_early_retrans             = 3
net.ipv4.tcp_no_metrics_save           = 1

# ── Keepalive / Timeout ───────────────────────────────────────────
net.ipv4.tcp_keepalive_time            = 35
net.ipv4.tcp_keepalive_intvl           = 5
net.ipv4.tcp_keepalive_probes          = 5
net.ipv4.tcp_fin_timeout               = 10
net.ipv4.tcp_syn_retries               = 3
net.ipv4.tcp_synack_retries            = 3
net.ipv4.tcp_retries2                  = 8
net.ipv4.tcp_orphan_retries            = 2
net.ipv4.tcp_max_orphans               = 32768

# ── Queue / Backlog ───────────────────────────────────────────────
net.core.somaxconn                     = 32768
net.ipv4.tcp_max_syn_backlog           = 32768
net.core.netdev_max_backlog            = 32768
net.core.netdev_budget                 = 600
net.core.netdev_budget_usecs           = 4000
net.ipv4.ip_local_port_range           = 1024 65535

# ── Busy poll: ลด latency เพิ่มอีกนิด (50us, เบาพอสำหรับ 1vCPU 2.69GHz
#    กับผู้ใช้ 2 คน — ถ้า CPU สูงผิดปกติให้ลบ 2 บรรทัดนี้ทิ้ง) ──────
net.core.busy_poll                     = 50
net.core.busy_read                     = 50

# ── TIME_WAIT ─────────────────────────────────────────────────────
net.ipv4.tcp_tw_reuse                  = 1
net.ipv4.tcp_max_tw_buckets            = 1440000

# ── Forward (จำเป็นสำหรับ VPN/Proxy) ────────────────────────────
net.ipv4.ip_forward                    = 1
net.ipv4.conf.all.forwarding           = 1
net.ipv4.conf.default.forwarding       = 1
net.ipv6.conf.all.forwarding           = 0

# ── SYN Protect ──────────────────────────────────────────────────
net.ipv4.tcp_syncookies                = 1
net.ipv4.tcp_rfc1337                   = 1
net.ipv4.tcp_challenge_ack_limit       = 1000

# ── VM / Swap ─────────────────────────────────────────────────────
vm.swappiness                          = 10
vm.dirty_ratio                         = 10
vm.dirty_background_ratio              = 3
vm.dirty_expire_centisecs              = 500
vm.dirty_writeback_centisecs           = 100
vm.min_free_kbytes                     = 98304
vm.vfs_cache_pressure                  = 50
vm.overcommit_memory                   = 1

# ── File descriptors ──────────────────────────────────────────────
fs.file-max                            = 1048576
fs.nr_open                             = 1048576
EOF

sysctl -p /etc/sysctl.d/99-vmess-perf.conf
ok "TCP/network tune เสร็จ"

# ── 3.1b MSS Clamp ผ่าน iptables (เสถียรกว่า sysctl base_mss อย่างเดียว) ─
# เหตุผลที่เลือก iptables clamp แทนตั้งแค่ sysctl:
#   - base_mss คือค่า "เริ่มต้น" ที่ kernel ใช้ตอนยังไม่รู้ PMTU จริง
#     มันมีผลแค่บาง edge case ตอนเริ่ม connection ไม่ใช่บังคับทุกแพ็กเกต
#   - --clamp-mss-to-pmtu (+ ceiling 1440) บังคับ "ทุก" SYN/SYN-ACK ที่
#     วิ่งผ่าน chain นี้ให้ MSS ไม่เกินค่าที่ตั้ง ป้องกัน fragmentation
#     จาก overhead ที่ WS + CloudFront เพิ่มเข้ามาเทียบกับ raw TCP ปกติ
#     ได้แน่นอนกว่า ไม่ขึ้นกับว่า client/kernel ฝั่งโน้นจะ negotiate ยังไง
# หมายเหตุ: นี่คือ firewall-level clamp เท่านั้น ไม่ใช่การตั้งค่าใน sockopt
# ของ xray/3x-ui (ตามที่ตกลงว่าจะไม่ยุ่งส่วนนั้น)
info "3.1b ตั้ง MSS clamp ที่ ${TCP_MSS_CEIL} ผ่าน iptables..."
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "$((TCP_MSS_CEIL+1)):1536" -j TCPMSS --set-mss "${TCP_MSS_CEIL}"
iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -m tcpmss --mss "$((TCP_MSS_CEIL+1)):1536" -j TCPMSS --set-mss "${TCP_MSS_CEIL}"
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
cat > /etc/systemd/system/mss-clamp-restore.service << MSSEOF
[Unit]
Description=Restore MSS clamp iptables rules
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'iptables-restore < /etc/iptables/rules.v4 2>/dev/null || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
MSSEOF
systemctl daemon-reload
systemctl enable mss-clamp-restore.service
ok "MSS clamp ${TCP_MSS_CEIL} เสร็จ (FORWARD + OUTPUT, persist ผ่าน reboot)"

# ── 3.2 Conntrack (เผื่อ connection พร้อมกันได้มาก แต่ยังเบากับ kernel) ─
info "3.2 ตั้ง nf_conntrack..."
echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max                      2>/dev/null || true
echo 600    > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established  2>/dev/null || true
echo 1      > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal           2>/dev/null || true
cat >> /etc/sysctl.d/99-vmess-perf.conf << 'EOF2'
net.netfilter.nf_conntrack_max                     = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_be_liberal          = 1
EOF2
ok "conntrack tune เสร็จ (262144 entries ~ใช้ RAM ราว 80MB เท่านั้น)"

# ── 3.2b NIC Tune (เบา ปลอดภัย แต่ช่วย throughput จริงบน 1vCPU) ─────
info "3.2b Tune NIC: ${NIC}..."
ethtool -K "${NIC}" gro on gso on tso on 2>/dev/null || true

RX_MAX=$(ethtool -g "${NIC}" 2>/dev/null \
  | awk '/^Pre-set maximums/,/^Current/ { if(/RX:/) {match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit}}')
TX_MAX=$(ethtool -g "${NIC}" 2>/dev/null \
  | awk '/^Pre-set maximums/,/^Current/ { if(/TX:/) {match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit}}')
RX_MAX="${RX_MAX:-1024}"; TX_MAX="${TX_MAX:-1024}"
ethtool -G "${NIC}" rx "$RX_MAX" tx "$TX_MAX" 2>/dev/null || true

ip link set "${NIC}" txqueuelen 10000 2>/dev/null || true

tc qdisc del dev "${NIC}" root 2>/dev/null || true
tc qdisc add dev "${NIC}" root handle 1: "${QDISC}" 2>/dev/null || true

# Persist หลัง reboot
cat > /etc/systemd/system/nic-tune.service << NSEOF
[Unit]
Description=NIC Tuning persistent (light)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ethtool -K ${NIC} gro on gso on tso on 2>/dev/null; ethtool -G ${NIC} rx ${RX_MAX} tx ${TX_MAX} 2>/dev/null; ip link set ${NIC} txqueuelen 10000 2>/dev/null; tc qdisc del dev ${NIC} root 2>/dev/null; tc qdisc add dev ${NIC} root handle 1: ${QDISC} 2>/dev/null || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
NSEOF
systemctl daemon-reload
systemctl enable nic-tune.service
ok "NIC tune เสร็จ (GRO/GSO/TSO on, ring buffer max, qdisc ${QDISC})"

# ── 3.3 Transparent Huge Pages OFF ──────────────────────────────────
info "3.3 ปิด THP..."
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag   2>/dev/null || true
cat > /etc/systemd/system/thp-disable.service << 'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=x-ui.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
THPEOF
systemctl daemon-reload
systemctl enable --now thp-disable.service
ok "THP ปิดแล้ว"

# ── 3.4 System Limits ───────────────────────────────────────────────
info "3.4 ตั้ง system limits..."
cat > /etc/security/limits.d/99-vmess.conf << 'LIMEOF'
*    soft nofile   2097152
*    hard nofile   2097152
*    soft nproc    131072
*    hard nproc    131072
root soft nofile   2097152
root hard nofile   2097152
root soft nproc    131072
root hard nproc    131072
LIMEOF
for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
  [ -f "$pam" ] || continue
  grep -qxF 'session required pam_limits.so' "$pam" \
    || echo 'session required pam_limits.so' >> "$pam"
done
ok "limits เสร็จ"

# ── 3.5 irqbalance ──────────────────────────────────────────────────
info "3.5 irqbalance..."
systemctl enable --now irqbalance 2>/dev/null || true
ok "irqbalance เสร็จ"

ok "═══ STEP 3 เสร็จสมบูรณ์ ═══"
info "หมายเหตุ: ไม่มีการแก้ x-ui systemd override / x-ui.db / SQLite WAL ใดๆ ในขั้นนี้"
info "เพราะเป็นการ 'จัดการ x-ui' ตามขอบเขตที่ตกลงไว้ — ตั้งเองใน panel ได้ตามสบาย"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 4 — Privacy & Security (ไม่เก็บ log / ไม่ leak IP / ลบตัวตน)"
# ═══════════════════════════════════════════════════════════════════

# ── 4.1 ปิด IPv6 สมบูรณ์ (ป้องกัน IPv6 leak) ───────────────────────
info "4.1 ปิด IPv6 ทั้งระบบ..."
cat > /etc/sysctl.d/99-disable-ipv6.conf << 'V6EOF'
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
V6EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf

for iface in $(ip link show | awk -F': ' '/^[0-9]+:/ {print $2}' | cut -d@ -f1); do
  echo 1 > /proc/sys/net/ipv6/conf/"${iface}"/disable_ipv6 2>/dev/null || true
done

# ip6tables block outbound (มาจาก iptables package — ติดตั้งชัดเจนใน step 1.3)
if command -v ip6tables &>/dev/null; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -j DROP
  mkdir -p /etc/iptables
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
else
  warn "ไม่เจอ ip6tables — ข้าม outbound IPv6 block ชั้นนี้ (sysctl disable_ipv6 ยังทำงานอยู่)"
fi

# GRUB kernel param
if [ -f /etc/default/grub ]; then
  grep -q "ipv6.disable=1" /etc/default/grub || \
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
  update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub update ล้มเหลว (non-fatal)"
fi
ok "IPv6 ปิดแล้ว: sysctl + ip6tables + grub"

# ── 4.2 DNS over TLS (ไม่มี DNS leak) — ใช้ Mullvad DoT เดิมตามที่ยืนยัน ─
info "4.2 DNS over TLS (Mullvad DoT) ..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dot.conf << 'DOTEOF'
[Resolve]
DNS=194.242.2.2#dns.mullvad.net
FallbackDNS=194.242.2.3#dns.mullvad.net
DNSOverTLS=yes
DNSSEC=no
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
# Domains=~. คือตัวที่กัน "DNS leak ผ่าน per-link DHCP" — ถ้าไม่ตั้งตัวนี้
# query บางตัวอาจหลุดไปใช้ DNS server ที่ DHCP ของ NIC ยัดมาให้ (เช่นของ
# host provider) แทน Mullvad DoT โดยไม่รู้ตัว นี่คือสาเหตุ DNS leak ที่พบ
# บ่อยที่สุดในเคส VPN/proxy จริง ไม่ใช่แค่ทฤษฎี
Domains=~.
# ปิด mDNS/LLMNR — ไม่เกี่ยวกับ leak ข้อมูล browsing โดยตรง แต่ลด broadcast
# metadata ที่เครื่องป่าวประกาศ hostname ออกไปใน local network โดยไม่จำเป็น
MulticastDNS=no
LLMNR=no
DOTEOF
systemctl enable --now systemd-resolved 2>/dev/null || true
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

# Block outbound port 53 ด้วย nftables
# ⚠ หมายเหตุ: block เฉพาะ port 53 (plain DNS) ไม่ใช่ UDP ทั้งหมด
# เพื่อให้ Xray relay UDP ของ client ได้ปกติ (เกม RoV/Roblox ฯลฯ)
cat > /etc/nftables-dns-block.conf << 'NFTEOF'
#!/usr/sbin/nft -f
table inet dns_privacy {
  chain output_dns_block {
    type filter hook output priority 0; policy accept;
    ip  daddr 127.0.0.53 udp dport 53 accept
    ip  daddr 127.0.0.53 tcp dport 53 accept
    udp dport 53 drop
    tcp dport 53 drop
  }
}
NFTEOF
nft -f /etc/nftables-dns-block.conf 2>/dev/null && info "nftables: block port 53 plain DNS" || warn "nftables DNS block ล้มเหลว (non-fatal)"

cat > /etc/systemd/system/dns-privacy-nft.service << 'DNSSEOF'
[Unit]
Description=Block plaintext DNS (force DoT)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables-dns-block.conf
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
DNSSEOF
systemctl daemon-reload
systemctl enable --now dns-privacy-nft.service
ok "DNS over TLS เสร็จ | plain DNS port 53 ถูก block"

echo ""
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  สคริปต์นี้ 'ไม่' แก้ Xray internal DNS / log / sockopt ใน x-ui.db"
warn "  เพราะนับเป็นการยุ่งกับ inbound/client ตามที่ตกลงไว้"
warn "  แนะนำให้ไปตั้งเองใน panel (Xray Configs หรือหน้า inbound):"
warn "  - DNS object ของ Xray ตั้งให้ชี้ 127.0.0.53 (local DoT stub ที่"
warn "    ตั้งไว้ข้างบนแล้ว) ป้องกัน Xray query DNS หลุดออกไปตรงๆ"
warn "    โดยไม่ผ่าน OS resolver — เคสนี้เกิดได้ถ้า template ของ x-ui"
warn "    บางรุ่นฝัง public resolver (เช่น 8.8.8.8) มาเป็นค่า default"
warn "  - Log: ตั้ง access=none, error=\"\", loglevel=none, dnsLog=false"
warn "  - Sniffing: ปิดทั้งหมดในหน้า inbound"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 4.3 Kernel Security Hardening ──────────────────────────────────
info "4.3 Kernel security hardening..."
cat > /etc/sysctl.d/99-security.conf << 'SECEOF'
kernel.kptr_restrict                       = 2
kernel.dmesg_restrict                      = 1
kernel.perf_event_paranoid                 = 3
kernel.unprivileged_bpf_disabled           = 1
net.core.bpf_jit_harden                   = 2
fs.suid_dumpable                           = 0
kernel.yama.ptrace_scope                   = 2
kernel.randomize_va_space                  = 2
kernel.sysrq                               = 0
fs.protected_hardlinks                     = 1
fs.protected_symlinks                      = 1
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.all.log_martians             = 1
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
SECEOF
sysctl -p /etc/sysctl.d/99-security.conf
ok "kernel hardening เสร็จ"

# ── 4.4 Journald: ไม่เขียน disk ─────────────────────────────────────
info "4.4 journald → RAM only (volatile)..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-volatile.conf << 'JEOF'
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=32M
RuntimeMaxUse=32M
RateLimitIntervalSec=0
RateLimitBurst=0
Seal=no
ReadKMsg=no
JEOF
journalctl --rotate      2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
find /var/log/journal -type f -name "*.journal" -delete 2>/dev/null || true
systemctl restart systemd-journald
ok "journald: RAM เท่านั้น ไม่เขียน disk"

# ── 4.5 /tmp → tmpfs ────────────────────────────────────────────────
info "4.5 /tmp → tmpfs (RAM)..."
if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
  echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=256m 0 0" >> /etc/fstab
fi
mount -o remount /tmp 2>/dev/null || true
ok "/tmp → tmpfs 256MB"

# ── 4.6 SSH Hardening ───────────────────────────────────────────────
info "4.6 SSH hardening..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardened.conf << 'SSHEOF'
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 20
ClientAliveInterval 120
ClientAliveCountMax 3
AllowTcpForwarding no
X11Forwarding no
PermitEmptyPasswords no
IgnoreRhosts yes
HostbasedAuthentication no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
SSHEOF
if sshd -t 2>/dev/null; then
  systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH hardened — publickey only"
else
  warn "sshd config test failed — ไม่ reload"
fi

# ── 4.7 Fail2ban ────────────────────────────────────────────────────
info "4.7 fail2ban..."
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/99-vmess.conf << FBEOF
[DEFAULT]
bantime  = 3600
findtime = 300
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 86400
FBEOF
systemctl enable --now fail2ban
systemctl restart fail2ban
ok "fail2ban: SSH ban 24h/3 tries"

# ── 4.8 Auto security updates ──────────────────────────────────────
info "4.8 auto security updates..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades-security << 'AUTEOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
AUTEOF
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTEOF2'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTEOF2
systemctl enable --now unattended-upgrades
ok "auto security updates เสร็จ"

# ── 4.9 DB Backup (daily, เก็บ 7 วัน) — backup เฉยๆ ไม่แก้เนื้อหา DB ──
info "4.9 DB backup (อ่านอย่างเดียว, ไม่แก้เนื้อหาใน x-ui.db)..."
BACKUP_DIR="/var/lib/vmess-setup/backups"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
DB="/etc/x-ui/x-ui.db"
cat > /usr/local/bin/xui-backup.sh << BKEOF
#!/usr/bin/env bash
DB="${DB}"
BACKUP_DIR="${BACKUP_DIR}"
[ -f "\$DB" ] || exit 0
TS=\$(date '+%Y%m%d_%H%M%S')
sqlite3 "\$DB" ".backup \${BACKUP_DIR}/x-ui_\${TS}.db" 2>/dev/null \
  || cp "\$DB" "\${BACKUP_DIR}/x-ui_\${TS}.db"
chmod 600 "\${BACKUP_DIR}/x-ui_\${TS}.db"
find "\$BACKUP_DIR" -name "x-ui_*.db" -mtime +7 -delete 2>/dev/null || true
BKEOF
chmod +x /usr/local/bin/xui-backup.sh
cat > /etc/systemd/system/xui-backup.service << 'BKSEOF'
[Unit]
Description=x-ui DB Backup (read-only copy)
[Service]
Type=oneshot
ExecStart=/usr/local/bin/xui-backup.sh
BKSEOF
cat > /etc/systemd/system/xui-backup.timer << 'BKTEOF'
[Unit]
Description=x-ui DB daily backup
[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
BKTEOF
systemctl daemon-reload
systemctl enable --now xui-backup.timer
/usr/local/bin/xui-backup.sh 2>/dev/null || true
ok "DB backup: ${BACKUP_DIR} (เก็บ 7 วัน, .backup เป็น read-only copy ไม่แก้ของจริง)"

# ── 4.10 Persist ip6tables ──────────────────────────────────────────
info "4.10 persist ip6tables rules on reboot..."
cat > /etc/systemd/system/ip6tables-restore.service << 'IP6EOF'
[Unit]
Description=Restore ip6tables rules
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'ip6tables-restore < /etc/iptables/rules.v6 2>/dev/null || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
IP6EOF
systemctl daemon-reload
systemctl enable ip6tables-restore.service
ok "ip6tables persist เสร็จ"

ok "═══ STEP 4 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "VERIFY — ตรวจสอบก่อน reboot"
# ═══════════════════════════════════════════════════════════════════
errors=0
chk_svc() {
  systemctl is-enabled "$1" &>/dev/null \
    && ok "$1 enabled" \
    || { warn "$1 NOT enabled"; errors=$((errors+1)); }
}
chk_val() {
  local label="$1" got="$2" want="$3"
  echo "$got" | grep -qF "$want" \
    && ok "${label}: ${got}" \
    || { warn "${label}: ได้ '${got}' คาดหวัง '${want}'"; errors=$((errors+1)); }
}

chk_svc fail2ban
chk_svc thp-disable.service
chk_svc nic-tune.service
chk_svc dns-privacy-nft.service
chk_svc unattended-upgrades
chk_svc mss-clamp-restore.service

chk_val "BBR"          "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
chk_val "FQ qdisc"     "$(tc qdisc show dev "${NIC}" 2>/dev/null | head -1)"      "fq"
chk_val "THP"          "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" "never"
chk_val "IPv6 disable" "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" "1"
chk_val "IP forward"   "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"            "1"
chk_val "kptr_restrict" "$(sysctl -n kernel.kptr_restrict 2>/dev/null)"          "2"

# ── DNS leak: ทดสอบจริง ไม่ใช่แค่เช็คว่า rule โหลดสำเร็จ ────────────
info "ทดสอบ DNS leak: ลองต่อ TCP:53 ไป public resolver ตรงๆ (ควรถูกบล็อก)..."
if timeout 3 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  warn "เชื่อมต่อ TCP:53 ไป 8.8.8.8 ได้สำเร็จ — nftables DNS block ไม่ทำงานจริง!"
  errors=$((errors+1))
else
  ok "TCP:53 ไป public resolver ถูกบล็อกแล้ว (DNS leak ปิดสนิท)"
fi
chk_val "resolved Domains=~." "$(resolvectl status 2>/dev/null | grep -m1 'DNS Domain')" "~."

# ── ตรวจ UFW ว่าไม่มี rule block UDP ทั้งหมด (เกม RoV/Roblox ต้องใช้ UDP) ──
info "ตรวจ UFW: ต้องไม่มี rule 'deny udp' ที่ block UDP ทั้งหมด..."
if ufw status 2>/dev/null | grep -qE "^DENY.*Anywhere.*\(v6\)$|deny.*proto udp.*any.*any"; then
  warn "⚠ พบ UFW rule ที่ block UDP ทั้งหมด! เกม RoV/Roblox จะใช้ไม่ได้ — ลบด้วย: ufw delete deny proto udp from any to any"
  errors=$((errors+1))
else
  ok "UFW ไม่มี rule block UDP ทั้งหมด (เกมเล่นได้ปกติ)"
fi

# ── ตรวจ MSS clamp ────────────────────────────────────────────────
info "ตรวจ MSS clamp rule ใน iptables..."
if iptables -t mangle -L OUTPUT -n 2>/dev/null | grep -q "TCPMSS"; then
  ok "MSS clamp rule ติดตั้งอยู่ใน mangle OUTPUT chain"
else
  warn "ไม่พบ MSS clamp rule ใน mangle OUTPUT chain"
  errors=$((errors+1))
fi

# ── ตรวจ panel port restriction ─────────────────────────────────────
if [ "$ALLOWED_PANEL_IP" = "CHANGE_ME_TO_YOUR_IP" ]; then
  warn "ALLOWED_PANEL_IP ยังเป็น placeholder — panel port ${PANEL_PORT} ปิดทุก IP อยู่"
  errors=$((errors+1))
else
  ok "Panel port ${PANEL_PORT} จำกัดเฉพาะ ${ALLOWED_PANEL_IP}"
fi

# ── ตรวจงบ RAM จริง vs ค่าที่คำนวณบัฟเฟอร์ไว้ (สมมติฐาน ~2048MB) ────
if [ "$RAM_MB" -lt 1800 ]; then
  warn "RAM จริง = ${RAM_MB}MB ต่ำกว่าที่คำนวณบัฟเฟอร์ไว้ (2048MB)"
  warn "ค่า tcp_mem/rmem_max ที่ตั้งอาจสูงเกินไปสำหรับเครื่องนี้ — พิจารณาลดลง"
  errors=$((errors+1))
else
  ok "RAM จริง = ${RAM_MB}MB ตรงกับงบที่คำนวณบัฟเฟอร์ (2048MB)"
fi

echo ""
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP    :${RST} ${PUB_IP}"
echo -e "  ${BLD}Panel URL    :${RST} http://${PUB_IP}:${PANEL_PORT}/  (เข้าได้เฉพาะจาก ${ALLOWED_PANEL_IP})"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}แนะนำการตั้ง Inbound (ตั้งเองใน panel — สคริปต์ไม่แตะ):${RST}"
echo -e "  ${BLD}Protocol     :${RST} VMess"
echo -e "  ${BLD}Network      :${RST} WS (WebSocket)"
echo -e "  ${BLD}Origin Port  :${RST} ${VMESS_WS_PORT}  (firewall เปิดรอ CloudFront อยู่แล้ว)"
echo -e "  ${BLD}Security     :${RST} none (TLS terminate ที่ CloudFront)"
echo -e "  ${BLD}Path/Host    :${RST} ให้ตรงกับ CloudFront origin path/domain ทุกตัวอักษร"
echo -e "  ${BLD}Sniffing     :${RST} แนะนำปิดทั้งหมด"
echo -e "  ${BLD}Xray DNS     :${RST} แนะนำชี้ 127.0.0.53 (ดูคำแนะนำ STEP 4.2 ด้านบน)"
echo -e "  ${BLD}Xray Log     :${RST} แนะนำ access=none, loglevel=none, dnsLog=false"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}MTU/MSS      :${RST}"
echo -e "    ${GRN}✔${RST}  tcp_base_mss = ${TCP_MSS_CEIL} (sysctl, ค่าเริ่มต้น)"
echo -e "    ${GRN}✔${RST}  iptables MSS clamp = ${TCP_MSS_CEIL} (บังคับจริงทุก connection)"
echo -e "    ${GRN}✔${RST}  เข้ากับ MTU 1500 ฝั่ง v2box"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Privacy      :${RST}"
echo -e "    ${GRN}✔${RST}  IPv6         : ปิดสมบูรณ์"
echo -e "    ${GRN}✔${RST}  DNS          : Mullvad DoT (853) + Domains=~. (กัน DHCP override leak)"
echo -e "    ${GRN}✔${RST}  DNS port 53  : blocked (nftables) + ทดสอบจริงแล้วใน VERIFY"
echo -e "    ${GRN}✔${RST}  mDNS/LLMNR   : ปิด (ลด broadcast metadata)"
echo -e "    ${GRN}✔${RST}  journald     : RAM only (volatile)"
echo -e "    ${GRN}✔${RST}  /tmp         : tmpfs (RAM)"
echo -e "    ${YEL}⚠${RST}  Xray log/DNS object : ยังไม่ patch (ต้องตั้งเองใน panel ตามคำแนะนำ STEP 4.2)"
echo -e "    ${YEL}⚠${RST}  UDP          : เปิด (จำเป็นสำหรับ Xray relay เกม RoV/Roblox)"
echo -e "                  DNS leak กันด้วย DoT + block port 53 แทน"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Performance  :${RST}"
echo -e "    ${GRN}✔${RST}  BBR congestion control"
echo -e "    ${GRN}✔${RST}  FQ qdisc | THP off | NIC: GRO/GSO/TSO + ring max"
echo -e "    ${GRN}✔${RST}  TCP buffer 8MB/socket (anti-bufferbloat) | tcp_mem 256/384/512MB"
echo -e "    ${GRN}✔${RST}  Busy-poll 50us | TCP fast | Keepalive 35s"
echo -e "    ${GRN}✔${RST}  Conntrack 262144 entries (~80MB)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Security     :${RST}"
echo -e "    ${GRN}✔${RST}  SSH: publickey only"
echo -e "    ${GRN}✔${RST}  fail2ban: SSH ban 24h"
echo -e "    ${GRN}✔${RST}  Kernel hardening (kptr/ptrace/BPF)"
echo -e "    ${GRN}✔${RST}  UFW: 22 (limit) / 80 TCP เปิด | ${PANEL_PORT} จำกัด IP | UDP relay เปิด"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Logs & Debug :${RST}"
echo -e "  systemctl status x-ui"
echo -e "  fail2ban-client status sshd"
echo -e "  iptables -t mangle -L OUTPUT -n -v   # ตรวจ MSS clamp"
echo -e "  ${BLD}Install log  :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""

if [ "$errors" -eq 0 ]; then
  echo -e "${BLD}${GRN}"
  echo -e "  ✔  ทุก step ผ่านหมด!"
  echo -e "${RST}"
else
  echo -e "${YEL}  ⚠  พบ ${errors} รายการ — ตรวจสอบด้านบน${RST}"
fi

echo -e "${BLD}${YEL}"
echo -e "  ════ ขั้นตอนต่อไป (คุณจัดการเองทั้งหมดตามที่ตกลง) ═══════════"
echo -e "  1. ถ้ายังไม่ติดตั้ง 3x-ui: ติดตั้งเอง"
echo -e "     bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
echo -e "  2. เข้า panel จาก IP ที่อนุญาต: http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  3. สร้าง inbound เอง:"
echo -e "     Protocol  : VMess"
echo -e "     Port      : ${VMESS_WS_PORT}"
echo -e "     Network   : WS"
echo -e "     Security  : none"
echo -e "     Path      : ตั้งเอง ให้ตรงกับ CloudFront origin path"
echo -e "     Sniffing  : ปิดทั้งหมด"
echo -e "  4. ตั้ง CloudFront distribution ให้ origin ชี้มาที่ ${PUB_IP}:${VMESS_WS_PORT}"
echo -e "     (HTTP only ที่ origin, TLS ให้ CloudFront จัดการที่ edge)"
echo -e "  5. ถ้า ALLOWED_PANEL_IP ยังเป็น placeholder ให้แก้ในสคริปต์แล้ว"
echo -e "     รันคำสั่งนี้เอง: ufw allow from <YOUR_IP> to any port ${PANEL_PORT} proto tcp"
echo -e "  6. reboot ครั้งเดียว: reboot"
echo -e "  ════════════════════════════════════════════════════════"
echo -e "${RST}"
echo -e "${BLD}${RED}  ⚠ ตรวจ authorized_keys ก่อน reboot! SSH = publickey only${RST}"
echo ""
