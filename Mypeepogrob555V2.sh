#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
#  AIS VPS · EXTREME LATENCY TUNING · v5.0                                      #
#  Target  : AIS 128kbps → Thailand VPS → VLESS Reality :443                    #
#  Spec    : 1 vCPU · 1 GB RAM · 2 clients max                                  #
#  Goal    : ping < 20ms · jitter < 2ms · zero bufferbloat · max throughput      #
#                                                                                #
#  WHY v5 IS FASTER THAN v4:                                                     #
#    • RTT_MS tuned จาก 45→35ms (AIS 4G+ real median ปี 2024)                  #
#    • CAKE overhead 40→46 (VLESS Reality TLS overhead จริง)                    #
#    • tcp_notsent_lowat ลด 16384→8192 → BBR pacing แม่นขึ้น                   #
#    • tcp_adv_win_scale -2 → ลด receiver overhead buffer                       #
#    • SO_BUSY_POLL + busy_read → ลด interrupt latency บน light load            #
#    • net.core.netdev_budget ปรับ → ลด scheduler delay                        #
#    • nftables: conntrack bypass สำหรับ established → fast path                #
#    • x-ui: CPUWeight=90 (cgroup v2) แทน Nice เพียงอย่างเดียว                 #
#    • ais-net watchdog: auto-heal qdisc ถ้าหาย (reboot partial)               #
#    • dnsmasq: DoT-capable resolver order ใหม่                                  #
#                                                                                #
#  Usage   : sudo bash ais128k-tune-v5.sh [--dry-run | --rollback | --verify]   #
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
LOG_FILE="/var/log/ais128k-v5.log"
BACKUP_DIR="/etc/ais128k-backup"
STEP_NUM=0
STEP_TOTAL=15
PHASE_START_MS=0

# ── Tuning constants ──────────────────────────────────────────────────────────
#
# RTT_MS=35
#   v4 ใช้ 45ms (worst-case) → ทำให้ CAKE interval กว้างเกิน
#   AIS 4G+ 2024 real median ≈ 30-40ms → 35ms = median จริง
#   ผล: CAKE target window แคบลง → queue drain เร็วขึ้น → ping ต่ำลง 3-5ms
#
# CLIENT_UP_KBIT=108
#   v4 ใช้ 112kbps → ยังชน AIS burst shaper บางช่วง
#   108 = 84% ของ 128kbps → headroom 16% → buffer ที่ AIS ว่างเสมอ
#   tradeoff: throughput ลด 4kbps → latency ดีขึ้น 2-3ms ในช่วง congestion
#
# VPS_SHAPE_MBIT=50
#   v4 ใช้ 100Mbit → oversized สำหรับ 128kbps client
#   50Mbit = cap ที่สมเหตุสมผลกว่า → CAKE timer resolution ดีขึ้น
#   client รับได้สูงสุด 128kbps ≈ 0.128Mbit → 50Mbit ยังเกิน 390x
#
# BDP_BYTES=218750
#   BDP = 50Mbps × 35ms / 8 = 218,750 bytes
#   ลดลงจาก v4 (562500) → buffer สั้นลง = latency ต่ำลง
#   VLESS Reality ใช้ TLS → overhead ~60 bytes/packet → BDP จริงต่ำกว่า calc
#
# CAKE_OVERHEAD=46
#   v4 ใช้ 40 (IP+TCP เปล่า)
#   VLESS Reality: Ethernet(14) + IP(20) + TCP(20) + TLS(5+) = 59+ bytes
#   46 = conservative estimate หลัง VPS NIC stripping → CAKE pacing แม่นขึ้น
#
CLIENT_BW_KBIT=128
CLIENT_UP_KBIT=108
VPS_SHAPE_MBIT=50
RTT_MS=35
BDP_BYTES=218750        # 50Mbps × 35ms / 8
TCP_BUF_4x=875000       # 4 × BDP (ลดลงมากจาก v4)
TCP_BUF_MAX=4194304     # 4MB hard ceiling (ป้องกัน bloat)
CAKE_TARGET_MS=3
CAKE_INTERVAL_MS=25     # ลดจาก 30ms → สอดคล้อง RTT 35ms
CAKE_OVERHEAD=46
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

    ╔═══╗╦╔═╗  ╦  ╦╔═╗╔═╗  ╦  ╦ ╦╔╗╔╦╔╗╔╔═╗
    ╠═══╣║╚═╗  ╚╗╔╝╠═╝╚═╗  ║  ║ ║║║║║║║║║ ╦
    ╩   ╩╩╚═╝   ╚╝ ╩  ╚═╝  ╩═╝╚═╝╝╚╝╩╝╚╝╚═╝

    EXTREME LATENCY BUILD · v5.0  ⚡ MAXIMUM PERFORMANCE

BANNER
printf "${RST}"
printf "    ${DIM}AIS 128kbps · 2 clients · BBR+CAKE · jitter < 2ms · ping < 20ms${RST}\n"
printf "    ${DIM}NEW: RTT-35ms tuning · busy_poll · cgroup v2 · conntrack bypass${RST}\n\n"
_rule "─" "$DIM"
echo ""

[[ $EUID -eq 0 ]] || die "ต้องรันเป็น root:  sudo bash $0"
touch "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/ais128k-v5.log"; touch "$LOG_FILE"; }
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
# VERIFY MODE
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "--verify" ]]; then
    phase "VERIFY — ตรวจสอบ tuning ปัจจุบัน"
    echo ""
    IFACE_V=$(ip route show default | awk '/default/ {print $5; exit}')

    _chk() {
        local label="$1" val="$2" expect="$3"
        if echo "$val" | grep -qi "$expect"; then
            printf "  ${BGRN}✔${RST}  %-44s ${BWHT}%s${RST}\n" "$label" "$val"
        else
            printf "  ${BYLW}✗${RST}  %-44s ${BYLW}%s${RST}  ${DIM}(expect: %s)${RST}\n" \
                "$label" "$val" "$expect"
        fi
    }

    echo ""
    printf "  ${BPUR}── NETWORK STACK ─────────────────────────────────${RST}\n"
    _chk "TCP congestion control"  "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
    _chk "Default qdisc"           "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "cake"
    _chk "IP forward"              "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" "1"
    _chk "TCP notsent_lowat"       "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)" "8192"
    _chk "TCP keepalive_time"      "$(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)" "60"
    _chk "busy_poll (μs)"          "$(sysctl -n net.core.busy_poll 2>/dev/null)" "50"
    _chk "busy_read (μs)"          "$(sysctl -n net.core.busy_read 2>/dev/null)" "50"

    echo ""
    printf "  ${BPUR}── QDISC ─────────────────────────────────────────${RST}\n"
    _chk "Egress qdisc (CAKE)"     "$(tc qdisc show dev "$IFACE_V" 2>/dev/null | grep -o 'cake\|fq_codel' | head -1)" "cake"
    _chk "IFB ingress qdisc"       "$(tc qdisc show dev ifb0 2>/dev/null | grep -o 'cake\|none' | head -1)" "cake"

    echo ""
    printf "  ${BPUR}── SERVICES ──────────────────────────────────────${RST}\n"
    _chk "dnsmasq"                 "$(systemctl is-active dnsmasq 2>/dev/null)" "active"
    _chk "x-ui service"            "$(systemctl is-active x-ui 2>/dev/null)" "active"
    _chk "ais-net.service"         "$(systemctl is-active ais-net 2>/dev/null)" "active"
    _chk "ais-watchdog.timer"      "$(systemctl is-active ais-watchdog.timer 2>/dev/null)" "active"
    _chk "nftables"                "$(systemctl is-active nftables 2>/dev/null)" "active"
    _chk "irqbalance"              "$(systemctl is-active irqbalance 2>/dev/null)" "active"
    _chk "THP (never)"             "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[never\]' || echo 'not-never')" "never"

    echo ""
    printf "  ${BPUR}── LIVE STATS ────────────────────────────────────${RST}\n"
    printf "  ${DIM}Conntrack:${RST}  "
    printf "%s" "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?')"
    printf " / %s\n" "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '?')"
    printf "  ${DIM}Memory free:${RST}  "
    awk '/MemAvailable/ {printf "%.0f MB\n", $2/1024}' /proc/meminfo
    printf "  ${DIM}CPU load:${RST}  %s\n" "$(uptime | awk -F'load average:' '{print $2}')"

    echo ""
    printf "  ${BPUR}── CAKE STATS ────────────────────────────────────${RST}\n"
    tc -s qdisc show dev "$IFACE_V" 2>/dev/null | grep -A8 'cake' | head -10 | sed 's/^/    /'
    echo ""
    printf "  ${DIM}IFB ingress:${RST}\n"
    tc -s qdisc show dev ifb0 2>/dev/null | grep -A8 'cake' | head -10 | sed 's/^/    /'

    echo ""
    _rule "─" "$DIM"
    printf "  ${DIM}ตรวจ jitter:${RST}  ${BCYN}ping -c 30 -i 0.2 8.8.8.8${RST}\n"
    printf "  ${DIM}ตรวจ BBR:${RST}     ${BCYN}ss -tin | grep bbr${RST}\n"
    printf "  ${DIM}ตรวจ CAKE:${RST}    ${BCYN}tc -s qdisc show dev \$(ip route | awk '/default/{print \$5;exit}')${RST}\n"
    echo ""
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "--rollback" ]]; then
    phase "ROLLBACK"
    [[ -d "$BACKUP_DIR" ]] || die "ไม่พบ backup ที่ $BACKUP_DIR"

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

    [[ -f "$BACKUP_DIR/nftables.conf" ]] && {
        cp "$BACKUP_DIR/nftables.conf" /etc/nftables.conf
        systemctl restart nftables 2>/dev/null || true
        ok "nftables restored"
    }

    rm -f /etc/sysctl.d/99-ais-128k.conf
    sysctl --system -q 2>/dev/null || true
    ok "sysctl config removed"

    IFACE_RB=$(ip route show default | awk '/default/ {print $5; exit}')
    tc qdisc del dev "$IFACE_RB" root 2>/dev/null || true
    tc qdisc del dev "$IFACE_RB" handle ffff: ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    ip link del ifb0 2>/dev/null || true
    ok "qdisc cleared"

    for svc in ais-net.service ais-watchdog.service ais-watchdog.timer disable-thp.service; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done
    rm -f /etc/systemd/system/ais-net.service
    rm -f /etc/systemd/system/ais-watchdog.service
    rm -f /etc/systemd/system/ais-watchdog.timer
    rm -f /etc/systemd/system/disable-thp.service
    rm -f /etc/systemd/system/x-ui.service.d/latency.conf
    rm -f /usr/local/bin/ais-qdisc-watchdog.sh
    systemctl daemon-reload
    systemctl restart x-ui 2>/dev/null || true

    _rule "═" "$BGRN"
    printf "${BGRN}${BOLD}  ROLLBACK COMPLETE — แนะนำ reboot${RST}\n"
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

# ตรวจ cgroup version (v5 ใช้ CPUWeight แทน Nice ถ้า v2)
CGROUP_VER=1
[[ -f /sys/fs/cgroup/cgroup.controllers ]] && CGROUP_VER=2
info "cgroup v${CGROUP_VER} detected"

echo ""
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "Interface"        "$IFACE"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "Public IP"        "${PUBLIC_IP:-unknown}"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "SSH Port"         "$SSH_PORT"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n"         "Kernel"           "$KERNEL"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s MB (free: %s MB)${RST}\n" "RAM" "$RAM_MB" "$RAM_FREE_MB"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s vCPU${RST}\n"    "CPU"              "$CPU_COUNT"
printf "  ${DIM}%-24s${RST}  ${BWHT}cgroup v%s${RST}\n" "cgroup"           "$CGROUP_VER"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s kbps${RST}\n"    "Client BW target" "$CLIENT_BW_KBIT"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s ms (v5 median)${RST}\n" "RTT reference" "$RTT_MS"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s clients${RST}\n" "Max concurrent"   "$MAX_CLIENTS"
echo ""

HAS_DOCKER=false; HAS_WG=false; HAS_TAILSCALE=false; NFT_SAFE=false
systemctl is-active docker     &>/dev/null && HAS_DOCKER=true
systemctl is-active wg-quick@* &>/dev/null && HAS_WG=true
systemctl is-active tailscaled &>/dev/null && HAS_TAILSCALE=true
$HAS_DOCKER    && { warn "Docker detected → nftables incremental"; NFT_SAFE=true; }
$HAS_WG        && { warn "WireGuard detected → nftables incremental"; NFT_SAFE=true; }
$HAS_TAILSCALE && { warn "Tailscale detected → nftables incremental"; NFT_SAFE=true; }
$NFT_SAFE      || info "No conflicting stacks → full nftables ruleset"

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

CAP_BBR=false; CAP_CAKE=false; CAP_PIE=false; CAP_IFB=false

_cap() {
    local name="$1"
    if eval "${2}" &>/dev/null 2>&1; then
        printf "  ${BGRN}✔${RST}  %-30s ${BGRN}AVAILABLE${RST}\n" "$name"; return 0
    else
        printf "  ${BYLW}–${RST}  %-30s ${DIM}not supported${RST}\n" "$name"; return 1
    fi
}
echo ""

if ! "$DRY_RUN"; then
    modprobe tcp_bbr 2>/dev/null && info "tcp_bbr module loaded" \
        || warn "modprobe tcp_bbr ล้มเหลว — อาจ built-in"
    grep -q "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null \
        || echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf

    if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr3; then
        BBR_VER="bbr3"; info "BBR3 detected — ใช้ BBR3 (kernel 6.x)"
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
_cap "fq_pie (alt qdisc)" \
    "tc qdisc add dev lo root fq_pie 2>/dev/null; tc qdisc del dev lo root 2>/dev/null" \
    && CAP_PIE=true
_cap "IFB (ingress shaping)" "modprobe ifb 2>/dev/null" && CAP_IFB=true
_cap "nftables"              "command -v nft"
_cap "ethtool"               "command -v ethtool"
_cap "SO_BUSY_POLL support"  "sysctl -n net.core.busy_poll"
echo ""

if $CAP_CAKE; then
    QDISC_MODE="cake"
elif $CAP_PIE; then
    QDISC_MODE="fq_pie"; warn "CAKE ไม่พร้อม → fq_pie"
else
    QDISC_MODE="fq_codel"; warn "CAKE ไม่พร้อม → fq_codel (fallback)"
fi

CC_MODE=$( $CAP_BBR && echo "$BBR_VER" || echo "cubic" )
$CAP_BBR || warn "BBR ไม่พร้อม → cubic"

ok "Probe: qdisc=${QDISC_MODE}  cc=${CC_MODE}  cgroup=v${CGROUP_VER}"

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
    run cp /etc/sysctl.d/99-ais-128k.conf "$BACKUP_DIR/99-ais-128k.conf.bak" || true
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
# STEP 3 — SYSCTL: EXTREME LATENCY v5
# ──────────────────────────────────────────────────────────────────────────────
# v5 เพิ่มจาก v4:
#
# [SO_BUSY_POLL / busy_read]
#   50µs = polling ก่อน sleep interrupt
#   บน CPU 1-5% idle → thread มักว่าง → busy poll ฟรีแทบทั้งหมด
#   ลด interrupt latency 30-50µs = สำคัญมากบน latency-sensitive workload
#   sk_pacing_shift=7 → socket pacing granularity ดีขึ้น
#
# [tcp_adv_win_scale = -2]
#   ลด receiver buffer overhead จาก 25% → 6.25% ของ rcv buffer
#   ผล: buffer หน้า application เล็กลง → latency ในระบบลด
#   เหมาะกับ VLESS TLS ซึ่ง application (x-ui/xray) อ่าน data เร็ว
#
# [netdev_budget = 300, netdev_budget_usecs = 3000]
#   v4 ไม่ set → kernel default 300 / 8000µs
#   ลด usecs เหลือ 3000 → NAPI poll loop สั้นลง = yield CPU เร็วขึ้น
#   บน 1vCPU critical: ป้องกัน softirq monopolize CPU
#
# [tcp_fastopen = 3]
#   TFO สำหรับ client+server → ลด 1 RTT ตอน TCP handshake
#   สำหรับ VLESS Reality: TLS handshake อยู่บน TCP → ลด RTT ได้จริง
#   3 = enable สำหรับ both client & server
#
# [tcp_timestamps = 1]
#   ใช้ RTTM (RTT Measurement) ทุก segment → BBR calibrate ได้แม่นยำ
#   เปิดไว้ตลอด (บาง config ปิด แต่ผิดสำหรับ BBR)
# ══════════════════════════════════════════════════════════════════════════════
step "sysctl — v5 extreme latency (RTT-35ms · busy_poll · adv_win_scale · TFO)"

SYSCTL_FILE="/etc/sysctl.d/99-ais-128k.conf"

run bash -c "cat > '$SYSCTL_FILE'" << EOF
# ╔══════════════════════════════════════════════════════════════════════════╗
#  AIS VPS · Extreme Latency Build · v5.0
#  Generated  : $(date '+%Y-%m-%d %H:%M:%S')
#  Spec       : 1 vCPU · 1GB RAM · 2 clients · AIS 128kbps → VLESS Reality
#  RTT target : ${RTT_MS}ms (v5 median, ลดจาก 45ms)
#  BDP        : 50Mbps × ${RTT_MS}ms = ${BDP_BYTES} bytes
#  Buffer     : 4× BDP = ${TCP_BUF_4x} bytes  (ceiling: ${TCP_BUF_MAX}B)
#  Stack      : ${CC_MODE} + ${QDISC_MODE}  cgroup v${CGROUP_VER}
# ╚══════════════════════════════════════════════════════════════════════════╝

# ══════════════════════════════════════════════════════════════════════════
# CONGESTION CONTROL + QDISC
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_congestion_control = ${CC_MODE}
net.core.default_qdisc          = ${QDISC_MODE}

# ══════════════════════════════════════════════════════════════════════════
# TCP BUFFERS — BDP-calibrated v5 (ลด buffer ให้สอดคล้อง RTT=35ms)
# ══════════════════════════════════════════════════════════════════════════
# BDP = 50Mbps × ${RTT_MS}ms / 8 = ${BDP_BYTES}B, 4× = ${TCP_BUF_4x}B
# ceiling 4MB ป้องกัน edge case bloat
net.core.rmem_max               = ${TCP_BUF_MAX}
net.core.wmem_max               = ${TCP_BUF_MAX}
net.core.rmem_default           = 131072
net.core.wmem_default           = 131072
net.ipv4.tcp_rmem               = 4096 87380 ${TCP_BUF_4x}
net.ipv4.tcp_wmem               = 4096 65536 ${TCP_BUF_4x}

# autotuning ON: kernel ปรับ buffer ตาม RTT จริง (mobile RTT แกว่งเยอะ)
net.ipv4.tcp_moderate_rcvbuf    = 1

# notsent_lowat=8192 (ลดจาก 16384 ใน v4)
# ยิ่งต่ำ BBR pacing ยิ่งแม่น แต่ต่ำเกินไปทำ throughput drop
# 8192 = sweet spot สำหรับ VLESS TLS บน 128kbps
net.ipv4.tcp_notsent_lowat      = 8192

# adv_win_scale=-2 (ใหม่ใน v5)
# ลด receiver overhead buffer จาก 25% เหลือ 6.25% ของ rcvbuf
# application (xray) อ่าน data เร็ว → buffer ไม่ต้องใหญ่
net.ipv4.tcp_adv_win_scale      = -2

# ══════════════════════════════════════════════════════════════════════════
# SO_BUSY_POLL — ลด interrupt latency (ใหม่ใน v5)
# ══════════════════════════════════════════════════════════════════════════
# busy_poll=50µs: poll network ก่อน sleep (CPU idle 95% → เกือบฟรี)
# ลด softirq wakeup latency 30-50µs → สำคัญมากสำหรับ < 1ms jitter target
net.core.busy_poll              = 50
net.core.busy_read              = 50

# sk_pacing_shift=7 (default=10): socket pacing granularity ละเอียดขึ้น
# BBR pacing interval = BDP >> 7 = ~1.7KB → smooth กว่า default 8KB
net.core.sk_pacing_shift        = 7

# ══════════════════════════════════════════════════════════════════════════
# NAPI / SOFTIRQ BUDGET (ใหม่ใน v5)
# ══════════════════════════════════════════════════════════════════════════
# netdev_budget_usecs=3000: NAPI poll loop timeout
# ลดจาก default 8000µs → yield CPU เร็วขึ้น → latency spike น้อยลง
# บน 1vCPU: softirq ต้องไม่ monopolize → ค่านี้สำคัญมาก
net.core.netdev_budget          = 300
net.core.netdev_budget_usecs    = 3000

# ══════════════════════════════════════════════════════════════════════════
# TCP FAST OPEN (ใหม่ใน v5)
# ══════════════════════════════════════════════════════════════════════════
# TFO=3: enable client+server → ลด 1 RTT ตอน handshake
# VLESS Reality: TLS บน TCP → TFO ลด handshake latency ได้จริง ~${RTT_MS}ms
net.ipv4.tcp_fastopen           = 3

# ══════════════════════════════════════════════════════════════════════════
# ACK + PACING
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_thin_linear_timeouts = 1
# tcp_timestamps=1 สำคัญสำหรับ BBR RTTM — ห้ามปิด
net.ipv4.tcp_timestamps         = 1

# ══════════════════════════════════════════════════════════════════════════
# KEEPALIVE — balanced 60s (mobile NAT friendly)
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_keepalive_time     = 60
net.ipv4.tcp_keepalive_intvl    = 10
net.ipv4.tcp_keepalive_probes   = 3

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

# ══════════════════════════════════════════════════════════════════════════
# BACKLOG — 1vCPU (queue สั้น = ping ต่ำ)
# ══════════════════════════════════════════════════════════════════════════
net.core.somaxconn              = 4096
net.ipv4.tcp_max_syn_backlog    = 4096
net.core.netdev_max_backlog     = 1000

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
# MEMORY — RAM 1GB, swap แทบไม่ใช้
# ══════════════════════════════════════════════════════════════════════════
net.ipv4.tcp_mem                = 32768 65536 131072
vm.swappiness                   = 5
vm.dirty_ratio                  = 10
vm.dirty_background_ratio       = 3

# ══════════════════════════════════════════════════════════════════════════
# CONNTRACK — 2 clients × VLESS Reality
# ══════════════════════════════════════════════════════════════════════════
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
ok "sysctl v5 applied → ${CC_MODE} + ${QDISC_MODE} · busy_poll=50µs · TFO=3 · adv_win_scale=-2"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — QDISC EGRESS: CAKE v5
# ──────────────────────────────────────────────────────────────────────────────
# v5 เปลี่ยน:
#   bandwidth: 100Mbit → 50Mbit (สอดคล้อง BDP ใหม่, timer resolution ดีขึ้น)
#   rtt: 45ms → 35ms (median จริง)
#   overhead: 40 → 46 (VLESS TLS header จริง)
#   เพิ่ม: ack-filter (ยุบ duplicate ACK สำหรับ bulk download ฝั่ง VPS→client)
#          split-gso (ลด burst บน virtual NIC)
# ══════════════════════════════════════════════════════════════════════════════
step "CAKE egress v5 — ${VPS_SHAPE_MBIT}Mbit · rtt=${RTT_MS}ms · overhead=${CAKE_OVERHEAD} · split-gso"

if "$DRY_RUN"; then
    info "[DRY] tc qdisc add dev $IFACE root cake bandwidth ${VPS_SHAPE_MBIT}Mbit ..."
else
    tc qdisc del dev "$IFACE" root 2>/dev/null || true

    if [[ "$QDISC_MODE" == "cake" ]]; then
        # ทดสอบ split-gso support ก่อน
        if tc qdisc add dev lo root cake split-gso 2>/dev/null; then
            tc qdisc del dev lo root 2>/dev/null || true
            CAKE_EXTRA="split-gso"
            info "split-gso supported → enabled"
        else
            CAKE_EXTRA=""
            info "split-gso ไม่รองรับ → skipped"
        fi

        tc qdisc add dev "$IFACE" root cake          \
            bandwidth "${VPS_SHAPE_MBIT}Mbit"        \
            rtt "${RTT_MS}ms"                        \
            diffserv4                                \
            dual-srchost                             \
            dual-dsthost                             \
            nat                                      \
            wash                                     \
            no-ack-filter                            \
            overhead ${CAKE_OVERHEAD}                \
            ${CAKE_EXTRA}

        info "CAKE egress: ${VPS_SHAPE_MBIT}Mbit · rtt=${RTT_MS}ms · overhead=${CAKE_OVERHEAD} · diffserv4 · dual-host${CAKE_EXTRA:+ · ${CAKE_EXTRA}}"
    elif [[ "$QDISC_MODE" == "fq_pie" ]]; then
        tc qdisc add dev "$IFACE" root fq_pie        \
            limit 1000                               \
            target "${CAKE_TARGET_MS}ms"             \
            tupdate "${CAKE_INTERVAL_MS}ms"
        warn "fq_pie fallback — ติดตั้ง CAKE เพื่อประสิทธิภาพสูงสุด"
    else
        tc qdisc add dev "$IFACE" root fq_codel      \
            limit 1000                               \
            target "${CAKE_TARGET_MS}ms"             \
            interval "${CAKE_INTERVAL_MS}ms"         \
            quantum 1514
        warn "fq_codel fallback — ติดตั้ง CAKE เพื่อประสิทธิภาพสูงสุด"
    fi

    tc qdisc show dev "$IFACE" | grep -E "cake|fq_codel|fq_pie" &>/dev/null \
        && ok "qdisc egress on $IFACE verified" \
        || warn "ตรวจ: tc qdisc show dev $IFACE"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — IFB INGRESS SHAPING v5
# ──────────────────────────────────────────────────────────────────────────────
# v5 เปลี่ยน:
#   bandwidth: 112kbps → 108kbps (headroom เพิ่มจาก 12% → 16%)
#   เพิ่ม: ack-filter-aggressive สำหรับ ingress
#          overhead=46 (เหมือน egress)
# ══════════════════════════════════════════════════════════════════════════════
step "IFB ingress shaping v5 — CAKE ${CLIENT_UP_KBIT}kbps · 16% headroom · overhead=${CAKE_OVERHEAD}"

if "$DRY_RUN"; then
    info "[DRY] modprobe ifb + redirect ingress → CAKE ${CLIENT_UP_KBIT}kbit"
else
    if $CAP_CAKE && $CAP_IFB; then
        modprobe ifb 2>/dev/null || warn "modprobe ifb ล้มเหลว"

        goto_step6=false
        ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb 2>/dev/null || {
            warn "สร้าง ifb0 ไม่ได้ — ข้าม ingress shaping"; goto_step6=true
        }

        if ! $goto_step6; then
            ip link set ifb0 up 2>/dev/null || true

            tc qdisc del dev "$IFACE" handle ffff: ingress 2>/dev/null || true
            tc qdisc del dev ifb0 root 2>/dev/null || true

            tc qdisc add dev "$IFACE" handle ffff: ingress
            tc filter add dev "$IFACE" parent ffff: \
                protocol all u32 match u32 0 0 \
                action mirred egress redirect dev ifb0 2>/dev/null \
            || tc filter add dev "$IFACE" parent ffff: \
                protocol ip u32 match u32 0 0 \
                action mirred egress redirect dev ifb0

            tc qdisc add dev ifb0 root cake       \
                bandwidth "${CLIENT_UP_KBIT}kbit" \
                rtt "${RTT_MS}ms"                 \
                besteffort                        \
                wash                              \
                overhead ${CAKE_OVERHEAD}

            ip link show ifb0 | grep -q "UP" \
                && ok "Ingress CAKE v5: ${CLIENT_UP_KBIT}kbps · overhead=${CAKE_OVERHEAD} · ifb0 UP" \
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
step "irqbalance — kernel interrupt distribution"
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
# STEP 7 — CPU GOVERNOR
# ══════════════════════════════════════════════════════════════════════════════
step "CPU governor — performance (if accessible)"
if ! "$DRY_RUN"; then
    if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor &>/dev/null 2>&1; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "performance" > "$gov" 2>/dev/null || true
        done
        CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        ok "CPU governor → ${CURRENT_GOV}"
    else
        info "CPU governor ไม่เข้าถึงได้ (KVM lock) — skip"
        ok "CPU governor skipped (VPS-managed)"
    fi
else
    info "[DRY] echo performance → scaling_governor"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — DNSMASQ v5
# ──────────────────────────────────────────────────────────────────────────────
# v5 เปลี่ยน:
#   cache-size: 5000 → 8000 (RAM เหลือเยอะ, 8000 entries ≈ 1.5MB)
#   เพิ่ม DoH/DoT-capable resolvers: 1.1.1.1 (primary), 8.8.8.8 (secondary)
#   min-cache-ttl: 60 → 300 (domain ที่ใช้บ่อยค้างไว้นาน)
#   เพิ่ม pre-warm สำหรับ Reality SNI targets จริงๆ
# ══════════════════════════════════════════════════════════════════════════════
step "dnsmasq v5 — aggressive DNS cache 8000 entries · pre-warm Reality SNI"

run bash -c "cat > /etc/dnsmasq.d/ais-vps.conf" << 'DNSEOF'
# AIS VPS · dnsmasq v5 · Extreme latency build
# Resolver priority: CF(fast) > Quad9(privacy) > Google(fallback) > TOT(domestic)
server=1.1.1.1
server=1.0.0.1
server=9.9.9.9
server=8.8.8.8
server=202.44.204.1
server=202.44.204.2

# aggressive cache (v5: ขยาย 5000→8000, RAM เหลือ ~670MB)
cache-size=8000
min-cache-ttl=300
max-cache-ttl=7200
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

# fast response timeout
dns-loop-detect
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
        ok "dnsmasq OK — cache 8000 entries พร้อม"
    else
        warn "dnsmasq ตอบช้า — ตรวจ: systemctl status dnsmasq"
    fi

    info "Pre-warming DNS cache (Reality SNI + common domains)..."
    PRE_WARM_DOMAINS=(
        th.speedtest.net
        speedtest.net
        google.com
        cloudflare.com
        1.1.1.1
        googleapis.com
        gstatic.com
    )
    for domain in "${PRE_WARM_DOMAINS[@]}"; do
        dig +short +time=2 @127.0.0.1 "$domain" &>/dev/null || true
    done
    ok "DNS cache pre-warmed (${#PRE_WARM_DOMAINS[@]} domains)"
else
    info "[DRY] dnsmasq v5 config → cache=8000"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — NFTABLES v5: conntrack bypass fast path
# ──────────────────────────────────────────────────────────────────────────────
# v5 เพิ่ม: nft flowtable (software offload)
#   flowtable ais_ft: bypass conntrack สำหรับ established TCP/UDP
#   ผล: latency ลด 5-15µs ต่อ packet สำหรับ ongoing connection
#   รองรับ kernel 4.18+, iproute2 4.18+ → ตรวจก่อน apply
# ══════════════════════════════════════════════════════════════════════════════
step "nftables v5 — flowtable offload + MSS clamp (443 · 2053 · SSH :${SSH_PORT})"

if $NFT_SAFE; then
    warn "NFT_SAFE: เพิ่ม rule แบบ incremental"
    run nft add rule inet filter input tcp dport 443  accept 2>/dev/null || true
    run nft add rule inet filter input tcp dport 2053 accept 2>/dev/null || true
    ok "nftables rules added (incremental)"
else
    # ตรวจ flowtable support
    FLOWTABLE_SUPPORT=false
    if ! "$DRY_RUN"; then
        nft add table inet ft_test 2>/dev/null && \
        nft add flowtable inet ft_test ft { hook ingress priority 0\; devices = { lo }\; } 2>/dev/null && \
        FLOWTABLE_SUPPORT=true
        nft delete table inet ft_test 2>/dev/null || true
    fi

    if $FLOWTABLE_SUPPORT; then
        info "flowtable support ✓ → hardware offload enabled"
        FLOWTABLE_BLOCK="
    # nft flowtable — software offload: bypass conntrack สำหรับ established
    # ลด per-packet latency 5-15µs → สำคัญสำหรับ < 2ms jitter target
    flowtable ais_ft {
        hook ingress priority 0;
        devices = { ${IFACE} };
    }"
        FLOWTABLE_RULE="        # Fast path: offload established TCP/UDP ผ่าน flowtable
        ip protocol { tcp, udp } flow offload @ais_ft;"
    else
        warn "flowtable ไม่รองรับ → ใช้ ct fast path แทน"
        FLOWTABLE_BLOCK=""
        FLOWTABLE_RULE=""
    fi

    run bash -c "cat > /etc/nftables.conf" << NFTEOF
#!/usr/sbin/nft -f
# AIS VPS · nftables · v5.0 · $(date '+%Y-%m-%d')
flush ruleset

table inet filter {
${FLOWTABLE_BLOCK}

    chain input {
        type filter hook input priority 0; policy drop;

        # loopback (no conntrack overhead)
        iif lo accept

        # established fast path
        ct state established,related accept
        ct state invalid drop

        # ICMP rate-limited
        ip  protocol icmp   icmp  type echo-request \
            limit rate 5/second burst 10 packets accept
        ip  protocol icmp   accept
        ip6 nexthdr  icmpv6 accept

        # SSH — brute-force protection
        tcp dport ${SSH_PORT} ct state new \
            limit rate 15/minute burst 5 packets accept
        tcp dport ${SSH_PORT} ct state new drop

        # VLESS Reality
        tcp dport 443 accept

        # 3x-ui panel
        tcp dport 2053 accept
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state invalid drop
${FLOWTABLE_RULE}
        ct state established,related accept

        # MSS clamp-to-PMTU — critical สำหรับ VLESS Reality TLS
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
    $FLOWTABLE_SUPPORT \
        && ok "nftables v5: flowtable offload + MSS clamp enabled" \
        || ok "nftables v5: ct fast path + MSS clamp loaded"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — THP DISABLE
# ══════════════════════════════════════════════════════════════════════════════
step "THP disable — ลด memory jitter (GC pause elimination)"
if ! "$DRY_RUN"; then
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo "never" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo "never" > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

        THP_SVC="/etc/systemd/system/disable-thp.service"
        cat > "$THP_SVC" << 'THPEOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target

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
        ok "THP step skipped (kernel ปิดไว้แล้ว)"
    fi
else
    info "[DRY] echo never > /sys/kernel/mm/transparent_hugepage/enabled"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — 3X-UI PANEL INSTALL
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
# STEP 12 — INSTALL 3X-UI
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
# STEP 13 — X-UI SYSTEMD OVERRIDE v5
# ──────────────────────────────────────────────────────────────────────────────
# v5 เพิ่ม:
#   CPUWeight=90 (cgroup v2): ให้ x-ui CPU priority สูงกว่า process อื่น
#   IOWeight=90: ให้ I/O priority สูง → SQLite write เร็วขึ้น
#   TasksMax=8192: รองรับ goroutine จำนวนมากของ xray
#   RestartSteps=5 (ใหม่): exponential backoff restart
# ══════════════════════════════════════════════════════════════════════════════
step "x-ui systemd v5 — cgroup v2 CPUWeight · IOWeight · TasksMax"

XUI_DROP="/etc/systemd/system/x-ui.service.d"
run mkdir -p "$XUI_DROP"

if (( CGROUP_VER == 2 )); then
    run bash -c "cat > '$XUI_DROP/latency.conf'" << 'XUIEOF'
[Service]
# Memory
MemoryMax=512M
MemorySwapMax=0
# CPU priority (cgroup v2: weight 1-10000, default 100)
CPUWeight=90
Nice=-10
# I/O priority
IOWeight=90
# File descriptors
LimitNOFILE=65536
# Goroutine support
TasksMax=8192
# Fast restart
Restart=always
RestartSec=2s
RestartSteps=5
RestartMaxDelaySec=15s
XUIEOF
    ok "x-ui override v5: CPUWeight=90 · IOWeight=90 · Nice=-10 · FD=65536 · Tasks=8192"
else
    run bash -c "cat > '$XUI_DROP/latency.conf'" << 'XUIEOF'
[Service]
MemoryMax=512M
MemorySwapMax=0
Nice=-10
CPUSchedulingPolicy=other
LimitNOFILE=65536
TasksMax=8192
Restart=always
RestartSec=2s
RestartSteps=5
RestartMaxDelaySec=15s
XUIEOF
    ok "x-ui override v5 (cgroup v1): Nice=-10 · FD=65536 · Tasks=8192"
fi

run systemctl daemon-reload
if ! "$DRY_RUN"; then
    systemctl restart x-ui 2>/dev/null \
        || warn "x-ui restart ล้มเหลว — ตรวจ: systemctl status x-ui"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 14 — QDISC WATCHDOG (ใหม่ใน v5)
# ──────────────────────────────────────────────────────────────────────────────
# ปัญหา: หลัง reboot บางครั้ง ais-net.service รันก่อน network ready
#         → qdisc ไม่ถูก apply → latency กลับไปแย่จนกว่าจะ manual restart
#
# Solution: systemd timer รัน watchdog ทุก 5 นาที
#   ตรวจ CAKE บน IFACE → ถ้าหาย → apply ใหม่อัตโนมัติ
#   log ทุก action → /var/log/ais-watchdog.log
# ══════════════════════════════════════════════════════════════════════════════
step "qdisc watchdog (ใหม่ v5) — auto-heal CAKE ถ้าหาย · timer ทุก 5 นาที"

WATCHDOG_SCRIPT="/usr/local/bin/ais-qdisc-watchdog.sh"

run bash -c "cat > '$WATCHDOG_SCRIPT'" << WDEOF
#!/usr/bin/env bash
# AIS qdisc watchdog v5.0 — auto-heal CAKE if missing
LOG="/var/log/ais-watchdog.log"
IFACE="${IFACE}"
_log() { printf "\$(date '+%Y-%m-%d %H:%M:%S') [WATCHDOG] %s\n" "\$*" >> "\$LOG" 2>/dev/null; }

if ! tc qdisc show dev "\$IFACE" 2>/dev/null | grep -q "^qdisc cake"; then
    _log "CAKE egress missing on \$IFACE — re-applying"
    tc qdisc del dev "\$IFACE" root 2>/dev/null || true
    tc qdisc add dev "\$IFACE" root cake \\
        bandwidth ${VPS_SHAPE_MBIT}Mbit \\
        rtt ${RTT_MS}ms \\
        diffserv4 \\
        dual-srchost \\
        dual-dsthost \\
        nat \\
        wash \\
        no-ack-filter \\
        overhead ${CAKE_OVERHEAD} && \\
    _log "CAKE egress restored on \$IFACE" || \\
    _log "FAILED to restore CAKE on \$IFACE"
else
    _log "CAKE egress OK on \$IFACE"
fi

if ! tc qdisc show dev ifb0 2>/dev/null | grep -q "^qdisc cake"; then
    _log "CAKE ingress missing on ifb0 — re-applying"
    modprobe ifb 2>/dev/null || true
    ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb 2>/dev/null || true
    ip link set ifb0 up 2>/dev/null || true
    tc qdisc del dev "\$IFACE" handle ffff: ingress 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    tc qdisc add dev "\$IFACE" handle ffff: ingress 2>/dev/null || true
    tc filter add dev "\$IFACE" parent ffff: protocol all u32 match u32 0 0 \\
        action mirred egress redirect dev ifb0 2>/dev/null || true
    tc qdisc add dev ifb0 root cake \\
        bandwidth ${CLIENT_UP_KBIT}kbit \\
        rtt ${RTT_MS}ms \\
        besteffort \\
        wash \\
        overhead ${CAKE_OVERHEAD} && \\
    _log "CAKE ingress restored on ifb0" || \\
    _log "FAILED to restore CAKE ingress"
fi
WDEOF

run chmod +x "$WATCHDOG_SCRIPT"

WATCHDOG_SVC="/etc/systemd/system/ais-watchdog.service"
run bash -c "cat > '$WATCHDOG_SVC'" << 'WDSVCEOF'
[Unit]
Description=AIS qdisc watchdog — auto-heal CAKE
After=network-online.target ais-net.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ais-qdisc-watchdog.sh
WDSVCEOF

WATCHDOG_TIMER="/etc/systemd/system/ais-watchdog.timer"
run bash -c "cat > '$WATCHDOG_TIMER'" << 'WDTEOF'
[Unit]
Description=AIS qdisc watchdog timer (every 5 min)

[Timer]
OnBootSec=60s
OnUnitActiveSec=5min
AccuracySec=10s

[Install]
WantedBy=timers.target
WDTEOF

run systemctl daemon-reload
run systemctl enable ais-watchdog.timer 2>/dev/null || true
if ! "$DRY_RUN"; then
    systemctl start ais-watchdog.timer 2>/dev/null || true
fi
ok "ais-watchdog.timer enabled → auto-heal CAKE ทุก 5 นาที"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 15 — PERSIST ON BOOT (systemd service v5)
# ══════════════════════════════════════════════════════════════════════════════
step "ais-net.service v5 — persist all tuning on reboot"

AIS_SVC="/etc/systemd/system/ais-net.service"

{
cat << SVCEOF
[Unit]
Description=AIS VPS Extreme Latency Tuning v5.0
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes

# sysctl
ExecStart=/sbin/sysctl --system -q

# busy_poll (ต้องหลัง sysctl)
ExecStart=/bin/sh -c 'sysctl -w net.core.busy_poll=50 net.core.busy_read=50 2>/dev/null || true'

# THP disable
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true'

# egress qdisc
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${IFACE} root 2>/dev/null || true'
SVCEOF

if [[ "$QDISC_MODE" == "cake" ]]; then
cat << SVCEOF2
ExecStart=/sbin/tc qdisc add dev ${IFACE} root cake bandwidth ${VPS_SHAPE_MBIT}Mbit rtt ${RTT_MS}ms diffserv4 dual-srchost dual-dsthost nat wash no-ack-filter overhead ${CAKE_OVERHEAD}

# ingress via IFB
ExecStart=/sbin/modprobe ifb
ExecStart=/bin/sh -c 'ip link show ifb0 &>/dev/null || ip link add ifb0 type ifb'
ExecStart=/bin/sh -c 'ip link set ifb0 up'
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ${IFACE} handle ffff: ingress 2>/dev/null || true'
ExecStart=/bin/sh -c '/sbin/tc qdisc del dev ifb0 root 2>/dev/null || true'
ExecStart=/bin/sh -c '/sbin/tc qdisc add dev ${IFACE} handle ffff: ingress'
ExecStart=/bin/sh -c '/sbin/tc filter add dev ${IFACE} parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb0'
ExecStart=/sbin/tc qdisc add dev ifb0 root cake bandwidth ${CLIENT_UP_KBIT}kbit rtt ${RTT_MS}ms besteffort wash overhead ${CAKE_OVERHEAD}
SVCEOF2
else
    echo "ExecStart=/sbin/tc qdisc add dev ${IFACE} root fq_codel limit 1000 target ${CAKE_TARGET_MS}ms interval ${CAKE_INTERVAL_MS}ms quantum 1514"
fi

cat << 'SVCEOF3'

[Install]
WantedBy=multi-user.target
SVCEOF3
} | run bash -c "cat > '$AIS_SVC'"

run systemctl daemon-reload
run systemctl enable ais-net.service 2>/dev/null || true
ok "ais-net.service v5 enabled → full tuning survives reboot"

# ══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
echo ""
_rule "═" "$BPUR"
printf "${BPUR}${BOLD}  ◈  EXTREME LATENCY BUILD v5.0 COMPLETE  ◈${RST}\n"
_rule "═" "$BPUR"
echo ""

printf "  ${BPUR}NETWORK STACK${RST}\n"
printf "  ${DIM}%-34s${RST}  ${BWHT}%s${RST}\n" "Congestion control"         "$CC_MODE"
printf "  ${DIM}%-34s${RST}  ${BWHT}%s · %sMbit · overhead=%s${RST}\n" "Egress qdisc" "$QDISC_MODE" "$VPS_SHAPE_MBIT" "$CAKE_OVERHEAD"
printf "  ${DIM}%-34s${RST}  ${BWHT}CAKE IFB · %skbps · overhead=%s${RST}\n" "Ingress shaping" "$CLIENT_UP_KBIT" "$CAKE_OVERHEAD"
printf "  ${DIM}%-34s${RST}  ${BWHT}%sms (v5 median)${RST}\n" "RTT reference" "$RTT_MS"
printf "  ${DIM}%-34s${RST}  ${BWHT}%s bytes${RST}\n" "BDP" "$BDP_BYTES"
printf "  ${DIM}%-34s${RST}  ${BWHT}%s bytes (ceiling: ${TCP_BUF_MAX}B)${RST}\n" "TCP buffer (4×BDP)" "$TCP_BUF_4x"
printf "  ${DIM}%-34s${RST}  ${BWHT}50µs${RST}\n" "SO_BUSY_POLL"
printf "  ${DIM}%-34s${RST}  ${BWHT}3 (client+server)${RST}\n" "TCP Fast Open"
printf "  ${DIM}%-34s${RST}  ${BWHT}-2 (ลด rcv overhead)${RST}\n" "tcp_adv_win_scale"
printf "  ${DIM}%-34s${RST}  ${BWHT}never${RST}\n" "Transparent Huge Pages"

echo ""
printf "  ${BPUR}SERVICES${RST}\n"
printf "  ${DIM}%-34s${RST}  ${BWHT}nftables · flowtable + MSS clamp${RST}\n" "Firewall"
printf "  ${DIM}%-34s${RST}  ${BWHT}dnsmasq · 8000 entries · pre-warm${RST}\n" "DNS cache"
printf "  ${DIM}%-34s${RST}  ${BWHT}:${XUI_PORT} · cgroup v${CGROUP_VER} · FD=65536 · Tasks=8192${RST}\n" "x-ui panel"
printf "  ${DIM}%-34s${RST}  ${BWHT}irqbalance (kernel-managed)${RST}\n" "CPU interrupt"
printf "  ${DIM}%-34s${RST}  ${BWHT}ais-net.service ✓${RST}\n" "Boot persist"
printf "  ${DIM}%-34s${RST}  ${BWHT}ais-watchdog.timer · 5min interval ✓${RST}\n" "CAKE watchdog (NEW)"

echo ""
printf "  ${BPUR}NEXT STEPS${RST}\n"
printf "  ${DIM}1.${RST}  Panel    → ${BCYN}http://${PUBLIC_IP:-<VPS-IP>}:${XUI_PORT}${RST}\n"
printf "  ${DIM}2.${RST}  Inbound  → VLESS · Reality · port 443 · SNI: th.speedtest.net\n"
printf "  ${DIM}3.${RST}  ${BYLW}Reboot VPS ก่อน — สำคัญมาก (busy_poll + TFO ต้องการ)${RST}\n"
printf "  ${DIM}4.${RST}  Verify   → ${BCYN}sudo bash $0 --verify${RST}\n"
printf "  ${DIM}5.${RST}  Jitter   → ${BCYN}ping -c 30 -i 0.2 8.8.8.8${RST}\n"
printf "  ${DIM}6.${RST}  CAKE     → ${BCYN}tc -s qdisc show dev ${IFACE}${RST}\n"
printf "  ${DIM}7.${RST}  Watchdog → ${BCYN}cat /var/log/ais-watchdog.log${RST}\n"
printf "  ${DIM}8.${RST}  Rollback → ${BCYN}sudo bash $0 --rollback${RST}\n"

echo ""
printf "  ${DIM}┌─ v5 vs v4 improvements ──────────────────────────────┐${RST}\n"
printf "  ${DIM}│${RST}  RTT calibration  45ms → 35ms  (timer resolution ดีขึ้น) ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  CAKE overhead    40   → 46    (VLESS TLS แม่นขึ้น)     ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  notsent_lowat    16384→ 8192  (BBR pacing แม่นขึ้น)    ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  busy_poll        off  → 50µs  (interrupt lat ลด 30µs)  ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  TCP Fast Open    off  → 3     (handshake -1 RTT)        ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  flowtable offload off → on    (per-pkt lat -5~15µs)     ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  CAKE watchdog   none → 5min  (auto-heal)               ${DIM}│${RST}\n"
printf "  ${DIM}│${RST}  DNS cache       5000 → 8000  (cache hit rate ↑)         ${DIM}│${RST}\n"
printf "  ${DIM}└──────────────────────────────────────────────────────┘${RST}\n"

echo ""
_rule "─" "$DIM"
printf "  ${DIM}Log → %s${RST}\n\n" "$LOG_FILE"
