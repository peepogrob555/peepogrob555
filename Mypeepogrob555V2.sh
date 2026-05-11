#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
#  AIS VPS · LATENCY-FIRST TUNING · v3.0
#  Profile : AIS 128 kbps  →  Thailand VPS  →  VLESS Reality :443
#  Panel   : 3x-ui :2053  ·  SNI: th.speedtest.net
#  Kernel  : 5.15.x (Ubuntu)  ·  Spec: 1 vCPU · 1 GB RAM
#  Goal    : ping ต่ำ-เสถียร  >>  throughput
#
#  Usage   : sudo bash ais128k-tune.sh [--dry-run | --rollback]
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# COLOUR PALETTE
# ─────────────────────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
BRED='\033[1;31m'; BGRN='\033[1;32m'; BYLW='\033[1;33m'
BCYN='\033[1;36m'; BWHT='\033[1;37m'
BG_BLK='\033[40m'; BG_YLW='\033[43m'; BLK='\033[0;30m'

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
LOG_FILE="/var/log/ais128k-tuning.log"
BACKUP_DIR="/etc/ais128k-backup"
STEP_NUM=0
STEP_TOTAL=12
PHASE_START_MS=0

# ── Tuning constants — คำนวณจากสภาพเน็ตจริง ──────────────────────────────────
# BDP = 128 kbps × 50 ms = 6 400 bytes
# Buffer = 4× BDP ≈ 32 KB / conn  (latency-first: เล็กพอ ไม่ bloat)
CLIENT_BW_KBIT=128       # AIS uplink ของ client
RTT_MS=50                # worst-case RTT client→VPS (4G Thailand)
TCP_BUF_MAX=4194304      # 4 MB — รองรับหลาย session พร้อมกัน
CAKE_TARGET_MS=5         # AQM target sojourn time
CAKE_INTERVAL_MS=100     # AQM interval ≈ 2× RTT

# ─────────────────────────────────────────────────────────────────────────────
# TUI ENGINE
# ─────────────────────────────────────────────────────────────────────────────
_now_ms() { date +%s%3N; }
_log()    { printf "$(date '+%Y-%m-%d %H:%M:%S') [%s] %s\n" "$1" "${*:2}" \
                >> "$LOG_FILE" 2>/dev/null || true; }
_cols()   { tput cols 2>/dev/null || echo 80; }

_rule() {
    local char="${1:--}" color="${2:-$DIM}"
    local line; line=$(printf "%$(_cols)s" | tr ' ' "$char")
    printf "${color}%s${RST}\n" "$line"
}

phase() {
    PHASE_START_MS=$(_now_ms)
    local title="$1" cols pad
    cols=$(_cols); pad=$(( (cols - ${#title} - 10) / 2 ))
    echo ""
    _rule "═" "$BCYN"
    printf "${BG_BLK}${BCYN}${BOLD}%${pad}s  ◈  %s  ◈  %${pad}s${RST}\n" "" "$title" ""
    _rule "═" "$BCYN"
    _log INFO "=== PHASE: $title ==="
}

step() {
    (( STEP_NUM++ )) || true
    local pct=$(( STEP_NUM * 100 / STEP_TOTAL ))
    local filled=$(( pct * 28 / 100 )) bar="" i
    for (( i=0; i<filled;  i++ )); do bar+="█"; done
    for (( i=filled; i<28; i++ )); do bar+="░"; done
    printf "\n${BCYN}  [%02d/%02d]${RST}  ${BOLD}%s${RST}\n" "$STEP_NUM" "$STEP_TOTAL" "$1"
    printf "          ${DIM}[${RST}${BGRN}%s${RST}${DIM}] %3d%%${RST}\n" "$bar" "$pct"
    _log INFO "STEP $STEP_NUM/$STEP_TOTAL: $1"
}

ok()   { local ms=$(( $(_now_ms) - PHASE_START_MS ))
         printf "  ${BGRN}✔${RST}  %-55s ${DIM}+%dms${RST}\n" "$*" "$ms"
         _log OK "$*"; }
info() { printf "  ${BCYN}·${RST}  %s\n" "$*"; _log INFO "$*"; }
warn() { printf "  ${BYLW}⚠${RST}  ${BYLW}%s${RST}\n" "$*"; _log WARN "$*"; }
die()  { printf "\n  ${BRED}✖  FATAL: %s${RST}\n\n" "$*" >&2; _log FAIL "$*"; exit 1; }

spinner() {
    local pid=$1 label="${2:-กำลังทำงาน}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BCYN}%s${RST}  %s..." "${frames[$((i % 10))]}" "$label"
        (( i++ )) || true; sleep 0.08
    done
    printf "\r%-72s\r" ""
}

run() {
    if "$DRY_RUN"; then
        printf "  ${BYLW}○${RST}  ${DIM}[DRY]${RST} %s\n" "$*"; return 0
    fi
    "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOT SCREEN
# ─────────────────────────────────────────────────────────────────────────────
clear
printf "${BCYN}"
cat << 'BANNER'

    ░█████╗░██╗░██████╗   ██╗░░░██╗██████╗░░██████╗
    ██╔══██╗██║██╔════╝   ██║░░░██║██╔══██╗██╔════╝
    ███████║██║╚█████╗░   ╚██╗░██╔╝██████╔╝╚█████╗░
    ██╔══██║██║░╚═══██╗   ░╚████╔╝░██╔═══╝░░╚═══██╗
    ██║░░██║██║██████╔╝   ░░╚██╔╝░░██║░░░░░██████╔╝
    ╚═╝░░╚═╝╚═╝╚═════╝░   ░░░╚═╝░░░╚═╝░░░░░╚═════╝░

BANNER
printf "${RST}"
printf "    ${DIM}AIS 128kbps · Thailand VPS · VLESS Reality :443 · 3x-ui :2053 · v3.0${RST}\n"
printf "    ${DIM}Mode: latency-first  ·  BBR + CAKE  ·  kernel 5.15.x${RST}\n\n"
_rule "─" "$DIM"
echo ""

[[ $EUID -eq 0 ]] || die "ต้องรันเป็น root:  sudo bash $0"
touch "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/ais128k-tuning.log"; touch "$LOG_FILE"; }
info "Session log → $LOG_FILE"
sleep 0.2

# ─────────────────────────────────────────────────────────────────────────────
# ARG PARSING
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --dry-run)
        DRY_RUN=true
        printf "\n  ${BG_YLW}${BLK}  DRY RUN — ไม่มีการเขียนจริง  ${RST}\n\n"
        sleep 0.3 ;;
    --rollback) : ;;
    "")         : ;;
    *) die "Usage: $0 [--dry-run | --rollback]" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--rollback" ]]; then
    phase "ROLLBACK"
    [[ -d "$BACKUP_DIR" ]] || die "ไม่พบ backup ที่ $BACKUP_DIR"

    local_job=$(atq 2>/dev/null | awk '{print $1}' | head -1)
    [[ -n "${local_job:-}" ]] && {
        atrm "$local_job" 2>/dev/null || true
        ok "Deadman timer cancelled (job #$local_job)"
    }

    if [[ -f "$BACKUP_DIR/resolv.conf.meta" ]]; then
        mode=$(cat "$BACKUP_DIR/resolv.conf.meta")
        chattr -i /etc/resolv.conf 2>/dev/null || true
        case "$mode" in
            symlink:*)
                target="${mode#symlink:}"
                rm -f /etc/resolv.conf
                ln -sf "$target" /etc/resolv.conf
                ok "resolv.conf symlink restored → $target" ;;
            file)
                cp "$BACKUP_DIR/resolv.conf" /etc/resolv.conf
                ok "resolv.conf static file restored" ;;
        esac
    fi

    [[ -f "$BACKUP_DIR/nftables.conf" ]] && {
        cp "$BACKUP_DIR/nftables.conf" /etc/nftables.conf
        systemctl restart nftables 2>/dev/null || true
        ok "nftables restored"
    }

    [[ -f /etc/sysctl.d/99-ais-128k.conf ]] && {
        rm -f /etc/sysctl.d/99-ais-128k.conf
        sysctl --system -q 2>/dev/null || true
        ok "sysctl config removed"
    }

    IFACE_RB=$(ip route show default | awk '/default/ {print $5; exit}')
    [[ -n "${IFACE_RB:-}" ]] && {
        tc qdisc del dev "$IFACE_RB" root 2>/dev/null || true
        ok "qdisc cleared on $IFACE_RB"
    }

    for svc in ais-net.service; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done

    [[ -f /etc/systemd/system/x-ui.service.d/latency.conf ]] && {
        rm -f /etc/systemd/system/x-ui.service.d/latency.conf
        systemctl daemon-reload
        systemctl restart x-ui 2>/dev/null || true
        ok "x-ui override removed"
    }

    echo ""
    _rule "═" "$BGRN"
    printf "${BGRN}${BOLD}  ROLLBACK COMPLETE${RST}  — แนะนำ reboot\n"
    _rule "═" "$BGRN"
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE A — ENVIRONMENT SCAN
# ══════════════════════════════════════════════════════════════════════════════
phase "ENVIRONMENT SCAN"

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n "$IFACE" ]] || die "ตรวจไม่พบ default network interface"

SSH_PORT=$(ss -tnlp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')
SSH_PORT=${SSH_PORT:-22}

PUBLIC_IP=$(curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null \
    || ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)

RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)

echo ""
printf "  ${DIM}%-22s${RST}  ${BWHT}%s${RST}\n"        "Interface"     "$IFACE"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s${RST}\n"        "Public IP"     "${PUBLIC_IP:-unknown}"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s${RST}\n"        "SSH Port"      "$SSH_PORT"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s${RST}\n"        "Kernel"        "$(uname -r)"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s MB${RST}\n"     "RAM"           "$RAM_MB"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s vCPU${RST}\n"   "CPU"           "$(nproc)"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s kbps${RST}\n"   "Client BW"     "$CLIENT_BW_KBIT"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s ms (worst)${RST}\n" "RTT target" "$RTT_MS"
echo ""

# conflicting services
HAS_DOCKER=false; HAS_WG=false; HAS_TAILSCALE=false; NFT_SAFE=false
systemctl is-active docker     &>/dev/null && HAS_DOCKER=true
systemctl is-active wg-quick@* &>/dev/null && HAS_WG=true
systemctl is-active tailscaled &>/dev/null && HAS_TAILSCALE=true
$HAS_DOCKER    && { warn "Docker detected    → nftables incremental mode"; NFT_SAFE=true; }
$HAS_WG        && { warn "WireGuard detected → nftables incremental mode"; NFT_SAFE=true; }
$HAS_TAILSCALE && { warn "Tailscale detected → nftables incremental mode"; NFT_SAFE=true; }
$NFT_SAFE      || info "No conflicting stacks → full nftables ruleset"

# resolver mode
if [[ -L /etc/resolv.conf ]]; then
    RESOLVER_MODE="symlink"; RESOLVER_TARGET=$(readlink -f /etc/resolv.conf)
    info "Resolver: symlink → $RESOLVER_TARGET"
else
    RESOLVER_MODE="file"; RESOLVER_TARGET=""
    info "Resolver: static file"
fi
ok "Scan complete"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE B — KERNEL CAPABILITY PROBE
# ══════════════════════════════════════════════════════════════════════════════
phase "KERNEL CAPABILITY PROBE"

CAP_BBR=false; CAP_CAKE=false; CAP_ZRAM=false

_cap() {
    local name="$1"
    if eval "${2}" &>/dev/null 2>&1; then
        printf "  ${BGRN}✔${RST}  %-26s ${BGRN}AVAILABLE${RST}\n" "$name"; return 0
    else
        printf "  ${BYLW}–${RST}  %-26s ${DIM}not supported${RST}\n" "$name"; return 1
    fi
}

echo ""
_cap "BBR (congestion ctrl)" \
    "sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr" && CAP_BBR=true

# CAKE: kernel ≥4.19 + iproute2 ≥4.19 — kernel 5.15 รองรับแน่นอน
_cap "CAKE (qdisc)" \
    "tc qdisc add dev lo root cake 2>/dev/null; tc qdisc del dev lo root 2>/dev/null" \
    && CAP_CAKE=true

_cap "ZRAM"     "modprobe -n zram"    && CAP_ZRAM=true
_cap "nftables" "command -v nft"
_cap "ethtool"  "command -v ethtool"
echo ""

# fallback logic
if $CAP_CAKE; then
    QDISC_MODE="cake"; info "CAKE ✓ — ใช้ CAKE (latency-first)"
else
    QDISC_MODE="fq_codel"
    warn "CAKE ไม่พร้อม → fallback fq_codel (ลอง: apt install iproute2)"
fi

if $CAP_BBR; then
    CC_MODE="bbr"; info "BBR ✓"
else
    CC_MODE="cubic"
    warn "BBR ไม่พร้อม → fallback cubic"
fi

ok "Probe: qdisc=${QDISC_MODE}  cc=${CC_MODE}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE C — BACKUP
# ══════════════════════════════════════════════════════════════════════════════
phase "BACKUP"
run mkdir -p "$BACKUP_DIR"

if ! "$DRY_RUN"; then
    if [[ "$RESOLVER_MODE" == "symlink" ]]; then
        echo "symlink:$RESOLVER_TARGET" > "$BACKUP_DIR/resolv.conf.meta"
        cp -L /etc/resolv.conf "$BACKUP_DIR/resolv.conf" 2>/dev/null || true
    else
        echo "file" > "$BACKUP_DIR/resolv.conf.meta"
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf" 2>/dev/null || true
    fi
fi

[[ -f /etc/nftables.conf ]]              && run cp /etc/nftables.conf             "$BACKUP_DIR/nftables.conf"     || true
[[ -f /etc/sysctl.d/99-ais-128k.conf ]] && run cp /etc/sysctl.d/99-ais-128k.conf "$BACKUP_DIR/99-ais-128k.conf" || true
ok "Backup → $BACKUP_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — PACKAGES
# ══════════════════════════════════════════════════════════════════════════════
phase "PACKAGES"
step "Install dependencies"

run systemctl stop    systemd-resolved 2>/dev/null || true
run systemctl disable systemd-resolved 2>/dev/null || true

if ! "$DRY_RUN"; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    info "Temp resolver → 1.1.1.1 / 8.8.8.8 (pinned)"
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
fi

APT_REQ="curl wget ethtool dnsmasq sqlite3 jq nftables dnsutils ca-certificates iproute2 iputils-ping"
APT_OPT="cron socat at"

if ! "$DRY_RUN"; then
    APT_LOG=$(mktemp /tmp/ais-apt-XXXXXX.log)

    {   apt-get update -qq 2>&1 || {
            warn "apt update มีข้อผิดพลาด — ลอง Ubuntu default mirrors"
            sed -i 's|http://mirrors\.bangmod\.cloud/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
                /etc/apt/sources.list 2>/dev/null || true
            apt-get update -qq 2>&1
        }
    } >> "$APT_LOG" 2>&1 &
    spinner $! "apt update"

    { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_REQ 2>&1; } \
        >> "$APT_LOG" 2>&1 &
    spinner $! "apt install (required)"
    wait $! || { cat "$APT_LOG" >&2; die "apt install ล้มเหลว"; }

    { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPT 2>&1; } \
        >> "$APT_LOG" 2>&1 || warn "Optional packages ไม่ครบ ($APT_OPT)"
    rm -f "$APT_LOG"

    for bin in nft dnsmasq sqlite3 tc; do
        command -v "$bin" &>/dev/null || die "ไม่พบ '$bin' หลัง install"
    done
else
    info "[DRY] apt-get install $APT_REQ $APT_OPT"
fi
ok "Packages ready"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — HOSTNAME
# ══════════════════════════════════════════════════════════════════════════════
step "Fix hostname in /etc/hosts"
HOSTNAME_NOW=$(hostname)
if ! grep -qF "$HOSTNAME_NOW" /etc/hosts 2>/dev/null; then
    run bash -c "echo '127.0.1.1 $HOSTNAME_NOW' >> /etc/hosts"
    ok "Added 127.0.1.1 $HOSTNAME_NOW"
else
    ok "Hostname already present — skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — SYSCTL: LATENCY-FIRST
# ──────────────────────────────────────────────────────────────────────────────
# หลักการ:
#   • Buffer เล็ก → queue สั้น → ping ไม่บวม
#   • ACK เร็ว   → BBR probe ถี่ → RTT ต่ำ
#   • Keepalive สั้น → detect link drop เร็ว (สำคัญสำหรับ VLESS long-conn)
#   • Retransmit เร็ว → ไม่รอนานเมื่อ 4G packet drop
# ══════════════════════════════════════════════════════════════════════════════
step "sysctl — latency-first (overwrite)"

SYSCTL_FILE="/etc/sysctl.d/99-ais-128k.conf"

run bash -c "cat > '$SYSCTL_FILE'" << EOF
# ╔══════════════════════════════════════════════════════════════╗
#  AIS 128kbps VPS · Latency-First · v3.0
#  Generated : $(date '+%Y-%m-%d %H:%M:%S')
#  BDP       : ${CLIENT_BW_KBIT}kbps × ${RTT_MS}ms = $(( CLIENT_BW_KBIT * 1000 / 8 * RTT_MS / 1000 )) bytes/conn
#  Stack     : ${CC_MODE} + ${QDISC_MODE}
# ╚══════════════════════════════════════════════════════════════╝

# ── Congestion Control ────────────────────────────────────────
net.ipv4.tcp_congestion_control = ${CC_MODE}
net.core.default_qdisc          = ${QDISC_MODE}

# ── TCP Buffers (latency-first: cap ที่ 4MB รองรับหลาย session) ──
# ไม่ตั้งใหญ่เกิน → ป้องกัน bufferbloat ฝั่ง VPS egress
net.core.rmem_max               = ${TCP_BUF_MAX}
net.core.wmem_max               = ${TCP_BUF_MAX}
net.core.rmem_default           = 131072
net.core.wmem_default           = 131072
net.ipv4.tcp_rmem               = 4096 87380 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem               = 4096 16384 ${TCP_BUF_MAX}

# ปิด auto-scale buffer ใหญ่เกิน (สำคัญ: ป้องกัน bloat)
net.ipv4.tcp_moderate_rcvbuf    = 0

# ── ACK & Delay (ยิ่ง ACK เร็ว RTT ยิ่งต่ำ) ──────────────────
net.ipv4.tcp_no_delay_ack        = 1
net.ipv4.tcp_thin_linear_timeouts = 1

# ── Keepalive — detect VLESS long-conn drop เร็ว ─────────────
net.ipv4.tcp_keepalive_time     = 30
net.ipv4.tcp_keepalive_intvl    = 5
net.ipv4.tcp_keepalive_probes   = 3

# ── Retransmit เร็ว (4G packet loss ไม่รอนาน) ───────────────
net.ipv4.tcp_retries2           = 5
net.ipv4.tcp_syn_retries        = 3
net.ipv4.tcp_synack_retries     = 3

# ── Fast Recovery ─────────────────────────────────────────────
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_dsack              = 1
net.ipv4.tcp_recovery           = 1

# ── TIME_WAIT (VLESS สร้าง/ทำลาย conn เยอะ) ─────────────────
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_max_tw_buckets     = 32768

# ── Backlog (1 vCPU — ไม่ต้องใหญ่มาก) ──────────────────────
# netdev_max_backlog เล็ก = queue สั้น = ping ต่ำ
net.core.somaxconn              = 4096
net.ipv4.tcp_max_syn_backlog    = 4096
net.core.netdev_max_backlog     = 2048

# ── IP Forward (VPS relay) ────────────────────────────────────
net.ipv4.ip_forward             = 1
net.ipv6.conf.all.forwarding    = 1
net.ipv4.conf.all.rp_filter     = 1
net.ipv4.conf.default.rp_filter = 1

# ── Memory — RAM 1 GB ─────────────────────────────────────────
net.ipv4.tcp_mem                = 65536 131072 196608
vm.swappiness                   = 10
vm.dirty_ratio                  = 15
vm.dirty_background_ratio       = 5

# ── Security ─────────────────────────────────────────────────
net.ipv4.tcp_syncookies                = 1
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.icmp_echo_ignore_broadcasts   = 1
EOF

run sysctl --system -q 2>/dev/null || true
ok "sysctl applied → ${CC_MODE} + ${QDISC_MODE}"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — QDISC: CAKE egress (VPS→client)
# ──────────────────────────────────────────────────────────────────────────────
# ทำไมไม่ set bandwidth:
#   VPS egress ≥2Gbps ไม่ใช่ bottleneck → ไม่ต้อง shape speed
#   CAKE ทำหน้าที่แค่ควบคุม latency / fairness
#   bottleneck จริงอยู่ที่ AIS 128kbps ฝั่ง client (CAKE ฝั่งนั้นทำไม่ได้จาก VPS)
# ══════════════════════════════════════════════════════════════════════════════
step "tc qdisc — ${QDISC_MODE} egress (VPS→client)"

if "$DRY_RUN"; then
    info "[DRY] tc qdisc replace dev $IFACE root $QDISC_MODE ..."
else
    tc qdisc del dev "$IFACE" root 2>/dev/null || true

    if [[ "$QDISC_MODE" == "cake" ]]; then
        tc qdisc add dev "$IFACE" root cake  \
            rtt "${RTT_MS}ms"                \
            besteffort                       \
            nat                              \
            wash                             \
            no-ack-filter
        info "CAKE: rtt=${RTT_MS}ms · besteffort · nat · wash · no-ack-filter"
    else
        # fq_codel fallback
        tc qdisc add dev "$IFACE" root fq_codel \
            limit 1000                           \
            target "${CAKE_TARGET_MS}ms"         \
            interval "${CAKE_INTERVAL_MS}ms"     \
            quantum 1514
        info "fq_codel: target=${CAKE_TARGET_MS}ms · interval=${CAKE_INTERVAL_MS}ms"
    fi

    tc qdisc show dev "$IFACE" | grep -E "cake|fq_codel" &>/dev/null \
        && ok "qdisc verified on $IFACE" \
        || warn "ตรวจ qdisc ด้วย: tc qdisc show dev $IFACE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — ETHTOOL: ลด NIC interrupt coalescing
# ══════════════════════════════════════════════════════════════════════════════
step "ethtool — reduce interrupt coalescing delay"

if ! "$DRY_RUN"; then
    # rx-usecs/tx-usecs ต่ำ = interrupt เร็ว = latency ต่ำ
    # Virtual NIC บางตัวไม่รองรับ — warn แล้วผ่านไป
    ethtool -C "$IFACE" rx-usecs 50 tx-usecs 50 2>/dev/null \
        && info "coalesce: rx-usecs=50 tx-usecs=50 ✓" \
        || info "coalesce: virtual NIC ไม่รองรับ — ข้ามได้ (ไม่กระทบ)"
    ok "ethtool done"
else
    info "[DRY] ethtool -C $IFACE rx-usecs 50 tx-usecs 50"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — DNSMASQ: local caching (ลด DNS lookup latency)
# ══════════════════════════════════════════════════════════════════════════════
step "dnsmasq — local DNS cache"

run bash -c "cat > /etc/dnsmasq.d/ais-vps.conf" << 'DNSEOF'
# AIS VPS · dnsmasq latency config
# upstream resolvers — เร็วในไทย
server=1.1.1.1
server=8.8.8.8
server=202.44.204.1
server=202.44.204.2

cache-size=2000
min-cache-ttl=60
neg-ttl=60
dns-forward-max=300
no-resolv
no-poll
log-queries=no
quiet-dhcp
DNSEOF

if ! "$DRY_RUN"; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    [[ "$RESOLVER_MODE" == "symlink" ]] && rm -f /etc/resolv.conf
    printf 'nameserver 127.0.0.1\nnameserver 1.1.1.1\n' > /etc/resolv.conf

    systemctl enable dnsmasq 2>/dev/null || true
    systemctl restart dnsmasq 2>/dev/null \
        || warn "dnsmasq restart ล้มเหลว — ตรวจ: journalctl -u dnsmasq -n 20"

    sleep 0.5
    if dig +short +time=2 @127.0.0.1 google.com &>/dev/null; then
        ok "dnsmasq OK — DNS cache พร้อม (127.0.0.1)"
    else
        warn "dnsmasq ตอบช้า — ตรวจ: systemctl status dnsmasq"
    fi
else
    info "[DRY] dnsmasq config → resolver 127.0.0.1"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — NFTABLES: production firewall
# ports: 443 (VLESS Reality) · 2053 (3x-ui panel) · SSH
# ══════════════════════════════════════════════════════════════════════════════
step "nftables — firewall (443 · 2053 · SSH :${SSH_PORT})"

if $NFT_SAFE; then
    warn "NFT_SAFE: เพิ่ม rule แบบ incremental (ไม่ flush)"
    run nft add rule inet filter input tcp dport 443  accept 2>/dev/null || true
    run nft add rule inet filter input tcp dport 2053 accept 2>/dev/null || true
    ok "nftables rules added (incremental)"
else
    run bash -c "cat > /etc/nftables.conf" << NFTEOF
#!/usr/sbin/nft -f
# AIS VPS · nftables · v3.0 · $(date '+%Y-%m-%d')
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop

        # ICMP (rate-limited)
        ip  protocol icmp   icmp  type echo-request limit rate 10/second accept
        ip  protocol icmp   accept
        ip6 nexthdr  icmpv6 accept

        # SSH — rate-limit ป้องกัน brute-force
        tcp dport ${SSH_PORT} ct state new limit rate 10/minute accept
        tcp dport ${SSH_PORT} ct state new drop

        # VLESS Reality — port 443 TCP
        tcp dport 443  accept

        # 3x-ui panel — port 2053
        # แนะนำ: เพิ่ม  ip saddr <trusted_ip>  ถ้าต้องการ restrict
        tcp dport 2053 accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
        ct state invalid drop
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oif "${IFACE}" masquerade
    }
}
NFTEOF

    run systemctl enable nftables 2>/dev/null || true
    if ! "$DRY_RUN"; then
        nft -f /etc/nftables.conf 2>&1 \
            || warn "nftables load ผิดพลาด — ตรวจ: nft -c -f /etc/nftables.conf"
        systemctl restart nftables 2>/dev/null || true
    fi
    ok "nftables full ruleset loaded"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — 3X-UI PANEL: collect settings
# ══════════════════════════════════════════════════════════════════════════════
phase "3X-UI PANEL"
step "กรอกค่า panel (ก่อน installer รัน)"

XUI_PORT=2053; XUI_USER="admin"; XUI_PASS=""; XUI_DOMAIN=""; XUI_SSL_MODE="ip"

if ! "$DRY_RUN"; then
    echo ""
    _rule "─" "$BCYN"
    printf "  ${BCYN}${BOLD}ตั้งค่า 3X-UI Panel${RST}\n"
    printf "  ${DIM}กรอกให้ตรงกับที่จะกรอกใน installer${RST}\n"
    _rule "─" "$BCYN"
    echo ""

    printf "  ${BWHT}Domain${RST}  ${DIM}(เช่น vps.example.com — Enter ถ้าใช้ IP):${RST}\n  › "
    read -r XUI_DOMAIN

    while true; do
        printf "  ${BWHT}Panel port${RST}  ${DIM}[default 2053]:${RST}  "
        read -r _p; XUI_PORT=${_p:-2053}
        (( XUI_PORT >= 1 && XUI_PORT <= 65535 )) && break
        printf "  ${BRED}port ต้องเป็น 1-65535${RST}\n"
    done

    printf "  ${BWHT}Username${RST}  ${DIM}[default admin]:${RST}  "
    read -r _u; XUI_USER=${_u:-admin}

    while true; do
        printf "  ${BWHT}Password${RST}  ${DIM}[min 8 ตัว]:${RST}  "
        read -rs XUI_PASS; echo ""
        (( ${#XUI_PASS} >= 8 )) && break
        printf "  ${BRED}password ต้องมีอย่างน้อย 8 ตัวอักษร${RST}\n"
    done

    echo ""
    _rule "─" "$DIM"
    printf "  ${DIM}Domain  :${RST}  ${BWHT}%s${RST}\n"  "${XUI_DOMAIN:-<ใช้ IP>}"
    printf "  ${DIM}Port    :${RST}  ${BWHT}%s${RST}\n"  "$XUI_PORT"
    printf "  ${DIM}Username:${RST}  ${BWHT}%s${RST}\n"  "$XUI_USER"
    printf "  ${DIM}Password:${RST}  ${BWHT}%s${RST}\n"  "$(printf '%*s' ${#XUI_PASS} '' | tr ' ' '●')"
    _rule "─" "$DIM"
    echo ""
    printf "  ${BYLW}ยืนยัน? [Y/n]:${RST}  "; read -r _c
    [[ "${_c,,}" == "n" ]] && { warn "ยกเลิก — รันใหม่"; exit 1; }

    # ── Let's Encrypt rate-limit check ──────────────────────────
    if [[ -n "${XUI_DOMAIN:-}" ]]; then
        info "ตรวจ LE rate-limit สำหรับ ${XUI_DOMAIN} ..."
        RL=$(curl -s --max-time 8 \
            "https://crt.sh/?q=${XUI_DOMAIN}&output=json" 2>/dev/null \
            | python3 -c "
import sys,json,datetime
try:
    data=json.load(sys.stdin)
    cut=datetime.datetime.utcnow()-datetime.timedelta(days=7)
    n=[d for d in data
       if datetime.datetime.strptime(d['entry_timestamp'][:19],'%Y-%m-%dT%H:%M:%S')>cut]
    print(len(n))
except: print(0)
" 2>/dev/null || echo 0)
        RL=${RL:-0}
        if (( RL >= 5 )); then
            printf "\n  ${BRED}✖  RATE LIMIT: %s ใบใน 7 วัน (limit=5)${RST}\n\n" "$RL"
            printf "  ${BWHT}1)${RST} ใช้ IP cert (6 วัน, auto-renew)\n"
            printf "  ${BWHT}2)${RST} ข้าม SSL — ตั้งใน panel ทีหลัง\n"
            printf "  ${BWHT}3)${RST} รันต่อ — installer จัดการเอง (อาจ fail)\n\n"
            printf "  เลือก [1/2/3]:  "; read -r _rl
            case "${_rl:-1}" in
                1) XUI_SSL_MODE="ip"     ; warn "→ installer: option 2 (IP Address)" ;;
                2) XUI_SSL_MODE="skip"   ; warn "→ installer: option 3 (Custom/skip)" ;;
                *) XUI_SSL_MODE="domain" ; warn "→ installer: option 1 (Domain)" ;;
            esac
        else
            ok "LE rate-limit OK (${RL}/5)"
            XUI_SSL_MODE="domain"
        fi
    else
        XUI_SSL_MODE="ip"
        info "ไม่มี domain → IP cert"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — INSTALL 3X-UI
# ══════════════════════════════════════════════════════════════════════════════
step "Install / update 3x-ui"

if "$DRY_RUN"; then
    info "[DRY] bash <(curl -Ls .../install.sh)"
else
    XUI_SCRIPT=$(mktemp /tmp/xui-XXXXXX.sh)
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
        -o "$XUI_SCRIPT" 2>/dev/null \
        || die "ดาวน์โหลด installer ล้มเหลว — ตรวจ internet"
    chmod +x "$XUI_SCRIPT"

    echo ""
    _rule "─" "$BYLW"
    printf "  ${BYLW}${BOLD}⚠  installer กำลังจะรัน — กรอกค่าเหล่านี้เมื่อถูกถาม:${RST}\n\n"
    printf "  ${DIM}Domain  :${RST}  ${BWHT}%s${RST}\n"   "${XUI_DOMAIN:-<กด Enter ผ่าน>}"
    printf "  ${DIM}Port    :${RST}  ${BWHT}%s${RST}\n"   "$XUI_PORT"
    printf "  ${DIM}Username:${RST}  ${BWHT}%s${RST}\n"   "$XUI_USER"
    printf "  ${DIM}Password:${RST}  ${BWHT}%s${RST}\n"   "$(printf '%*s' ${#XUI_PASS} '' | tr ' ' '●')"
    printf "  ${DIM}SSL mode:${RST}  ${BWHT}%s${RST}\n\n" "$XUI_SSL_MODE"
    _rule "─" "$BYLW"
    echo ""
    printf "  ${BCYN}กด Enter เพื่อเริ่ม installer...${RST}  "; read -r _

    bash "$XUI_SCRIPT"
    rm -f "$XUI_SCRIPT"
fi
ok "3x-ui installed"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — X-UI SYSTEMD OVERRIDE
# ══════════════════════════════════════════════════════════════════════════════
step "x-ui systemd — latency override"

XUI_DROP="/etc/systemd/system/x-ui.service.d"
run mkdir -p "$XUI_DROP"
run bash -c "cat > '$XUI_DROP/latency.conf'" << 'XUIEOF'
[Service]
# ป้องกัน OOM (1GB RAM)
MemoryMax=512M
MemorySwapMax=128M
# CPU priority สูงกว่า background
Nice=-5
# restart เร็วถ้า crash
Restart=always
RestartSec=3s
XUIEOF

run systemctl daemon-reload
! "$DRY_RUN" && { systemctl restart x-ui 2>/dev/null \
    || warn "x-ui restart ล้มเหลว — ตรวจ: systemctl status x-ui"; }
ok "x-ui override applied (Nice=-5 · MemoryMax=512M)"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — ZRAM (RAM headroom สำหรับ 1GB VPS)
# ══════════════════════════════════════════════════════════════════════════════
step "ZRAM swap — 256 MB compressed"

if $CAP_ZRAM && ! "$DRY_RUN"; then
    swapoff -a 2>/dev/null || true
    modprobe zram 2>/dev/null || true
    ZRAM_DEV=$(ls /dev/zram* 2>/dev/null | head -1)
    if [[ -n "${ZRAM_DEV:-}" ]]; then
        local_name="${ZRAM_DEV##*/}"
        echo zstd > "/sys/block/${local_name}/comp_algorithm" 2>/dev/null \
            || echo lz4 > "/sys/block/${local_name}/comp_algorithm" 2>/dev/null || true
        echo $(( 256 * 1024 * 1024 )) > "/sys/block/${local_name}/disksize"
        mkswap "$ZRAM_DEV" &>/dev/null
        swapon -p 10 "$ZRAM_DEV"

        # udev rule เพื่อ persist
        cat > /etc/udev/rules.d/99-zram.rules << ZRAMEOF
KERNEL=="zram0", ATTR{comp_algorithm}="zstd", ATTR{disksize}="268435456", \
    RUN="/sbin/mkswap /dev/zram0", RUN+="/sbin/swapon -p 10 /dev/zram0"
ZRAMEOF
        ok "ZRAM: 256MB on $ZRAM_DEV (zstd/lz4)"
    else
        warn "ZRAM device ไม่พบ — ข้าม"
    fi
elif "$DRY_RUN"; then
    info "[DRY] ZRAM 256MB swap"
else
    warn "ZRAM ไม่รองรับ — ข้าม"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — PERSIST QDISC ON BOOT (systemd)
# ══════════════════════════════════════════════════════════════════════════════
step "ais-net.service — persist qdisc on reboot"

AIS_SVC="/etc/systemd/system/ais-net.service"

{
cat << SVCEOF
[Unit]
Description=AIS VPS Network Latency Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/sysctl --system -q
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${IFACE} root 2>/dev/null || true'
SVCEOF

if [[ "$QDISC_MODE" == "cake" ]]; then
    echo "ExecStart=/sbin/tc qdisc add dev ${IFACE} root cake rtt ${RTT_MS}ms besteffort nat wash no-ack-filter"
else
    echo "ExecStart=/sbin/tc qdisc add dev ${IFACE} root fq_codel limit 1000 target ${CAKE_TARGET_MS}ms interval ${CAKE_INTERVAL_MS}ms quantum 1514"
fi

cat << 'SVCEOF2'

[Install]
WantedBy=multi-user.target
SVCEOF2
} | run bash -c "cat > '$AIS_SVC'"

run systemctl daemon-reload
run systemctl enable ais-net.service 2>/dev/null || true
ok "ais-net.service enabled → qdisc persists on reboot"

# ══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
_rule "═" "$BGRN"
printf "${BGRN}${BOLD}  ✔  TUNING COMPLETE${RST}\n"
_rule "═" "$BGRN"
echo ""
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "Congestion control"    "$CC_MODE"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "Queue discipline"      "$QDISC_MODE (egress)"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s ms${RST}\n" "RTT reference"       "$RTT_MS"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "TCP buffer max"        "4 MB (latency-first)"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "Firewall"             "nftables (443+2053+SSH)"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "DNS cache"            "dnsmasq 127.0.0.1"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "ZRAM swap"            "256 MB (zstd)"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "x-ui panel"           ":${XUI_PORT} · ${XUI_USER}"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "Boot service"         "ais-net.service ✓"
printf "  ${DIM}%-30s${RST}  ${BWHT}%s${RST}\n" "Log"                  "$LOG_FILE"
echo ""
printf "  ${BYLW}ขั้นตอนถัดไป:${RST}\n"
printf "  ${DIM}1.${RST}  Panel  → http://${PUBLIC_IP:-<VPS-IP>}:2053\n"
printf "  ${DIM}2.${RST}  Inbound → VLESS · Reality · port 443 · SNI: th.speedtest.net\n"
printf "  ${DIM}3.${RST}  ตรวจ qdisc  : ${BCYN}tc -s qdisc show dev $IFACE${RST}\n"
printf "  ${DIM}4.${RST}  ตรวจ sysctl : ${BCYN}sysctl net.ipv4.tcp_congestion_control${RST}\n"
printf "  ${DIM}5.${RST}  Rollback    : ${BCYN}sudo bash $0 --rollback${RST}\n"
echo ""
_rule "─" "$DIM"
printf "  ${DIM}แนะนำ reboot 1 ครั้งเพื่อให้ทุก setting มีผลเต็มที่${RST}\n"
echo ""
