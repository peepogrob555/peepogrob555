#!/usr/bin/env bash
# VMess WS Setup — Ubuntu 24.04 LTS
# Port: 22/80/2053 | Gaming optimized | Low latency | Privacy hardened
set -uo pipefail
export LANG=C DEBIAN_FRONTEND=noninteractive

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

STATE_DIR="/var/lib/vmess-setup"
LOG_FILE="${STATE_DIR}/setup.log"
mkdir -p "$STATE_DIR"

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}✘ ต้องรันด้วย root${RST}"; exit 1; }

# ── ป้องกัน session หลุด ด้วย tmux ──
if [ -z "${TMUX:-}" ]; then
  apt-get update -y -qq 2>/dev/null
  apt-get install -y -qq tmux 2>/dev/null
  echo -e "${YEL}เปิด tmux session เพื่อป้องกัน SSH หลุด...${RST}"
  echo -e "${YEL}ถ้า SSH หลุด → reconnect แล้วพิมพ์: tmux attach -t vmess-setup${RST}"
  sleep 2
  exec tmux new-session -s vmess-setup bash "$0" "$@"
fi

exec > >(tee -a "$LOG_FILE") 2>&1

hdr()  { echo -e "\n${BLD}${CYN}▶ $1${RST}"; }
ok()   { echo -e "  ${GRN}✔${RST} $1"; }
warn() { echo -e "  ${YEL}⚠${RST} $1"; }

# ════════════════════════════════════════════════════
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VMess WS Setup — Ubuntu 24.04 (Gaming)      ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════╝${RST}"

# ════════════════════════════════════════════════════
hdr "STEP 1 — System Update"
# ════════════════════════════════════════════════════
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades 2>/dev/null || true
waited=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock &>/dev/null; do
  [ "$waited" -ge 60 ] && { fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true; break; }
  sleep 5; waited=$((waited+5))
done
dpkg --configure -a
apt-get update -y
apt-get -y full-upgrade
apt-get -y autoremove --purge
apt-get autoclean -y
apt-get install -y curl ufw nftables sqlite3 tmux
ok "ระบบอัปเดตเสร็จ"

# ════════════════════════════════════════════════════
hdr "STEP 2 — Firewall (เปิดเฉพาะ 22/80/2053)"
# ════════════════════════════════════════════════════
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny forward
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw 2>/dev/null || true

ufw allow 22/tcp   comment 'SSH'
ufw allow 80/tcp   comment 'VMess-WS'
ufw allow 2053/tcp comment '3x-ui Panel'

# ปิด port อันตราย (outbound) ที่ไม่จำเป็น
# block inbound UDP ทั้งหมด ยกเว้น ICMP
ufw deny proto udp from any to any

ufw --force enable
ufw status verbose
ok "เปิดเฉพาะ TCP 22/80/2053 — UDP/พอร์ตอื่นปิดหมด"

# ════════════════════════════════════════════════════
hdr "STEP 3 — ติดตั้ง 3x-ui"
# ════════════════════════════════════════════════════
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
sleep 5
systemctl enable x-ui 2>/dev/null || true
systemctl start x-ui 2>/dev/null || true
ok "3x-ui ติดตั้งเสร็จ"

# ════════════════════════════════════════════════════
hdr "STEP 4 — Kernel & Network Tuning (Gaming / Low Latency)"
# ════════════════════════════════════════════════════

# ── BBR: โหลด module แล้วตรวจว่าใช้ได้จริง ──
modprobe tcp_bbr 2>/dev/null || true
if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  CC=bbr
  ok "BBR พร้อมใช้"
else
  CC=cubic
  warn "BBR ไม่พร้อม → fallback cubic"
fi

# ── CAKE: โหลด module แล้วทดสอบ apply จริงบน lo ──
modprobe sch_cake     2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true

QDISC=fq
if tc qdisc add dev lo root cake 2>/dev/null; then
  tc qdisc del dev lo root 2>/dev/null || true
  QDISC=cake
  ok "CAKE พร้อมใช้"
elif tc qdisc add dev lo root fq_codel 2>/dev/null; then
  tc qdisc del dev lo root 2>/dev/null || true
  QDISC=fq_codel
  warn "CAKE ไม่พร้อม → fallback fq_codel"
else
  QDISC=fq
  warn "fq_codel ไม่พร้อม → fallback fq"
fi

# persist modules โหลดทุก boot
grep -q tcp_bbr      /etc/modules 2>/dev/null || echo tcp_bbr      >> /etc/modules
grep -q sch_cake     /etc/modules 2>/dev/null || echo sch_cake     >> /etc/modules
grep -q sch_fq_codel /etc/modules 2>/dev/null || echo sch_fq_codel >> /etc/modules

# Buffer: 500Mbps × 60ms RTT × 1.5 headroom = ~5.6MB ≈ capped 4MB เหมาะกับ mobile
# MTU 1500 → TCP MSS 1440 (20 IP + 20 TCP + 20 options = 60 header)
# ปรับ buffer ให้เหมาะกับ mobile VPN: ไม่ใหญ่เกินไปเพื่อลด latency
BUF_BYTES=4194304   # 4MB — gaming sweet spot, ไม่บวม queue
MSS=1440

cat > /etc/sysctl.d/99-vmess-gaming.conf << EOF
# ── Congestion & Qdisc ──
net.ipv4.tcp_congestion_control    = ${CC}
net.core.default_qdisc             = ${QDISC}

# ── Buffer (4MB — gaming/mobile optimized) ──
net.core.rmem_default              = 262144
net.core.wmem_default              = 262144
net.core.rmem_max                  = ${BUF_BYTES}
net.core.wmem_max                  = ${BUF_BYTES}
net.ipv4.tcp_rmem                  = 4096 87380 ${BUF_BYTES}
net.ipv4.tcp_wmem                  = 4096 65536 ${BUF_BYTES}
net.ipv4.tcp_moderate_rcvbuf       = 1

# ── Low Latency / Anti-Jitter ──
net.ipv4.tcp_notsent_lowat         = 16384
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_ecn                   = 1
net.ipv4.tcp_sack                  = 1
net.ipv4.tcp_dsack                 = 1
net.ipv4.tcp_fack                  = 0

# ── Connection hardening ──
net.ipv4.tcp_rfc1337               = 1
net.ipv4.tcp_syncookies            = 1
net.ipv4.tcp_max_syn_backlog       = 4096
net.core.somaxconn                 = 4096
net.core.netdev_max_backlog        = 4096

# ── Keepalive (ลด idle disconnect บน mobile) ──
net.ipv4.tcp_keepalive_time        = 30
net.ipv4.tcp_keepalive_intvl       = 10
net.ipv4.tcp_keepalive_probes      = 6

# ── Time-wait reuse ──
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_fin_timeout           = 10

# ── MSS clamp hint (MTU 1500 → MSS 1440) ──
net.ipv4.tcp_base_mss              = ${MSS}

# ── Security / Privacy ──
net.ipv4.conf.all.rp_filter        = 1
net.ipv4.conf.default.rp_filter    = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects   = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_timestamps            = 0

# ── File descriptors ──
fs.file-max                        = 1000000
fs.nr_open                         = 1000000

# ── VM ──
vm.swappiness                      = 10
vm.dirty_ratio                     = 10
vm.dirty_background_ratio          = 5

# ── IPv6 ปิด ──
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
EOF

sysctl --system >/dev/null 2>&1
ok "Kernel tuned: BBR(${CC}) + ${QDISC} + 4MB buf + MSS ${MSS} + gaming sysctl"

# MSS clamp ผ่าน iptables (MTU 1500 VPN → MSS 1440)
if command -v iptables &>/dev/null; then
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS} 2>/dev/null || true
  iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS} 2>/dev/null || true
fi
ok "MSS clamp ${MSS} bytes"

# ── THP disable ──
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

# ── initcwnd = 20 ──
DEV=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "${DEV:-}" ]; then
  cat > /etc/systemd/system/initcwnd-tune.service << SVCEOF
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
SVCEOF
  ip route change default dev "${DEV}" initcwnd 20 initrwnd 20 2>/dev/null || true
fi

# ── x-ui override: realtime + autorestart ──
mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
Nice=-10
IOSchedulingClass=realtime
IOSchedulingPriority=0
LimitNOFILE=1000000
Restart=always
RestartSec=5
EOF

# ── fd limits ──
cat > /etc/security/limits.d/99-vmess.conf << 'EOF'
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF

systemctl daemon-reload
systemctl enable --now thp-disable.service 2>/dev/null || true
[ -n "${DEV:-}" ] && systemctl enable --now initcwnd-tune.service 2>/dev/null || true
ok "THP off + initcwnd 20 + x-ui realtime + fd 1M"

# ── Swap 512MB ──
if swapon --show | grep -q '/swapfile'; then
  ok "Swap มีอยู่แล้ว"
else
  fallocate -l 512M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=512
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap 512MB"
fi

# ════════════════════════════════════════════════════
hdr "STEP 5 — Log เก็บบน Disk (persistent)"
# ════════════════════════════════════════════════════
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
cat > /etc/systemd/journald.conf.d/99-persistent.conf << 'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=200M
SystemKeepFree=500M
SystemMaxFileSize=50M
MaxRetentionSec=7day
MaxFileSec=1day
ForwardToSyslog=no
EOF
# ไม่ restart journald ตอนนี้ — จะใช้หลัง reboot (ป้องกัน SSH หลุด)
ok "journald → disk persistent, rotate 7 วัน, max 200MB"

# ════════════════════════════════════════════════════
hdr "STEP 6 — DNS over TLS + ปิด IPv6 + บล็อก DNS Leak"
# ════════════════════════════════════════════════════

# systemd-resolved → Cloudflare DoT
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
ok "DNS → 1.1.1.1 DoT"

# บล็อก plaintext DNS port 53 ขาออกทั้งหมด
cat > /etc/nftables-dns-block.conf << 'EOF'
table inet dns_privacy {
  chain output_dns_block {
    type filter hook output priority 0; policy accept;
    # อนุญาตเฉพาะ stub resolver ของ systemd-resolved
    ip daddr 127.0.0.53 udp dport 53 accept
    ip daddr 127.0.0.53 tcp dport 53 accept
    # บล็อก DNS plaintext ทุกอย่างที่เหลือ
    udp dport 53 drop
    tcp dport 53 drop
  }
}
EOF
nft delete table inet dns_privacy 2>/dev/null || true
nft -f /etc/nftables-dns-block.conf

cat > /etc/systemd/system/dns-privacy-nft.service << 'EOF'
[Unit]
Description=Block plaintext DNS (anti-leak)
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
ok "บล็อก port 53 plaintext DNS ขาออก"

# ปิด IPv6 บน kernel ทุก interface
for iface in $(ip link show | awk -F': ' '/^[0-9]+:/ {print $2}' | cut -d@ -f1); do
  echo 1 > /proc/sys/net/ipv6/conf/"${iface}"/disable_ipv6 2>/dev/null || true
done
ok "IPv6 ปิดสมบูรณ์"

# ════════════════════════════════════════════════════
hdr "STEP 7 — Harden SSH (ป้องกัน brute force)"
# ════════════════════════════════════════════════════
# Rate-limit SSH connection ผ่าน ufw
ufw limit 22/tcp comment 'SSH rate-limit'

# Harden sshd config
SSHD=/etc/ssh/sshd_config
cp "$SSHD" "${SSHD}.bak.$(date +%s)"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' "$SSHD"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/' "$SSHD"
sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 30/' "$SSHD"
grep -q "^ClientAliveInterval" "$SSHD" || echo "ClientAliveInterval 120" >> "$SSHD"
grep -q "^ClientAliveCountMax" "$SSHD" || echo "ClientAliveCountMax 3" >> "$SSHD"
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "SSH hardened + rate-limited"

# ════════════════════════════════════════════════════
hdr "STEP 8 — Restart x-ui"
# ════════════════════════════════════════════════════
systemctl restart x-ui
sleep 5

# ════════════════════════════════════════════════════
hdr "VERIFY"
# ════════════════════════════════════════════════════
errors=0
chk() { if eval "$2"; then ok "$1"; else warn "$1 — ไม่ผ่าน"; errors=$((errors+1)); fi; }

chk "Congestion control = ${CC}"  "[ \"\$(sysctl -n net.ipv4.tcp_congestion_control)\" = '${CC}' ]"
chk "qdisc = ${QDISC}"            "[ \"\$(sysctl -n net.core.default_qdisc)\" = '${QDISC}' ]"
chk "IPv6 ปิด"                    "[ \"\$(sysctl -n net.ipv6.conf.all.disable_ipv6)\" = '1' ]"
chk "TCP timestamps ปิด"          "[ \"\$(sysctl -n net.ipv4.tcp_timestamps)\" = '0' ]"
chk "DNS → 1.1.1.1"               "resolvectl status 2>/dev/null | grep -q '1.1.1.1'"
chk "Port 22 เปิด"                "ufw status | grep -qE '^22/tcp'"
chk "Port 80 เปิด"                "ufw status | grep -qE '^80/tcp'"
chk "Port 2053 เปิด"              "ufw status | grep -qE '^2053/tcp'"
chk "x-ui ทำงานอยู่"              "systemctl is-active --quiet x-ui"
chk "Port 2053 listening"         "ss -tlnp | grep -q ':2053'"
chk "Swap active"                 "swapon --show | grep -q '/swapfile'"

if timeout 3 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
  warn "DNS leak: port 53 ยังออกได้"
  errors=$((errors+1))
else
  ok "ไม่มี DNS leak (port 53 ถูกบล็อก)"
fi

PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || \
         curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "  ══════════════════════════════════════════════════════"
echo -e "  ${BLD}Server IP${RST}   : ${PUB_IP}"
echo -e "  ${BLD}Panel URL${RST}   : https://<domain>:2053/<path>"
echo -e "  ${BLD}Firewall${RST}    : TCP 22(rate-limited)/80/2053 เปิด — ที่เหลือปิดหมด"
echo -e "  ${BLD}DNS${RST}         : 1.1.1.1 DoT | plaintext port 53 บล็อก"
echo -e "  ${BLD}IPv6${RST}        : ปิดสมบูรณ์"
echo -e "  ${BLD}Log${RST}         : disk persistent, rotate 7 วัน, max 200MB"
echo -e "  ${BLD}Performance${RST} : BBR(${CC}) + ${QDISC} + 4MB buf + MSS 1440 + initcwnd 20"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}ตั้งใน VMess WS Inbound (3x-ui):${RST}"
echo -e "    Protocol    : VMess"
echo -e "    Port        : 80"
echo -e "    Network     : ws"
echo -e "    Path        : /ws  (หรือตั้งเอง)"
echo -e "    Host        : speedtest.net"
echo -e "    Sniffing    : ปิดทั้งหมด"
echo -e "    Xray DNS    : 127.0.0.53"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}ตั้งใน V2Box (Client):${RST}"
echo -e "    Protocol    : VMess"
echo -e "    Server      : ${PUB_IP} : 80"
echo -e "    Network     : WebSocket"
echo -e "    Path        : /ws"
echo -e "    Host        : speedtest.net"
echo -e "    MTU         : 1500"
echo -e "    TCP MSS     : 1440"
echo -e "  ══════════════════════════════════════════════════════"
echo ""

if [ "$errors" -eq 0 ]; then
  echo -e "${BLD}${GRN}  ✔ ผ่านหมด${RST}"
else
  echo -e "${YEL}  ⚠ พบ ${errors} รายการไม่ผ่าน — ดู log: ${LOG_FILE}${RST}"
fi

echo -e "${BLD}${YEL}  → reboot แล้วเข้า panel ตั้ง VMess WS inbound ได้เลย${RST}"
echo -e "${BLD}${RED}  ⚠ ตรวจว่า SSH เข้าได้ก่อน reboot ทุกครั้ง${RST}"
echo -e "  Log: ${LOG_FILE}"
echo ""
