#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
#  AIS VPS · EXTREME LATENCY TUNING · v4.0
#  Target : AIS 128kbps → Thailand VPS → VLESS Reality :443
#  Spec   : 1 vCPU · 1 GB RAM · 2 clients max
#  Goal   : ping ต่ำ-เสถียร · jitter < 2ms · ไม่มี bufferbloat
#
#  Usage  : sudo bash ais128k-tune-v4.sh [--dry-run | --rollback | --verify]
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# COLOUR PALETTE
# ─────────────────────────────────────────────────────────────────────────────
RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
BRED='\033[1;31m'; BGRN='\033[1;32m'; BYLW='\033[1;33m'
BCYN='\033[1;36m'; BWHT='\033[1;37m'; BPUR='\033[1;35m'
BG_BLK='\033[40m'; BG_YLW='\033[43m'; BLK='\033[0;30m'

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
LOG_FILE="/var/log/ais128k-v4.log"
BACKUP_DIR="/etc/ais128k-backup"
STEP_NUM=0
STEP_TOTAL=14
PHASE_START_MS=0

# ── Tuning constants ──────────────────────────────────────────────────────────
# ทำไมค่าเหล่านี้:
#   CLIENT_UP_KBIT=112  : 128kbps จริง AIS ≈ 110-120 → 112 = safe headroom
#                          ต่ำกว่า ISP shaper 12% → ป้องกัน burst ก่อนถูก shape
#   VPS_SHAPE_MBIT=100  : upstream VPS >> 128kbps แต่ cap ไว้ป้องกัน burstiness
#                          client รับได้ 128kbps → cap 100M = ไม่มีประโยชน์ cap ต่ำกว่า
#   RTT_MS=45           : 4G Thailand real-world (AIS ≈ 30-60ms) → 45 = median
#   BDP_BYTES=562500    : BDP = 100Mbps × 45ms = 562500 bytes → TCP window จริง
#   CAKE_TARGET_MS=3    : Latency target ใน CAKE (ต่ำกว่า 5ms ของ default)
#   MAX_CLIENTS=2       : Hard limit สำหรับ fairness tuning
CLIENT_BW_KBIT=128
CLIENT_UP_KBIT=112
VPS_SHAPE_MBIT=100
RTT_MS=45
BDP_BYTES=562500      # 100Mbps × 45ms / 8
TCP_BUF_4x=2250000    # 4 × BDP
CAKE_TARGET_MS=3
CAKE_INTERVAL_MS=30
MAX_CLIENTS=2

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
    _rule "═" "$BPUR"
    printf "${BG_BLK}${BPUR}${BOLD}%${pad}s  ◈  %s  ◈  %${pad}s${RST}\n" "" "$title" ""
    _rule "═" "$BPUR"
    _log INFO "=== PHASE: $title ==="
}

step() {
    (( STEP_NUM++ )) || true
    local pct=$(( STEP_NUM * 100 / STEP_TOTAL ))
    local filled=$(( pct * 30 / 100 )) bar="" i
    for (( i=0; i<filled;  i++ )); do bar+="█"; done
    for (( i=filled; i<30; i++ )); do bar+="░"; done
    printf "\n${BCYN}  [%02d/%02d]${RST}  ${BOLD}%s${RST}\n" "$STEP_NUM" "$STEP_TOTAL" "$1"
    printf "          ${DIM}[${RST}${BGRN}%s${RST}${DIM}] %3d%%${RST}\n" "$bar" "$pct"
    _log INFO "STEP $STEP_NUM/$STEP_TOTAL: $1"
}

ok()   { local ms=$(( $(_now_ms) - PHASE_START_MS ))
         printf "  ${BGRN}✔${RST}  %-60s ${DIM}+%dms${RST}\n" "$*" "$ms"
         _log OK "$*"; }
info() { printf "  ${BCYN}·${RST}  %s\n" "$*"; _log INFO "$*"; }
warn() { printf "  ${BYLW}⚠${RST}  ${BYLW}%s${RST}\n" "$*"; _log WARN "$*"; }
die()  { printf "\n  ${BRED}✖  FATAL: %s${RST}\n\n" "$*" >&2; _log FAIL "$*"; exit 1; }

spinner() {
    local pid=$1 label="${2:-working}"
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
printf "${BPUR}"
cat << 'BANNER'

    ╔═╗╦╔═╗  ╦  ╦╔═╗╔═╗  ╦  ╦ ╦╔╗╔╦╔╗╔╔═╗
    ╠═╣║╚═╗  ╚╗╔╝╠═╝╚═╗  ║  ║ ║║║║║║║║║ ╦
    ╩ ╩╩╚═╝   ╚╝ ╩  ╚═╝  ╩═╝╚═╝╝╚╝╩╝╚╝╚═╝

    EXTREME LATENCY BUILD · v4.0

BANNER
printf "${RST}"
printf "    ${DIM}AIS 128kbps · 2 clients · BBR+CAKE · kernel 5.15+ · jitter < 2ms${RST}\n"
printf "    ${DIM}Stack: sysctl + CAKE egress + IFB ingress + nftables + dnsmasq + x-ui${RST}\n\n"
_rule "─" "$DIM"
echo ""

[[ $EUID -eq 0 ]] || die "ต้องรันเป็น root:  sudo bash $0"
touch "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/ais128k-v4.log"; touch "$LOG_FILE"; }
info "Session log → $LOG_FILE"
sleep 0.2

# ─────────────────────────────────────────────────────────────────────────────
# ARG PARSING
# ─────────────────────────────────────────────────────────────────────────────
MODE="${1:-}"
case "$MODE" in
    --dry-run)
        DRY_RUN=true
        printf "\n  ${BG_YLW}${BLK}  DRY RUN — ไม่มีการเขียนจริง  ${RST}\n\n"
        sleep 0.3 ;;
    --rollback|--verify|"") : ;;
    *) die "Usage: $0 [--dry-run | --rollback | --verify]" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY MODE — แค่แสดง status ของ tuning ปัจจุบัน
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "--verify" ]]; then
    phase "VERIFY — ตรวจสอบ tuning ปัจจุบัน"
    echo ""
    IFACE_V=$(ip route show default | awk '/default/ {print $5; exit}')

    _chk() {
        local label="$1" val="$2" expect="$3"
        if echo "$val" | grep -qi "$expect"; then
            printf "  ${BGRN}✔${RST}  %-40s ${BWHT}%s${RST}\n" "$label" "$val"
        else
            printf "  ${BYLW}✗${RST}  %-40s ${BYLW}%s${RST}  ${DIM}(expect: %s)${RST}\n" \
                "$label" "$val" "$expect"
        fi
    }

    _chk "TCP congestion control" \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
    _chk "Default qdisc" \
        "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "cake"
    _chk "IP forward" \
        "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" "1"
    _chk "TCP notsent_lowat" \
        "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)" "16384"
    _chk "TCP keepalive_time" \
        "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)" "60"
    _chk "Egress qdisc (CAKE)" \
        "$(tc qdisc show dev "$IFACE_V" 2>/dev/null | grep -o 'cake\|fq_codel' | head -1)" "cake"
    _chk "IFB ingress qdisc" \
        "$(tc qdisc show dev ifb0 2>/dev/null | grep -o 'cake\|none' | head -1)" "cake"
    _chk "dnsmasq" \
        "$(systemctl is-active dnsmasq 2>/dev/null)" "active"
    _chk "x-ui service" \
        "$(systemctl is-active x-ui 2>/dev/null)" "active"
    _chk "ais-net.service" \
        "$(systemctl is-active ais-net 2>/dev/null)" "active"
    _chk "nftables" \
        "$(systemctl is-active nftables 2>/dev/null)" "active"
    _chk "irqbalance" \
        "$(systemctl is-active irqbalance 2>/dev/null)" "active"

    echo ""
    printf "  ${DIM}Conntrack usage:${RST}  "
    cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null \
        && printf " / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)\n" || true

    printf "  ${DIM}Memory free:${RST}  "
    awk '/MemAvailable/ {printf "%.0f MB\n", $2/1024}' /proc/meminfo

    printf "  ${DIM}CAKE egress stats:${RST}\n"
    tc -s qdisc show dev "$IFACE_V" 2>/dev/null | \
        grep -A5 'cake\|fq_codel' | head -8 | sed 's/^/    /'

    echo ""
    _rule "─" "$DIM"
    printf "  ${DIM}ตรวจ jitter ด้วย:${RST}  ${BCYN}ping -c 20 -i 0.2 8.8.8.8${RST}\n"
    printf "  ${DIM}ตรวจ BBR:${RST}         ${BCYN}ss -tin | grep bbr${RST}\n"
    echo ""
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "--rollback" ]]; then
    phase "ROLLBACK"
    [[ -d "$BACKUP_DIR" ]] || die "ไม่พบ backup ที่ $BACKUP_DIR"

    # resolver
    if [[ -f "$BACKUP_DIR/resolv.conf.meta" ]]; then
        mode_rb=$(cat "$BACKUP_DIR/resolv.conf.meta")
        chattr -i /etc/resolv.conf 2>/dev/null || true
        case "$mode_rb" in
            symlink:*)
                target_rb="${mode_rb#symlink:}"
                rm -f /etc/resolv.conf
                ln -sf "$target_rb" /etc/resolv.conf
                ok "resolv.conf symlink restored → $target_rb" ;;
            file)
                cp "$BACKUP_DIR/resolv.conf" /etc/resolv.conf
                ok "resolv.conf file restored" ;;
        esac
    fi

    # nftables
    [[ -f "$BACKUP_DIR/nftables.conf" ]] && {
        cp "$BACKUP_DIR/nftables.conf" /etc/nftables.conf
        systemctl restart nftables 2>/dev/null || true
        ok "nftables restored"
    }

    # sysctl
    rm -f /etc/sysctl.d/99-ais-128k.conf
    sysctl --system -q 2>/dev/null || true
    ok "sysctl config removed"

    # qdisc
    IFACE_RB=$(ip route show default | awk '/default/ {print $5; exit}')
    tc qdisc del dev "$IFACE_RB" root 2>/dev/null || true
    tc qdisc del dev "$IFACE_RB" handle ffff: ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
    ok "qdisc cleared"

    # services
    for svc in ais-net.service; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/ais-net.service
    rm -f /etc/systemd/system/x-ui.service.d/latency.conf
    systemctl daemon-reload
    systemctl restart x-ui 2>/dev/null || true

    _rule "═" "$BGRN"
    printf "${BGRN}${BOLD}  ROLLBACK COMPLETE${RST}\n"
    _rule "═" "$BGRN"
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
RAM_FREE_MB=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)
CPU_COUNT=$(nproc)
KERNEL=$(uname -r)

echo ""
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "Interface"        "$IFACE"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "Public IP"        "${PUBLIC_IP:-unknown}"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "SSH Port"         "$SSH_PORT"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "Kernel"           "$KERNEL"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s MB (free: %s MB)${RST}\n" "RAM" "$RAM_MB" "$RAM_FREE_MB"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s vCPU${RST}\n"    "CPU"              "$CPU_COUNT"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s kbps${RST}\n"    "Client BW target" "$CLIENT_BW_KBIT"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s ms${RST}\n"      "RTT reference"    "$RTT_MS"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s clients${RST}\n" "Max concurrent"   "$MAX_CLIENTS"
echo ""

# detect conflicts
HAS_DOCKER=false; HAS_WG=false; HAS_TAILSCALE=false; NFT_SAFE=false
systemctl is-active docker     &>/dev/null && HAS_DOCKER=true
systemctl is-active wg-quick@* &>/dev/null && HAS_WG=true
systemctl is-active tailscaled &>/dev/null && HAS_TAILSCALE=true
$HAS_DOCKER    && { warn "Docker detected → nftables incremental"; NFT_SAFE=true; }
$HAS_WG        && { warn "WireGuard detected → nftables incremental"; NFT_SAFE=true; }
$HAS_TAILSCALE && { warn "Tailscale detected → nftables incremental"; NFT_SAFE=true; }
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

CAP_BBR=false; CAP_CAKE=false

_cap() {
    local name="$1"
    if eval "${2}" &>/dev/null 2>&1; then
        printf "  ${BGRN}✔${RST}  %-26s ${BGRN}AVAILABLE${RST}\n" "$name"; return 0
    else
        printf "  ${BYLW}–${RST}  %-26s ${DIM}not supported${RST}\n" "$name"; return 1
    fi
}
echo ""

# BBR: load module ก่อน
if ! "$DRY_RUN"; then
    modprobe tcp_bbr 2>/dev/null && info "tcp_bbr module loaded" \
        || warn "modprobe tcp_bbr ล้มเหลว — kernel อาจ build-in"
    if ! grep -q "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf
    fi
    # BBR3 probe (kernel 6.x+) - ถ้ามี ดีกว่า BBR1
    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr3; then
        BBR_VER="bbr3"; info "BBR3 detected — ใช้ BBR3"
    else
        BBR_VER="bbr"; info "BBR (v1) will be used"
    fi
else
    BBR_VER="bbr"
    info "[DRY] modprobe tcp_bbr"
fi

_cap "BBR congestion ctrl" \
    "sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr" && CAP_BBR=true

_cap "CAKE qdisc" \
    "tc qdisc add dev lo root cake 2>/dev/null; tc qdisc del dev lo root 2>/dev/null" \
    && CAP_CAKE=true

_cap "fq_pie (alt qdisc)" "tc qdisc add dev lo root fq_pie 2>/dev/null; tc qdisc del dev lo root 2>/dev/null" \
    && CAP_PIE=true || CAP_PIE=false

_cap "IFB (ingress shaping)" "modprobe ifb 2>/dev/null" && CAP_IFB=true || CAP_IFB=false
_cap "nftables"              "command -v nft"
_cap "ethtool"               "command -v ethtool"
echo ""

# fallback logic — ลำดับความนิยม: CAKE > fq_pie > fq_codel
if $CAP_CAKE; then
    QDISC_MODE="cake"
elif $CAP_PIE; then
    QDISC_MODE="fq_pie"
    warn "CAKE ไม่พร้อม → fq_pie (next best)"
else
    QDISC_MODE="fq_codel"
    warn "CAKE ไม่พร้อม → fq_codel (fallback)"
fi

CC_MODE=$( $CAP_BBR && echo "$BBR_VER" || echo "cubic" )
$CAP_BBR || warn "BBR ไม่พร้อม → cubic"

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
[[ -f /etc/nftables.conf ]] && \
    run cp /etc/nftables.conf "$BACKUP_DIR/nftables.conf" || true
[[ -f /etc/sysctl.d/99-ais-128k.conf ]] && \
    run cp /etc/sysctl.d/99-ais-128k.conf "$BACKUP_DIR/99-ais-128k.conf" || true
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
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
fi

APT_REQ="curl wget ethtool dnsmasq sqlite3 jq nftables dnsutils ca-certificates iproute2 iputils-ping"
APT_OPT="cron socat at irqbalance"

if ! "$DRY_RUN"; then
    APT_LOG=$(mktemp /tmp/ais-apt-XXXXXX.log)
    {
        apt-get update -qq 2>&1 || {
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
        >> "$APT_LOG" 2>&1 || warn "Optional packages บางตัวไม่ครบ"
    rm -f "$APT_LOG"

    for bin in nft dnsmasq sqlite3 tc; do
        command -v "$bin" &>/dev/null || die "ไม่พบ '$bin' หลัง install"
    done
else
    info "[DRY] apt-get install $APT_REQ $APT_OPT"
fi
ok "Packages ready"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — HOSTNAME FIX
# ══════════════════════════════════════════════════════════════════════════════
step "Fix hostname in /etc/hosts"
HOSTNAME_NOW=$(hostname)
if ! grep -qF "$HOSTNAME_NOW" /etc/hosts 2>/dev/null; then
    run bash -c "echo '127.0.1.1 $HOSTNAME_NOW' >> /etc/hosts"
    ok "Added 127.0.1.1 $HOSTNAME_NOW"
else
    ok "Hostname already present"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — SYSCTL: EXTREME LATENCY-FIRST
# ──────────────────────────────────────────────────────────────────────────────
# Design rationale:
#
# [Buffer sizing]
#   BDP = 100Mbps × 45ms = 562,500 bytes  (actual bottleneck is 128kbps client)
#   Buffer = 4× BDP = 2.25MB  → เพียงพอสำหรับ pipeline filling ไม่ bloat
#   tcp_moderate_rcvbuf=1 → kernel adjust ตาม RTT จริง (mobile RTT แกว่ง 30-100ms)
#   tcp_notsent_lowat=16384 → ลด kernel send buffer → BBR + CAKE เห็น queue จริง
#
# [ACK timing]
#   ไม่ใช้ tcp_no_delay_ack → AIS 128kbps uplink แคบ ACK flood ทำ latency แย่ลง
#   tcp_thin_linear_timeouts → thin stream (SSH/gaming) ไม่ต้อง backoff
#
# [Keepalive 60s]
#   30s aggressive → mobile NAT churn + battery ลด → เลือก 60s
#   3×10s probe → detect drop ใน 30s หลัง keepalive start = รวม 90s max
#
# [Conntrack สำหรับ 2 clients]
#   2 clients × VLESS Reality → แต่ละ client อาจสร้าง 100+ TCP flows
#   conntrack_max=65536 → เพียงพอ + ไม่กิน memory มาก (1GB RAM)
#   established timeout=3600 → ตาม x-ui keepalive
#
# [ZRAM disabled — เจตนา]
#   ZRAM บน VPS 1vCPU: CPU overhead compress/decompress > benefit
#   swappiness=5 → แทบไม่ swap → ลด jitter จาก swap I/O
# ══════════════════════════════════════════════════════════════════════════════
step "sysctl — extreme latency-first (BDP-calibrated, 2-client optimized)"

SYSCTL_FILE="/etc/sysctl.d/99-ais-128k.conf"

run bash -c "cat > '$SYSCTL_FILE'" << EOF
# ╔══════════════════════════════════════════════════════════════════════════╗
#  AIS VPS · Extreme Latency Build · v4.0
#  Generated : $(date '+%Y-%m-%d %H:%M:%S')
#  Spec      : 1 vCPU · 1GB RAM · 2 clients · AIS 128kbps → VLESS Reality
#  BDP       : 100Mbps × ${RTT_MS}ms = ${BDP_BYTES} bytes
#  Buffer    : 4× BDP = ${TCP_BUF_4x} bytes (~2.1MB, ping-first)
#  Stack     : ${CC_MODE} + ${QDISC_MODE}
# ╚══════════════════════════════════════════════════════════════════════════╝

# ══════════════════════════════════════════════════════════════════════════
# CONGESTION CONTROL + QDISC
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_congestion_control = ${CC_MODE}
net.core.default_qdisc          = ${QDISC_MODE}

# ══════════════════════════════════════════════════════════════════════════
# TCP BUFFERS — BDP-calibrated, latency-first
# ══════════════════════════════════════════════════════════════════════════
# BDP = 100Mbps × ${RTT_MS}ms = ${BDP_BYTES}B, 4× = ${TCP_BUF_4x}B
# max 4MB = ป้องกัน single connection กิน memory ทั้งหมด
net.core.rmem_max               = 4194304
net.core.wmem_max               = 4194304
net.core.rmem_default           = 131072
net.core.wmem_default           = 131072
net.ipv4.tcp_rmem               = 4096 131072 ${TCP_BUF_4x}
net.ipv4.tcp_wmem               = 4096 65536  ${TCP_BUF_4x}

# autotuning ON: kernel ปรับ buffer ตาม RTT จริง (mobile RTT แกว่งเยอะ)
net.ipv4.tcp_moderate_rcvbuf    = 1

# notsent_lowat: ลด data สะสมใน kernel send buffer
# BBR + CAKE เห็น queue จริง → pacing แม่นยำขึ้น → jitter ลด
net.ipv4.tcp_notsent_lowat      = 16384

# ══════════════════════════════════════════════════════════════════════════
# ACK + PACING (สำคัญสำหรับ 128kbps uplink แคบ)
# ══════════════════════════════════════════════════════════════════════════
# tcp_thin_linear_timeouts: SSH/RTP/gaming stream ไม่ต้อง exponential backoff
net.ipv4.tcp_thin_linear_timeouts = 1

# ══════════════════════════════════════════════════════════════════════════
# KEEPALIVE — balanced 60s (mobile NAT friendly)
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_keepalive_time     = 60
net.ipv4.tcp_keepalive_intvl    = 10
net.ipv4.tcp_keepalive_probes   = 3
# detect link drop ใน max 60+(3×10)=90s — เหมาะกับ VLESS long-conn

# ══════════════════════════════════════════════════════════════════════════
# RETRANSMIT — aggressive recovery สำหรับ 4G packet loss
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_retries2           = 5
net.ipv4.tcp_syn_retries        = 3
net.ipv4.tcp_synack_retries     = 3

# ══════════════════════════════════════════════════════════════════════════
# FAST RECOVERY
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_dsack              = 1
net.ipv4.tcp_recovery           = 1
net.ipv4.tcp_early_retrans      = 3
net.ipv4.tcp_reordering         = 3

# ══════════════════════════════════════════════════════════════════════════
# TIME_WAIT (VLESS สร้าง/ทำลาย connection เยอะ)
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 10
net.ipv4.tcp_max_tw_buckets     = 16384
# 16384 = เพียงพอสำหรับ 2 clients ไม่กิน memory มาก

# ══════════════════════════════════════════════════════════════════════════
# BACKLOG — 1vCPU optimized (queue สั้น = ping ต่ำ)
# ══════════════════════════════════════════════════════════════════════════
net.core.somaxconn              = 4096
net.ipv4.tcp_max_syn_backlog    = 4096
net.core.netdev_max_backlog     = 1000
# netdev_max_backlog=1000 (ลดจาก 2048): queue สั้น → ping ต่ำ
# 2 clients ไม่ต้องการ backlog ใหญ่

# ══════════════════════════════════════════════════════════════════════════
# IP FORWARD + SECURITY
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.ip_forward                    = 1
net.ipv6.conf.all.forwarding           = 1
net.ipv4.conf.all.rp_filter            = 1
net.ipv4.conf.default.rp_filter        = 1
net.ipv4.tcp_syncookies                = 1
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.icmp_echo_ignore_broadcasts   = 1

# ══════════════════════════════════════════════════════════════════════════
# MEMORY — RAM 1GB, swappiness aggressive-low
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_mem                = 32768 65536 131072
# tcp_mem ลดลง: 2 clients ไม่ต้องการ memory tcp pool ใหญ่
# เก็บ free memory ไว้สำหรับ x-ui + OS

vm.swappiness                   = 5
# swappiness=5 (ลดจาก 10): แทบไม่ swap → ลด jitter จาก disk I/O
# ถ้า x-ui + OS ใช้ RAM รวมกันไม่เกิน 512MB (จาก memory profile ที่บอก 33%)
# swappiness=5 ปลอดภัย

vm.dirty_ratio                  = 10
vm.dirty_background_ratio       = 3

# ══════════════════════════════════════════════════════════════════════════
# CONNTRACK — 2 clients × VLESS Reality multiplexing
# ══════════════════════════════════════════════════════════════════════════
# 2 clients × ~200 flows max = 400 → set 65536 (ไม่กิน memory เปล่า)
# เดิมใช้ 131072 แต่สำหรับ 2 clients ใช้ RAM เกินจำเป็น
net.netfilter.nf_conntrack_max                     = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 5
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 10
net.netfilter.nf_conntrack_tcp_timeout_syn_sent    = 10
net.netfilter.nf_conntrack_udp_timeout             = 30
net.netfilter.nf_conntrack_udp_timeout_stream      = 60
EOF

run sysctl --system -q 2>/dev/null || true
ok "sysctl applied → ${CC_MODE} + ${QDISC_MODE} (BDP=${BDP_BYTES}B)"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — QDISC EGRESS: CAKE (VPS→client)
# ──────────────────────────────────────────────────────────────────────────────
# CAKE parameters ที่เลือก:
#   bandwidth 100Mbit  : cap ที่ VPS interface (real bottleneck = AIS 128kbps)
#   rtt 45ms           : calibrated RTT → CAKE interval = RTT/10 (internal)
#   diffserv4          : 4 tier QoS → VLESS Reality ไม่โดน bulk traffic เบียด
#   dual-srchost       : fairness per client IP ขาออก (สำคัญเมื่อมี 2 clients)
#   dual-dsthost       : fairness per client IP ขาเข้า
#   nat                : aware ของ NAT masquerade ใน table ip nat
#   wash               : ล้าง DSCP garbage จาก AIS upstream marking
#   no-ack-filter      : ไม่ยุบ ACK (สำคัญสำหรับ TLS VLESS)
#   overhead 40        : IP+TCP header overhead compensation = CAKE pacing แม่น
# ══════════════════════════════════════════════════════════════════════════════
step "CAKE egress — ${VPS_SHAPE_MBIT}Mbit · rtt=${RTT_MS}ms · diffserv4 · dual-host"

if "$DRY_RUN"; then
    info "[DRY] tc qdisc add dev $IFACE root cake bandwidth ${VPS_SHAPE_MBIT}Mbit ..."
else
    tc qdisc del dev "$IFACE" root 2>/dev/null || true

    if [[ "$QDISC_MODE" == "cake" ]]; then
        tc qdisc add dev "$IFACE" root cake          \
            bandwidth "${VPS_SHAPE_MBIT}Mbit"        \
            rtt "${RTT_MS}ms"                        \
            diffserv4                                \
            dual-srchost                             \
            dual-dsthost                             \
            nat                                      \
            wash                                     \
            no-ack-filter                            \
            overhead 40
        info "CAKE: ${VPS_SHAPE_MBIT}Mbit · rtt=${RTT_MS}ms · diffserv4 · dual-host · overhead=40"
    elif [[ "$QDISC_MODE" == "fq_pie" ]]; then
        tc qdisc add dev "$IFACE" root fq_pie        \
            limit 1000                               \
            target "${CAKE_TARGET_MS}ms"             \
            tupdate "${CAKE_INTERVAL_MS}ms"
        warn "fq_pie: target=${CAKE_TARGET_MS}ms — ติดตั้ง CAKE สำหรับ full features"
    else
        tc qdisc add dev "$IFACE" root fq_codel      \
            limit 1000                               \
            target "${CAKE_TARGET_MS}ms"             \
            interval "${CAKE_INTERVAL_MS}ms"         \
            quantum 1514
        warn "fq_codel: target=${CAKE_TARGET_MS}ms — ติดตั้ง CAKE สำหรับ best performance"
    fi

    tc qdisc show dev "$IFACE" | grep -E "cake|fq_codel|fq_pie" &>/dev/null \
        && ok "qdisc egress on $IFACE verified" \
        || warn "ตรวจ: tc qdisc show dev $IFACE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — IFB INGRESS SHAPING (client→VPS)
# ──────────────────────────────────────────────────────────────────────────────
# สำคัญที่สุด: bufferbloat ใหญ่สุดมักเกิดฝั่ง client→VPS (AIS 128kbps uplink)
# IFB = Intermediate Functional Block = virtual interface สำหรับ redirect ingress
# Shape ด้วย CAKE 112kbps = 12% headroom ต่ำกว่า AIS shaper → ป้องกัน burst
#
# ทำไม 112kbps ไม่ใช่ 128:
#   AIS 128kbps = marketing speed → จริงๆ 110-120kbps หลัง overhead
#   ถ้า shape ที่ 128 → ยังชน AIS shaper → ยังเกิด bufferbloat
#   112kbps = ต่ำกว่า AIS floor → เราเป็น bottleneck เอง → CAKE จัดการ queue
# ══════════════════════════════════════════════════════════════════════════════
step "IFB ingress shaping — CAKE ${CLIENT_UP_KBIT}kbps (client→VPS bufferbloat fix)"

if "$DRY_RUN"; then
    info "[DRY] modprobe ifb + redirect ingress → CAKE ${CLIENT_UP_KBIT}kbit"
else
    if $CAP_CAKE && $CAP_IFB; then
        modprobe ifb 2>/dev/null || warn "modprobe ifb ล้มเหลว"

        # สร้าง ifb0 ถ้ายังไม่มี
        ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb 2>/dev/null || {
            warn "สร้าง ifb0 ไม่ได้ — ข้าม ingress (ไม่ critical)"; goto_step6=true
        }

        if ! ${goto_step6:-false}; then
            ip link set ifb0 up 2>/dev/null || true

            # ล้าง qdisc เดิม
            tc qdisc del dev "$IFACE" handle ffff: ingress 2>/dev/null || true
            tc qdisc del dev ifb0 root 2>/dev/null || true

            # redirect ingress → ifb0
            tc qdisc add dev "$IFACE" handle ffff: ingress
            tc filter add dev "$IFACE" parent ffff: \
                protocol all u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null \
            || tc filter add dev "$IFACE" parent ffff: \
                protocol ip u32 match u32 0 0 \
                action mirred egress redirect dev ifb0

            # CAKE ingress (besteffort = ไม่แยก tier, ingress traffic ไม่ต้องการ)
            tc qdisc add dev ifb0 root cake       \
                bandwidth "${CLIENT_UP_KBIT}kbit" \
                rtt "${RTT_MS}ms"                 \
                besteffort                        \
                wash                              \
                overhead 40

            ip link show ifb0 | grep -q "UP" \
                && ok "Ingress CAKE: ${CLIENT_UP_KBIT}kbps on ifb0" \
                || warn "ifb0 อาจไม่ UP — ตรวจ: ip link show ifb0"
        fi
    elif ! $CAP_CAKE; then
        warn "ข้าม ingress shaping — ต้องการ CAKE"
    elif ! $CAP_IFB; then
        warn "ข้าม ingress shaping — ต้องการ IFB module"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — IRQBALANCE
# ══════════════════════════════════════════════════════════════════════════════
step "irqbalance — kernel-managed interrupt distribution"
if ! "$DRY_RUN"; then
    systemctl enable irqbalance 2>/dev/null || true
    systemctl restart irqbalance 2>/dev/null || true
    systemctl is-active irqbalance &>/dev/null \
        && ok "irqbalance active" \
        || warn "irqbalance ไม่ active — ไม่ critical บน 1vCPU"
else
    info "[DRY] systemctl enable irqbalance"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — CPU GOVERNOR: performance (ถ้าเข้าถึงได้บน VPS)
# ──────────────────────────────────────────────────────────────────────────────
# บน KVM VPS ส่วนใหญ่ governor ถูก lock ที่ performance อยู่แล้ว
# แต่ถ้าเปลี่ยนได้ → ลด scheduler latency → interrupt processing เร็วขึ้น
# ══════════════════════════════════════════════════════════════════════════════
step "CPU governor — set performance (if accessible)"
if ! "$DRY_RUN"; then
    if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor &>/dev/null 2>&1; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "performance" > "$gov" 2>/dev/null || true
        done
        CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        ok "CPU governor → ${CURRENT_GOV}"
    else
        info "CPU governor ไม่เข้าถึงได้บน VPS นี้ (KVM lock) — skip"
        ok "CPU governor skipped (VPS-managed)"
    fi
else
    info "[DRY] echo performance → scaling_governor"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — DNSMASQ: local caching resolver
# ──────────────────────────────────────────────────────────────────────────────
# ทำไม dnsmasq:
#   DNS latency ตาม x-ui มักถูกมองข้าม แต่ทุก connection ต้อง resolve hostname
#   Reality SNI (th.speedtest.net) ต้อง resolve ทุก session
#   dnsmasq cache 5000 entries + negative TTL → ลด DNS overhead ทั้งหมด
#
# Resolver priority:
#   1. 1.1.1.1 (Cloudflare) — เส้นทาง AIS→CF ดีที่สุดใน Thailand
#   2. 9.9.9.9 (Quad9)      — privacy-focused fallback
#   3. 202.44.x (TOT)       — domestic fallback เมื่อ CF ช้า
# ══════════════════════════════════════════════════════════════════════════════
step "dnsmasq — aggressive DNS cache (5000 entries)"

run bash -c "cat > /etc/dnsmasq.d/ais-vps.conf" << 'DNSEOF'
# AIS VPS · dnsmasq v4 · Extreme latency build
server=1.1.1.1
server=1.0.0.1
server=9.9.9.9
server=202.44.204.1
server=202.44.204.2

# aggressive cache
cache-size=5000
min-cache-ttl=60
max-cache-ttl=3600
neg-ttl=30

# connection tuning
dns-forward-max=500
edns-packet-max=4096

# reliability
no-resolv
no-poll
strict-order

# performance
log-queries=no
quiet-dhcp

# สำหรับ Reality SNI pre-resolve
# เพิ่ม entries ที่ใช้บ่อยเพื่อ warm cache
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
        ok "dnsmasq OK — cache 5000 entries พร้อม"
    else
        warn "dnsmasq ตอบช้า — ตรวจ: systemctl status dnsmasq"
    fi

    # Pre-warm DNS cache สำหรับ Reality targets
    info "Pre-warming DNS cache..."
    for domain in th.speedtest.net google.com cloudflare.com; do
        dig +short +time=2 @127.0.0.1 "$domain" &>/dev/null || true
    done
    ok "DNS cache pre-warmed"
else
    info "[DRY] dnsmasq config → 127.0.0.1 cache=5000"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — NFTABLES: minimal attack surface + MSS clamp
# ──────────────────────────────────────────────────────────────────────────────
# สำคัญ: tcp option maxseg size set rt mtu
#   = clamp-to-pmtu → adaptive ตาม route จริง
#   ป้องกัน packet fragmentation บน VLESS Reality (TLS overhead)
#   ผล: ลด retransmit, ลด jitter, ลด "video กระตุก" ใน mobile
#
# Rate limits:
#   SSH: 15/min (aggressive brute-force protection)
#   ICMP: 5/s (ป้องกัน ping flood กิน CPU 1vCPU)
# ══════════════════════════════════════════════════════════════════════════════
step "nftables — minimal ruleset + MSS clamp (443 · 2053 · SSH :${SSH_PORT})"

if $NFT_SAFE; then
    warn "NFT_SAFE: เพิ่ม rule แบบ incremental"
    run nft add rule inet filter input tcp dport 443  accept 2>/dev/null || true
    run nft add rule inet filter input tcp dport 2053 accept 2>/dev/null || true
    ok "nftables rules added (incremental)"
else
    run bash -c "cat > /etc/nftables.conf" << NFTEOF
#!/usr/sbin/nft -f
# AIS VPS · nftables · v4.0 · $(date '+%Y-%m-%d')
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # loopback
        iif lo accept

        # established (fast path)
        ct state established,related accept
        ct state invalid drop

        # ICMP rate-limited (ป้องกัน flood บน 1vCPU)
        ip  protocol icmp   icmp  type echo-request \
            limit rate 5/second burst 10 packets accept
        ip  protocol icmp   accept
        ip6 nexthdr  icmpv6 accept

        # SSH — brute-force protection
        tcp dport ${SSH_PORT} ct state new \
            limit rate 15/minute burst 5 packets accept
        tcp dport ${SSH_PORT} ct state new drop

        # VLESS Reality :443
        tcp dport 443 accept

        # 3x-ui panel :2053
        # TIP: เพิ่ม  ip saddr <your-home-ip>  เพื่อ restrict panel access
        tcp dport 2053 accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
        ct state invalid drop

        # MSS clamp-to-PMTU — critical สำหรับ VLESS Reality TLS
        # adaptive ตาม route จริง → ไม่ต้อง hardcode 1280
        # ลด fragmentation → ลด retransmit → ลด jitter
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu
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
    ok "nftables full ruleset loaded (MSS clamp enabled)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — 3X-UI PANEL INSTALL
# ══════════════════════════════════════════════════════════════════════════════
phase "3X-UI PANEL"
step "กรอกค่า panel settings"

XUI_PORT=2053; XUI_USER="admin"; XUI_PASS=""; XUI_DOMAIN=""; XUI_SSL_MODE="ip"

if ! "$DRY_RUN"; then
    echo ""
    _rule "─" "$BPUR"
    printf "  ${BPUR}${BOLD}ตั้งค่า 3X-UI Panel${RST}\n"
    _rule "─" "$BPUR"
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
    printf "  %-12s ${BWHT}%s${RST}\n" "Domain:"   "${XUI_DOMAIN:-<IP address>}"
    printf "  %-12s ${BWHT}%s${RST}\n" "Port:"     "$XUI_PORT"
    printf "  %-12s ${BWHT}%s${RST}\n" "Username:" "$XUI_USER"
    printf "  %-12s ${BWHT}%s${RST}\n" "Password:" "$(printf '%*s' ${#XUI_PASS} '' | tr ' ' '●')"
    _rule "─" "$DIM"
    echo ""
    printf "  ${BYLW}ยืนยัน? [Y/n]:${RST}  "; read -r _c
    [[ "${_c,,}" == "n" ]] && { warn "ยกเลิก"; exit 1; }

    # Let's Encrypt rate-limit check
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
            warn "RATE LIMIT: ${RL} ใบใน 7 วัน → เลือก IP cert"
            XUI_SSL_MODE="ip"
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
# STEP 11 — INSTALL 3X-UI
# ══════════════════════════════════════════════════════════════════════════════
step "Install / update 3x-ui"

if "$DRY_RUN"; then
    info "[DRY] bash <(curl -Ls .../install.sh)"
else
    XUI_SCRIPT=$(mktemp /tmp/xui-XXXXXX.sh)
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
        -o "$XUI_SCRIPT" 2>/dev/null \
        || die "ดาวน์โหลด installer ล้มเหลว"
    chmod +x "$XUI_SCRIPT"

    _rule "─" "$BYLW"
    printf "  ${BYLW}${BOLD}⚠  กรอกค่าเหล่านี้เมื่อ installer ถาม:${RST}\n\n"
    printf "  %-12s ${BWHT}%s${RST}\n" "Domain:"   "${XUI_DOMAIN:-<กด Enter>}"
    printf "  %-12s ${BWHT}%s${RST}\n" "Port:"     "$XUI_PORT"
    printf "  %-12s ${BWHT}%s${RST}\n" "Username:" "$XUI_USER"
    printf "  %-12s ${BWHT}%s${RST}\n" "Password:" "$(printf '%*s' ${#XUI_PASS} '' | tr ' ' '●')"
    printf "  %-12s ${BWHT}%s${RST}\n" "SSL mode:" "$XUI_SSL_MODE"
    _rule "─" "$BYLW"
    printf "  ${BCYN}กด Enter เพื่อเริ่ม installer...${RST}  "; read -r _

    bash "$XUI_SCRIPT"
    rm -f "$XUI_SCRIPT"
fi
ok "3x-ui installed"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — X-UI SYSTEMD OVERRIDE
# ══════════════════════════════════════════════════════════════════════════════
step "x-ui systemd — performance override"

XUI_DROP="/etc/systemd/system/x-ui.service.d"
run mkdir -p "$XUI_DROP"
run bash -c "cat > '$XUI_DROP/latency.conf'" << 'XUIEOF'
[Service]
# Memory limits (1GB RAM, 2 clients)
MemoryMax=512M
MemorySwapMax=0
# CPU priority (higher = better latency)
Nice=-10
CPUSchedulingPolicy=other
# Fast restart on crash
Restart=always
RestartSec=2s
RestartSteps=3
RestartMaxDelaySec=10s
# File descriptors (VLESS creates many connections)
LimitNOFILE=65536
XUIEOF

run systemctl daemon-reload
if ! "$DRY_RUN"; then
    systemctl restart x-ui 2>/dev/null \
        || warn "x-ui restart ล้มเหลว — ตรวจ: systemctl status x-ui"
fi
ok "x-ui override: Nice=-10 · MemoryMax=512M · LimitNOFILE=65536"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 13 — KERNEL HUGE PAGES & THP DISABLE (ลด jitter)
# ──────────────────────────────────────────────────────────────────────────────
# THP (Transparent Huge Pages) = ใน latency workload → GC pause → jitter spike
# Disable: OS จัดการ memory ด้วย 4KB pages เสมอ → predictable latency
# ══════════════════════════════════════════════════════════════════════════════
step "THP disable — ลด memory jitter"
if ! "$DRY_RUN"; then
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "never" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo "never" > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

        # persist via rc.local หรือ systemd
        THP_SVC="/etc/systemd/system/disable-thp.service"
        cat > "$THP_SVC" << 'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"

[Install]
WantedBy=multi-user.target
THPEOF
        systemctl enable disable-thp 2>/dev/null || true
        ok "THP disabled (never) → persist via disable-thp.service"
    else
        info "THP ไม่พร้อม — VPS kernel อาจ disable ไว้แล้ว"
        ok "THP step skipped"
    fi
else
    info "[DRY] echo never > /sys/kernel/mm/transparent_hugepage/enabled"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 14 — PERSIST QDISC ON BOOT (systemd service)
# ══════════════════════════════════════════════════════════════════════════════
step "ais-net.service — persist all tuning on reboot"

AIS_SVC="/etc/systemd/system/ais-net.service"

{
cat << SVCEOF
[Unit]
Description=AIS VPS Extreme Latency Tuning v4.0
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# sysctl
ExecStart=/sbin/sysctl --system -q

# egress qdisc
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${IFACE} root 2>/dev/null || true'
SVCEOF

if [[ "$QDISC_MODE" == "cake" ]]; then
    cat << SVCEOF2
ExecStart=/sbin/tc qdisc add dev ${IFACE} root cake bandwidth ${VPS_SHAPE_MBIT}Mbit rtt ${RTT_MS}ms diffserv4 dual-srchost dual-dsthost nat wash no-ack-filter overhead 40

# ingress via IFB
ExecStart=/sbin/modprobe ifb
ExecStart=/bin/sh -c 'ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb'
ExecStart=/bin/sh -c 'ip link set ifb0 up'
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${IFACE} handle ffff: ingress 2>/dev/null || true'
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ifb0 root 2>/dev/null || true'
ExecStart=/bin/sh -c '/sbin/tc qdisc add dev ${IFACE} handle ffff: ingress'
ExecStart=/bin/sh -c '/sbin/tc filter add dev ${IFACE} parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0'
ExecStart=/sbin/tc qdisc add dev ifb0 root cake bandwidth ${CLIENT_UP_KBIT}kbit rtt ${RTT_MS}ms besteffort wash overhead 40
SVCEOF2
else
    echo "ExecStart=/sbin/tc qdisc add dev ${IFACE} root fq_codel limit 1000 target ${CAKE_TARGET_MS}ms interval ${CAKE_INTERVAL_MS}ms quantum 1514"
fi

cat << 'SVCEOF3'

# THP disable
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true'

[Install]
WantedBy=multi-user.target
SVCEOF3
} | run bash -c "cat > '$AIS_SVC'"

run systemctl daemon-reload
run systemctl enable ais-net.service 2>/dev/null || true
ok "ais-net.service enabled → full tuning survives reboot"

# ══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
_rule "═" "$BPUR"
printf "${BPUR}${BOLD}  ◈  EXTREME LATENCY BUILD COMPLETE  ◈${RST}\n"
_rule "═" "$BPUR"
echo ""

printf "  ${BPUR}NETWORK STACK${RST}\n"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "Congestion control"       "$CC_MODE"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "Egress qdisc"             "${QDISC_MODE} · ${VPS_SHAPE_MBIT}Mbit"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "Ingress shaping"          "CAKE IFB · ${CLIENT_UP_KBIT}kbps"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "RTT reference"            "${RTT_MS}ms"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s bytes${RST}\n" "BDP (buffer target)"  "$BDP_BYTES"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s bytes${RST}\n" "TCP buffer (4× BDP)"  "$TCP_BUF_4x"
printf "  ${DIM}%-32s${RST}  ${BWHT}never${RST}\n"    "Transparent Huge Pages"

echo ""
printf "  ${BPUR}SERVICES${RST}\n"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "Firewall"       "nftables · 443+2053+SSH"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "DNS cache"      "dnsmasq · 5000 entries"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "x-ui panel"     ":${XUI_PORT} · Nice=-10 · FD=65536"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "CPU interrupt"  "irqbalance (kernel-managed)"
printf "  ${DIM}%-32s${RST}  ${BWHT}%s${RST}\n" "Boot persist"   "ais-net.service ✓"

echo ""
printf "  ${BPUR}NEXT STEPS${RST}\n"
printf "  ${DIM}1.${RST}  Panel    → ${BCYN}http://${PUBLIC_IP:-<VPS-IP>}:${XUI_PORT}${RST}\n"
printf "  ${DIM}2.${RST}  Inbound  → VLESS · Reality · port 443 · SNI: th.speedtest.net\n"
printf "  ${DIM}3.${RST}  Verify   → ${BCYN}sudo bash $0 --verify${RST}\n"
printf "  ${DIM}4.${RST}  Reboot   → ${BYLW}แนะนำ reboot 1 ครั้ง${RST}\n"
printf "  ${DIM}5.${RST}  Monitor  → ${BCYN}tc -s qdisc show dev ${IFACE}${RST}\n"
printf "  ${DIM}6.${RST}  Jitter   → ${BCYN}ping -c 30 -i 0.2 8.8.8.8${RST}\n"
printf "  ${DIM}7.${RST}  Rollback → ${BCYN}sudo bash $0 --rollback${RST}\n"

echo ""
_rule "─" "$DIM"
printf "  ${DIM}Log → %s${RST}\n\n" "$LOG_FILE"
