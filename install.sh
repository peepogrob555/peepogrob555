#!/usr/bin/env bash
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

STATE_DIR="/var/lib/vless-reality-setup"
LOG_FILE="${STATE_DIR}/setup.log"
mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

hdr()  { echo -e "\n${BLD}${CYN}▶ $1${RST}"; }
ok()   { echo -e "  ${GRN}✔${RST} $1"; }
warn() { echo -e "  ${YEL}⚠${RST} $1"; }

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}${BLD}✘ ต้องรันด้วย root (sudo bash $0)${RST}"; exit 1; }

PANEL_PORT=2053
REALITY_PORT=443
CERT_PORT=80
SSH_PORT=22
REALITY_DEST="speedtest.net:443"
REALITY_SNI="speedtest.net"
REALITY_FP="firefox"

BW_MBPS=500
RTT_MS=60
HEADROOM=1.5
MIN_BUF=1048576
MAX_BUF=8388608

BDP_BYTES=$(awk -v bw="$BW_MBPS" -v rtt="$RTT_MS" 'BEGIN{printf "%.0f", bw*1000000*rtt/1000/8}')
BUF_BYTES=$(awk -v b="$BDP_BYTES" -v h="$HEADROOM" 'BEGIN{printf "%.0f", b*h}')
[ "$BUF_BYTES" -lt "$MIN_BUF" ] && BUF_BYTES=$MIN_BUF
[ "$BUF_BYTES" -gt "$MAX_BUF" ] && BUF_BYTES=$MAX_BUF
BUF_MB=$(awk -v b="$BUF_BYTES" 'BEGIN{printf "%.2f", b/1048576}')

echo -e "${BLD}${CYN}╔══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VLESS Reality Setup (Ubuntu 24.04)           ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════╝${RST}"

hdr "STEP 1 — System Update"
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades 2>/dev/null || true
waited=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock &>/dev/null; do
  [ "$waited" -ge 60 ] && { fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true; break; }
  sleep 5; waited=$((waited+5))
done
dpkg --configure -a
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
apt-get autoclean -y
DEBIAN_FRONTEND=noninteractive apt-get install -y curl ufw nftables sqlite3
ok "ระบบอัปเดตเสร็จ"

hdr "STEP 2 — Firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward
ufw allow ${SSH_PORT}/tcp
ufw allow ${CERT_PORT}/tcp
ufw allow ${REALITY_PORT}/tcp
ufw allow ${PANEL_PORT}/tcp
ufw --force enable
ufw status verbose
ok "เปิด TCP ${SSH_PORT}/${CERT_PORT}/${REALITY_PORT}/${PANEL_PORT} — ที่เหลือปิดหมด"

hdr "STEP 3 — ติดตั้ง 3x-ui"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

hdr "STEP 4 — Optimize / Tune"

modprobe tcp_bbr 2>/dev/null || true
CC=cubic
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && CC=bbr
QDISC=fq
modinfo sch_fq_codel &>/dev/null && QDISC=fq_codel
modinfo sch_cake &>/dev/null && QDISC=cake

cat > /etc/sysctl.d/99-reality-perf.conf << EOF
net.ipv4.tcp_congestion_control = ${CC}
net.core.default_qdisc          = ${QDISC}
net.core.rmem_max        = ${BUF_BYTES}
net.core.wmem_max        = ${BUF_BYTES}
net.ipv4.tcp_rmem        = 4096 87380 ${BUF_BYTES}
net.ipv4.tcp_wmem        = 4096 65536 ${BUF_BYTES}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fastopen    = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_rfc1337 = 1
net.core.somaxconn           = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog  = 4096
net.ipv4.tcp_tw_reuse    = 1
net.ipv4.tcp_fin_timeout = 10
vm.swappiness = 10
fs.file-max = 65536
fs.nr_open  = 65536
EOF
sysctl --system >/dev/null 2>&1
ok "BBR(${CC}) + qdisc ${QDISC} + buffer ~${BUF_MB}MB + low-latency sysctl ครบ"

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag   2>/dev/null || true
cat > /etc/systemd/system/thp-disable.service << 'EOF'
[Unit]
Description=Disable THP
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

cat > /etc/security/limits.d/99-reality.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
EOF

DEV=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
cat > /etc/systemd/system/initcwnd-tune.service << EOF
[Unit]
Description=Tune initcwnd/initrwnd
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/sbin/ip route change default dev ${DEV} initcwnd 20 initrwnd 20
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
ip route change default dev "${DEV}" initcwnd 20 initrwnd 20 2>/dev/null || true

mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=0
LimitNOFILE=65536
EOF

systemctl daemon-reload
systemctl enable --now thp-disable.service initcwnd-tune.service
systemctl restart x-ui 2>/dev/null || true
ok "THP off + initcwnd/initrwnd=20 + x-ui realtime priority + fd limit ครบ"

if swapon --show | grep -q '/swapfile'; then
  ok "Swap มีอยู่แล้ว"
else
  fallocate -l 512M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=512
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap 512MB พร้อม"
fi

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-volatile.conf << 'EOF'
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=32M
RuntimeMaxUse=32M
EOF
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
find /var/log/journal -type f -name "*.journal" -delete 2>/dev/null || true
systemctl restart systemd-journald
ok "journald → RAM only"

hdr "STEP 5 — DNS + IP Leak Protection"

sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true
cat > /etc/sysctl.d/99-disable-ipv6.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1
for iface in $(ip link show | awk -F': ' '/^[0-9]+:/ {print $2}' | cut -d@ -f1); do
  echo 1 > /proc/sys/net/ipv6/conf/"${iface}"/disable_ipv6 2>/dev/null || true
done
if [ -f /etc/default/grub ]; then
  grep -q "ipv6.disable=1" /etc/default/grub || sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
  update-grub 2>/dev/null || true
fi
ok "IPv6 ปิดสมบูรณ์"

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
ok "DNS → 1.1.1.1 ผ่าน DoT"

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
nft delete table inet dns_privacy 2>/dev/null || true
nft -f /etc/nftables-dns-block.conf

cat > /etc/systemd/system/dns-privacy-nft.service << 'EOF'
[Unit]
Description=Block plaintext DNS
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
ok "บล็อก plaintext DNS port 53 ขาออก"

echo ""
warn "ตั้งเองในหน้า 3x-ui panel (Xray Configs): DNS object → 127.0.0.53 | Sniffing → ปิดทั้งหมด | Log → none"
echo ""

hdr "VERIFY"
errors=0
chk() { if eval "$2"; then ok "$1"; else warn "$1 — ไม่ผ่าน"; errors=$((errors+1)); fi; }

chk "Congestion control = ${CC}"   "[ \"\$(sysctl -n net.ipv4.tcp_congestion_control)\" = '${CC}' ]"
chk "qdisc = ${QDISC}"             "[ \"\$(sysctl -n net.core.default_qdisc)\" = '${QDISC}' ]"
chk "IPv6 ปิดสมบูรณ์"                "[ \"\$(sysctl -n net.ipv6.conf.all.disable_ipv6)\" = '1' ]"
chk "DNS ชี้ไป 1.1.1.1"              "resolvectl status 2>/dev/null | grep -q '1.1.1.1'"
chk "Port ${SSH_PORT} เปิด"         "ufw status | grep -qE '^${SSH_PORT}/tcp'"
chk "Port ${CERT_PORT} เปิด"        "ufw status | grep -qE '^${CERT_PORT}/tcp'"
chk "Port ${REALITY_PORT} เปิด"     "ufw status | grep -qE '^${REALITY_PORT}/tcp'"
chk "Port ${PANEL_PORT} เปิด"       "ufw status | grep -qE '^${PANEL_PORT}/tcp'"
chk "x-ui ทำงานอยู่"                 "systemctl is-active --quiet x-ui"
chk "Swap active"                   "swapon --show | grep -q '/swapfile'"

if timeout 3 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  warn "DNS leak: TCP:53 ไป 8.8.8.8 หลุดออกไปได้"
  errors=$((errors+1))
else
  ok "ไม่มี DNS leak (port 53 ถูกบล็อก)"
fi

PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "  ══════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP${RST}   : ${PUB_IP}"
echo -e "  ${BLD}Panel URL${RST}   : http://${PUB_IP}:${PANEL_PORT}/"
echo -e "  ${BLD}Firewall${RST}    : TCP ${SSH_PORT}/${CERT_PORT}/${REALITY_PORT}/${PANEL_PORT} เปิด — UDP ปิดหมด"
echo -e "  ${BLD}DNS/IPv6${RST}    : 1.1.1.1 DoT, plaintext:53 บล็อก, IPv6 ปิดสมบูรณ์"
echo -e "  ${BLD}Performance${RST} : BBR(${CC}) + ${QDISC} + buffer ~${BUF_MB}MB + initcwnd20 + x-ui realtime priority"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}กรอกเองใน VLESS Reality Inbound:${RST}"
echo -e "    Network/Port/Security : tcp / ${REALITY_PORT} / reality"
echo -e "    Dest / SNI / FP        : ${REALITY_DEST} / ${REALITY_SNI} / ${REALITY_FP}"
echo -e "    Sniffing               : ปิดทั้งหมด"
echo -e "    Xray DNS               : 127.0.0.53"
echo -e "  ══════════════════════════════════════════════════════"
echo ""

if [ "$errors" -eq 0 ]; then
  echo -e "${BLD}${GRN}  ✔ ผ่านหมด — reboot แล้วเข้า panel ตั้ง inbound ได้เลย${RST}"
else
  echo -e "${YEL}  ⚠ พบ ${errors} รายการไม่ผ่าน${RST}"
fi
echo -e "${RED}${BLD}  ⚠ เช็ค SSH access ให้แน่ใจก่อน reboot${RST}"
echo -e "  Log: ${LOG_FILE}"
echo ""
