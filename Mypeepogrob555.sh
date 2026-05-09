#!/usr/bin/env bash
# ==============================================================================
# AIS 128kbps — Network & System Optimizer
#
# Target:
#   Ubuntu 22.04 / 1 vCPU / 1 GB RAM / VPS ในประเทศไทย
#   AIS 4G/5G throttled 128 kbps
#   3x-ui panel port : 2053
#
# GOAL: ปิงต่ำสุด / jitter ต่ำสุด / bufferbloat ต่ำสุด
#
# RUN  : sudo bash ais128k-Mypeepogrob.sh
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
# DETECT INTERFACE
# ------------------------------------------------------------------------------

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n "$IFACE" ]] || die "Cannot detect default interface"
info "Interface : $IFACE"

# ------------------------------------------------------------------------------
# MTU AUTO-DETECT
# ------------------------------------------------------------------------------

detect_mtu() {
    for size in 1428 1400 1372 1344; do
        if ping -c1 -W1 -M do -s "$size" 1.1.1.1 &>/dev/null 2>&1; then
            echo $(( size + 28 - 80 ))
            return
        fi
    done
    echo 1360
}

MTU_VAL=$(detect_mtu)
info "MTU (auto-detected) : $MTU_VAL"

# ==============================================================================
# 1. PACKAGES
# ==============================================================================

info "Stopping systemd-resolved (free port 53 before dnsmasq)..."
systemctl stop systemd-resolved    2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf

info "apt update + upgrade + install..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget ethtool dnsmasq jq cron socat \
    ca-certificates iproute2 iputils-ping nftables

ok "Packages ready"

# ==============================================================================
# 2. INSTALL / UPDATE 3X-UI
# ==============================================================================

info "Installing / updating 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
    || die "3x-ui install failed"
ok "3x-ui installed / updated"

# ==============================================================================
# 3. SET 3X-UI PANEL PORT → 2053
# ==============================================================================

info "Setting panel port to 2053..."

X_UI_DB="/etc/x-ui/x-ui.db"
[[ -f "$X_UI_DB" ]] || die "x-ui.db not found — 3x-ui install may have failed"

systemctl stop x-ui 2>/dev/null || true

# ติดตั้ง sqlite3 ถ้ายังไม่มี
DEBIAN_FRONTEND=noninteractive apt-get install -y sqlite3 2>/dev/null || true

sqlite3 "$X_UI_DB" "UPDATE settings SET value='2053' WHERE key='webPort';" 2>/dev/null \
    && ok "Panel port → 2053" \
    || warn "Could not set panel port via sqlite3 — set manually in panel"

# ==============================================================================
# 4. SYSCTL
# ==============================================================================

info "Applying sysctl..."

cat > /etc/sysctl.d/99-ais-128k.conf << 'SYSCTL'
# AIS 128kbps LOW-LATENCY — tuned for 1vCPU/1GB/2users

# CC / AQM
net.core.default_qdisc          = fq_codel
net.ipv4.tcp_congestion_control = bbr

# Buffer (เล็กพอ — ไม่ bloat บน 128kbps)
net.core.rmem_max     = 1048576
net.core.wmem_max     = 1048576
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.ipv4.tcp_rmem     = 4096 32768 524288
net.ipv4.tcp_wmem     = 4096 32768 524288

# Latency
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_notsent_lowat         = 4096
net.ipv4.tcp_autocorking           = 0
net.ipv4.tcp_moderate_rcvbuf       = 1

# Connection
net.core.somaxconn            = 512
net.core.netdev_max_backlog   = 512
net.ipv4.tcp_max_syn_backlog  = 512
net.ipv4.tcp_fin_timeout      = 10
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 15
net.ipv4.tcp_keepalive_probes = 3

# Memory
vm.swappiness             = 10
vm.vfs_cache_pressure     = 50
vm.dirty_ratio            = 10
vm.dirty_background_ratio = 3

# Security
net.ipv4.tcp_syncookies              = 1
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Forward (VPN/proxy)
net.ipv4.ip_forward = 1

# Jitter reduction
kernel.nmi_watchdog            = 0
kernel.sched_autogroup_enabled = 0
SYSCTL

sysctl --system -q
ok "sysctl applied"

# ==============================================================================
# 5. CAKE QDISC
# ==============================================================================

info "Applying CAKE qdisc..."
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root cake \
    bandwidth 115kbit \
    diffserv4 \
    nat \
    wash \
    no-ack-filter \
    rtt 20ms
ok "CAKE: 115kbps / diffserv4 / rtt 20ms"

# ==============================================================================
# 6. NIC TUNING
# ==============================================================================

ip link set "$IFACE" txqueuelen 32
ok "txqueuelen=32"

ethtool -K "$IFACE" gro off gso off tso off 2>/dev/null || true
ok "GRO/GSO/TSO disabled"

ip link set dev "$IFACE" mtu "$MTU_VAL" 2>/dev/null \
    && ok "MTU=$MTU_VAL" \
    || warn "Cannot set MTU=$MTU_VAL — continuing"

# ==============================================================================
# 7. FIREWALL — nftables
# ==============================================================================

info "Setting up nftables..."

cat > /etc/nftables.conf << 'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept

        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        # SSH
        tcp dport 22 ct state new limit rate 10/minute accept

        # VLESS Reality (client เชื่อม)
        tcp dport 443 accept

        # 3x-ui panel
        tcp dport 2053 accept

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
# 8. DNSMASQ
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
no-resolv
server=1.1.1.1
server=1.0.0.1
cache-size=2000
neg-ttl=30
dns-forward-max=50
no-poll
bogus-priv
domain-needed
DNSMASQ

systemctl enable dnsmasq
systemctl restart dnsmasq
ok "dnsmasq ready"

# ==============================================================================
# 9. ZRAM
# ==============================================================================

info "Setting up ZRAM..."

if swapon --show | grep -q zram0; then
    info "ZRAM already active — skipping"
else
    modprobe zram 2>/dev/null || true

    cat > /etc/systemd/system/zram.service << 'ZRAMSVC'
[Unit]
Description=ZRAM swap
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
    systemctl start zram || warn "ZRAM start failed (may need reboot)"
fi
ok "ZRAM ready"

# ==============================================================================
# 10. X-UI TUNING + START
# ==============================================================================

info "Tuning x-ui service..."
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
# 11. CPU GOVERNOR
# ==============================================================================

if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
    ok "CPU governor: performance"
else
    info "CPU governor not available (VM — normal)"
fi

# ==============================================================================
# 12. THP OFF
# ==============================================================================

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
ok "THP disabled"

# ==============================================================================
# 13. PERSIST ON REBOOT
# ==============================================================================

info "Creating ais-net.service..."
MTU_PERSIST="$MTU_VAL"

cat > /etc/systemd/system/ais-net.service << NETSVC
[Unit]
Description=AIS 128k Network Tuning (CAKE + MTU + Offload)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    tc qdisc del dev ${IFACE} root 2>/dev/null || true; \
    tc qdisc add dev ${IFACE} root cake bandwidth 115kbit diffserv4 nat wash no-ack-filter rtt 20ms; \
    ip link set ${IFACE} txqueuelen 32; \
    ip link set dev ${IFACE} mtu ${MTU_PERSIST} 2>/dev/null || true; \
    ethtool -K ${IFACE} gro off gso off tso off 2>/dev/null || true; \
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; \
    echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true'

[Install]
WantedBy=multi-user.target
NETSVC

systemctl daemon-reload
systemctl enable ais-net.service
ok "ais-net.service enabled"

# ==============================================================================
# 14. JOURNAL LIMIT
# ==============================================================================

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/limit.conf << 'JOURNAL'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=20M
JOURNAL
systemctl restart systemd-journald
ok "Journal limited"

# ==============================================================================
# 15. DISABLE NOISE SERVICES
# ==============================================================================

for svc in apport ufw; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl stop    "$svc" 2>/dev/null || true
done
ok "Unused services disabled"

# ==============================================================================
# SUMMARY
# ==============================================================================

clear
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      AIS 128kbps — NETWORK OPTIMIZER DONE               ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  NETWORK TUNING                                          ║"
echo "║  MTU    : ${MTU_VAL} (auto-detected)                     "
echo "║  Qdisc  : CAKE 115kbps / diffserv4 / rtt 20ms           ║"
echo "║  CC     : BBR                                            ║"
echo "║  FW     : nftables (22 / 443 / 2053)                    ║"
echo "║  DNS    : dnsmasq → 1.1.1.1                             ║"
echo "║  ZRAM   : 256MB compressed swap                         ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  3X-UI PANEL                                             ║"
echo "║  http://YOUR_IP:2053                                     ║"
echo "║  (เข้าไปสร้าง inbound เองใน panel)                     ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  VERIFY                                                  ║"
echo "║  sysctl net.ipv4.tcp_congestion_control                  ║"
echo "║  tc qdisc show dev ${IFACE}                              "
echo "║  systemctl status x-ui                                   ║"
echo "║  nft list ruleset                                        ║"
echo "║  swapon --show                                           ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  ⚠️  REBOOT เพื่อให้ sysctl + ZRAM มีผลสมบูรณ์          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
