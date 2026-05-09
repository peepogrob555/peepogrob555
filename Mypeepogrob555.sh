#!/usr/bin/env bash
# ==============================================================================
# AIS 128kbps VMESS/VLESS WS :80 — Low-Latency / Low-Jitter Build
#
# Target:
#   Ubuntu 22.04
#   1 vCPU / 1 GB RAM
#   2 users max
#   VPS ในประเทศไทย 
#   VMESS/VLESS + WS + Port 80 (no TLS)
#   AIS 4G/5G throttled 128 kbps
#   speedtest host : th.speedtest.net  path : /Ais
#
# GOAL: ปิงต่ำสุด / jitter ต่ำสุด / bufferbloat ต่ำสุด
#
# RUN:
#   sudo bash ais128k-vmess/vless.sh
#
# IDEMPOTENT: รัน ซ้ำได้ปลอดภัย
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# COLOR / LOG
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[FAIL]${RESET} $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# ROOT CHECK
# ------------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

# ------------------------------------------------------------------------------
# DETECT INTERFACE
# ------------------------------------------------------------------------------

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n "$IFACE" ]] || die "Cannot detect default interface"
info "Interface : $IFACE"

# ------------------------------------------------------------------------------
# MTU DISCOVERY
# (WS overhead ≈ 72 bytes: IP20 + TCP20 + HTTP-upgrade ~32)
# ใช้ path MTU probe แล้ว fallback 1400 ถ้าไม่ได้ผล
# ------------------------------------------------------------------------------

detect_mtu() {
    local target="1.1.1.1"
    local probe_mtu
    for size in 1428 1400 1372 1344; do
        if ping -c1 -W1 -M do -s "$size" "$target" &>/dev/null 2>&1; then
            probe_mtu=$(( size + 28 ))
            echo $(( probe_mtu - 80 ))
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

info "Installing packages..."

# --- [FIX] หยุด systemd-resolved ก่อน apt install dnsmasq ---
# apt จะ auto-start dnsmasq ทันทีหลัง install
# ถ้า systemd-resolved ยังฟัง port 53 อยู่ → dnsmasq start failed
info "Stopping systemd-resolved before dnsmasq install..."
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# ตั้ง resolv.conf ชั่วคราวให้ใช้ Cloudflare โดยตรง
rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# --- [FIX] update + upgrade ก่อนเสมอ ---
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget ethtool dnsmasq jq cron socat ca-certificates \
    iproute2 iputils-ping nftables

ok "Packages installed + upgraded"

# ==============================================================================
# 2. INSTALL 3X-UI (always install / update)
# ==============================================================================

info "Installing / updating 3x-ui..."
# --- [FIX] ลบ condition [[ ! -d /etc/x-ui ]] ออก ---
# รันทุกครั้งเพื่อการันตี install และ update เป็น version ล่าสุด
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) \
    || die "3x-ui install failed"
ok "3x-ui installed / updated"

# ==============================================================================
# 3. SYSCTL
# ==============================================================================

info "Applying sysctl..."

cat > /etc/sysctl.d/99-ais-128k.conf << 'SYSCTL'
# ==============================================================================
# AIS 128kbps LOW-LATENCY / LOW-JITTER
# Tuned for: throttled 128kbps, VPS in-country, 1vCPU/1GB, 2 users
# ==============================================================================

# --- AQM / CC ---
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# --- BUFFER ---
net.core.rmem_max        = 1048576
net.core.wmem_max        = 1048576
net.core.rmem_default    = 131072
net.core.wmem_default    = 131072

net.ipv4.tcp_rmem = 4096 32768 524288
net.ipv4.tcp_wmem = 4096 32768 524288

# --- LATENCY TUNING ---
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing        = 1
net.ipv4.tcp_notsent_lowat      = 4096
net.ipv4.tcp_autocorking        = 0
net.ipv4.tcp_moderate_rcvbuf    = 1

# --- CONNECTION ---
net.core.somaxconn           = 512
net.core.netdev_max_backlog  = 512
net.ipv4.tcp_max_syn_backlog = 512
net.ipv4.tcp_fin_timeout     = 10
net.ipv4.tcp_keepalive_time  = 60
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3

# --- MEMORY (1GB RAM) ---
vm.swappiness             = 10
vm.vfs_cache_pressure     = 50
vm.dirty_ratio            = 10
vm.dirty_background_ratio = 3

# --- SECURITY ---
net.ipv4.tcp_syncookies          = 1
net.ipv4.conf.all.rp_filter      = 1
net.ipv4.conf.default.rp_filter  = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

# --- FORWARD (proxy/VPN) ---
net.ipv4.ip_forward = 1

# --- JITTER REDUCTION ---
kernel.nmi_watchdog          = 0
kernel.sched_autogroup_enabled = 0
SYSCTL

sysctl --system -q
ok "sysctl applied"

# ==============================================================================
# 4. TRAFFIC CONTROL — CAKE
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

ok "CAKE applied (115kbps / diffserv4 / rtt 20ms)"

# ==============================================================================
# 5. TXQUEUE
# ==============================================================================

ip link set "$IFACE" txqueuelen 32
ok "txqueuelen=32"

# ==============================================================================
# 6. NIC OFFLOAD
# ==============================================================================

ethtool -K "$IFACE" gro off gso off tso off 2>/dev/null || true
ok "NIC offload disabled"

# ==============================================================================
# 7. MTU
# ==============================================================================

ip link set dev "$IFACE" mtu "$MTU_VAL" 2>/dev/null \
    && ok "MTU=$MTU_VAL" \
    || warn "Cannot set MTU=$MTU_VAL (VM may ignore) — continuing"

# ==============================================================================
# 8. FIREWALL — nftables
# ==============================================================================

info "Setting up nftables firewall..."

cat > /etc/nftables.conf << 'NFT'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept

        ip protocol icmp  icmp  type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        tcp dport 22 ct state new limit rate 10/minute accept
        tcp dport 80 accept
        tcp dport 54321 accept

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
ok "nftables firewall active"

# ==============================================================================
# 9. DNSMASQ
# ==============================================================================
# systemd-resolved ถูก stop/disable ไปแล้วใน section 1

info "Configuring dnsmasq..."

systemctl stop dnsmasq 2>/dev/null || true

rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'RESOLV'
nameserver 127.0.0.1
options timeout:1 attempts:2
RESOLV

chattr +i /etc/resolv.conf 2>/dev/null || warn "chattr not available — resolv.conf may be overwritten"

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
# 10. ZRAM (idempotent)
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
# 11. X-UI / XRAY TUNING
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
systemctl restart x-ui 2>/dev/null || warn "x-ui restart failed"
ok "x-ui tuned"

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
# 13. THP OFF
# ==============================================================================

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
ok "THP disabled"

# ==============================================================================
# 14. PERSIST: TC + MTU + OFFLOAD (survive reboot)
# ==============================================================================

info "Creating persistence service..."

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
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
NETSVC

systemctl daemon-reload
systemctl enable ais-net.service
ok "Persistence service: ais-net.service"

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
ok "Journal limited"

# ==============================================================================
# 16. DISABLE NOISE SERVICES
# ==============================================================================

for svc in apport ufw; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl stop    "$svc" 2>/dev/null || true
done
ok "Unused services disabled"

# ==============================================================================
# VERIFY SUMMARY
# ==============================================================================

clear

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     AIS 128kbps VMESS WS — LOW LATENCY BUILD DONE       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  VMESS/VLESS SETTINGS (ตั้งใน 3x-ui panel)                 ║"
echo "║  ─────────────────────────────────                 ║"
echo "║  Port     : 80                                           ║"
echo "║  Network  : ws                                           ║"
echo "║  Path     : /Ais                                         ║"
echo "║  TLS      : OFF                                          ║"
echo "║  MUX      : OFF                                          ║"
echo "║  gRPC     : OFF                                          ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  NETWORK TUNING                                          ║"
echo "║  ─────────────────────────────────                 ║"
echo "║  MTU      : $MTU_VAL (auto-detected)                     "
echo "║  Qdisc    : CAKE 115kbps / diffserv4 / rtt 20ms          ║"
echo "║  txqueue  : 32                                           ║"
echo "║  CC       : BBR                                          ║"
echo "║  Firewall : nftables (port 22/80/54321)                  ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  VERIFY COMMANDS                                         ║"
echo "║  ─────────────────────────────────                 ║"
echo "║  sysctl net.ipv4.tcp_congestion_control                  ║"
echo "║  tc qdisc show dev $IFACE                                "
echo "║  swapon --show                                           ║"
echo "║  nft list ruleset                                        ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  ⚠️  REBOOT เพื่อให้ sysctl + ZRAM มีผลสมบูรณ์                 ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
