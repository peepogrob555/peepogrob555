#!/usr/bin/env bash
set -uo pipefail
export LANG=C

main() {
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

STATE_DIR="/var/lib/vless-reality-setup"
LOG_FILE="${STATE_DIR}/setup.log"
mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

hdr()  { echo -e "\n${BLD}${CYN}▶ $1${RST}"; }
ok()   { echo -e "  ${GRN}✔${RST} $1"; }
warn() { echo -e "  ${YEL}⚠${RST} $1"; }
info() { echo -e "  ${CYN}ℹ${RST} $1"; }
die()  { echo -e "\n${RED}${BLD}✘ $1${RST}\n"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root — รันใหม่ด้วย: sudo bash <(curl -Ls 'https://raw.githubusercontent.com/peepogrob555/peepogrob555/refs/heads/main/install.sh')"

SSH_PORT=22
HTTP_PORT=80
REALITY_PORT=443
PANEL_PORT=2053
CF_PORTS=(2052 2082 2086 2095 8080 8880 2083 2087 2096 8443)

REALITY_DEST="speedtest.net:443"
REALITY_SNI="speedtest.net"
REALITY_FP="firefox"

BW_MBPS=1000
RTT_MS=80
HEADROOM=1.2
MIN_BUF=2097152
MAX_BUF=16777216

BDP_BYTES=$(awk -v bw="$BW_MBPS" -v rtt="$RTT_MS" 'BEGIN{printf "%.0f", bw*1000000*rtt/1000/8}')
BUF_BYTES=$(awk -v b="$BDP_BYTES" -v h="$HEADROOM" 'BEGIN{printf "%.0f", b*h}')
[ "$BUF_BYTES" -lt "$MIN_BUF" ] && BUF_BYTES=$MIN_BUF
[ "$BUF_BYTES" -gt "$MAX_BUF" ] && BUF_BYTES=$MAX_BUF
BUF_MB=$(awk -v b="$BUF_BYTES" 'BEGIN{printf "%.2f", b/1048576}')

echo -e "${BLD}${CYN}╔══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VLESS Reality — Remaster v2 (Ubuntu 24.04)   ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════╝${RST}"
info "BDP @ ${BW_MBPS}Mbps/${RTT_MS}ms = ${BDP_BYTES} bytes → buffer หลัง headroom+clamp = ${BUF_BYTES} bytes (~${BUF_MB}MB)"

hdr "STEP 1 — System Update"
systemctl stop unattended-upgrades 2>/dev/null || true
waited=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
            /var/cache/apt/archives/lock &>/dev/null; do
  [ "$waited" -ge 60 ] && {
    fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
             /var/cache/apt/archives/lock 2>/dev/null || true
    break
  }
  info "รอ apt lock... ${waited}s"; sleep 5; waited=$((waited+5))
done
dpkg --configure -a

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
apt-get autoclean -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ufw nftables sqlite3 unattended-upgrades
ok "อัปเดตระบบ + แพ็กเกจพื้นฐานเสร็จ"

hdr "STEP 1.5 — SSH: บังคับใช้ Key เท่านั้น (ปิด Password Authentication)"
SSHD_CONF="/etc/ssh/sshd_config"
cp -an "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)" 2>/dev/null || true

AUTH_KEYS_OK=0
for home in /root /home/*; do
  if [ -s "${home}/.ssh/authorized_keys" ]; then
    AUTH_KEYS_OK=1
    break
  fi
done

set_sshd_opt() {
  local key="$1" val="$2"
  if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "$SSHD_CONF"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$SSHD_CONF"
  else
    echo "${key} ${val}" >> "$SSHD_CONF"
  fi
}

if [ "$AUTH_KEYS_OK" -eq 1 ]; then
  set_sshd_opt "PubkeyAuthentication" "yes"
  set_sshd_opt "PasswordAuthentication" "no"
  set_sshd_opt "KbdInteractiveAuthentication" "no"
  set_sshd_opt "PermitRootLogin" "prohibit-password"

  if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "$f" ] || continue
      sed -i -E 's|^[#[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication no|I' "$f"
      sed -i -E 's|^[#[:space:]]*KbdInteractiveAuthentication[[:space:]].*|KbdInteractiveAuthentication no|I' "$f"
    done
  fi

  sshd -t && {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    ok "บังคับใช้ SSH key เท่านั้น (ปิด password login แล้ว, สำรอง config เดิมไว้ที่ ${SSHD_CONF}.bak.*)"
  } || warn "sshd_config มีปัญหา syntax — ไม่ restart sshd (เช็คด้วยมือ: sshd -t)"
else
  warn "ไม่พบ authorized_keys ในเครื่องนี้เลย — ข้ามการปิด password auth (กันตัวเองล็อกตัวเองออกจาก SSH)"
  warn "เพิ่ม public key ก่อนด้วย: mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
  warn "แล้วรันสคริปต์นี้ใหม่ทีหลังเพื่อปิด password auth จริง"
fi

hdr "STEP 2 — Firewall: เปิดพอร์ตที่ใช้จริง (ไม่ไล่ deny ทีละพอร์ต — default-deny ครอบคลุมส่วนที่เหลืออยู่แล้ว)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward

ufw allow ${SSH_PORT}/tcp
ufw allow ${HTTP_PORT}/tcp
ufw allow ${REALITY_PORT}/tcp
ufw allow ${PANEL_PORT}/tcp

for p in "${CF_PORTS[@]}"; do
  ufw allow ${p}/tcp
done

sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
ufw --force enable
ufw status verbose
ok "เปิด TCP: ${SSH_PORT} ${HTTP_PORT} ${REALITY_PORT} ${PANEL_PORT} + Cloudflare ports (allow ล้วน ไม่มี limit/deny รายพอร์ต) — ที่เหลือปิดด้วย default-deny policy"

hdr "STEP 3 — ติดตั้ง 3x-ui (interactive — กรอก username/password/port เอง)"
if command -v x-ui &>/dev/null || [ -x /usr/local/x-ui/x-ui ]; then
  ok "พบ 3x-ui ติดตั้งอยู่แล้ว — ข้าม"
else
  info "เริ่ม installer จริง — กรอก username/password/port ของคุณเองตามที่ถาม..."
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
fi
if command -v x-ui &>/dev/null || [ -x /usr/local/x-ui/x-ui ]; then
  ok "3x-ui ติดตั้งสำเร็จ"
else
  warn "ไม่พบ x-ui หลังติดตั้ง — เช็ค output ด้านบนว่า error หรือไม่"
fi

hdr "STEP 4 — Optimize/Tune (BBR + Buffer ${BUF_MB}MB) + ย้ายทุกอย่างที่ปลอดภัยไป RAM"

modprobe tcp_bbr 2>/dev/null || true
modprobe sch_cake 2>/dev/null || true
CC="bbr"
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
  || { warn "BBR ไม่มีในเคอร์เนลนี้ — ใช้ cubic แทน"; CC="cubic"; }
QDISC="cake"
modinfo sch_cake &>/dev/null \
  || { warn "cake module ไม่มีในเคอร์เนลนี้ — fallback ไป fq_codel"; QDISC="fq_codel"; }

cat > /etc/modules-load.d/99-reality-net.conf << 'EOF'
tcp_bbr
sch_cake
EOF
ok "โหลดโมดูล tcp_bbr + sch_cake แล้ว (และตั้งให้โหลดอัตโนมัติทุก reboot)"

cat > /etc/sysctl.d/99-reality-perf.conf << EOF
net.ipv4.tcp_congestion_control = ${CC}
net.core.default_qdisc          = ${QDISC}

net.core.rmem_max        = ${BUF_BYTES}
net.core.wmem_max        = ${BUF_BYTES}
net.ipv4.tcp_rmem        = 4096 87380 ${BUF_BYTES}
net.ipv4.tcp_wmem        = 4096 65536 ${BUF_BYTES}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen    = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0

net.core.somaxconn           = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog  = 8192

net.ipv4.tcp_tw_reuse    = 1
net.ipv4.tcp_fin_timeout = 10

vm.swappiness = 10
vm.vfs_cache_pressure = 50

fs.file-max = 131072
fs.nr_open  = 131072
EOF
sysctl -p /etc/sysctl.d/99-reality-perf.conf
ok "BBR(${CC}) + qdisc ${QDISC} + buffer ${BUF_MB}MB + backlog 8192 (ปรับสเกลสำหรับ RAM 2GB)"

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag   2>/dev/null || true
cat > /etc/systemd/system/thp-disable.service << 'EOF'
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
EOF
systemctl daemon-reload
systemctl enable --now thp-disable.service
ok "THP ปิดแล้ว"

cat > /etc/security/limits.d/99-reality.conf << 'EOF'
* soft nofile 131072
* hard nofile 131072
EOF
ok "fd limit = 131072"

if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 1024M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
ok "Swap 1GB พร้อม"

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-volatile.conf << 'EOF'
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=64M
RuntimeMaxUse=64M
EOF
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
find /var/log/journal -type f -name "*.journal" -delete 2>/dev/null || true
systemctl restart systemd-journald
ok "journald → RAM only (volatile, จำกัด 64MB, ไม่เขียน disk)"

if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
  echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=512m 0 0" >> /etc/fstab
fi
mount -o remount /tmp 2>/dev/null || mount /tmp 2>/dev/null || true
ok "/tmp → tmpfs 512MB (RAM)"

hdr "STEP 5 — DNS + IP Leak Protection (1.1.1.1 DoT, ปิด IPv6)"

cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf
for iface in $(ip link show | awk -F': ' '/^[0-9]+:/ {print $2}' | cut -d@ -f1); do
  echo 1 > /proc/sys/net/ipv6/conf/"${iface}"/disable_ipv6 2>/dev/null || true
done
if [ -f /etc/default/grub ]; then
  grep -q "ipv6.disable=1" /etc/default/grub || \
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
  update-grub 2>/dev/null || true
fi
ok "ปิด IPv6 สมบูรณ์ (sysctl + grub)"

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dot.conf << 'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com
FallbackDNS=1.0.0.1#cloudflare-dns.com
DNSOverTLS=yes
DNSSEC=no
Cache=yes
DNSStubListener=yes
Domains=~.
MulticastDNS=no
LLMNR=no
EOF
systemctl enable --now systemd-resolved 2>/dev/null || true
systemctl restart systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
ok "DNS → 1.1.1.1 ผ่าน DoT + Domains=~. กัน leak จาก DHCP"

cat > /etc/nftables-dns-block.conf << 'EOF'
table inet dns_privacy {
  chain output_dns_block {
    type filter hook output priority 0; policy accept;
    ip daddr 127.0.0.53 udp dport 53 accept
    ip daddr 127.0.0.53 tcp dport 53 accept
    udp dport 53 drop
    tcp dport 53 drop
  }
}
EOF
nft -f /etc/nftables-dns-block.conf 2>/dev/null \
  && ok "บล็อก plaintext DNS port 53 ขาออกแล้ว" \
  || warn "nftables DNS block ล้มเหลว (non-fatal)"

cat > /etc/systemd/system/dns-privacy-nft.service << 'EOF'
[Unit]
Description=Block plaintext DNS (force DoT)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables-dns-block.conf
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now dns-privacy-nft.service

echo ""
warn "ไปตั้งเองในหน้า 3x-ui panel (Xray Configs) หลังติดตั้ง:"
warn "  DNS object ของ Xray → ชี้ 127.0.0.53 (สำคัญมาก ไม่งั้น Xray resolve โดเมนไม่ได้"
warn "  เพราะ DNS ขาออกตรงถูก nftables บล็อกไว้แล้ว — ค้างโหลดได้ถ้าลืมตั้งจุดนี้)"
warn "  Sniffing → ปิดทั้งหมด | Log → access=none, loglevel=none, dnsLog=false"
echo ""

hdr "VERIFY"
errors=0
chk() {
  local label="$1"; local cond="$2"
  if eval "$cond"; then ok "$label"; else warn "$label — ไม่ผ่าน"; errors=$((errors+1)); fi
}

chk "BBR/${CC} congestion control"        "[ \"\$(sysctl -n net.ipv4.tcp_congestion_control)\" = '${CC}' ]"
chk "Buffer ceiling = ${BUF_BYTES}"       "[ \"\$(sysctl -n net.core.rmem_max)\" = '${BUF_BYTES}' ]"
chk "IPv6 ปิดสมบูรณ์"                      "[ \"\$(sysctl -n net.ipv6.conf.all.disable_ipv6)\" = '1' ]"
chk "DNS ชี้ไป 1.1.1.1"                    "resolvectl status 2>/dev/null | grep -q '1.1.1.1'"
chk "Port ${HTTP_PORT}/tcp เปิดใน UFW"     "ufw status | grep -qE '^${HTTP_PORT}/tcp'"
chk "Port ${REALITY_PORT}/tcp เปิดใน UFW"  "ufw status | grep -qE '^${REALITY_PORT}/tcp'"
chk "Port ${PANEL_PORT}/tcp เปิดใน UFW"    "ufw status | grep -qE '^${PANEL_PORT}/tcp'"
chk "journald = volatile (RAM)"            "grep -q 'Storage=volatile' /etc/systemd/journald.conf.d/99-volatile.conf"
chk "/tmp = tmpfs (RAM)"                   "grep -q 'tmpfs /tmp' /etc/fstab"

info "ทดสอบ DNS leak: ลอง TCP:53 ตรงไป 8.8.8.8 (ควรถูกบล็อก)..."
if timeout 3 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  warn "เชื่อมต่อ TCP:53 ไป 8.8.8.8 ได้ — DNS block ไม่ทำงานจริง!"
  errors=$((errors+1))
else
  ok "Plaintext DNS (port 53) ถูกบล็อกแล้ว — ไม่มี DNS leak"
fi

PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "  ══════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP${RST}   : ${PUB_IP}"
echo -e "  ${BLD}Panel URL${RST}   : http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  ${BLD}Firewall${RST}    : เปิด TCP ${SSH_PORT}/${HTTP_PORT}/${REALITY_PORT}/${PANEL_PORT} + Cloudflare ports (allow ล้วน) — ที่เหลือปิดด้วย default-deny (รวม UDP)"
echo -e "  ${BLD}DNS${RST}         : 1.1.1.1 ผ่าน DoT — plaintext port 53 บล็อก"
echo -e "  ${BLD}IPv6${RST}        : ปิดสมบูรณ์"
echo -e "  ${BLD}RAM-backed${RST}  : journald (64MB) + /tmp (512MB tmpfs)"
echo -e "  ${BLD}Performance${RST} : BBR(${CC}) + ${QDISC} + buffer ${BUF_MB}MB (BDP@${BW_MBPS}Mbps/${RTT_MS}ms) + THP off + swap 1GB"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}ค่าที่ต้องกรอกเองใน VLESS Reality Inbound (panel):${RST}"
echo -e "    Protocol     : VLESS"
echo -e "    Network      : tcp (raw)"
echo -e "    Port         : ${REALITY_PORT}"
echo -e "    Security     : reality"
echo -e "    Dest         : ${REALITY_DEST}"
echo -e "    Server Name  : ${REALITY_SNI}"
echo -e "    Fingerprint  : ${REALITY_FP}"
echo -e "    Sniffing     : ปิดทั้งหมด"
echo -e "    Xray DNS     : ชี้ไป 127.0.0.53"
echo -e "  ══════════════════════════════════════════════════════"
echo ""

if [ "$errors" -eq 0 ]; then
  echo -e "${BLD}${GRN}  ✔ ทุก step ผ่านหมด — reboot แล้วเข้า panel ตั้ง inbound ได้เลย${RST}"
else
  echo -e "${YEL}  ⚠ พบ ${errors} รายการที่ไม่ผ่าน — ตรวจสอบด้านบน${RST}"
fi
echo ""
echo -e "${RED}${BLD}  ⚠ ตรวจการเข้าถึง SSH ของคุณให้แน่ใจก่อน reboot${RST}"
echo -e "  Install log: ${LOG_FILE}"
echo ""

}

main "$@"
