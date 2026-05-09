#!/usr/bin/env bash
# ==============================================================================
# AIS 128kbps VPS Optimizer — Rebuilt from scratch
#
# Target : Ubuntu 22.04 / 1 vCPU / 1 GB RAM / VPS Thailand
#          AIS 4G/5G 128kbps throttled (ฝั่ง client)
#          3x-ui panel : port 2053
#          Proxy port  : 443
#
# หลักการที่ถูกต้อง:
#   - CAKE/shaping ใช้ฝั่ง CLIENT เท่านั้น ไม่ใช้บน VPS server
#   - VPS server ใช้ fq_codel + BBR → ปล่อย traffic เต็มที่ ลด latency
#   - ลด bufferbloat ด้วย fq_codel (built-in ใน kernel) ไม่ต้อง shape
#
# RUN      : sudo bash ais128k-tuning.sh
# IDEMPOTENT: รัน ซ้ำได้ปลอดภัย
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'

info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[FAIL]${RESET} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ------------------------------------------------------------------------------
# DETECT INTERFACE + PUBLIC IP
# ------------------------------------------------------------------------------

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n "$IFACE" ]] || die "Cannot detect default interface"
info "Interface : $IFACE"

PUBLIC_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
info "Public IP : $PUBLIC_IP"

# ==============================================================================
# 1. PACKAGES
# ==============================================================================

info "Stopping systemd-resolved (free port 53 before dnsmasq)..."
systemctl stop systemd-resolved    2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# ตั้ง resolv.conf ชั่วคราว ป้องกัน DNS break ระหว่าง install
rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf

info "apt update + upgrade + install..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget ethtool dnsmasq sqlite3 jq cron socat \
    ca-certificates iproute2 iputils-ping nftables

ok "Packages ready"

# ==============================================================================
# 2. HOSTNAME ใน /etc/hosts (แก้ปัญหา sudo: unable to resolve host)
# ==============================================================================

HOSTNAME_NOW=$(hostname)
if ! grep -q "$HOSTNAME_NOW" /etc/hosts 2>/dev/null; then
    echo "127.0.1.1 $HOSTNAME_NOW" >> /etc/hosts
    ok "Hostname $HOSTNAME_NOW added to /etc/hosts"
else
    info "Hostname already in /etc/hosts"
fi

# ==============================================================================
# 3. INSTALL / UPDATE 3X-UI
# ==============================================================================

info "Installing / updating 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
    || die "3x-ui install failed"
ok "3x-ui installed / updated"

# ==============================================================================
# 4. SET 3X-UI PANEL PORT → 2053
# ==============================================================================

info "Setting panel port to 2053..."

X_UI_DB="/etc/x-ui/x-ui.db"
[[ -f "$X_UI_DB" ]] || die "x-ui.db not found — 3x-ui install failed"

systemctl stop x-ui 2>/dev/null || true

sqlite3 "$X_UI_DB" "UPDATE settings SET value='2053' WHERE key='webPort';" 2>/dev/null \
    && ok "Panel port → 2053" \
    || warn "sqlite3 failed — set panel port manually to 2053"

# ==============================================================================
# 5. SYSCTL — BBR + fq_codel + TCP latency tuning
# ==============================================================================
# หลักการ:
#   BBR = congestion control ที่ดีที่สุดสำหรับ latency-sensitive connection
#   fq_codel = AQM ลด bufferbloat โดยไม่ต้อง shape bandwidth
#   buffer เล็ก = ลด queue delay บน link ที่ช้า
# ==============================================================================

info "Applying sysctl..."

cat > /etc/sysctl.d/99-ais-128k.conf << 'SYSCTL'
# ============================================================
# AIS 128kbps VPS — Low Latency Tuning
# ใช้ BBR + fq_codel ไม่มี CAKE (CAKE ใช้ฝั่ง client เท่านั้น)
# ============================================================

# --- Congestion Control ---
net.core.default_qdisc          = fq_codel
net.ipv4.tcp_congestion_control = bbr

# --- TCP Buffer (ปรับให้พอดี ไม่ bloat) ---
net.core.rmem_max     = 16777216
net.core.wmem_max     = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem     = 4096 87380 16777216
net.ipv4.tcp_wmem     = 4096 65536 16777216

# --- TCP Latency ---
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_notsent_lowat         = 16384
net.ipv4.tcp_autocorking           = 0
net.ipv4.tcp_moderate_rcvbuf       = 1
net.ipv4.tcp_sack                  = 1
net.ipv4.tcp_timestamps            = 1

# --- Connection Handling ---
net.core.somaxconn            = 4096
net.core.netdev_max_backlog   = 4096
net.ipv4.tcp_max_syn_backlog  = 4096
net.ipv4.tcp_fin_timeout      = 15
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_tw_reuse          = 1

# --- Memory (1GB RAM) ---
vm.swappiness             = 10
vm.vfs_cache_pressure     = 50
vm.dirty_ratio            = 15
vm.dirty_background_ratio = 5

# --- Security ---
net.ipv4.tcp_syncookies              = 1
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_rfc1337                 = 1

# --- IP Forward (สำหรับ proxy/VPN) ---
net.ipv4.ip_forward = 1

# --- Jitter Reduction ---
kernel.nmi_watchdog            = 0
kernel.sched_autogroup_enabled = 0
SYSCTL

sysctl --system -q
ok "sysctl applied (BBR + fq_codel)"

# ==============================================================================
# 6. QDISC — fq_codel เท่านั้น ไม่ shape bandwidth บน server
# ==============================================================================
# ทำไมไม่ใช้ CAKE บน server:
#   CAKE ที่ 115kbps จะ cap traffic ขาออกจาก VPS → client ช้ามาก
#   CAKE ควรรันบน router/client ฝั่งผู้ใช้ที่มี link 128kbps จริงๆ
#   บน server ใช้แค่ fq_codel → ลด queue delay โดยไม่ cap bandwidth
# ==============================================================================

info "Setting fq_codel qdisc (no bandwidth cap on server)..."
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root fq_codel \
    limit 1024 \
    flows 1024 \
    target 5ms \
    interval 100ms \
    ecn
ok "fq_codel applied"

# ==============================================================================
# 7. NIC TUNING
# ==============================================================================

info "NIC tuning..."

# txqueuelen ปกติ 1000 ดีกว่า 32 สำหรับ server (32 เหมาะ client เท่านั้น)
ip link set "$IFACE" txqueuelen 1000
ok "txqueuelen=1000"

# บน VPS virtio ปกติ GRO/GSO ช่วย throughput — เปิดทิ้งไว้
# ปิดแค่ TSO เพราะ interact กับ fq_codel ได้ไม่ดี
ethtool -K "$IFACE" tso off 2>/dev/null || true
ok "TSO disabled (GRO/GSO kept for VPS throughput)"

# ==============================================================================
# 8. FIREWALL — nftables
# ==============================================================================

info "Setting up nftables..."

cat > /etc/nftables.conf << 'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # loopback
        iif lo accept

        # established / related
        ct state established,related accept

        # ICMP (จำเป็นสำหรับ PMTUD + ping)
        ip  protocol icmp icmp  type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr  icmpv6     accept

        # SSH (rate limit ป้องกัน brute force)
        tcp dport 22 ct state new limit rate 10/minute accept

        # VLESS Reality / proxy
        tcp dport 443 accept

        # 3x-ui panel
        tcp dport 2053 accept

        # drop ที่เหลือ
        log prefix "nft-drop: " flags all limit rate 5/minute
        drop
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFT

systemctl enable nftables
systemctl restart nftables
ok "nftables active (22 / 443 / 2053)"

# ==============================================================================
# 9. DNSMASQ — local DNS cache
# ==============================================================================

info "Configuring dnsmasq..."
systemctl stop dnsmasq 2>/dev/null || true

rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'RESOLV'
nameserver 127.0.0.1
options timeout:1 attempts:2
RESOLV

chattr +i /etc/resolv.conf 2>/dev/null || warn "chattr not available"

cat > /etc/dnsmasq.d/ais.conf << 'DNSMASQ'
# ไม่อ่าน /etc/resolv.conf
no-resolv

# upstream DNS
server=1.1.1.1
server=1.0.0.1

# cache
cache-size=2000
neg-ttl=30
dns-forward-max=150
no-poll
bogus-priv
domain-needed

# bind เฉพาะ localhost
listen-address=127.0.0.1
bind-interfaces
DNSMASQ

systemctl enable dnsmasq
systemctl restart dnsmasq
ok "dnsmasq ready (cache → 1.1.1.1)"

# ==============================================================================
# 10. ZRAM — compressed swap 256MB
# ==============================================================================

info "Setting up ZRAM..."

if swapon --show | grep -q zram0; then
    info "ZRAM already active — skipping"
else
    modprobe zram 2>/dev/null || true

    cat > /etc/systemd/system/zram.service << 'ZRAMSVC'
[Unit]
Description=ZRAM compressed swap
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/bin/bash -c '\
    modprobe zram 2>/dev/null || true; \
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null \
        || echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null \
        || true; \
    echo 268435456 > /sys/block/zram0/disksize; \
    mkswap /dev/zram0 && swapon -p 100 /dev/zram0'

ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
ZRAMSVC

    systemctl daemon-reload
    systemctl enable zram
    systemctl start zram || warn "ZRAM start failed (reboot แล้วลองใหม่)"
fi
ok "ZRAM ready"

# ==============================================================================
# 11. X-UI TUNING + START
# ==============================================================================

info "Tuning x-ui / xray..."
mkdir -p /etc/systemd/system/x-ui.service.d

cat > /etc/systemd/system/x-ui.service.d/override.conf << 'XRAY'
[Service]
Environment=GOMAXPROCS=1
Environment=GOGC=80
LimitNOFILE=65536
LimitNPROC=4096
OOMScoreAdjust=-500
Restart=always
RestartSec=3
XRAY

systemctl daemon-reload
systemctl enable x-ui
systemctl restart x-ui
ok "x-ui tuned + started"

# ==============================================================================
# 12. CPU GOVERNOR
# ==============================================================================

if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
    ok "CPU governor: performance"
else
    info "CPU governor not available (VM/cloud — normal)"
fi

# ==============================================================================
# 13. THP OFF (ลด latency spike)
# ==============================================================================

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
ok "THP disabled"

# ==============================================================================
# 14. PERSIST ON REBOOT — ais-net.service
# ==============================================================================

info "Creating ais-net.service (persist after reboot)..."

cat > /etc/systemd/system/ais-net.service << NETSVC
[Unit]
Description=AIS VPS Network Tuning (fq_codel + NIC)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/bin/bash -c '\
    tc qdisc del dev ${IFACE} root 2>/dev/null || true; \
    tc qdisc add dev ${IFACE} root fq_codel limit 1024 flows 1024 target 5ms interval 100ms ecn; \
    ip link set ${IFACE} txqueuelen 1000; \
    ethtool -K ${IFACE} tso off 2>/dev/null || true; \
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; \
    echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true'

[Install]
WantedBy=multi-user.target
NETSVC

systemctl daemon-reload
systemctl enable ais-net.service
ok "ais-net.service enabled"

# ==============================================================================
# 15. JOURNAL LIMIT
# ==============================================================================

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limit.conf << 'JOURNAL'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=20M
JOURNAL
systemctl restart systemd-journald
ok "Journal limited to 50MB"

# ==============================================================================
# 16. DISABLE NOISE SERVICES
# ==============================================================================

for svc in apport ufw; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl stop    "$svc" 2>/dev/null || true
done
ok "Unused services disabled (apport / ufw)"

# ==============================================================================
# SUMMARY
# ==============================================================================

clear
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║        AIS 128kbps VPS OPTIMIZER — DONE                 ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  NETWORK (server-side ที่ถูกต้อง)                       ║"
echo "║  Qdisc  : fq_codel (ไม่ cap bandwidth บน server)        ║"
echo "║  CC     : BBR                                            ║"
echo "║  FW     : nftables — port 22 / 443 / 2053               ║"
echo "║  DNS    : dnsmasq cache → 1.1.1.1                       ║"
echo "║  ZRAM   : 256MB compressed swap                         ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  3X-UI PANEL                                             ║"
echo "║  http://${PUBLIC_IP}:2053                                "
echo "║  (เข้าไปสร้าง inbound VLESS Reality เองใน panel)        ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  VERIFY                                                  ║"
echo "║  tc qdisc show dev ${IFACE}                              "
echo "║  sysctl net.ipv4.tcp_congestion_control                  ║"
echo "║  systemctl status x-ui dnsmasq                          ║"
echo "║  nft list ruleset                                        ║"
echo "║  swapon --show                                           ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  ⚠️  REBOOT เพื่อให้ sysctl + ZRAM มีผลสมบูรณ์          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
