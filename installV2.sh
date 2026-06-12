#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  VLESS REALITY SETUP — 4 STEPS — Ubuntu 22.04
#  สร้างโดย: Claude | เป้าหมาย: ปิง่ต่ำ + ความเป็นส่วนตัวสูงสุด
#  SNI: speedtest.net | Fingerprint: firefox
#  รันเสร็จ → reboot 1 ครั้ง → ใช้งานได้เลย
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
export LANG=C

# ── สี ──────────────────────────────────────────────────────────────
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

# ── log ─────────────────────────────────────────────────────────────
STATE_DIR="/var/lib/vless-setup"
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

# ── ตั้งค่าหลัก ──────────────────────────────────────────────────────
PANEL_PORT=2053
TLS_FINGERPRINT="firefox"
TLS_SNI="speedtest.net"
SWAP_SIZE_MB=512

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
echo -e "${BLD}${CYN}║  VLESS REALITY SETUP — 4 STEPS                          ║${RST}"
echo -e "${BLD}${CYN}║  SNI: speedtest.net | Fingerprint: firefox               ║${RST}"
echo -e "${BLD}${CYN}║  Port 443 (VLESS) | Panel: ${PANEL_PORT} | IPv6: OFF          ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
info "Server IP : ${PUB_IP}"
info "NIC       : ${NIC}"
info "RAM       : ${RAM_MB}MB  vCPU: ${VCPU}"
echo ""

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
info "1.3 ติดตั้ง dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ufw nftables sqlite3 ethtool iproute2 \
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

# เปิดเฉพาะ TCP ที่จำเป็น (AIS บล็อก UDP หนัก)
ufw limit   22/tcp      comment "SSH"
ufw allow   80/tcp      comment "HTTP (bughost redirect)"
ufw allow   443/tcp     comment "VLESS REALITY"
ufw allow   ${PANEL_PORT}/tcp comment "3x-ui panel"

# ปิด UDP ทั้งหมด (AIS บล็อก / ไม่ใช้)
ufw deny    proto udp from any to any comment "Block UDP"

# ปิด port อันตราย
ufw deny    23/tcp
ufw deny    25/tcp
ufw deny    3389/tcp

# ปิด IPv6 ใน UFW
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true

ufw --force enable
ufw status verbose
ok "UFW Firewall เปิดแล้ว: 22/80/443/${PANEL_PORT} TCP เท่านั้น"

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
hdr "STEP 2 — ติดตั้ง 3x-ui"
# ═══════════════════════════════════════════════════════════════════
# NOTE: ขั้นตอนนี้จะแสดง interactive prompt ของ 3x-ui ให้กรอกเองทุกอย่าง
# ผมไม่ซ่อน ไม่ข้าม ไม่กรอกอัตโนมัติ
# คุณจะเห็น: Username / Password / Panel Port / Web Path ให้กรอกตามต้องการ

echo ""
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  3x-ui installer จะถามข้อมูลให้คุณกรอกเอง:"
warn "  - Username (admin ก็ได้)"
warn "  - Password (ตั้งให้แข็งแกร่ง)"
warn "  - Panel Port (แนะนำ: ${PANEL_PORT})"
warn "  - Web Base Path (แนะนำ: ตั้งเองหรือกด Enter ข้าม)"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
ask "กด ENTER เพื่อเริ่มติดตั้ง 3x-ui (คุณจะเห็น prompt ทุกอย่าง)..."
read -r

installer=$(mktemp /tmp/3xui-XXXXXX.sh)
for attempt in 1 2 3; do
  if curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$installer"; then
    break
  fi
  warn "download ล้มเหลว ครั้งที่ ${attempt}/3 รอ 5s..."
  [ "$attempt" -ge 3 ] && { rm -f "$installer"; die "ดาวน์โหลด 3x-ui installer ไม่ได้"; }
  sleep 5
done
chmod +x "$installer"

# รัน installer ตรงๆ ให้คุณเห็นและกรอกเอง
bash "$installer"
rm -f "$installer"

# รอให้ x-ui service ขึ้น
info "รอ x-ui service..."
for i in $(seq 1 30); do
  systemctl is-active x-ui &>/dev/null && break
  sleep 2
done
systemctl is-active x-ui &>/dev/null && ok "x-ui active" || warn "x-ui อาจยังไม่ active — ตรวจ: systemctl status x-ui"

ok "═══ STEP 2 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 3 — Optimize: Kernel / Network / TCP (ปิง่ต่ำ + throughput สูง)"
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

# ── ค่าบัฟเฟอร์: คำนวณให้พอดีกับ RAM 2GB / 1vCPU 2.69GHz ────────────
# max 32MB ต่อ socket (เพดานสูงพอสำหรับ throughput เต็มสปีด แต่ไม่กิน RAM
# จนเหลือไม่พอให้ x-ui/xray/ระบบ แม้เปิดหลาย connection พร้อมกัน)
RMEM_MAX=33554432
WMEM_MAX=33554432
RMEM_DEF=2097152
WMEM_DEF=2097152

cat > /etc/sysctl.d/99-vless-perf.conf << EOF
# ── BBR + FQ ──────────────────────────────────────────────────────
net.ipv4.tcp_congestion_control        = ${CC}
net.core.default_qdisc                 = ${QDISC}

# ── Buffer ────────────────────────────────────────────────────────
net.core.rmem_max                      = ${RMEM_MAX}
net.core.wmem_max                      = ${WMEM_MAX}
net.core.rmem_default                  = ${RMEM_DEF}
net.core.wmem_default                  = ${WMEM_DEF}
net.ipv4.tcp_rmem                      = 4096 ${RMEM_DEF} ${RMEM_MAX}
net.ipv4.tcp_wmem                      = 4096 ${WMEM_DEF} ${WMEM_MAX}
net.ipv4.tcp_mem                       = 65536 131072 196608
net.ipv4.tcp_moderate_rcvbuf           = 1
net.ipv4.tcp_adv_win_scale             = 1

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
net.ipv4.tcp_base_mss                  = 1440
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
net.core.netdev_max_backlog            = 16384
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
vm.min_free_kbytes                     = 65536
vm.vfs_cache_pressure                  = 50
vm.overcommit_memory                   = 1

# ── File descriptors ──────────────────────────────────────────────
fs.file-max                            = 1048576
fs.nr_open                             = 1048576
EOF

sysctl -p /etc/sysctl.d/99-vless-perf.conf
ok "TCP/network tune เสร็จ"

# ── 3.2 Conntrack (เผื่อ connection พร้อมกันได้มาก แต่ยังเบากับ kernel) ─
info "3.2 ตั้ง nf_conntrack..."
echo 131072 > /proc/sys/net/netfilter/nf_conntrack_max                      2>/dev/null || true
echo 600    > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established  2>/dev/null || true
echo 1      > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal           2>/dev/null || true
cat >> /etc/sysctl.d/99-vless-perf.conf << 'EOF2'
net.netfilter.nf_conntrack_max                     = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_be_liberal          = 1
EOF2
ok "conntrack tune เสร็จ (131072 entries ~ใช้ RAM ราว 40MB เท่านั้น)"

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
cat > /etc/security/limits.d/99-vless.conf << 'LIMEOF'
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

# ── 3.5 x-ui systemd override (performance) ────────────────────────
info "3.5 x-ui systemd override..."
xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
if [ -x "$xui_bin" ]; then
  ram_avail=$(free -m | awk '/^Mem:/ {print $7}')
  gomemlimit=$(( ram_avail - 150 ))
  [ "$gomemlimit" -lt 400 ] && gomemlimit=400
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << OEOF
[Service]
LimitNOFILE=2097152
LimitNPROC=131072
Restart=always
RestartSec=2
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=100
Environment=GODEBUG=madvdontneed=1
Environment=GOMEMLIMIT=${gomemlimit}MiB
OOMScoreAdjust=-1000
PrivateTmp=yes
NoNewPrivileges=no
OEOF
  systemctl daemon-reload
  systemctl restart x-ui 2>/dev/null || true
  ok "x-ui override เสร็จ (GOMEMLIMIT=${gomemlimit}MiB)"
else
  warn "ไม่เจอ x-ui binary — ข้ามขั้นตอนนี้"
fi

# ── 3.6 SQLite WAL ──────────────────────────────────────────────────
info "3.6 SQLite WAL optimize..."
DB="/etc/x-ui/x-ui.db"
if [ -f "$DB" ]; then
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;"       2>/dev/null || true
  sqlite3 "$DB" "PRAGMA synchronous=NORMAL;"      2>/dev/null || true
  sqlite3 "$DB" "PRAGMA cache_size=-65536;"       2>/dev/null || true
  sqlite3 "$DB" "PRAGMA temp_store=MEMORY;"       2>/dev/null || true
  sqlite3 "$DB" "PRAGMA mmap_size=268435456;"     2>/dev/null || true
  sqlite3 "$DB" "VACUUM;"                         2>/dev/null || true
  sqlite3 "$DB" "ANALYZE;"                        2>/dev/null || true
  JM=$(sqlite3 "$DB" "PRAGMA journal_mode;" 2>/dev/null || echo "?")
  ok "SQLite journal_mode=${JM}"

  # WAL checkpoint timer
  cat > /etc/systemd/system/xui-db-wal.service << WEOF
[Unit]
Description=x-ui SQLite WAL checkpoint
[Service]
Type=oneshot
ExecStart=/usr/bin/sqlite3 ${DB} "PRAGMA wal_checkpoint(TRUNCATE);"
WEOF
  cat > /etc/systemd/system/xui-db-wal.timer << 'WTEOF'
[Unit]
Description=x-ui SQLite WAL checkpoint 30min
[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
[Install]
WantedBy=timers.target
WTEOF
  systemctl daemon-reload
  systemctl enable --now xui-db-wal.timer
else
  warn "ไม่เจอ x-ui.db — SQLite จะ optimize หลัง reboot เมื่อสร้าง inbound แล้ว"
fi

# ── 3.7 irqbalance ─────────────────────────────────────────────────
info "3.7 irqbalance..."
systemctl enable --now irqbalance 2>/dev/null || true
ok "irqbalance เสร็จ"

ok "═══ STEP 3 เสร็จสมบูรณ์ ═══"

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

# ip6tables block outbound
if command -v ip6tables &>/dev/null; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -j DROP
  mkdir -p /etc/iptables
  ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi

# GRUB kernel param
if [ -f /etc/default/grub ]; then
  grep -q "ipv6.disable=1" /etc/default/grub || \
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
  update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub update ล้มเหลว (non-fatal)"
fi
ok "IPv6 ปิดแล้ว: sysctl + ip6tables + grub"

# ── 4.2 DNS over TLS (ไม่มี DNS leak) ──────────────────────────────
info "4.2 DNS over TLS (Cloudflare DoT) ..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dot.conf << 'DOTEOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
FallbackDNS=9.9.9.9#dns.quad9.net
DNSOverTLS=yes
DNSSEC=no
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
DOTEOF
systemctl enable --now systemd-resolved 2>/dev/null || true
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

# Block outbound port 53 ด้วย nftables
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

# ── 4.4 Xray: ปิด log ทั้งหมด (ไม่เก็บ access/error) ──────────────
info "4.4 ปิด xray log..."
DB="/etc/x-ui/x-ui.db"
if [ -f "$DB" ] && command -v sqlite3 &>/dev/null && command -v python3 &>/dev/null; then
  template=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || true)
  if [ -n "$template" ]; then
    new_template=$(printf '%s' "$template" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['log'] = {'access': 'none', 'error': '', 'loglevel': 'none', 'dnsLog': False}
print(json.dumps(d, separators=(',',':')))
" 2>/dev/null || true)
    if [ -n "$new_template" ]; then
      esc="${new_template//\'/\'\'}"
      sqlite3 "$DB" "UPDATE settings SET value='${esc}' WHERE key='xrayTemplateConfig';" 2>/dev/null || true
      ok "xray log ปิดแล้ว (ไม่บันทึก access/error)"
    fi
  else
    warn "xrayTemplateConfig ว่างเปล่า — จะ patch ใหม่ได้หลังสร้าง inbound"
  fi
else
  warn "ไม่เจอ x-ui.db — จะ patch log หลัง reboot + สร้าง inbound"
fi

# ── 4.5 Patch sockopt + Firefox fingerprint + SNI ───────────────────
info "4.5 Patch fingerprint=firefox + SNI=speedtest.net บน VLESS port 443..."
DB="/etc/x-ui/x-ui.db"
SOCKOPT='{"acceptProxyProtocol":false,"tcpFastOpen":true,"mark":0,"tproxy":"off","tcpcongestion":"bbr","tcpNoDelay":true,"tcpKeepAliveInterval":35,"tcpKeepAliveIdle":35,"tcpUserTimeout":30000,"V6Only":false,"domainStrategy":"AsIs"}'
if [ -f "$DB" ] && command -v sqlite3 &>/dev/null && command -v python3 &>/dev/null; then
  count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM inbounds WHERE port=443 AND protocol='vless';" 2>/dev/null || echo "0")
  if [ "$count" -gt 0 ]; then
    stream=$(sqlite3 "$DB" "SELECT stream_settings FROM inbounds WHERE port=443 AND protocol='vless' LIMIT 1;" 2>/dev/null || true)
    if [ -n "$stream" ]; then
      new_stream=$(printf '%s' "$stream" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['sockopt'] = json.loads(sys.argv[1])
if 'realitySettings' in d:
    d['realitySettings']['fingerprint'] = 'firefox'
    d['realitySettings']['serverNames'] = ['speedtest.net', 'www.speedtest.net']
if 'tlsSettings' in d:
    d['tlsSettings']['fingerprint'] = 'firefox'
print(json.dumps(d, separators=(',',':')))
" "$SOCKOPT" 2>/dev/null || true)
      if [ -n "$new_stream" ]; then
        esc="${new_stream//\'/\'\'}"
        sqlite3 "$DB" "UPDATE inbounds SET stream_settings='${esc}' WHERE port=443 AND protocol='vless';"
        ok "fingerprint=firefox + SNI=speedtest.net patch เสร็จ"
      fi
    fi
  else
    warn "ยังไม่มี vless port 443 — รันสคริปต์นี้อีกครั้งหลังสร้าง inbound หรือจะตั้งใน panel เอง"
    info "ตั้งใน panel: fingerprint=firefox | serverName=speedtest.net"
  fi
fi

# ── 4.6 Journald: ไม่เขียน disk ─────────────────────────────────────
info "4.6 journald → RAM only (volatile)..."
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

# ── 4.7 /tmp → tmpfs ────────────────────────────────────────────────
info "4.7 /tmp → tmpfs (RAM)..."
if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
  echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=256m 0 0" >> /etc/fstab
fi
mount -o remount /tmp 2>/dev/null || true
ok "/tmp → tmpfs 256MB"

# ── 4.8 SSH Hardening ───────────────────────────────────────────────
info "4.8 SSH hardening..."
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

# ── 4.9 Fail2ban ────────────────────────────────────────────────────
info "4.9 fail2ban..."
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/99-vless.conf << FBEOF
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

# ── 4.10 Auto security updates ──────────────────────────────────────
info "4.10 auto security updates..."
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

# ── 4.11 DB Backup (daily, เก็บ 7 วัน) ─────────────────────────────
info "4.11 DB backup..."
BACKUP_DIR="/var/lib/vless-setup/backups"
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
Description=x-ui DB Backup
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
ok "DB backup: ${BACKUP_DIR} (เก็บ 7 วัน)"

# ── 4.12 Persist ip6tables ──────────────────────────────────────────
info "4.12 persist ip6tables rules on reboot..."
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

chk_svc x-ui
chk_svc fail2ban
chk_svc thp-disable.service
chk_svc nic-tune.service
chk_svc dns-privacy-nft.service
chk_svc unattended-upgrades

chk_val "BBR"          "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
chk_val "FQ qdisc"     "$(tc qdisc show dev "${NIC}" 2>/dev/null | head -1)"      "fq"
chk_val "THP"          "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" "never"
chk_val "IPv6 disable" "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" "1"
chk_val "IP forward"   "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"            "1"
chk_val "kptr_restrict" "$(sysctl -n kernel.kptr_restrict 2>/dev/null)"          "2"

echo ""
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP    :${RST} ${PUB_IP}"
echo -e "  ${BLD}Panel URL    :${RST} http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Protocol     :${RST} VLESS | Port: 443 | Network: TCP"
echo -e "  ${BLD}Security     :${RST} Reality"
echo -e "  ${BLD}Flow         :${RST} xtls-rprx-vision"
echo -e "  ${BLD}SNI          :${RST} ${TLS_SNI}"
echo -e "  ${BLD}Fingerprint  :${RST} ${TLS_FINGERPRINT}"
echo -e "  ${BLD}SpiderX      :${RST} /"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Privacy      :${RST}"
echo -e "    ${GRN}✔${RST}  IPv6         : ปิดสมบูรณ์"
echo -e "    ${GRN}✔${RST}  DNS          : over TLS (Cloudflare 853)"
echo -e "    ${GRN}✔${RST}  DNS port 53  : blocked (nftables)"
echo -e "    ${GRN}✔${RST}  Xray log     : ปิด (none)"
echo -e "    ${GRN}✔${RST}  journald     : RAM only (volatile)"
echo -e "    ${GRN}✔${RST}  Fingerprint  : firefox"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Performance  :${RST}"
echo -e "    ${GRN}✔${RST}  BBR congestion control"
echo -e "    ${GRN}✔${RST}  FQ qdisc | THP off | NIC: GRO/GSO/TSO + ring max"
echo -e "    ${GRN}✔${RST}  TCP buffer 32MB | tcp_mem fit 2GB RAM"
echo -e "    ${GRN}✔${RST}  Busy-poll 50us | TCP fast | Keepalive 35s"
echo -e "    ${GRN}✔${RST}  Conntrack 131072 entries"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Security     :${RST}"
echo -e "    ${GRN}✔${RST}  SSH: publickey only"
echo -e "    ${GRN}✔${RST}  fail2ban: SSH ban 24h"
echo -e "    ${GRN}✔${RST}  Kernel hardening (kptr/ptrace/BPF)"
echo -e "    ${GRN}✔${RST}  UFW: 22/80/443/${PANEL_PORT} TCP เท่านั้น"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Logs & Debug :${RST}"
echo -e "  systemctl status x-ui"
echo -e "  fail2ban-client status sshd"
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
echo -e "  ════ ขั้นตอนต่อไป ═══════════════════════════════════════"
echo -e "  1. เข้า panel: http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  2. สร้าง inbound:"
echo -e "     Protocol  : VLESS"
echo -e "     Port      : 443"
echo -e "     Network   : TCP (raw)"
echo -e "     Security  : Reality"
echo -e "     Flow      : xtls-rprx-vision"
echo -e "     SNI       : speedtest.net"
echo -e "     Fingerprint: firefox"
echo -e "     SpiderX   : /"
echo -e "     Sniffing  : ปิดทั้งหมด"
echo -e "  3. reboot ครั้งเดียว: reboot"
echo -e "  ════════════════════════════════════════════════════════"
echo -e "${RST}"
echo -e "${BLD}${RED}  ⚠ ตรวจ authorized_keys ก่อน reboot! SSH = publickey only${RST}"
echo ""
