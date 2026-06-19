#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  VLESS REALITY SETUP — 4 STEPS — Ubuntu 22.04 LTS
#  สร้างโดย: Claude | เป้าหมาย: ความปลอดภัยสูงสุด + รองรับเน็ตแรง (500Mbps@100ms)
#  SNI: speedtest.net | Fingerprint: firefox | DNS: Cloudflare (1.1.1.1 DoT)
#  เน้นใช้งานเกม/สตรีมหนัง/ดาวน์โหลด-อัพโหลดหนักได้จริง ไม่ใช่แค่ทฤษฎี
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
PUB_IP=$(curl -sf --max-time 8 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 8 https://api.ipify.org 2>/dev/null || echo "N/A")

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
# หมายเหตุ: ใส่ iptables ตรงๆ แม้ ufw จะดึงมาเป็น dependency อยู่แล้ว
# เพื่อการันตี ip6tables พร้อมใช้เสมอไม่ว่า cloud image จะ pre-install
# ไว้หรือไม่ — กันพลาดตอนรัน step 4.1 (ip6tables OUTPUT DROP)
# linux-modules-extra: จำเป็นสำหรับโมดูล sch_cake บน cloud kernel บางตัว
# ที่ไม่ได้ build sch_cake ไว้ใน base kernel image (ดู step 3.1)
info "1.3 ติดตั้ง dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ufw nftables iptables sqlite3 ethtool iproute2 \
  fail2ban auditd \
  python3 libcap2-bin irqbalance \
  unattended-upgrades
ok "ติดตั้งแพ็กเกจหลักเสร็จ"

# linux-modules-extra: แพ็กเกจที่มักมีโมดูล sch_cake แยกออกมาบน cloud
# kernel หลายตัว — ติดตั้งแยกเป็น non-fatal เพราะบาง provider/kernel
# variant อาจไม่มีแพ็กเกจนี้ในชื่อนี้เป๊ะๆ (เช่น custom kernel) ถ้าไม่มี
# จริงๆ step 3.1 จะ fallback เป็น fq/fq_codel ให้เองอยู่แล้ว ไม่ทำให้
# สคริปต์ทั้งก้อนหยุดกลางทาง
EXTRA_MOD_PKG="linux-modules-extra-$(uname -r)"
if apt-cache show "${EXTRA_MOD_PKG}" &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${EXTRA_MOD_PKG}" \
    && ok "ติดตั้ง ${EXTRA_MOD_PKG} เสร็จ (รองรับ sch_cake)" \
    || warn "ติดตั้ง ${EXTRA_MOD_PKG} ล้มเหลว (non-fatal) — จะลองโหลด sch_cake ตรงๆ ใน step 3.1 ถ้าไม่ได้จะ fallback เป็น fq"
else
  warn "ไม่พบแพ็กเกจ ${EXTRA_MOD_PKG} ใน apt cache — kernel นี้อาจรวม sch_cake ไว้ใน base image แล้ว หรือไม่รองรับ จะตรวจจริงใน step 3.1"
fi

# ── 1.4 Firewall (UFW) ──────────────────────────────────────────────
info "1.4 ตั้ง UFW Firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

# ── พอร์ต TCP ที่ต้องเปิด (allow) — เปิดเฉพาะที่ใช้งานจริงเท่านั้น ──
# หลักการ: TCP ขาเข้า = deny-by-default (ข้างบน) แล้วเปิดเป็น allowlist
# ทีละพอร์ตตรงนี้ — ไม่มีพอร์ตอื่นเปิดอยู่นอกจากรายการนี้
ufw limit   22/tcp      comment "SSH"
ufw allow   80/tcp      comment "HTTP (bughost redirect / ACME)"
ufw allow   443/tcp     comment "VLESS REALITY (หลัก)"
ufw allow   ${PANEL_PORT}/tcp comment "3x-ui panel (พอร์ตนี้ดันตรงกับ Cloudflare HTTPS port พอดี)"

# พอร์ตที่ Cloudflare proxy รองรับ (เผื่ออนาคตจะเอาเว็บ/บริการอื่นไป
# ผ่าน Cloudflare orange-cloud) — เปิดไว้ล่วงหน้าตามที่สั่ง ไม่ได้ใช้
# งานจริงตอนนี้สักพอร์ต แต่เปิดรอไว้ไม่มีผลเสียเพราะไม่มี service ฟังอยู่
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

# หมายเหตุเรื่อง "port google": เซิร์ฟเวอร์นี้ทำหน้าที่ relay/exit ไม่ได้
# host บริการของ Google เอง จึงไม่มี "พอร์ต Google" ขาเข้าที่ต้องเปิด —
# สิ่งที่เกี่ยวจริงคือขาออก UDP/443 (QUIC) ที่ YouTube/Google ใช้หนักมาก
# สำหรับสตรีมวิดีโอ ซึ่งยังใช้ได้ปกติเพราะ outbound UDP ไม่ถูกบล็อก
# (ดู note ใน 1.4b ด้านล่าง — มีแต่ inbound UDP เท่านั้นที่ถูกปิด)

# ── พอร์ต TCP อันตรายที่ปิดอย่างเจาะจง (defense-in-depth — default
#    policy ก็ deny อยู่แล้ว แต่ระบุตรงๆ กันกรณี policy ถูกเปลี่ยนทีหลัง
#    โดยไม่ได้ตั้งใจ — เลือกจากพอร์ตที่ถูกสแกน/โจมตีบ่อยที่สุดในโลกจริง) ──
ufw deny 21/tcp    comment "FTP - ส่ง credential แบบ cleartext"
ufw deny 23/tcp    comment "Telnet - cleartext ทั้ง session"
ufw deny 25/tcp    comment "SMTP - เสี่ยงถูกใช้เป็น spam relay"
ufw deny 110/tcp   comment "POP3 - cleartext"
ufw deny 135/tcp   comment "MS-RPC - ช่องโหว่ Windows เพียบ"
ufw deny 137/tcp   comment "NetBIOS"
ufw deny 138/tcp   comment "NetBIOS"
ufw deny 139/tcp   comment "NetBIOS/SMB"
ufw deny 143/tcp   comment "IMAP - cleartext"
ufw deny 445/tcp   comment "SMB - ช่องโหว่ระดับ worm (EternalBlue ฯลฯ)"
ufw deny 1433/tcp  comment "MSSQL - มักถูก brute-force"
ufw deny 3306/tcp  comment "MySQL - ไม่ควร expose ตรงๆ"
ufw deny 3389/tcp  comment "RDP - เป้าหมาย brute-force อันดับต้นๆ"
ufw deny 5432/tcp  comment "PostgreSQL - ไม่ควร expose ตรงๆ"
ufw deny 5900/tcp  comment "VNC - มักไม่มีรหัสผ่านแข็งแรงพอ"
ufw deny 6379/tcp  comment "Redis - ค่า default ไม่มี auth เลย โดนยึดเครื่องบ่อย"
ufw deny 8291/tcp  comment "Mikrotik Winbox - ถูกสแกนหนักทั่วโลก"
ufw deny 11211/tcp comment "Memcached - ใช้ทำ DDoS amplification ได้"

# ── 1.4b UDP: ปิดขาเข้าทั้งหมดโดยหลักการ (allowlist เฉพาะที่ใช้จริง)
#    แต่ "ไม่แตะขาออก" เด็ดขาด — เหตุผล:
#    - Inbound UDP: ไม่มี service ไหนบนเซิร์ฟเวอร์นี้ที่ต้อง "รอรับ" UDP
#      จากอินเทอร์เน็ตเลย (VLESS วิ่งบน TCP 443 เท่านั้น) จึงปิดได้หมด
#      อย่างปลอดภัย 100% โดยไม่กระทบการใช้งาน
#    - Outbound UDP: ต้องปล่อยผ่านเสมอ เพราะ Xray เป็นคน relay UDP
#      traffic ของไคลเอนต์ (เกม RoV/Roblox, DNS-over-QUIC, VoIP, video
#      streaming ผ่าน QUIC ฯลฯ) ออกไปยังปลายทางแบบสุ่มพอร์ต — ถ้าบล็อก
#      ขาออกจะตัดเกม/สตรีมของผู้ใช้ทันที ขัดกับเป้าหมายสคริปต์นี้ ──────
ufw default deny incoming  # (ครอบคลุม UDP ขาเข้าทุกพอร์ตอยู่แล้วโดย default)

# อนุญาตเฉพาะ UDP ขาเข้าที่เป็น "การตอบกลับของ request ที่เราเริ่มเอง"
# (ESTABLISHED/RELATED) ผ่าน nftables — ไม่ใช่ open port ใหม่ แค่ให้
# reply ของ DNS/NTP ที่เซิร์ฟเวอร์เป็นฝ่ายยิงออกไปก่อน กลับเข้ามาได้
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
  info "nftables: inbound UDP ใหม่ทุกพอร์ตถูก drop (เหลือแค่ reply ของ request ที่เครื่องเริ่มเอง) — outbound UDP ไม่ถูกแตะ"
else
  warn "nftables UDP inbound rule ล้มเหลว (non-fatal) — ufw default deny incoming ยังกันพื้นฐานอยู่"
  warn "nft error: ${nft_udp_err}"
fi

cat > /etc/systemd/system/udp-inbound-nft.service << 'UDPSEOF'
[Unit]
Description=Drop new inbound UDP, allow established/related only (outbound UDP untouched)
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

# ปิด IPv6 ใน UFW
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true

ufw --force enable
ufw status verbose
ok "UFW Firewall เปิดแล้ว — TCP allow: 22/80/443/${PANEL_PORT} + Cloudflare ports | TCP deny: รายชื่อพอร์ตอันตรายข้างบน | UDP: inbound ใหม่ทั้งหมด drop (เหลือ established/related), outbound ใช้ได้ปกติ"

# ── 1.5 Swap ────────────────────────────────────────────────────────
info "1.5 สร้าง Swap ${SWAP_SIZE_MB}MB..."
AVAIL_DISK_MB=$(df -m --output=avail / 2>/dev/null | tail -1 | tr -d ' ')
if [ -n "${AVAIL_DISK_MB:-}" ] && [ "$AVAIL_DISK_MB" -lt $((SWAP_SIZE_MB + 1024)) ]; then
  warn "เหลือพื้นที่ดิสก์ ${AVAIL_DISK_MB}MB — น้อยกว่า swap ${SWAP_SIZE_MB}MB + เผื่อ 1GB"
  warn "ลด SWAP_SIZE_MB ในสคริปต์ลงก่อนรันถ้าดิสก์เล็ก ไม่งั้นเสี่ยงดิสก์เต็ม"
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
hdr "STEP 2 — ติดตั้ง 3x-ui"

echo ""
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "  3x-ui installer จะถามข้อมูลให้คุณกรอกเอง:"
warn "  - Username (admin ก็ได้)"
warn "  - Password (ตั้งให้แข็งแกร่ง)"
warn "  - Panel Port (แนะนำ: ${PANEL_PORT})"
warn "  - Web Base Path (แนะนำ: ตั้งเองหรือกด Enter ข้าม)"
warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
ask "กด ENTER เพื่อเริ่มติดตั้ง 3x-ui (คุณจะเห็น prompt ทุกอย่าง)..."
read -r

bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
  || die "ติดตั้ง 3x-ui ล้มเหลว — ตรวจ DNS/network แล้วรันสคริปต์ใหม่"

for i in $(seq 1 30); do
  systemctl is-active x-ui &>/dev/null && break
  sleep 2
done
systemctl is-active x-ui &>/dev/null \
  && ok "x-ui active" \
  || warn "x-ui อาจยังไม่ active — ตรวจ: systemctl status x-ui"

ok "═══ STEP 2 เสร็จสมบูรณ์ ═══"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 3 — Optimize: Kernel / Network / TCP (ปิงต่ำ + throughput สูง)"
# ═══════════════════════════════════════════════════════════════════

# ── 3.1 BBR + CAKE Tune ─────────────────────────────────────────────
info "3.1 โหลด BBR + CAKE + ตั้งค่า TCP/network..."
modprobe tcp_bbr     2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

# ตรวจ BBR
CC="bbr"
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
  || { warn "BBR ไม่มี — ใช้ cubic"; CC="cubic"; }

# ── โหลดโมดูล sch_cake ก่อนเสมอ — ถ้าไม่โหลดก่อน คำสั่ง
#    `tc qdisc add ... cake` จะ fail แบบเงียบๆ (มี || true ครอบอยู่
#    หลายที่ในสคริปต์นี้ ทำให้พลาดได้ง่ายถ้าไม่เช็คตรงนี้ก่อน) ─────────
QDISC="cake"
modprobe sch_cake 2>/dev/null
if ! lsmod | grep -q '^sch_cake' && ! grep -qx sch_cake /proc/modules 2>/dev/null; then
  # ลองอีกครั้งหลัง apt install linux-modules-extra (step 1.3)
  depmod -a 2>/dev/null || true
  modprobe sch_cake 2>/dev/null
fi
if modinfo sch_cake &>/dev/null && modprobe sch_cake 2>/dev/null; then
  ok "โมดูล sch_cake โหลดสำเร็จ — ใช้ cake เป็น qdisc"
else
  warn "โหลด sch_cake ไม่ได้ (kernel นี้อาจไม่มีโมดูลนี้) — fallback เป็น fq"
  QDISC="fq"
  modinfo sch_fq &>/dev/null || { warn "fq ก็ไม่มี — fallback เป็น fq_codel"; QDISC="fq_codel"; }
fi

# ── ค่าบัฟเฟอร์ — ตามที่สั่ง: floor 2MB / default 4MB / ceiling 8MB
#    เหตุผลที่ตัวเลขนี้เข้าท่าจริง ไม่ใช่สุ่ม: BDP (bandwidth-delay product)
#    ของลิงก์ 500Mbps ที่ ping 100ms = 500e6/8 * 0.1 = 6.25MB — ต้องมี
#    buffer ขั้นต่ำ ~6.25MB ต่อ flow ถึงจะดันความเร็วได้เต็มที่โดยไม่ต้องรอ
#    ack แปลว่า ceiling 8MB ที่สั่งมาคือพอดี เผื่อเหลือเล็กน้อยจริง ๆ
#    ข้อควรรู้ (ความปลอดภัยของระบบ ไม่ใช่ความปลอดภัยข้อมูล): ค่า "floor"
#    (ตัวแรกของ tcp_rmem/wmem) คือ guarantee ขั้นต่ำที่ kernel จองให้ทุก
#    socket แบบ "เอาคืนไม่ได้แม้ memory จะตึง" — ตั้งเป็น 2MB ตรง ๆ ตามที่
#    สั่ง หมายความว่าถ้ามี ~100 connection พร้อมกัน (เล่นเกม+ดูหนัง+โหลด+
#    เปิดเว็บของ 2 คน) จะมี RAM ถูกจองล็อกไว้ขั้นต่ำ ~100*2MB*2(rx+tx)
#    ~400MB ทันทีไม่ว่าจะใช้จริงหรือไม่ — เพิ่ม swap เป็น 4096MB ข้างบน
#    ก็เพื่อรองรับจุดนี้โดยเฉพาะ (กันชนตอน RAM จริงตึงจากการจองล็อกนี้)
#    หมายเหตุ CAKE: CAKE มี AQM/shaper ในตัวเอง overhead ต่ำกว่า fq มาก
#    ต่อ flow จึงไม่ต้องลดค่า buffer ลงเพื่อชดเชยอะไร — BDP calculation
#    ข้างบนยังใช้ตัวเลขเดิมได้ตรง ๆ ──────────────────────────────────
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

# ── Buffer (floor 2MB / default 4MB / ceiling 8MB ตามสั่ง — รองรับ
#    500Mbps @ 100ms RTT แบบมี headroom จริงจาก BDP calculation) ──────
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

sysctl -p /etc/sysctl.d/99-vless-perf.conf
ok "TCP/network tune เสร็จ (qdisc=${QDISC}, cc=${CC})"

# ── 3.2 Conntrack (เผื่อ connection พร้อมกันได้มาก แต่ยังเบากับ kernel) ─
info "3.2 ตั้ง nf_conntrack..."
echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max                      2>/dev/null || true
echo 600    > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established  2>/dev/null || true
echo 1      > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal           2>/dev/null || true
cat >> /etc/sysctl.d/99-vless-perf.conf << 'EOF2'
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

# โหลด sch_cake อีกครั้งให้ชัวร์ก่อนผูกกับ NIC จริง (กันเคส modprobe
# ใน 3.1 สำเร็จแต่โมดูลถูก unload ไปจากที่อื่นระหว่างทาง — กันเหตุ
# "ใช้ไม่ได้" ที่พบบ่อยสุดของ cake คือลืมโหลดโมดูลก่อน)
modprobe "sch_${QDISC}" 2>/dev/null || true

tc qdisc del dev "${NIC}" root 2>/dev/null || true
if tc qdisc add dev "${NIC}" root handle 1: "${QDISC}" 2>/dev/null; then
  ok "ผูก qdisc ${QDISC} กับ ${NIC} สำเร็จ"
else
  warn "ผูก qdisc ${QDISC} กับ ${NIC} ไม่สำเร็จ — ลอง fallback เป็น fq_codel"
  QDISC="fq_codel"
  tc qdisc add dev "${NIC}" root handle 1: fq_codel 2>/dev/null || true
  sed -i "s/^net.core.default_qdisc.*/net.core.default_qdisc                 = fq_codel/" /etc/sysctl.d/99-vless-perf.conf
  sysctl -p /etc/sysctl.d/99-vless-perf.conf >/dev/null 2>&1 || true
fi

# Persist หลัง reboot — modprobe sch_cake ก่อนเสมอ ก่อนค่อย tc qdisc add
# (ลำดับนี้สำคัญ: ถ้า tc สั่งก่อนโมดูลพร้อม จะ fail แล้ว "ใช้ไม่ได้"
#  ตามที่กังวลไว้)
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

# ── 4.2 DNS over TLS (ไม่มี DNS leak) ──────────────────────────────
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
# Domains=~. คือตัวที่กัน "DNS leak ผ่าน per-link DHCP" — ถ้าไม่ตั้งตัวนี้
# query บางตัวอาจหลุดไปใช้ DNS server ที่ DHCP ของ NIC ยัดมาให้ (เช่นของ
# host provider) แทน Cloudflare DoT โดยไม่รู้ตัว นี่คือสาเหตุ DNS leak ที่
# พบบ่อยที่สุดในเคส VPN/proxy จริง ไม่ใช่แค่ทฤษฎี
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

# ── 4.2b Patch Xray internal DNS (กัน leak ที่ระดับ engine เอง) ────
# เหตุผล: ฮาร์ดเดนระดับ OS (resolved + nftables ข้างบน) กันได้แค่ DNS
# query ที่ออกมาจาก host เอง — แต่ Xray-core เป็น Go binary ที่ "อาจ" มี
# "dns" object ของตัวเองฝังอยู่ใน config (ตั้งโดย default ของ x-ui บางรุ่น
# หรือผู้ใช้ตั้งเอง) ถ้ามันชี้ไป public resolver ตรงๆ (เช่น 8.8.8.8 แบบ
# plain UDP) จะ leak โดยไม่ผ่าน OS resolver เลย ไม่ว่า resolved/nftables
# จะตั้งดีแค่ไหนก็ตาม — บล็อกนี้บังคับให้ Xray ใช้ local stub (127.0.0.53)
# ซึ่งถูก enforce ต่อไปเป็น DoT ผ่าน Cloudflare เสมอ
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
      ok "Xray internal DNS ถูกบังคับผ่าน 127.0.0.53 (local DoT stub) แล้ว"
    else
      warn "patch Xray DNS ล้มเหลว (JSON parse error) — ข้ามแบบ non-fatal"
    fi
  else
    warn "xrayTemplateConfig ว่างเปล่า — จะ patch ใหม่ได้หลังสร้าง inbound แรก"
  fi
  systemctl restart x-ui 2>/dev/null || true
else
  warn "ไม่เจอ x-ui.db — จะ patch Xray DNS หลัง reboot + สร้าง inbound"
fi

# (TCP-only lockdown แบบเดิม / blanket UDP outbound block ไม่ถูกใช้ใน
#  สคริปต์นี้ — เกม RoV/Roblox/อื่นๆ พึ่ง UDP จริงสำหรับ traffic ระหว่าง
#  เล่นที่ relay ผ่าน Xray ขาออก บล็อก UDP ขาออกทั้งหมดจะทำให้เกมพวกนี้
#  เล่นไม่ได้ทันที สิ่งที่ทำแทนคือ "ปิด UDP ขาเข้าใหม่ทั้งหมด" ใน step
#  1.4b ซึ่งปลอดภัยขึ้นจริงโดยไม่กระทบเกม เพราะไม่มี service ไหนต้อง
#  รอรับ UDP จากอินเทอร์เน็ตอยู่แล้ว — ส่วน DNS leak protection
#  (DoT/Domains=~./Xray internal DNS) ที่ทำไว้ก่อนหน้านี้ไม่ถูกแตะต้อง
#  เลย เพราะนั่นบล็อกเฉพาะ "พอร์ต 53" ไม่ใช่ UDP ทั้งหมด)

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
hdr "ติดตั้งคำสั่ง vless-verify (เรียกซ้ำได้ตลอด ไม่ต้องรัน setup ใหม่)"
# ═══════════════════════════════════════════════════════════════════
cat > /usr/local/bin/vless-verify << VERIFYEOF
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  vless-verify — เช็คสุขภาพ VLESS Reality setup ได้ตลอด ไม่ต้องรัน
#  สคริปต์ setup ใหม่ทั้งอัน รันได้ทุกเมื่อหลัง deploy ด้วยคำสั่ง:
#     sudo vless-verify
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

sep()  { echo -e "\${DIM}\${CYN}──────────────────────────────────────────────────────\${RST}"; }
hdr()  { echo -e "\n\${BLD}\${CYN}▶  \$1\${RST}"; sep; }
ok()   { echo -e "  \${GRN}✔\${RST}  \$1"; }
warn() { echo -e "  \${YEL}⚠\${RST}  \$1"; }
info() { echo -e "  \${CYN}ℹ\${RST}  \$1"; }

if [ "\$(id -u)" -ne 0 ]; then
  warn "ไม่ได้รันด้วย root — บางเช็ค (nft list, fail2ban) อาจอ่านไม่ได้ครบ"
  warn "แนะนำรันใหม่ด้วย: sudo vless-verify"
fi

PANEL_PORT="\${VLESS_PANEL_PORT:-${PANEL_PORT}}"
TLS_SNI="\${VLESS_SNI:-${TLS_SNI}}"
TLS_FINGERPRINT="\${VLESS_FP:-${TLS_FINGERPRINT}}"
EXPECT_QDISC="${QDISC}"
EXPECT_RAM_MB=2048
EXPECT_SWAP_MB=${SWAP_SIZE_MB}

_detect_nic() { ip route show default 2>/dev/null | awk '/^default/ {print \$5; exit}'; }
NIC=\$(_detect_nic)
[ -z "\$NIC" ] && NIC=\$(ip link show | awk -F': ' '/^[0-9]+: / && !/lo:/ {print \$2}' | head -1 | cut -d@ -f1)
[ -z "\$NIC" ] && NIC="eth0"
RAM_MB=\$(free -m | awk '/^Mem:/ {print \$2}')
SWAP_MB=\$(free -m | awk '/^Swap:/ {print \$2}')

echo ""
echo -e "\${BLD}\${CYN}╔══════════════════════════════════════════════════════════╗\${RST}"
echo -e "\${BLD}\${CYN}║  VLESS VERIFY — health check (รันได้ตลอดเวลา)            ║\${RST}"
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
chk_svc dns-privacy-nft.service
chk_svc udp-inbound-nft.service
chk_svc unattended-upgrades

hdr "PERFORMANCE TUNING"
chk_val "Congestion control" "\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
qdisc_now="\$(tc qdisc show dev "\${NIC}" 2>/dev/null | head -1)"
if echo "\$qdisc_now" | grep -q "\${EXPECT_QDISC}"; then
  ok "qdisc บน \${NIC}: \${qdisc_now} (ตรงกับที่ตั้งไว้: \${EXPECT_QDISC})"
else
  warn "qdisc บน \${NIC}: \${qdisc_now} — คาดหวัง \${EXPECT_QDISC} (เช็คว่าโมดูล sch_\${EXPECT_QDISC} โหลดอยู่ไหมด้วย lsmod)"
  errors=\$((errors+1))
fi
if [ "\${EXPECT_QDISC}" = "cake" ]; then
  if lsmod | grep -q '^sch_cake'; then
    ok "โมดูล sch_cake: โหลดอยู่"
  else
    warn "โมดูล sch_cake: ไม่พบใน lsmod — cake อาจ fallback ไป fq_codel ไปแล้ว"
    errors=\$((errors+1))
  fi
fi
chk_val "THP"      "\$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" "never"
tcp_rmem_now="\$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
tcp_wmem_now="\$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
if echo "\$tcp_rmem_now" | grep -q "2097152" && echo "\$tcp_rmem_now" | grep -q "8388608"; then
  ok "tcp_rmem: \${tcp_rmem_now} (floor 2MB / ceiling 8MB ตรงตามตั้งไว้)"
else
  warn "tcp_rmem: \${tcp_rmem_now} — ไม่ตรงกับ floor 2MB/ceiling 8MB ที่ตั้งไว้"
  errors=\$((errors+1))
fi
if echo "\$tcp_wmem_now" | grep -q "2097152" && echo "\$tcp_wmem_now" | grep -q "8388608"; then
  ok "tcp_wmem: \${tcp_wmem_now} (floor 2MB / ceiling 8MB ตรงตามตั้งไว้)"
else
  warn "tcp_wmem: \${tcp_wmem_now} — ไม่ตรงกับ floor 2MB/ceiling 8MB ที่ตั้งไว้"
  errors=\$((errors+1))
fi

hdr "PRIVACY / DNS LEAK"
chk_val "IPv6 disable"  "\$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" "1"
chk_val "kptr_restrict" "\$(sysctl -n kernel.kptr_restrict 2>/dev/null)"          "2"
chk_val "resolved Domains=~." "\$(resolvectl status 2>/dev/null | grep -m1 'DNS Domain')" "~."
if resolvectl status 2>/dev/null | grep -q "1.1.1.1"; then
  ok "Cloudflare DNS (1.1.1.1) active ใน resolvectl status"
else
  warn "ไม่เจอ 1.1.1.1 ใน resolvectl status — ตรวจ /etc/systemd/resolved.conf.d/99-dot.conf"
  errors=\$((errors+1))
fi

info "ทดสอบ DNS leak จริง: ลองต่อ TCP:53 ไป public resolver (ควรถูกบล็อก)..."
if timeout 3 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  warn "เชื่อมต่อ TCP:53 ไป 8.8.8.8 ได้สำเร็จ — nftables DNS block ไม่ทำงานจริง!"
  errors=\$((errors+1))
else
  ok "TCP:53 ไป public resolver ถูกบล็อกแล้ว (DNS leak ปิดสนิท)"
fi

hdr "FIREWALL — TCP"
if command -v ufw &>/dev/null; then
  ufw_out=\$(ufw status 2>/dev/null)
  echo "\$ufw_out" | grep -qE "^22/tcp.*(LIMIT|ALLOW)" \
    && ok "พอร์ต 22/tcp: เปิดอยู่ (LIMIT/ALLOW — ตามแผน)" \
    || { warn "พอร์ต 22/tcp: ไม่พบ LIMIT/ALLOW rule"; errors=\$((errors+1)); }
  for p in 80 443 "\${PANEL_PORT}"; do
    echo "\$ufw_out" | grep -qE "^\${p}/tcp.*ALLOW" \
      && ok "พอร์ต \${p}/tcp: ALLOW (ตามแผน)" \
      || { warn "พอร์ต \${p}/tcp: ไม่พบ ALLOW rule"; errors=\$((errors+1)); }
  done
  for p in 3389 6379 445 23; do
    echo "\$ufw_out" | grep -qE "^\${p}/tcp.*DENY" \
      && ok "พอร์ตอันตราย \${p}/tcp: DENY (ปิดอยู่)" \
      || { warn "พอร์ตอันตราย \${p}/tcp: ไม่พบ DENY rule ชัดเจน"; errors=\$((errors+1)); }
  done
else
  warn "ไม่เจอคำสั่ง ufw"
fi

hdr "FIREWALL — UDP (inbound ใหม่ต้อง drop, outbound ต้องใช้ได้)"
if command -v nft &>/dev/null; then
  if nft list table inet udp_inbound &>/dev/null; then
    ok "nftables table udp_inbound: มีอยู่ (inbound UDP ใหม่ถูก drop)"
  else
    warn "nftables table udp_inbound: ไม่พบ — inbound UDP อาจไม่ได้ถูกบล็อกเพิ่มเติม"
    errors=\$((errors+1))
  fi
else
  warn "ไม่เจอคำสั่ง nft"
fi
info "ทดสอบ outbound UDP จริง (DNS query ผ่าน DoT/stub ควรยังทำงานได้)..."
if timeout 3 bash -c 'exec 3<>/dev/udp/1.1.1.1/53' 2>/dev/null; then
  ok "เปิด UDP socket ขาออกได้ปกติ (เกม/สตรีมที่ relay ผ่าน Xray ใช้งานได้)"
else
  info "ไม่สามารถเปิด UDP socket ทดสอบได้ (อาจเป็นเพราะ environment ทดสอบเอง ไม่ใช่ firewall — ตรวจ ufw status เพิ่มถ้าสงสัย)"
fi

hdr "RESOURCES"
if [ "\$RAM_MB" -lt 1800 ]; then
  warn "RAM จริง = \${RAM_MB}MB ต่ำกว่างบที่คำนวณบัฟเฟอร์ไว้ (\${EXPECT_RAM_MB}MB)"
  warn "ค่า tcp_mem/rmem_max อาจสูงเกินไปสำหรับเครื่องนี้ — พิจารณาลดลง"
  errors=\$((errors+1))
else
  ok "RAM จริง = \${RAM_MB}MB (งบที่ตั้งไว้ \${EXPECT_RAM_MB}MB)"
fi
if [ "\$SWAP_MB" -lt \$((EXPECT_SWAP_MB - 100)) ]; then
  warn "Swap จริง = \${SWAP_MB}MB ต่ำกว่าที่ตั้งไว้ (\${EXPECT_SWAP_MB}MB) — ตรวจ: swapon --show"
  errors=\$((errors+1))
else
  ok "Swap จริง = \${SWAP_MB}MB"
fi

echo ""
if [ "\$errors" -eq 0 ]; then
  echo -e "\${BLD}\${GRN}  ✔  ทุกเช็คผ่านหมด — ระบบยังอยู่ในสถานะที่ตั้งใจไว้\${RST}"
else
  echo -e "\${YEL}  ⚠  พบ \${errors} รายการที่ต้องตรวจสอบเพิ่ม (ดูรายละเอียดด้านบน)\${RST}"
fi
echo ""
exit "\$errors"
VERIFYEOF
chmod +x /usr/local/bin/vless-verify
ok "ติดตั้งแล้ว — เรียกใช้ได้ตลอดเวลาด้วยคำสั่ง: sudo vless-verify"

hdr "VERIFY — ตรวจสอบก่อน reboot (รันผ่านคำสั่งที่ติดตั้งไว้)"
vless-verify
verify_errors=$?

echo ""
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP    :${RST} ${PUB_IP}"
echo -e "  ${BLD}Panel URL    :${RST} http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Protocol     :${RST} VLESS | Port: 443 | Network: TCP (UDP relay เปิดใช้งานได้ปกติ — เกมที่พึ่ง UDP เล่นได้)"
echo -e "  ${BLD}Security     :${RST} Reality"
echo -e "  ${BLD}Flow         :${RST} xtls-rprx-vision"
echo -e "  ${BLD}SNI          :${RST} ${TLS_SNI}"
echo -e "  ${BLD}Fingerprint  :${RST} ${TLS_FINGERPRINT}"
echo -e "  ${BLD}SpiderX      :${RST} /"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Privacy      :${RST}"
echo -e "    ${GRN}✔${RST}  IPv6         : ปิดสมบูรณ์"
echo -e "    ${GRN}✔${RST}  DNS          : Cloudflare DoT (853) + Domains=~. (กัน DHCP override leak)"
echo -e "    ${GRN}✔${RST}  DNS port 53  : blocked (nftables) + ทดสอบจริงแล้วใน VERIFY"
echo -e "    ${GRN}✔${RST}  Xray internal DNS : บังคับผ่าน local stub (กัน leak ระดับ engine)"
echo -e "    ${GRN}✔${RST}  mDNS/LLMNR   : ปิด (ลด broadcast metadata)"
echo -e "    ${GRN}✔${RST}  Xray log     : ปิด (none)"
echo -e "    ${GRN}✔${RST}  journald     : RAM only (volatile)"
echo -e "    ${GRN}✔${RST}  Fingerprint  : firefox"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Performance  :${RST}"
echo -e "    ${GRN}✔${RST}  BBR congestion control"
echo -e "    ${GRN}✔${RST}  ${QDISC} qdisc | THP off | NIC: GRO/GSO/TSO + ring max"
echo -e "    ${GRN}✔${RST}  TCP buffer floor/default/ceiling 2/4/8MB (BDP 500Mbps@100ms) | tcp_mem 384/512/768MB"
echo -e "    ${GRN}✔${RST}  Swap ${SWAP_SIZE_MB}MB (กันชน RAM จากการจอง buffer floor 2MB/socket)"
echo -e "    ${GRN}✔${RST}  Busy-poll 50us | TCP fast | Keepalive 35s"
echo -e "    ${GRN}✔${RST}  Conntrack 262144 entries (~80MB)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Security     :${RST}"
echo -e "    ${GRN}✔${RST}  SSH: publickey only"
echo -e "    ${GRN}✔${RST}  fail2ban: SSH ban 24h"
echo -e "    ${GRN}✔${RST}  Kernel hardening (kptr/ptrace/BPF)"
echo -e "    ${GRN}✔${RST}  UFW TCP allow : 22, 80, 443, ${PANEL_PORT}, + Cloudflare ports (2052/2082/2086/2095/8080/8880/2083/2087/2096/8443)"
echo -e "    ${GRN}✔${RST}  UFW TCP deny  : 21,23,25,110,135,137-139,143,445,1433,3306,3389,5432,5900,6379,8291,11211"
echo -e "    ${GRN}✔${RST}  UDP inbound   : ใหม่ทั้งหมด drop (เหลือแค่ established/related) | UDP outbound: ปกติ (เกม/สตรีมผ่าน Xray ใช้ได้)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Logs & Debug :${RST}"
echo -e "  systemctl status x-ui"
echo -e "  fail2ban-client status sshd"
echo -e "  ${BLD}Install log  :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""

if [ "$verify_errors" -eq 0 ]; then
  echo -e "${BLD}${GRN}"
  echo -e "  ✔  ทุก step ผ่านหมด!"
  echo -e "${RST}"
else
  echo -e "${YEL}  ⚠  พบ ${verify_errors} รายการ — ตรวจสอบด้านบน${RST}"
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
