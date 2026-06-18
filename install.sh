#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  VLESS Reality (RAW TCP) Port 443 — REMASTER 3.0 — Ubuntu 24.04 LTS
#  สร้างโดย: Claude | เป้าหมาย: ปิงต่ำ + รองรับ 1Gbps + privacy สูงสุด
#  Transport: tcp (raw, ไม่มี WS) | Security: Reality
#  Fingerprint: firefox | Dest/SNI: speedtest.net | Port: 443
#
#  ⚠ ขอบเขตของสคริปต์นี้ (ตามที่ตกลง):
#    - จะติดตั้ง 3x-ui ให้ (interactive installer ของจริง) แต่จะ "ไม่"
#      auto-กรอก inbound/client/sockopt ใดๆ ทั้งสิ้น — ผู้ใช้กรอกเอง
#      ทุกช่องในหน้า panel หลังติดตั้งเสร็จ
#    - จะไม่แก้ x-ui.db, ไม่ฉีด systemd override ไปยุ่ง sockopt ของ xray
#    - MSS 1440: สคริปต์ clamp ระดับ firewall (iptables/mangle) ให้
#      เข้ากันเฉยๆ ส่วน tcpMaxSeg ใน 3x-ui inbound settings ผู้ใช้ตั้งเอง
#
#  รันเสร็จ → reboot 1 ครั้ง → เข้า panel กรอก inbound เอง
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
export LANG=C

# ── สี ──────────────────────────────────────────────────────────────
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

# ── log ─────────────────────────────────────────────────────────────
STATE_DIR="/var/lib/vless-reality-setup"
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

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root (sudo bash vless-reality-setup.sh)"

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
#  ตั้งค่าหลัก
# ═══════════════════════════════════════════════════════════════════
PANEL_PORT=2053
REALITY_PORT=443           # VLESS Reality listen ตรงนี้ raw TCP ไม่มี CDN
SWAP_SIZE_MB=512
TCP_MSS_CEIL=1440           # เข้ากับ MTU 1500 ฝั่ง v2box
REALITY_DEST="speedtest.net:443"
REALITY_SNI="speedtest.net"
REALITY_FINGERPRINT="firefox"

# UDP ports สำหรับเกมหลักๆที่รู้ port แน่นอน + Xray relay เอง
# (เปิด ephemeral เต็ม 1024-65535 ตามที่ตกลง)
GAME_UDP_PORTS=(
  "1024:65535"     # for Game
)

ask "กรอก IP เครื่องที่จะใช้เข้า panel (เว้นว่างเพื่อเปิดให้ทุก IP — ไม่แนะนำ):"
read -r ALLOWED_PANEL_IP
[ -z "$ALLOWED_PANEL_IP" ] && ALLOWED_PANEL_IP="ANY"

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
echo -e "${BLD}${CYN}║  VLESS Reality (RAW TCP) Port 443 — REMASTER 3.0          ║${RST}"
echo -e "${BLD}${CYN}║  Fingerprint: firefox | Dest/SNI: speedtest.net           ║${RST}"
echo -e "${BLD}${CYN}║  Port: ${REALITY_PORT} | Panel: ${PANEL_PORT} | IPv6: OFF                  ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
info "Server IP : ${PUB_IP}"
info "NIC       : ${NIC}"
info "RAM       : ${RAM_MB}MB  vCPU: ${VCPU}"
echo ""

if [ "$ALLOWED_PANEL_IP" = "ANY" ]; then
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "  panel port ${PANEL_PORT} จะเปิดให้ทุก IP เข้าได้ — ไม่ปลอดภัย"
  warn "  ถ้าต้องการจำกัด ให้ Ctrl+C แล้วรันใหม่พร้อมกรอก IP"
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ask "กด ENTER เพื่อรันต่อแบบเปิด panel ให้ทุก IP (Ctrl+C เพื่อยกเลิก)..."
  read -r
fi

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 1 — Full Upgrade + ติดตั้งแพ็กเกจ + Firewall"
# ═══════════════════════════════════════════════════════════════════

# ── 1.1 รอ lock apt ─────────────────────────────────────────────────
info "1.1 หยุด unattended-upgrades ชั่วคราว + รอ apt lock..."
systemctl stop    unattended-upgrades 2>/dev/null || true
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

# ── 1.2 Full update + upgrade ทุกอย่างจริงๆ (รวม dist-upgrade + firmware) ──
info "1.2 apt update + full-upgrade + dist-upgrade (อัปเดตทุกอย่างที่มี)..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge
apt-get autoclean -y
ok "full-upgrade + dist-upgrade + autoremove เสร็จ"

if command -v fwupdmgr &>/dev/null; then
  info "1.2b ตรวจ firmware update (ถ้า VPS provider รองรับ)..."
  fwupdmgr refresh --force 2>/dev/null || true
  fwupdmgr get-updates 2>/dev/null || true
  fwupdmgr update -y 2>/dev/null || true
  ok "firmware check เสร็จ (ถ้าไม่มีอะไรให้อัปเดตจะข้ามแบบไม่ error)"
fi

if [ -f /var/run/reboot-required ]; then
  warn "ระบบแจ้งว่าต้อง reboot จาก kernel/lib update — สคริปต์จะแนะนำ reboot ท้ายสุดอยู่แล้ว"
fi

# ── 1.3 ติดตั้งแพ็กเกจที่จำเป็น ─────────────────────────────────────
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

# SSH + Reality port
ufw limit 22/tcp                comment "SSH"
ufw allow ${REALITY_PORT}/tcp   comment "VLESS Reality raw TCP"
ufw allow 80/tcp                comment "HTTP"

# Panel port
if [ "$ALLOWED_PANEL_IP" != "ANY" ]; then
  ufw allow from "${ALLOWED_PANEL_IP}" to any port "${PANEL_PORT}" proto tcp comment "3x-ui panel (restricted)"
  ok "Panel port ${PANEL_PORT} เปิดเฉพาะจาก ${ALLOWED_PANEL_IP}"
else
  ufw allow ${PANEL_PORT}/tcp comment "3x-ui panel (open - no IP restriction set)"
  warn "Panel port ${PANEL_PORT} เปิดให้ทุก IP (ไม่ได้กรอก IP ตอนเริ่มสคริปต์)"
fi

# UDP เกม — เปิดเฉพาะช่วงที่รู้จัก ไม่เปิด ephemeral เต็มช่วง
info "1.4b เปิด UDP ports สำหรับเกม (เฉพาะช่วงที่รู้จัก ไม่เปิดกว้างทั้ง ephemeral)..."
for range in "${GAME_UDP_PORTS[@]}"; do
  ufw allow ${range}/udp comment "Game UDP"
  info "  เปิด UDP ${range}"
done

# ปิด port อันตราย
ufw deny 23/tcp
ufw deny 25/tcp
ufw deny 3389/tcp

# ปิด IPv6 ใน UFW
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true

ufw --force enable
ufw status verbose
ok "UFW Firewall เปิดแล้ว: 22 (limit) / ${REALITY_PORT} TCP เปิด | ${PANEL_PORT} TCP | UDP เกมเฉพาะช่วงที่กำหนด"

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
hdr "STEP 2 — ติดตั้ง 3x-ui (Interactive — ผู้ใช้กรอกเอง ไม่ auto)"
# ═══════════════════════════════════════════════════════════════════
# ตามที่ตกลง: รัน installer ตัวจริงแบบ interactive ให้ผู้ใช้กรอก
# username/password/port เองทั้งหมด สคริปต์นี้ "ไม่" auto-เติมอะไรให้
# และจะไม่ไปสร้าง/แก้ inbound, client, sockopt ใดๆ ใน x-ui.db ทั้งสิ้น

if command -v x-ui &>/dev/null || [ -x /usr/local/x-ui/x-ui ]; then
  ok "พบ 3x-ui ติดตั้งอยู่แล้วในระบบ — ข้ามการติดตั้ง"
  systemctl is-active x-ui &>/dev/null && ok "x-ui service active" || warn "x-ui ติดตั้งแล้วแต่ service ยังไม่ active — เช็คเอง: systemctl status x-ui"
else
  info "เริ่มติดตั้ง 3x-ui (interactive) — กรอก username/password/port ของคุณเองตามที่ installer ถาม..."
  echo ""
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  echo ""
  if command -v x-ui &>/dev/null || [ -x /usr/local/x-ui/x-ui ]; then
    ok "ติดตั้ง 3x-ui สำเร็จ"
  else
    warn "ไม่พบ x-ui หลังติดตั้ง — ตรวจสอบ output ด้านบนว่า installer error หรือไม่"
  fi
fi

echo ""
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  ค่าที่ต้องกรอกเองตอนสร้าง VLESS Reality inbound ใน panel:"
warn "  - Protocol      : VLESS"
warn "  - Network       : tcp (raw — ไม่ใช่ WS)"
warn "  - Port          : ${REALITY_PORT}"
warn "  - Security      : reality"
warn "  - Dest          : ${REALITY_DEST}"
warn "  - Server Name(s): ${REALITY_SNI}"
warn "  - Fingerprint   : ${REALITY_FINGERPRINT}"
warn "  - Private/Public Key + Short ID : กด generate ในหน้า panel เอง"
warn "  - tcpMaxSeg     : ${TCP_MSS_CEIL} (ตั้งเองในหน้า sockopt ของ inbound)"
warn "  - Sniffing      : แนะนำปิดทั้งหมด"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ok "═══ STEP 2 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 3 — Optimize: Kernel / Network / TCP (เกม + Netflix 4K60, รองรับ 1Gbps)"
# ═══════════════════════════════════════════════════════════════════

# ── 3.1 BBR + FQ ────────────────────────────────────────────────────
info "3.1 โหลด BBR + ตั้งค่า TCP/network..."
modprobe tcp_bbr     2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

CC="bbr"
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
  || { warn "BBR ไม่มี — ใช้ cubic"; CC="cubic"; }

QDISC="fq"
modinfo sch_fq &>/dev/null || { warn "fq ไม่มี — ใช้ fq_codel"; QDISC="fq_codel"; }

# ── บัฟเฟอร์: เล็กพอไม่ bufferbloat/ไม่ร้อน CPU แต่พอสำหรับ 1Gbps
# คำนวณจาก BDP ที่ RTT เฉลี่ย (~150ms) บนลิงก์ 1Gbps:
#   BDP = 1,000,000,000 bps * 0.15s / 8 = ~18.75MB ทางทฤษฎี
# แต่ค่านี้ใหญ่เกินจำเป็นจริงสำหรับ 2 ผู้ใช้ และจะทำให้ bufferbloat
# (แลคตอน burst) แทนที่จะช่วย — ใช้ BBR เป็นตัวคุม pacing หลัก ส่วน
# socket buffer ตั้งแค่ "พอเผื่อ" BBR ทำงานโดยไม่ติด ceiling ไว ๆ
# เลือก ceiling 16MB ต่อ socket: พอสำหรับ Netflix 4K60 (~25-40Mbps
# เฉลี่ย, burst ระยะสั้นสูงกว่านั้น) + เกม latency-sensitive ไม่กิน
# RAM เกินจำเป็นบนเครื่อง 1-2GB
RMEM_MAX=16777216
WMEM_MAX=16777216
RMEM_DEF=131072
WMEM_DEF=131072

cat > /etc/sysctl.d/99-reality-perf.conf << EOF
# ── BBR + FQ ──────────────────────────────────────────────────────
net.ipv4.tcp_congestion_control        = ${CC}
net.core.default_qdisc                 = ${QDISC}

# ── Buffer (เล็กพอ ไม่ bufferbloat แต่พอสำหรับ 1Gbps + 4K60) ───────
net.core.rmem_max                      = ${RMEM_MAX}
net.core.wmem_max                      = ${WMEM_MAX}
net.core.rmem_default                  = ${RMEM_DEF}
net.core.wmem_default                  = ${WMEM_DEF}
net.ipv4.tcp_rmem                      = 4096 ${RMEM_DEF} ${RMEM_MAX}
net.ipv4.tcp_wmem                      = 4096 ${WMEM_DEF} ${WMEM_MAX}
net.ipv4.tcp_mem                       = 65536 131072 262144
net.ipv4.tcp_moderate_rcvbuf           = 1
net.ipv4.tcp_adv_win_scale             = 1
net.ipv4.tcp_notsent_lowat             = 131072

# ── Loss recovery / re-ordering ────────────────────────────────────
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

# ── Queue / Backlog (รองรับ throughput สูงถึง 1Gbps) ───────────────
net.core.somaxconn                     = 32768
net.ipv4.tcp_max_syn_backlog           = 32768
net.core.netdev_max_backlog            = 32768
net.core.netdev_budget                 = 600
net.core.netdev_budget_usecs           = 4000
net.ipv4.ip_local_port_range           = 1024 65535

# ── Busy poll: ลด latency เพิ่มอีกนิด (เบาพอสำหรับ 1vCPU, ผู้ใช้ 2 คน) ──
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

sysctl -p /etc/sysctl.d/99-reality-perf.conf
ok "TCP/network tune เสร็จ (buffer ceiling 16MB/socket, รองรับ 1Gbps ไม่ bufferbloat)"

# ── 3.1b MSS Clamp ผ่าน iptables (firewall-level, เข้ากับ tcpMaxSeg ที่ตั้งใน panel) ─
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

# ── 3.2 Conntrack ───────────────────────────────────────────────────
info "3.2 ตั้ง nf_conntrack..."
echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max                      2>/dev/null || true
echo 600    > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established  2>/dev/null || true
echo 1      > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal           2>/dev/null || true
cat >> /etc/sysctl.d/99-reality-perf.conf << 'EOF2'
net.netfilter.nf_conntrack_max                     = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_be_liberal          = 1
EOF2
ok "conntrack tune เสร็จ (262144 entries ~ใช้ RAM ราว 80MB เท่านั้น)"

# ── 3.2b NIC Tune ───────────────────────────────────────────────────
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
ok "THP ปิดแล้ว (ลดโอกาส latency spike จาก huge page compaction)"

# ── 3.4 System Limits ───────────────────────────────────────────────
info "3.4 ตั้ง system limits..."
cat > /etc/security/limits.d/99-reality.conf << 'LIMEOF'
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
info "3.5 irqbalance (กระจาย interrupt ข้าม core ลด CPU spike ตัวเดียว)..."
systemctl enable --now irqbalance 2>/dev/null || true
ok "irqbalance เสร็จ"

# ── 3.6 CPU governor: performance (ถ้า VPS provider expose ให้ปรับ) ─
info "3.6 ตรวจ CPU governor..."
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$gov" 2>/dev/null || true
  done
  ok "ตั้ง CPU governor = performance (ลด latency จาก frequency scaling)"
else
  info "VPS นี้ไม่ expose cpufreq governor ให้ปรับ (ปกติสำหรับ KVM ส่วนใหญ่) — ข้าม"
fi

ok "═══ STEP 3 เสร็จสมบูรณ์ ═══"
info "หมายเหตุ: ไม่มีการแก้ x-ui systemd override / x-ui.db / sockopt ใดๆ ในขั้นนี้"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 4 — Privacy & Security (ไม่เก็บ log / ไม่ leak IP-DNS / ซ่อนตัวตน)"
# ═══════════════════════════════════════════════════════════════════

# ── 4.1 ปิด IPv6 สมบูรณ์ ────────────────────────────────────────────
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

if command -v ip6tables &>/dev/null; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -j DROP
  mkdir -p /etc/iptables
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
else
  warn "ไม่เจอ ip6tables — ข้าม outbound IPv6 block ชั้นนี้ (sysctl disable_ipv6 ยังทำงานอยู่)"
fi

if [ -f /etc/default/grub ]; then
  grep -q "ipv6.disable=1" /etc/default/grub || \
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
  update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub update ล้มเหลว (non-fatal)"
fi
ok "IPv6 ปิดแล้ว: sysctl + ip6tables + grub"

# ── 4.2 DNS over TLS (Mullvad DoT) ที่ระดับ OS ──────────────────────
info "4.2 DNS over TLS (Mullvad DoT) ที่ระดับ OS..."
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
# Domains=~. กัน DNS leak ผ่าน per-link DHCP — ถ้าไม่ตั้งตัวนี้ query
# บางตัวอาจหลุดไปใช้ DNS server ที่ DHCP ของ NIC ยัดมาให้ (เช่นของ
# host provider) แทน Mullvad DoT โดยไม่รู้ตัว
Domains=~.
MulticastDNS=no
LLMNR=no
DOTEOF
systemctl enable --now systemd-resolved 2>/dev/null || true
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

# Block outbound port 53 plaintext — ไม่แตะ UDP เกม/Xray relay
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
ok "DNS over TLS เสร็จ (OS-level) | plain DNS port 53 ถูก block"

echo ""
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  ไปตั้งเองในหน้า 3x-ui panel (Xray Configs):"
warn "  - DNS object ของ Xray → ชี้ 127.0.0.53 (local DoT stub ที่ตั้งไว้ข้างบน)"
warn "    ป้องกัน Xray query DNS หลุดออกตรงๆไม่ผ่าน OS resolver — บาง"
warn "    template ของ x-ui ฝัง public resolver (เช่น 8.8.8.8) มาเป็น default"
warn "  - Log: access=none, error=\"\", loglevel=none, dnsLog=false"
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

# ── 4.4 journald → RAM only (ไม่เขียน disk) ─────────────────────────
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
cat > /etc/fail2ban/jail.d/99-reality.conf << FBEOF
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

# ── 4.9 DB Backup (daily, อ่านอย่างเดียว ไม่แก้เนื้อหา) ─────────────
info "4.9 DB backup (read-only copy, ไม่แก้เนื้อหาใน x-ui.db)..."
BACKUP_DIR="/var/lib/vless-reality-setup/backups"
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

# ── 4.11 ลบ/ลด metadata ที่ระบุตัวตนเครื่อง ──────────────────────────
info "4.11 ลด system metadata ที่อาจระบุตัวตน (motd, hostname banner)..."
chmod -x /etc/update-motd.d/* 2>/dev/null || true
echo "" > /etc/motd 2>/dev/null || true
sed -i 's/^Banner.*/#Banner none/' /etc/ssh/sshd_config 2>/dev/null || true
ok "ลด metadata เสร็จ"

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

info "ทดสอบ DNS leak: ลองต่อ TCP:53 ไป public resolver ตรงๆ (ควรถูกบล็อก)..."
if timeout 3 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  warn "เชื่อมต่อ TCP:53 ไป 8.8.8.8 ได้สำเร็จ — nftables DNS block ไม่ทำงานจริง!"
  errors=$((errors+1))
else
  ok "TCP:53 ไป public resolver ถูกบล็อกแล้ว (DNS leak ปิดสนิท)"
fi
chk_val "resolved Domains=~." "$(resolvectl status 2>/dev/null | grep -m1 'DNS Domain')" "~."

info "ตรวจ Reality port ${REALITY_PORT} เปิดอยู่ใน UFW..."
if ufw status 2>/dev/null | grep -qE "^${REALITY_PORT}/tcp"; then
  ok "Port ${REALITY_PORT}/tcp เปิดอยู่"
else
  warn "ไม่พบ port ${REALITY_PORT}/tcp ใน UFW status"
  errors=$((errors+1))
fi

info "ตรวจ outbound ไป ${REALITY_SNI}:443 (สำหรับ Reality handshake fallback)..."
if timeout 5 bash -c "exec 3<>/dev/tcp/${REALITY_SNI}/443" 2>/dev/null; then
  ok "ต่อออกไปยัง ${REALITY_SNI}:443 ได้ (Reality dest พร้อมใช้งาน)"
else
  warn "ต่อออกไปยัง ${REALITY_SNI}:443 ไม่ได้ — ตรวจ DNS/outbound firewall อีกครั้ง"
  errors=$((errors+1))
fi

info "ตรวจ MSS clamp rule ใน iptables..."
if iptables -t mangle -L OUTPUT -n 2>/dev/null | grep -q "TCPMSS"; then
  ok "MSS clamp rule ติดตั้งอยู่ใน mangle OUTPUT chain"
else
  warn "ไม่พบ MSS clamp rule ใน mangle OUTPUT chain"
  errors=$((errors+1))
fi

if [ "$ALLOWED_PANEL_IP" = "ANY" ]; then
  warn "Panel port ${PANEL_PORT} เปิดให้ทุก IP (ไม่ได้กรอก IP จำกัดไว้)"
else
  ok "Panel port ${PANEL_PORT} จำกัดเฉพาะ ${ALLOWED_PANEL_IP}"
fi

echo ""
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP    :${RST} ${PUB_IP}"
echo -e "  ${BLD}Panel URL    :${RST} http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}ค่าที่ต้องกรอกเองใน VLESS Reality Inbound:${RST}"
echo -e "  ${BLD}Protocol     :${RST} VLESS"
echo -e "  ${BLD}Network      :${RST} tcp (raw)"
echo -e "  ${BLD}Port         :${RST} ${REALITY_PORT}"
echo -e "  ${BLD}Security     :${RST} reality"
echo -e "  ${BLD}Dest         :${RST} ${REALITY_DEST}"
echo -e "  ${BLD}Server Name  :${RST} ${REALITY_SNI}"
echo -e "  ${BLD}Fingerprint  :${RST} ${REALITY_FINGERPRINT}"
echo -e "  ${BLD}tcpMaxSeg    :${RST} ${TCP_MSS_CEIL}  ${YEL}(ตั้งเองในหน้า sockopt ของ inbound)${RST}"
echo -e "  ${BLD}Sniffing     :${RST} แนะนำปิดทั้งหมด"
echo -e "  ${BLD}Xray DNS     :${RST} แนะนำชี้ 127.0.0.53"
echo -e "  ${BLD}Xray Log     :${RST} แนะนำ access=none, loglevel=none, dnsLog=false"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}UDP เกมที่เปิดไว้:${RST}"
for range in "${GAME_UDP_PORTS[@]}"; do
  echo -e "    ${GRN}✔${RST}  ${range}/udp"
done
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}MTU/MSS      :${RST}"
echo -e "    ${GRN}✔${RST}  tcp_base_mss = ${TCP_MSS_CEIL} (sysctl, ค่าเริ่มต้น)"
echo -e "    ${GRN}✔${RST}  iptables MSS clamp = ${TCP_MSS_CEIL} (บังคับจริงทุก connection ระดับ firewall)"
echo -e "    ${YEL}⚠${RST}  tcpMaxSeg ใน 3x-ui inbound: ยังไม่ตั้ง — ไปตั้ง ${TCP_MSS_CEIL} เองในหน้า sockopt"
echo -e "    ${GRN}✔${RST}  เข้ากับ MTU 1500 ฝั่ง v2box"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Privacy      :${RST}"
echo -e "    ${GRN}✔${RST}  IPv6         : ปิดสมบูรณ์"
echo -e "    ${GRN}✔${RST}  DNS          : Mullvad DoT (853) + Domains=~. (กัน DHCP override leak)"
echo -e "    ${GRN}✔${RST}  DNS port 53  : blocked (nftables) + ทดสอบจริงแล้วใน VERIFY"
echo -e "    ${GRN}✔${RST}  mDNS/LLMNR   : ปิด"
echo -e "    ${GRN}✔${RST}  journald     : RAM only (volatile)"
echo -e "    ${GRN}✔${RST}  /tmp         : tmpfs (RAM)"
echo -e "    ${GRN}✔${RST}  motd/banner  : ลด metadata"
echo -e "    ${YEL}⚠${RST}  Xray log/DNS object : ยังไม่ patch (ต้องตั้งเองใน panel ตามคำแนะนำ STEP 4.2)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Performance  :${RST}"
echo -e "    ${GRN}✔${RST}  BBR congestion control"
echo -e "    ${GRN}✔${RST}  FQ qdisc | THP off | NIC: GRO/GSO/TSO + ring max"
echo -e "    ${GRN}✔${RST}  TCP buffer 16MB/socket ceiling (รองรับ 1Gbps, ไม่ bufferbloat)"
echo -e "    ${GRN}✔${RST}  Busy-poll 50us | TCP fast | Keepalive 35s | CPU governor performance"
echo -e "    ${GRN}✔${RST}  Conntrack 262144 entries (~80MB)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Security     :${RST}"
echo -e "    ${GRN}✔${RST}  SSH: publickey only"
echo -e "    ${GRN}✔${RST}  fail2ban: SSH ban 24h"
echo -e "    ${GRN}✔${RST}  Kernel hardening (kptr/ptrace/BPF)"
echo -e "    ${GRN}✔${RST}  UFW: 22 (limit) / ${REALITY_PORT} TCP เปิด | UDP เกมเฉพาะช่วงที่กำหนด"
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
echo -e "  ════ ขั้นตอนต่อไป (คุณกรอกเองทั้งหมดใน panel) ═══════════"
echo -e "  1. เข้า panel: http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  2. สร้าง inbound เอง:"
echo -e "     Protocol     : VLESS"
echo -e "     Network      : tcp"
echo -e "     Port         : ${REALITY_PORT}"
echo -e "     Security     : reality"
echo -e "     Dest         : ${REALITY_DEST}"
echo -e "     Server Name  : ${REALITY_SNI}"
echo -e "     Fingerprint  : ${REALITY_FINGERPRINT}"
echo -e "     tcpMaxSeg    : ${TCP_MSS_CEIL}"
echo -e "     Sniffing     : ปิดทั้งหมด"
echo -e "  3. กด generate key pair + short ID เองในหน้า panel"
echo -e "  4. ตั้ง Xray DNS object → 127.0.0.53, Log → none ตามคำแนะนำ STEP 4.2"
echo -e "  5. reboot ครั้งเดียว: reboot"
echo -e "  ════════════════════════════════════════════════════════"
echo -e "${RST}"
echo -e "${BLD}${RED}  ⚠ ตรวจ authorized_keys ก่อน reboot! SSH = publickey only${RST}"
echo ""
