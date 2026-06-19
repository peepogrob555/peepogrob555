#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  VLESS REALITY SETUP — 4 STEPS — Ubuntu 22.04 LTS
#  สร้างโดย: Claude | เป้าหมาย: ความปลอดภัยสูงสุด + รองรับเน็ตแรง (500Mbps@100ms)
#  SNI: speedtest.net | Fingerprint: firefox | DNS: Cloudflare (1.1.1.1 DoT)
#  เน้นใช้งานเกม/สตรีมหนัง/ดาวน์โหลด-อัพโหลดหนักได้จริง ไม่ใช่แค่ทฤษฎี
#  รันเสร็จ → reboot 1 ครั้ง → ใช้งานได้เลย
#
#  [PATCH] เพิ่ม DNS preflight check + auto-fix ก่อนเริ่ม step ใดๆ
#  [PATCH] เพิ่มฟังก์ชัน dl_retry สำหรับ curl/download ที่ retry อัตโนมัติ
#  [PATCH] ใช้ dl_retry กับการโหลด 3x-ui installer และการเช็ค public IP
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

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root (sudo bash install.sh)"

# ── [PATCH] ฟังก์ชัน download แบบ retry ──────────────────────────────
# ลอง curl สูงสุด N ครั้ง, รอเพิ่มขึ้นทุกครั้ง (backoff), ใช้ -4 บังคับ IPv4
# คืนค่า 0 = สำเร็จ, อื่นๆ = ล้มเหลว
dl_retry() {
  local url="$1" out="${2:-}" tries=5 wait=2 i
  for ((i=1; i<=tries; i++)); do
    if [ -n "$out" ]; then
      curl -4 -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$out" && return 0
    else
      curl -4 -fsSL --connect-timeout 10 --max-time 30 "$url" && return 0
    fi
    warn "ดาวน์โหลด ${url} ล้มเหลว (ครั้งที่ ${i}/${tries}) — รอ ${wait}s แล้วลองใหม่..."
    sleep "$wait"
    wait=$((wait * 2))
  done
  return 1
}

# ── [PATCH] DNS preflight: เช็ค + ซ่อม DNS resolution ก่อนเริ่มทุกอย่าง ──
hdr "PRE-CHECK — ตรวจสอบ DNS resolution"
_dns_ok() {
  getent hosts raw.githubusercontent.com &>/dev/null \
    || curl -4 -fsS --connect-timeout 5 --max-time 8 -o /dev/null https://raw.githubusercontent.com 2>/dev/null
}

if _dns_ok; then
  ok "DNS resolution ใช้งานได้ปกติ"
else
  warn "DNS resolution ใช้งานไม่ได้ — กำลังพยายามซ่อม..."

  # 1) restart systemd-resolved เผื่อมันค้าง
  if systemctl is-active systemd-resolved &>/dev/null; then
    info "ลอง restart systemd-resolved..."
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 2
  fi
  _dns_ok && ok "ซ่อมสำเร็จหลัง restart systemd-resolved" || true

  # 2) ลองตั้ง resolv.conf ชี้ public DNS ตรงๆ ชั่วคราว (ไม่ symlink ทับถาวร)
  if ! _dns_ok; then
    info "ลอง fallback ไปใช้ public DNS (1.1.1.1 / 8.8.8.8) ชั่วคราว..."
    if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
      cp -L /etc/resolv.conf /etc/resolv.conf.bak.$(date +%s) 2>/dev/null || true
    fi
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << 'DNSFALLBACK'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
DNSFALLBACK
    sleep 1
    _dns_ok && ok "ซ่อมสำเร็จด้วย fallback DNS ตรงๆ (จะถูกตั้งใหม่เป็น DoT ใน step 4)" || true
  fi

  # 3) เช็คเน็ตทั่วไปว่าใช้งานได้ไหม (เผื่อปัญหาไม่ใช่ DNS แต่เป็น routing/firewall)
  if ! _dns_ok; then
    if ping -c1 -W3 1.1.1.1 &>/dev/null; then
      warn "ping IP ได้ปกติ แต่ resolve โดเมนไม่ได้ — อาจเป็นปัญหา DNS server ฝั่ง provider"
    else
      warn "ping IP ก็ไม่ได้ — เครื่องอาจไม่มี outbound network เลย ตรวจสอบ network/routing ของ VPS ก่อน"
    fi
    die "DNS/Network ยังใช้งานไม่ได้หลังพยายามซ่อม — กรุณาตรวจสอบเครือข่ายของ VPS (เช่น ติดต่อ provider) แล้วรันสคริปต์ใหม่"
  fi
fi

# ── ตรวจ Ubuntu version (non-fatal — แค่เตือน) ───────────────────────
OS_ID=""; OS_VER=""
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
fi
if [ "$OS_ID" != "ubuntu" ] || [ "$OS_VER" != "22.04" ]; then
  warn "สคริปต์นี้ปรับสำหรับ Ubuntu 22.04 — ตรวจพบระบบ: ${OS_ID:-unknown} ${OS_VER:-?}"
  warn "ยังรันต่อได้ แต่บางคำสั่ง (GRUB path / เวอร์ชัน package) อาจต่างจากที่ทดสอบไว้"
else
  ok "ตรวจพบ Ubuntu 22.04 ตรงตามที่สคริปต์ออกแบบไว้"
fi

# ── ตั้งค่าหลัก ──────────────────────────────────────────────────────
PANEL_PORT=2053
TLS_FINGERPRINT="firefox"
TLS_SNI="speedtest.net"
SWAP_SIZE_MB=4096

_detect_nic() {
  ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}
NIC=$(_detect_nic)
[ -z "$NIC" ] && NIC=$(ip link show | awk -F': ' '/^[0-9]+: / && !/lo:/ {print $2}' | head -1 | cut -d@ -f1)
[ -z "$NIC" ] && NIC="eth0"

RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
VCPU=$(nproc)
PUB_IP=$(dl_retry https://ifconfig.me - 2>/dev/null || dl_retry https://api.ipify.org - 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VLESS REALITY SETUP — 4 STEPS (Ubuntu 22.04)            ║${RST}"
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
  curl ufw nftables iptables sqlite3 ethtool iproute2 \
  fail2ban auditd \
  python3 libcap2-bin irqbalance \
  unattended-upgrades
ok "ติดตั้งแพ็กเกจหลักเสร็จ"

EXTRA_MOD_PKG="linux-modules-extra-$(uname -r)"
if apt-cache show "${EXTRA_MOD_PKG}" &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${EXTRA_MOD_PKG}" \
    && ok "ติดตั้ง ${EXTRA_MOD_PKG} เสร็จ (รองรับ sch_cake)" \
    || warn "ติดตั้ง ${EXTRA_MOD_PKG} ล้มเหลว (non-fatal)"
else
  warn "ไม่พบแพ็กเกจ ${EXTRA_MOD_PKG} — จะตรวจจริงใน step 3.1"
fi

# ── 1.4 Firewall (UFW) ──────────────────────────────────────────────
info "1.4 ตั้ง UFW Firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

ufw limit   22/tcp      comment "SSH"
ufw allow   80/tcp      comment "HTTP (bughost redirect / ACME)"
ufw allow   443/tcp     comment "VLESS REALITY (หลัก)"
ufw allow   ${PANEL_PORT}/tcp comment "3x-ui panel"

ufw allow 2052/tcp comment "Cloudflare HTTP"
ufw allow 2082/tcp comment "Cloudflare HTTP"
ufw allow 2086/tcp comment "Cloudflare HTTP"
ufw allow 2095/tcp comment "Cloudflare HTTP"
ufw allow 8080/tcp comment "Cloudflare HTTP"
ufw allow 8880/tcp comment "Cloudflare HTTP"
ufw allow 2083/tcp comment "Cloudflare HTTPS"
ufw allow 2087/tcp comment "Cloudflare HTTPS"
ufw allow 2096/tcp comment "Cloudflare HTTPS"
ufw allow 8443/tcp comment "Cloudflare HTTPS"

ufw deny 21/tcp    comment "FTP"
ufw deny 23/tcp    comment "Telnet"
ufw deny 25/tcp    comment "SMTP"
ufw deny 110/tcp   comment "POP3"
ufw deny 135/tcp   comment "MS-RPC"
ufw deny 137/tcp   comment "NetBIOS"
ufw deny 138/tcp   comment "NetBIOS"
ufw deny 139/tcp   comment "NetBIOS/SMB"
ufw deny 143/tcp   comment "IMAP"
ufw deny 445/tcp   comment "SMB"
ufw deny 1433/tcp  comment "MSSQL"
ufw deny 3306/tcp  comment "MySQL"
ufw deny 3389/tcp  comment "RDP"
ufw deny 5432/tcp  comment "PostgreSQL"
ufw deny 5900/tcp  comment "VNC"
ufw deny 6379/tcp  comment "Redis"
ufw deny 8291/tcp  comment "Mikrotik Winbox"
ufw deny 11211/tcp comment "Memcached"

ufw default deny incoming

cat > /etc/nftables-udp-inbound.conf << 'UDPINEOF'
#!/usr/sbin/nft -f
table inet udp_inbound {
  chain input_udp {
    type filter hook input priority -1; policy accept;
    meta l4proto udp ct state established,related accept
    meta l4proto udp ct state new drop
  }
}
UDPINEOF
nft_udp_err=$(nft -f /etc/nftables-udp-inbound.conf 2>&1)
nft_udp_rc=$?
if [ "$nft_udp_rc" -eq 0 ]; then
  info "nftables: inbound UDP ใหม่ทุกพอร์ตถูก drop — outbound UDP ไม่ถูกแตะ"
else
  warn "nftables UDP inbound rule ล้มเหลว (non-fatal): ${nft_udp_err}"
fi

cat > /etc/systemd/system/udp-inbound-nft.service << 'UDPSEOF'
[Unit]
Description=Drop new inbound UDP, allow established/related only
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables-udp-inbound.conf
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UDPSEOF
systemctl daemon-reload
systemctl enable --now udp-inbound-nft.service

sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true

ufw --force enable
ufw status verbose
ok "UFW Firewall เปิดแล้ว — TCP allow: 22/80/443/${PANEL_PORT} + Cloudflare ports | UDP inbound ใหม่: drop | outbound: ปกติ"

# ── 1.5 Swap ────────────────────────────────────────────────────────
info "1.5 สร้าง Swap ${SWAP_SIZE_MB}MB..."
AVAIL_DISK_MB=$(df -m --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "${AVAIL_DISK_MB:-}" ] && [ "$AVAIL_DISK_MB" -lt $((SWAP_SIZE_MB + 1024)) ]; then
  warn "เหลือพื้นที่ดิสก์ ${AVAIL_DISK_MB}MB — น้อยกว่า swap ${SWAP_SIZE_MB}MB + เผื่อ 1GB"
fi
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
# [PATCH] ใช้ dl_retry แทน curl ตรงๆ เพื่อกัน DNS/network กระตุกชั่วคราว
# download ไฟล์ลงดิสก์ก่อน แล้วรันด้วย stdin=/dev/tty
# เพื่อให้ interactive prompt (username/password/port) ทำงานได้จริง
# แม้จะรันสคริปต์นี้ด้วย bash <(curl ...) ก็ตาม
_3xui_installer=$(mktemp /tmp/3xui-XXXXXX.sh)
if ! dl_retry https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh "$_3xui_installer"; then
  die "ดาวน์โหลด 3x-ui installer ไม่ได้ (ลองแล้วหลายครั้ง) — ตรวจสอบเครือข่าย/DNS ของ VPS แล้วรันสคริปต์ใหม่อีกครั้ง"
fi
[ -s "$_3xui_installer" ] || die "ดาวน์โหลด 3x-ui installer ได้ไฟล์ว่างเปล่า — ลองรันสคริปต์ใหม่อีกครั้ง"
chmod +x "$_3xui_installer"
bash "$_3xui_installer" < /dev/tty
rm -f "$_3xui_installer"

ok "═══ STEP 2 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 3 — Optimize: Kernel / Network / TCP (ปิงต่ำ + throughput สูง)"
# ═══════════════════════════════════════════════════════════════════

# ── 3.1 BBR + CAKE Tune ─────────────────────────────────────────────
info "3.1 โหลด BBR + CAKE + ตั้งค่า TCP/network..."
modprobe tcp_bbr     2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

CC="bbr"
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
  || { warn "BBR ไม่มี — ใช้ cubic"; CC="cubic"; }

QDISC="cake"
modprobe sch_cake 2>/dev/null
if ! lsmod | grep -q '^sch_cake' && ! grep -qx sch_cake /proc/modules 2>/dev/null; then
  depmod -a 2>/dev/null || true
  modprobe sch_cake 2>/dev/null
fi
if modinfo sch_cake &>/dev/null && modprobe sch_cake 2>/dev/null; then
  ok "โมดูล sch_cake โหลดสำเร็จ — ใช้ cake เป็น qdisc"
else
  warn "โหลด sch_cake ไม่ได้ — fallback เป็น fq"
  QDISC="fq"
  modinfo sch_fq &>/dev/null || { warn "fq ก็ไม่มี — fallback เป็น fq_codel"; QDISC="fq_codel"; }
fi

RMEM_MAX=8388608
WMEM_MAX=8388608
RMEM_DEF=4194304
WMEM_DEF=4194304
RMEM_MIN=2097152
WMEM_MIN=2097152

cat > /etc/sysctl.d/99-vless-perf.conf << EOF
# ── BBR + CAKE ────────────────────────────────────────────────────
net.ipv4.tcp_congestion_control        = ${CC}
net.core.default_qdisc                 = ${QDISC}

# ── Buffer (floor 2MB / default 4MB / ceiling 8MB — BDP 500Mbps@100ms) ──
net.core.rmem_max                      = ${RMEM_MAX}
net.core.wmem_max                      = ${WMEM_MAX}
net.core.rmem_default                  = ${RMEM_DEF}
net.core.wmem_default                  = ${WMEM_DEF}
net.ipv4.tcp_rmem                      = ${RMEM_MIN} ${RMEM_DEF} ${RMEM_MAX}
net.ipv4.tcp_wmem                      = ${WMEM_MIN} ${WMEM_DEF} ${WMEM_MAX}
net.ipv4.tcp_mem                       = 98304 131072 196608
net.ipv4.tcp_moderate_rcvbuf           = 1
net.ipv4.tcp_adv_win_scale             = 1
net.ipv4.tcp_notsent_lowat             = 131072

# ── Loss recovery ─────────────────────────────────────────────────
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
net.core.netdev_max_backlog            = 32768
net.core.netdev_budget                 = 600
net.core.netdev_budget_usecs           = 4000
net.ipv4.ip_local_port_range           = 1024 65535

# ── Busy poll ─────────────────────────────────────────────────────
net.core.busy_poll                     = 50
net.core.busy_read                     = 50

# ── TIME_WAIT ─────────────────────────────────────────────────────
net.ipv4.tcp_tw_reuse                  = 1
net.ipv4.tcp_max_tw_buckets            = 1440000

# ── Forward ───────────────────────────────────────────────────────
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

sysctl -p /etc/sysctl.d/99-vless-perf.conf
ok "TCP/network tune เสร็จ (qdisc=${QDISC}, cc=${CC})"

# ── 3.2 Conntrack ───────────────────────────────────────────────────
info "3.2 ตั้ง nf_conntrack..."
echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max                     2>/dev/null || true
echo 600    > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
echo 1      > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal          2>/dev/null || true
cat >> /etc/sysctl.d/99-vless-perf.conf << 'EOF2'
net.netfilter.nf_conntrack_max                     = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_be_liberal          = 1
EOF2
ok "conntrack tune เสร็จ (262144 entries ~80MB)"

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

modprobe "sch_${QDISC}" 2>/dev/null || true
tc qdisc del dev "${NIC}" root 2>/dev/null || true
if tc qdisc add dev "${NIC}" root handle 1: "${QDISC}" 2>/dev/null; then
  ok "ผูก qdisc ${QDISC} กับ ${NIC} สำเร็จ"
else
  warn "ผูก qdisc ${QDISC} ไม่สำเร็จ — fallback เป็น fq_codel"
  QDISC="fq_codel"
  tc qdisc add dev "${NIC}" root handle 1: fq_codel 2>/dev/null || true
  sed -i "s/^net.core.default_qdisc.*/net.core.default_qdisc                 = fq_codel/" /etc/sysctl.d/99-vless-perf.conf
  sysctl -p /etc/sysctl.d/99-vless-perf.conf >/dev/null 2>&1 || true
fi

cat > /etc/systemd/system/nic-tune.service << NSEOF
[Unit]
Description=NIC Tuning persistent (light)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'modprobe sch_${QDISC} 2>/dev/null || true; ethtool -K ${NIC} gro on gso on tso on 2>/dev/null; ethtool -G ${NIC} rx ${RX_MAX} tx ${TX_MAX} 2>/dev/null; ip link set ${NIC} txqueuelen 10000 2>/dev/null; tc qdisc del dev ${NIC} root 2>/dev/null; tc qdisc add dev ${NIC} root handle 1: ${QDISC} 2>/dev/null || tc qdisc add dev ${NIC} root handle 1: fq_codel 2>/dev/null || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
NSEOF
systemctl daemon-reload
systemctl enable --now nic-tune.service
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

# ── 3.5 x-ui systemd override ───────────────────────────────────────
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
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;"    2>/dev/null || true
  sqlite3 "$DB" "PRAGMA synchronous=NORMAL;"  2>/dev/null || true
  sqlite3 "$DB" "PRAGMA cache_size=-65536;"   2>/dev/null || true
  sqlite3 "$DB" "PRAGMA temp_store=MEMORY;"   2>/dev/null || true
  sqlite3 "$DB" "PRAGMA mmap_size=268435456;" 2>/dev/null || true
  sqlite3 "$DB" "VACUUM;"                     2>/dev/null || true
  sqlite3 "$DB" "ANALYZE;"                    2>/dev/null || true
  JM=$(sqlite3 "$DB" "PRAGMA journal_mode;" 2>/dev/null || echo "?")
  ok "SQLite journal_mode=${JM}"

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

# ── 3.7 irqbalance ──────────────────────────────────────────────────
info "3.7 irqbalance..."
systemctl enable --now irqbalance 2>/dev/null || true
ok "irqbalance เสร็จ"

ok "═══ STEP 3 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 4 — Privacy & Security (ไม่เก็บ log / ไม่ leak IP / ลบตัวตน)"
# ═══════════════════════════════════════════════════════════════════

# ── 4.1 ปิด IPv6 ────────────────────────────────────────────────────
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
  warn "ไม่เจอ ip6tables — ข้าม outbound IPv6 block (sysctl ยังทำงาน)"
fi

if [ -f /etc/default/grub ]; then
  grep -q "ipv6.disable=1" /etc/default/grub || \
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
  update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || warn "grub update ล้มเหลว (non-fatal)"
fi
ok "IPv6 ปิดแล้ว: sysctl + ip6tables + grub"

# ── 4.2 DNS over TLS ────────────────────────────────────────────────
info "4.2 DNS over TLS (Cloudflare 1.1.1.1) ..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dot.conf << 'DOTEOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com
FallbackDNS=1.0.0.1#cloudflare-dns.com
DNSOverTLS=yes
DNSSEC=yes
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
Domains=~.
MulticastDNS=no
LLMNR=no
DOTEOF
systemctl enable --now systemd-resolved 2>/dev/null || true
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

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
nft -f /etc/nftables-dns-block.conf 2>/dev/null \
  && info "nftables: block port 53 plain DNS" \
  || warn "nftables DNS block ล้มเหลว (non-fatal)"

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

# ── [PATCH] ตรวจ DNS resolution ใหม่อีกครั้งหลังเปลี่ยนเป็น DoT ──────
info "4.2c ตรวจสอบ DNS resolution หลังเปลี่ยนเป็น DoT..."
sleep 2
if _dns_ok; then
  ok "DNS over TLS resolve โดเมนได้ปกติ"
else
  warn "DNS over TLS resolve ไม่ได้ — กำลัง rollback nftables DNS block ชั่วคราวเพื่อไม่ให้ระบบใช้งานไม่ได้"
  systemctl stop dns-privacy-nft.service 2>/dev/null || true
  nft delete table inet dns_privacy 2>/dev/null || true
  systemctl disable dns-privacy-nft.service 2>/dev/null || true
  warn "ปิด DNS-block ไปแล้ว — แนะนำเช็ค resolvectl status ด้วยตัวเองหลัง reboot แล้วเปิดใหม่: systemctl enable --now dns-privacy-nft.service"
fi

# ── 4.2b Patch Xray internal DNS ────────────────────────────────────
info "4.2b Patch Xray internal DNS → บังคับผ่าน local DoT stub..."
DB="/etc/x-ui/x-ui.db"
if [ -f "$DB" ] && command -v sqlite3 &>/dev/null && command -v python3 &>/dev/null; then
  template=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || true)
  if [ -n "$template" ]; then
    new_template=$(printf '%s' "$template" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['dns'] = {'servers': ['127.0.0.53'], 'queryStrategy': 'UseIPv4'}
print(json.dumps(d, separators=(',',':')))
" 2>/dev/null || true)
    if [ -n "$new_template" ]; then
      esc="${new_template//\'/\'\'}"
      sqlite3 "$DB" "UPDATE settings SET value='${esc}' WHERE key='xrayTemplateConfig';" 2>/dev/null || true
      ok "Xray internal DNS → 127.0.0.53 (local DoT stub)"
    else
      warn "patch Xray DNS ล้มเหลว (JSON parse error) — non-fatal"
    fi
  else
    warn "xrayTemplateConfig ว่างเปล่า — จะ patch ใหม่ได้หลังสร้าง inbound"
  fi
  systemctl restart x-ui 2>/dev/null || true
else
  warn "ไม่เจอ x-ui.db — จะ patch Xray DNS หลัง reboot + สร้าง inbound"
fi

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

# ── 4.4 Xray: ปิด log ───────────────────────────────────────────────
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
      ok "xray log ปิดแล้ว"
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
    warn "ยังไม่มี vless port 443 — ตั้งใน panel: fingerprint=firefox | serverName=speedtest.net"
  fi
fi

# ── 4.6 Journald: RAM only ───────────────────────────────────────────
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
# ── [PATCH] เช็ค authorized_keys ก่อนล็อก password auth ──────────────
_has_authorized_key=0
for keyfile in /root/.ssh/authorized_keys $(find /home -maxdepth 3 -path '*/.ssh/authorized_keys' 2>/dev/null); do
  [ -s "$keyfile" ] && _has_authorized_key=1 && break
done
if [ "$_has_authorized_key" -eq 0 ]; then
  warn "ไม่พบ SSH public key (authorized_keys) ในระบบเลย!"
  warn "ข้ามการล็อก PasswordAuthentication=no เพื่อกัน lock ตัวเองออกจาก SSH"
  rm -f /etc/ssh/sshd_config.d/99-hardened.conf
  cat > /etc/ssh/sshd_config.d/99-hardened.conf << 'SSHEOF2'
Protocol 2
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
SSHEOF2
  warn "กรุณาเพิ่ม SSH key ของคุณก่อนแล้วค่อยตั้ง PasswordAuthentication no เอง"
fi
if sshd -t 2>/dev/null; then
  systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "SSH hardened"
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
hdr "ติดตั้งคำสั่ง vless-verify"
# ═══════════════════════════════════════════════════════════════════
cat > /usr/local/bin/vless-verify << VERIFYEOF
#!/usr/bin/env bash
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

sep()  { echo -e "\${DIM}\${CYN}──────────────────────────────────────────────────────\${RST}"; }
hdr()  { echo -e "\n\${BLD}\${CYN}▶  \$1\${RST}"; sep; }
ok()   { echo -e "  \${GRN}✔\${RST}  \$1"; }
warn() { echo -e "  \${YEL}⚠\${RST}  \$1"; }
info() { echo -e "  \${CYN}ℹ\${RST}  \$1"; }

[ "\$(id -u)" -ne 0 ] && warn "แนะนำรันด้วย: sudo vless-verify"

PANEL_PORT="\${VLESS_PANEL_PORT:-${PANEL_PORT}}"
EXPECT_QDISC="${QDISC}"
EXPECT_SWAP_MB=${SWAP_SIZE_MB}

_detect_nic() { ip route show default 2>/dev/null | awk '/^default/ {print \$5; exit}'; }
NIC=\$(_detect_nic)
[ -z "\$NIC" ] && NIC=\$(ip link show | awk -F': ' '/^[0-9]+: / && !/lo:/ {print \$2}' | head -1 | cut -d@ -f1)
[ -z "\$NIC" ] && NIC="eth0"
RAM_MB=\$(free -m | awk '/^Mem:/ {print \$2}')
SWAP_MB=\$(free -m | awk '/^Swap:/ {print \$2}')
PUB_IP=\$(curl -4 -sf --max-time 5 https://ifconfig.me 2>/dev/null || curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "\${BLD}\${CYN}╔══════════════════════════════════════════════════════════╗\${RST}"
echo -e "\${BLD}\${CYN}║  VLESS VERIFY — health check                             ║\${RST}"
echo -e "\${BLD}\${CYN}╚══════════════════════════════════════════════════════════╝\${RST}"

errors=0
chk_svc() {
  systemctl is-active "\$1" &>/dev/null \
    && ok "\$1 active" \
    || { warn "\$1 NOT active"; errors=\$((errors+1)); }
}
chk_val() {
  local label="\$1" got="\$2" want="\$3"
  echo "\$got" | grep -qF "\$want" \
    && ok "\${label}: \${got}" \
    || { warn "\${label}: ได้ '\${got}' คาดหวัง '\${want}'"; errors=\$((errors+1)); }
}

hdr "SERVICES"
chk_svc x-ui
chk_svc fail2ban
chk_svc thp-disable.service
chk_svc nic-tune.service
chk_svc unattended-upgrades
systemctl is-enabled dns-privacy-nft.service &>/dev/null \
  && chk_svc dns-privacy-nft.service \
  || info "dns-privacy-nft.service: ปิดใช้งานอยู่ (อาจถูก rollback เพราะ DNS resolve ไม่ได้ตอนติดตั้ง)"
chk_svc udp-inbound-nft.service

hdr "PERFORMANCE TUNING"
chk_val "Congestion control" "\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
qdisc_now="\$(tc qdisc show dev "\${NIC}" 2>/dev/null | head -1)"
if echo "\$qdisc_now" | grep -q "\${EXPECT_QDISC}"; then
  ok "qdisc บน \${NIC}: \${qdisc_now}"
else
  warn "qdisc บน \${NIC}: \${qdisc_now} — คาดหวัง \${EXPECT_QDISC}"; errors=\$((errors+1))
fi
if [ "\${EXPECT_QDISC}" = "cake" ]; then
  lsmod | grep -q '^sch_cake' && ok "โมดูล sch_cake: โหลดอยู่" \
    || { warn "โมดูล sch_cake: ไม่พบใน lsmod"; errors=\$((errors+1)); }
fi
chk_val "THP" "\$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" "never"
tcp_rmem_now="\$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
tcp_wmem_now="\$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
if echo "\$tcp_rmem_now" | grep -q "2097152" && echo "\$tcp_rmem_now" | grep -q "8388608"; then
  ok "tcp_rmem: \${tcp_rmem_now}"
else
  warn "tcp_rmem: \${tcp_rmem_now} — ไม่ตรงกับ floor 2MB/ceiling 8MB"; errors=\$((errors+1))
fi
if echo "\$tcp_wmem_now" | grep -q "2097152" && echo "\$tcp_wmem_now" | grep -q "8388608"; then
  ok "tcp_wmem: \${tcp_wmem_now}"
else
  warn "tcp_wmem: \${tcp_wmem_now} — ไม่ตรงกับ floor 2MB/ceiling 8MB"; errors=\$((errors+1))
fi

hdr "PRIVACY / DNS LEAK"
chk_val "IPv6 disable"  "\$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" "1"
chk_val "kptr_restrict" "\$(sysctl -n kernel.kptr_restrict 2>/dev/null)" "2"
info "ทดสอบ DNS resolve พื้นฐาน..."
if getent hosts google.com &>/dev/null; then
  ok "DNS resolve ใช้งานได้ปกติ"
else
  warn "DNS resolve ไม่ได้ — ตรวจสอบ /etc/resolv.conf และ systemd-resolved"; errors=\$((errors+1))
fi

hdr "FIREWALL — TCP"
if command -v ufw &>/dev/null; then
  ufw_out=\$(ufw status 2>/dev/null)
  echo "\$ufw_out" | grep -qE "^22/tcp.*(LIMIT|ALLOW)" \
    && ok "พอร์ต 22/tcp: LIMIT/ALLOW" \
    || { warn "พอร์ต 22/tcp: ไม่พบ rule"; errors=\$((errors+1)); }
  for p in 80 443 "\${PANEL_PORT}"; do
    echo "\$ufw_out" | grep -qE "^\${p}/tcp.*ALLOW" \
      && ok "พอร์ต \${p}/tcp: ALLOW" \
      || { warn "พอร์ต \${p}/tcp: ไม่พบ ALLOW"; errors=\$((errors+1)); }
  done
  for p in 3389 6379 445 23; do
    echo "\$ufw_out" | grep -qE "^\${p}/tcp.*DENY" \
      && ok "พอร์ตอันตราย \${p}/tcp: DENY" \
      || { warn "พอร์ตอันตราย \${p}/tcp: ไม่พบ DENY"; errors=\$((errors+1)); }
  done
else
  warn "ไม่เจอคำสั่ง ufw"
fi

hdr "FIREWALL — UDP"
if command -v nft &>/dev/null; then
  nft list table inet udp_inbound &>/dev/null \
    && ok "nftables udp_inbound: มีอยู่ (inbound UDP ใหม่ถูก drop)" \
    || { warn "nftables udp_inbound: ไม่พบ"; errors=\$((errors+1)); }
else
  warn "ไม่เจอคำสั่ง nft"
fi
info "ทดสอบ outbound UDP..."
timeout 3 bash -c 'exec 3<>/dev/udp/1.1.1.1/53' 2>/dev/null \
  && ok "outbound UDP ใช้ได้ปกติ (เกม/สตรีม relay ผ่าน Xray ใช้ได้)" \
  || info "ไม่สามารถทดสอบ UDP socket ได้ (อาจเป็น environment เอง)"

hdr "RESOURCES"
if [ "\$RAM_MB" -lt 1800 ]; then
  warn "RAM = \${RAM_MB}MB ต่ำกว่างบ 2048MB — พิจารณาลดค่า buffer"; errors=\$((errors+1))
else
  ok "RAM = \${RAM_MB}MB"
fi
if [ "\$SWAP_MB" -lt \$((EXPECT_SWAP_MB - 100)) ]; then
  warn "Swap = \${SWAP_MB}MB ต่ำกว่าที่ตั้งไว้ (\${EXPECT_SWAP_MB}MB)"; errors=\$((errors+1))
else
  ok "Swap = \${SWAP_MB}MB"
fi

echo ""
if [ "\$errors" -eq 0 ]; then
  echo -e "\${BLD}\${GRN}  ✔  ทุกเช็คผ่านหมด\${RST}"
else
  echo -e "\${YEL}  ⚠  พบ \${errors} รายการ — ดูรายละเอียดด้านบน\${RST}"
fi

echo ""
echo -e "  \${BLD}Server IP :${RST} \${PUB_IP}"
echo -e "  \${BLD}Panel URL :${RST} http://\${PUB_IP}:\${PANEL_PORT}/"
echo ""
exit "\$errors"
VERIFYEOF
chmod +x /usr/local/bin/vless-verify
ok "ติดตั้ง vless-verify เสร็จ — รันได้ด้วย: sudo vless-verify"

hdr "VERIFY — ตรวจสอบก่อน reboot"
vless-verify
verify_errors=$?

echo ""
PUB_IP=$(curl -4 -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP    :${RST} ${PUB_IP}"
echo -e "  ${BLD}Panel URL    :${RST} http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Protocol     :${RST} VLESS | Port 443 | Network TCP"
echo -e "  ${BLD}Security     :${RST} Reality"
echo -e "  ${BLD}Flow         :${RST} xtls-rprx-vision"
echo -e "  ${BLD}SNI          :${RST} ${TLS_SNI}"
echo -e "  ${BLD}Fingerprint  :${RST} ${TLS_FINGERPRINT}"
echo -e "  ${BLD}SpiderX      :${RST} /"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Privacy      :${RST}"
echo -e "    ${GRN}✔${RST}  IPv6         : ปิดสมบูรณ์"
echo -e "    ${GRN}✔${RST}  DNS          : Cloudflare DoT + Domains=~."
echo -e "    ${GRN}✔${RST}  DNS port 53  : blocked (nftables, ถ้า resolve ได้ปกติหลัง patch)"
echo -e "    ${GRN}✔${RST}  Xray DNS     : บังคับผ่าน local stub"
echo -e "    ${GRN}✔${RST}  mDNS/LLMNR   : ปิด"
echo -e "    ${GRN}✔${RST}  Xray log     : ปิด (none)"
echo -e "    ${GRN}✔${RST}  journald     : RAM only"
echo -e "    ${GRN}✔${RST}  Fingerprint  : firefox"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Performance  :${RST}"
echo -e "    ${GRN}✔${RST}  BBR | ${QDISC} qdisc | THP off"
echo -e "    ${GRN}✔${RST}  TCP buffer 2/4/8MB | Swap ${SWAP_SIZE_MB}MB"
echo -e "    ${GRN}✔${RST}  Conntrack 262144 | Busy-poll 50us"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Security     :${RST}"
echo -e "    ${GRN}✔${RST}  SSH publickey only (ถ้าตรวจพบ key) | fail2ban 24h"
echo -e "    ${GRN}✔${RST}  Kernel hardening | UFW + nftables"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""

if [ "$verify_errors" -eq 0 ]; then
  echo -e "${BLD}${GRN}  ✔  ทุก step ผ่านหมด!${RST}"
else
  echo -e "${YEL}  ⚠  พบ ${verify_errors} รายการ — ตรวจสอบด้านบน${RST}"
fi

echo -e "${BLD}${YEL}"
echo -e "  ════ ขั้นตอนต่อไป ════════════════════════════════════════"
echo -e "  1. เข้า panel: http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  2. สร้าง inbound:"
echo -e "     Protocol   : VLESS"
echo -e "     Port       : 443"
echo -e "     Network    : TCP (raw)"
echo -e "     Security   : Reality"
echo -e "     Flow       : xtls-rprx-vision"
echo -e "     SNI        : speedtest.net"
echo -e "     Fingerprint: firefox"
echo -e "     SpiderX    : /"
echo -e "     Sniffing   : ปิดทั้งหมด"
echo -e "  3. reboot: reboot"
echo -e "  ══════════════════════════════════════════════════════════"
echo -e "${RST}"
if [ "$_has_authorized_key" -eq 0 ]; then
  echo -e "${BLD}${RED}  ⚠ ยังไม่พบ SSH public key ในระบบ — SSH ยัง login ด้วย password ได้อยู่${RST}"
  echo -e "${BLD}${RED}    แนะนำเพิ่ม authorized_keys แล้วค่อยปิด PasswordAuthentication เองภายหลัง${RST}"
else
  echo -e "${BLD}${RED}  ⚠ ตรวจ authorized_keys ก่อน reboot! SSH = publickey only${RST}"
fi
echo ""
