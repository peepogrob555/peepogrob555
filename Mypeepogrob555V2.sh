#!/usr/bin/env bash
# ████████████████████████████████████████████████████████████████████████████
#
#   ░█████╗░██╗░██████╗   ██╗░░░██╗██████╗░░██████╗
#   ██╔══██╗██║██╔════╝   ██║░░░██║██╔══██╗██╔════╝
#   ███████║██║╚█████╗░   ╚██╗░██╔╝██████╔╝╚█████╗░
#   ██╔══██║██║░╚═══██╗   ░╚████╔╝░██╔═══╝░░╚═══██╗
#   ██║░░██║██║██████╔╝   ░░╚██╔╝░░██║░░░░░██████╔╝
#   ╚═╝░░╚═╝╚═╝╚═════╝░   ░░░╚═╝░░░╚═╝░░░░░╚═════╝░
#
#   AIS 128kbps · Thailand VPS · VLESS/VMess WS None-TLS · 3x-ui · v3.1
#   WS Host : th.speedtest.net
#   Protocol: VLESS WS + VMess WS  (None TLS, port 80)
#   Goal    : ปิงต่ำ + เสถียร บน 4G/5G 128kbps
#
#   USAGE: sudo bash ais128k-ws-tuning.sh [--dry-run | --rollback]
# ████████████████████████████████████████████████████████████████████████████

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# TERMINAL PALETTE
# ══════════════════════════════════════════════════════════════════════════════

RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
BRED='\033[1;31m'; BGRN='\033[1;32m'
BYLW='\033[1;33m'; BCYN='\033[1;36m'
BWHT='\033[1;37m'; BG_BLK='\033[40m'
BG_YLW='\033[43m'; BLK='\033[0;30m'

# ══════════════════════════════════════════════════════════════════════════════
# GLOBALS
# ══════════════════════════════════════════════════════════════════════════════

DRY_RUN=false
LOG_FILE="/var/log/ais128k-tuning.log"
BACKUP_DIR="/etc/ais128k-backup"
STEP_NUM=0
STEP_TOTAL=15
PHASE_START_MS=0

# WS transport ใช้ port 80 None-TLS, Host header = th.speedtest.net
WS_HOST="th.speedtest.net"
WS_PORT=80

# ══════════════════════════════════════════════════════════════════════════════
# TUI ENGINE
# ══════════════════════════════════════════════════════════════════════════════

_now_ms() { date +%s%3N; }
_log()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
_cols()   { tput cols 2>/dev/null || echo 80; }

_rule() {
    local char="${1:--}" color="${2:-$DIM}"
    printf "${color}"; printf '%*s' "$(_cols)" '' | tr ' ' "$char"; printf "${RST}\n"
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
    local filled=$(( pct * 24 / 100 )) bar="" i
    for (( i=0; i<filled; i++ ));  do bar+="█"; done
    for (( i=filled; i<24; i++ )); do bar+="░"; done
    printf "\n${BCYN}  [%02d/%02d]${RST}  ${BOLD}%s${RST}\n" "$STEP_NUM" "$STEP_TOTAL" "$1"
    printf "          ${DIM}[${RST}${BGRN}%s${RST}${DIM}] %3d%%${RST}\n" "$bar" "$pct"
    _log INFO "STEP $STEP_NUM/$STEP_TOTAL: $1"
}

ok()   { printf "  ${BGRN}✔${RST}  %-52s ${DIM}+%dms${RST}\n" "$*" "$(( $(_now_ms) - PHASE_START_MS ))"; _log OK "$*"; }
info() { printf "  ${BCYN}·${RST}  %s\n" "$*"; _log INFO "$*"; }
warn() { printf "  ${BYLW}⚠${RST}  ${BYLW}%s${RST}\n" "$*"; _log WARN "$*"; }
die()  { printf "\n  ${BRED}✖  FATAL: %s${RST}\n\n" "$*" >&2; _log FAIL "$*"; exit 1; }

spinner() {
    local pid=$1 label="${2:-working}" frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BCYN}%s${RST}  %s..." "${frames[$((i % 10))]}" "$label"
        (( i++ )) || true; sleep 0.08
    done
    printf "\r%-70s\r" ""
}

run() {
    "$DRY_RUN" && { printf "  ${BYLW}○${RST}  ${DIM}[DRY]${RST} %s\n" "$*"; return 0; }
    "$@"
}

_confirm() {
    "$DRY_RUN" && { info "[DRY] ข้าม confirm: $1"; return 0; }
    printf "\n  ${BYLW}▶  %s${RST}  ${DIM}[Y/n]:${RST}  " "${1:-ดำเนินการต่อ?}"
    read -r _ans
    [[ "${_ans,,}" != "n" ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# BOOT SCREEN
# ══════════════════════════════════════════════════════════════════════════════

clear
echo -e "${BCYN}"
cat << 'BANNER'

    ░█████╗░██╗░██████╗   ██╗░░░██╗██████╗░░██████╗
    ██╔══██╗██║██╔════╝   ██║░░░██║██╔══██╗██╔════╝
    ███████║██║╚█████╗░   ╚██╗░██╔╝██████╔╝╚█████╗░
    ██╔══██║██║░╚═══██╗   ░╚████╔╝░██╔═══╝░░╚═══██╗
    ██║░░██║██║██████╔╝   ░░╚██╔╝░░██║░░░░░██████╔╝
    ╚═╝░░╚═╝╚═╝╚═════╝░   ░░░╚═╝░░░╚═╝░░░░░╚═════╝░

BANNER
echo -e "${RST}"
printf "    ${DIM}AIS 128kbps · Thailand VPS · VLESS/VMess WS None-TLS · v3.1${RST}\n"
printf "    ${DIM}WS port 80 · Host: th.speedtest.net · 1 CPU · 1GB RAM${RST}\n\n"
_rule "─" "$DIM"; echo ""

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
touch "$LOG_FILE" 2>/dev/null || { LOG_FILE="/tmp/ais128k-tuning.log"; touch "$LOG_FILE"; }
info "Session log → $LOG_FILE"
sleep 0.2

# ══════════════════════════════════════════════════════════════════════════════
# ARG PARSING
# ══════════════════════════════════════════════════════════════════════════════

case "${1:-}" in
    --dry-run)
        DRY_RUN=true
        printf "\n  ${BG_YLW}${BLK}  DRY RUN — no changes will be written  ${RST}\n\n"
        sleep 0.4 ;;
    --rollback) : ;;
    "")         : ;;
    *)          die "Usage: $0 [--dry-run|--rollback]" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# ROLLBACK
# ══════════════════════════════════════════════════════════════════════════════

if [[ "${1:-}" == "--rollback" ]]; then
    phase "ROLLBACK"
    [[ -d "$BACKUP_DIR" ]] || die "No backup at $BACKUP_DIR"

    local_job=$(atq 2>/dev/null | awk '{print $1}' | head -1)
    [[ -n "${local_job:-}" ]] && { atrm "$local_job" 2>/dev/null; ok "Deadman timer cancelled"; }

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

    [[ -f "$BACKUP_DIR/99-ais-128k.conf" ]] && {
        rm -f /etc/sysctl.d/99-ais-128k.conf
        sysctl --system -q 2>/dev/null || true
        ok "sysctl config removed"
    }

    IFACE_RB=$(ip route show default | awk '/default/ {print $5; exit}')
    [[ -n "${IFACE_RB:-}" ]] && {
        tc qdisc del dev "$IFACE_RB" root 2>/dev/null || true
        ok "qdisc cleared on $IFACE_RB"
    }

    for svc in ais-net.service zram.service; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done
    ok "ais-net + zram disabled"

    [[ -f /etc/systemd/system/x-ui.service.d/override.conf ]] && {
        rm -f /etc/systemd/system/x-ui.service.d/override.conf
        systemctl daemon-reload
        systemctl restart x-ui 2>/dev/null || true
        ok "x-ui override removed"
    }

    echo ""; _rule "═" "$BGRN"
    printf "${BGRN}${BOLD}  ROLLBACK COMPLETE${RST}  — reboot recommended\n"
    _rule "═" "$BGRN"; echo ""; exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT SCAN
# ══════════════════════════════════════════════════════════════════════════════

phase "ENVIRONMENT SCAN"

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[[ -n "$IFACE" ]] || die "Cannot detect default network interface"

SSH_PORT=$(ss -tnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}')
SSH_PORT=${SSH_PORT:-22}

PUBLIC_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
    || ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)

# ── ตรวจ virtualization type — กระทบ ZRAM ─────────────────────────────────
VIRT_TYPE="unknown"
if command -v systemd-detect-virt &>/dev/null; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo unknown)
fi
# OpenVZ/LXC ไม่รองรับ kernel modules
IS_CONTAINER=false
[[ "$VIRT_TYPE" == "openvz" || "$VIRT_TYPE" == "lxc" || "$VIRT_TYPE" == "lxc-libvirt" ]] && IS_CONTAINER=true

echo ""
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Interface"   "$IFACE"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Public IP"   "${PUBLIC_IP:-unknown}"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "SSH Port"    "$SSH_PORT"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Kernel"      "$(uname -r)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "OS"          "$(lsb_release -ds 2>/dev/null || uname -s)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "RAM"         "$(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "vCPU"        "$(nproc) × $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Virt"        "$VIRT_TYPE"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "WS Host"     "$WS_HOST"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "WS Port"     "$WS_PORT (None TLS)"
echo ""

$IS_CONTAINER && warn "Container VPS (${VIRT_TYPE}) — ZRAM/module loading จะถูก skip อัตโนมัติ"

HAS_DOCKER=false; HAS_WIREGUARD=false; HAS_TAILSCALE=false; NFT_SAFE_MODE=false
systemctl is-active docker     &>/dev/null && HAS_DOCKER=true
systemctl is-active wg-quick@* &>/dev/null && HAS_WIREGUARD=true
systemctl is-active tailscaled &>/dev/null && HAS_TAILSCALE=true
$HAS_DOCKER    && { warn "Docker detected    → nftables incremental mode"; NFT_SAFE_MODE=true; }
$HAS_WIREGUARD && { warn "WireGuard detected → nftables incremental mode"; NFT_SAFE_MODE=true; }
$HAS_TAILSCALE && { warn "Tailscale detected → nftables incremental mode"; NFT_SAFE_MODE=true; }
$NFT_SAFE_MODE || info "No conflicting stacks → full nftables ruleset"

if [[ -L /etc/resolv.conf ]]; then
    RESOLVER_MODE="symlink"; RESOLVER_TARGET=$(readlink -f /etc/resolv.conf)
    info "Resolver: systemd-resolved symlink → $RESOLVER_TARGET"
else
    RESOLVER_MODE="file"; RESOLVER_TARGET=""
    info "Resolver: static file"
fi
ok "Scan complete"

# ══════════════════════════════════════════════════════════════════════════════
# CAPABILITY PROBE
# ══════════════════════════════════════════════════════════════════════════════

phase "KERNEL CAPABILITY PROBE"
CAP_BBR=false; CAP_FQCODEL=false; CAP_ZRAM=false

_cap() {
    local name="$1" cmd="$2"
    if eval "$cmd" &>/dev/null 2>&1; then
        printf "  ${BGRN}✔${RST}  %-22s ${BGRN}AVAILABLE${RST}\n" "$name"; return 0
    else
        printf "  ${BYLW}–${RST}  %-22s ${DIM}not supported${RST}\n" "$name"; return 1
    fi
}

echo ""
_cap "BBR"      "sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr" && CAP_BBR=true
_cap "fq_codel" "tc qdisc add dev lo root fq_codel 2>/dev/null; tc qdisc del dev lo root 2>/dev/null" && CAP_FQCODEL=true

# ZRAM: ถ้าเป็น container ให้ skip ทันที ไม่พยายาม modprobe
if $IS_CONTAINER; then
    printf "  ${BYLW}–${RST}  %-22s ${DIM}skipped (container VPS)${RST}\n" "ZRAM"
else
    _cap "ZRAM" "modprobe -n zram" && CAP_ZRAM=true
fi

_cap "nftables" "command -v nft"
echo ""; ok "Probe complete"

# ══════════════════════════════════════════════════════════════════════════════
# BACKUP
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
[[ -f /etc/sysctl.d/99-ais-128k.conf ]]  && run cp /etc/sysctl.d/99-ais-128k.conf "$BACKUP_DIR/99-ais-128k.conf"  || true
ok "Backup saved → $BACKUP_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — PACKAGES
# ══════════════════════════════════════════════════════════════════════════════

phase "PACKAGES"
_confirm "ติดตั้ง dependencies?" || die "ยกเลิก"
step "Install dependencies"

run systemctl stop    systemd-resolved 2>/dev/null || true
run systemctl disable systemd-resolved 2>/dev/null || true

if ! "$DRY_RUN"; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    info "Temporary resolver → 1.1.1.1 / 1.0.0.1 (pinned for apt)"
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
fi

APT_REQUIRED="curl wget ethtool dnsmasq sqlite3 jq nftables dnsutils ca-certificates iproute2 iputils-ping"
APT_OPTIONAL="cron socat at"

if ! "$DRY_RUN"; then
    APT_LOG=$(mktemp /tmp/ais-apt-XXXXXX.log)

    { apt-get update -qq 2>&1 || {
        warn "apt update errors — retrying with Ubuntu main mirrors"
        sed -i 's|http://mirrors\.bangmod\.cloud/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            /etc/apt/sources.list 2>/dev/null || true
        apt-get update -qq 2>&1
    }; } >> "$APT_LOG" 2>&1 &
    spinner $! "apt update"

    { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_REQUIRED 2>&1; } \
        >> "$APT_LOG" 2>&1 &
    spinner $! "apt install"
    wait $! || { cat "$APT_LOG" >&2; die "apt install failed"; }

    { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTIONAL 2>&1; } \
        >> "$APT_LOG" 2>&1 || \
        warn "Optional packages unavailable — deadman timer may be skipped"
    rm -f "$APT_LOG"

    for bin in nft dnsmasq sqlite3; do
        command -v "$bin" &>/dev/null || die "Binary '$bin' not found after install"
    done
fi
ok "Packages ready"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — HOSTNAME
# ══════════════════════════════════════════════════════════════════════════════

step "Fix hostname in /etc/hosts"
HOSTNAME_NOW=$(hostname)
if ! grep -qF "$HOSTNAME_NOW" /etc/hosts 2>/dev/null; then
    run bash -c "echo '127.0.1.1 $HOSTNAME_NOW' >> /etc/hosts"
    ok "Added: 127.0.1.1 $HOSTNAME_NOW"
else
    ok "Already present — skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — รับค่า 3x-ui panel
# ══════════════════════════════════════════════════════════════════════════════

phase "3X-UI PANEL CONFIG"
_confirm "กรอกค่า 3x-ui panel?" || die "ยกเลิก"
step "Collect panel settings"

XUI_PORT=2053; XUI_USER="admin"; XUI_PASS=""
XUI_WS_PATH="/ws"
# WS_PORT=80 กำหนดไว้ใน GLOBALS แล้ว (None TLS)

if ! "$DRY_RUN"; then
    echo ""; _rule "─" "$BCYN"
    printf "  ${BCYN}${BOLD}กรอกค่าสำหรับ 3X-UI Panel${RST}\n"
    printf "  ${DIM}Protocol: VLESS/VMess WS · None TLS · port ${BWHT}${WS_PORT}${RST}\n"
    printf "  ${DIM}WS Host : ${BWHT}${WS_HOST}${RST}\n"
    _rule "─" "$BCYN"; echo ""

    # Panel port
    while true; do
        printf "  ${BWHT}Panel port${RST}  ${DIM}(default 2053 — เข้า web panel):${RST}  "
        read -r _p; XUI_PORT=${_p:-2053}
        (( XUI_PORT >= 1 && XUI_PORT <= 65535 )) && break
        printf "  ${BRED}ต้องเป็นตัวเลข 1–65535${RST}\n"
    done

    # WS path
    printf "  ${BWHT}WS path${RST}  ${DIM}(default /ws):${RST}  "
    read -r _path; XUI_WS_PATH=${_path:-/ws}
    [[ "${XUI_WS_PATH:0:1}" != "/" ]] && XUI_WS_PATH="/$XUI_WS_PATH"

    # Username
    printf "  ${BWHT}Username${RST}  ${DIM}(default admin):${RST}\n  > "
    read -r _u; XUI_USER=${_u:-admin}

    # Password
    while true; do
        printf "  ${BWHT}Password${RST}  ${DIM}(min 8 ตัวอักษร):${RST}  "
        read -rs XUI_PASS; echo ""
        (( ${#XUI_PASS} >= 8 )) && break
        printf "  ${BRED}Password ต้องมีอย่างน้อย 8 ตัว${RST}\n"
    done

    echo ""; _rule "─" "$DIM"
    printf "  ${DIM}Protocol  :${RST}  ${BWHT}VLESS WS + VMess WS (None TLS)${RST}\n"
    printf "  ${DIM}WS Port   :${RST}  ${BWHT}%s${RST}\n"   "$WS_PORT"
    printf "  ${DIM}WS Path   :${RST}  ${BWHT}%s${RST}\n"   "$XUI_WS_PATH"
    printf "  ${DIM}WS Host   :${RST}  ${BWHT}%s${RST}\n"   "$WS_HOST"
    printf "  ${DIM}Panel port:${RST}  ${BWHT}%s${RST}\n"   "$XUI_PORT"
    printf "  ${DIM}Username  :${RST}  ${BWHT}%s${RST}\n"   "$XUI_USER"
    printf "  ${DIM}Password  :${RST}  ${BWHT}%s${RST}\n"   "$(printf '%*s' ${#XUI_PASS} | tr ' ' '*')"
    _rule "─" "$DIM"; echo ""
    printf "  ${BYLW}ยืนยัน? [Y/n]:${RST}  "; read -r _c
    [[ "${_c,,}" == "n" ]] && { warn "ยกเลิก — รันใหม่"; exit 1; }
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — ติดตั้ง 3x-ui
# ══════════════════════════════════════════════════════════════════════════════

_confirm "ติดตั้ง 3x-ui?" || die "ยกเลิก"
step "Install / update 3x-ui"

if "$DRY_RUN"; then
    info "[DRY] bash <(curl -Ls .../install.sh)"
else
    XUI_SCRIPT=$(mktemp /tmp/xui-install-XXXXXX.sh)
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
        -o "$XUI_SCRIPT" 2>/dev/null \
        || die "ดาวน์โหลด 3x-ui installer ล้มเหลว"
    chmod +x "$XUI_SCRIPT"

    echo ""; _rule "─" "$BYLW"
    printf "  ${BYLW}${BOLD}⚠  กรอกค่าใน installer ตามนี้:${RST}\n"
    printf "  ${DIM}Panel port:${RST} ${BWHT}%s${RST}  │  ${DIM}User:${RST} ${BWHT}%s${RST}\n" "$XUI_PORT" "$XUI_USER"
    printf "  ${BRED}★  SSL → เลือก option 3 (None/Custom) — None TLS ไม่ต้องการ cert${RST}\n"
    _rule "─" "$BYLW"; echo ""

    bash "$XUI_SCRIPT"; rm -f "$XUI_SCRIPT"
fi
ok "3x-ui installed / updated"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Patch 3x-ui DB
# ══════════════════════════════════════════════════════════════════════════════

_confirm "Patch panel DB?" || warn "ข้าม DB patch"
step "Patch panel DB → port:${XUI_PORT} user:${XUI_USER}"
X_UI_DB="/etc/x-ui/x-ui.db"

if ! "$DRY_RUN"; then
    for _i in $(seq 1 20); do [[ -f "$X_UI_DB" ]] && break; sleep 1; done

    if [[ -f "$X_UI_DB" ]]; then
        systemctl stop x-ui 2>/dev/null || true; sleep 1

        _db_upsert() {
            local key="$1" val="$2"
            if sqlite3 "$X_UI_DB" "SELECT 1 FROM settings WHERE key='${key}';" 2>/dev/null | grep -q 1; then
                sqlite3 "$X_UI_DB" "UPDATE settings SET value='${val}' WHERE key='${key}';"
            else
                sqlite3 "$X_UI_DB" "INSERT INTO settings(key,value) VALUES('${key}','${val}');" 2>/dev/null || true
            fi
            ok "  DB ✔  ${key} = ${val}"
        }

        _db_upsert "webPort"     "$XUI_PORT"
        _db_upsert "webUsername" "$XUI_USER"
        _db_upsert "webPassword" "$XUI_PASS"
        # ไม่แตะ webBasePath — ใช้ random path จาก installer

        systemctl start x-ui
        ok "Panel DB patched  [port:${XUI_PORT} · user:${XUI_USER}]"
        warn "webBasePath: ดูจาก installer output ข้างบน"
    else
        warn "x-ui.db ไม่พบหลัง 20 วินาที — ตั้งค่าใน panel เอง"
    fi
else
    info "[DRY] sqlite3: port=${XUI_PORT} user=${XUI_USER}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — SYSCTL
# ══════════════════════════════════════════════════════════════════════════════
# ค่าทุกตัวคำนวณจาก:
#   Bandwidth = 128 kbps = 16 KB/s
#   RTT 4G/AIS Thailand = 40–80ms (ใช้ worst case 80ms)
#   BDP = 16KB/s × 0.08s = 1.28 KB  ← เล็กมาก
#   Buffer ควรเป็น 4–16× BDP = 5–20 KB เท่านั้น
#   ใช้ 4MB max เพื่อรองรับ burst และ WS framing overhead
# ══════════════════════════════════════════════════════════════════════════════

phase "KERNEL TUNING"
_confirm "ปรับ kernel sysctl สำหรับ WS 128kbps?" || warn "ข้าม sysctl"
step "Write sysctl (WS None-TLS optimized)"

CC_CHOICE=$($CAP_BBR    && echo bbr     || echo cubic)
QD_CHOICE=$($CAP_FQCODEL && echo fq_codel || echo fq)

if ! "$DRY_RUN"; then
cat > /etc/sysctl.d/99-ais-128k.conf << EOF
# ══════════════════════════════════════════════════════════════
# AIS 128kbps VPS — VLESS/VMess WS None-TLS Low Latency Tuning
# Generated : $(date)
# Protocol  : WS port 80, Host: ${WS_HOST}
# Link      : 128 kbps, RTT 40-80ms (AIS 4G/5G)
# BDP       : ~1.3 KB → buffer max 4MB (rounding up for WS)
# ══════════════════════════════════════════════════════════════

# ── Congestion Control ──────────────────────────────────────
net.core.default_qdisc          = ${QD_CHOICE}
net.ipv4.tcp_congestion_control = ${CC_CHOICE}

# ── TCP Buffers (tuned for 128kbps, low BDP) ───────────────
# 4MB max เพียงพอ — 16MB ทำให้ buffer bloat บน slow link
net.core.rmem_max     = 4194304
net.core.wmem_max     = 4194304
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.ipv4.tcp_rmem     = 4096 43690 4194304
net.ipv4.tcp_wmem     = 4096 16384 4194304

# ── UDP Buffers (WS ใช้ TCP แต่ xray ยังใช้ UDP ภายใน) ─────
net.core.netdev_max_backlog = 2048
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096

# ── TCP Latency (สำคัญมากสำหรับ WS บน low-bandwidth) ──────
net.ipv4.tcp_slow_start_after_idle = 0   # ไม่ slow start หลัง idle (WS ใช้ keepalive)
net.ipv4.tcp_mtu_probing           = 1   # ค้นหา MTU อัตโนมัติ (ป้องกัน PMTUD blackhole)
net.ipv4.tcp_notsent_lowat         = 8192 # ลด latency ของ WS frame — ส่งเร็วขึ้น
net.ipv4.tcp_autocorking           = 0   # ปิด autocork — WS ต้องการ flush ทันที
net.ipv4.tcp_moderate_rcvbuf       = 1
net.ipv4.tcp_sack                  = 1   # SACK — สำคัญบน lossy 4G
net.ipv4.tcp_dsack                 = 1   # D-SACK — ช่วย retransmit ที่ถูก ACK แล้ว
net.ipv4.tcp_timestamps            = 1
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_rfc1337               = 1
net.ipv4.tcp_ecn                   = 1   # ECN — ให้ fq_codel signal congestion แทน drop

# ── WS Connection Stability (AIS NAT timeout ~5 min) ───────
# tcp_keepalive_time ต้องน้อยกว่า AIS NAT timeout (300s)
# ตั้ง 60s เพื่อ margin ปลอดภัย
net.core.somaxconn            = 2048
net.ipv4.tcp_max_syn_backlog  = 2048
net.ipv4.tcp_fin_timeout      = 10   # AIS drop connection เร็ว — ล้าง FIN_WAIT เร็ว
net.ipv4.tcp_keepalive_time   = 60   # WS keepalive ก่อน AIS NAT timeout (ต้อง < 300s)
net.ipv4.tcp_keepalive_intvl  = 10   # ส่ง probe ทุก 10s หลัง keepalive_time
net.ipv4.tcp_keepalive_probes = 3    # ลอง 3 ครั้ง → 60+30s = 90s รวม ก่อน drop

# ── Conntrack (proxy traffic) ───────────────────────────────
net.netfilter.nf_conntrack_max                     = 32768
net.netfilter.nf_conntrack_tcp_timeout_established = 300  # ลดจาก 600 — เหมาะ WS short-lived
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 10

# ── Memory (1 GB RAM) ───────────────────────────────────────
vm.swappiness             = 10
vm.vfs_cache_pressure     = 50
vm.dirty_ratio            = 10
vm.dirty_background_ratio = 3

# ── Security ────────────────────────────────────────────────
net.ipv4.tcp_syncookies              = 1
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.ip_forward                  = 1
EOF

    # tcp_fastopen — probe ก่อน apply
    if sysctl -n net.ipv4.tcp_fastopen &>/dev/null; then
        echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.d/99-ais-128k.conf
        info "tcp_fastopen = 3 (ลด 1 RTT บน reconnect)"
    else
        warn "tcp_fastopen unavailable on this kernel — skipped"
    fi
fi

if "$DRY_RUN"; then
    info "[DRY] sysctl --system"
else
    sysctl --system 2>&1 | grep -E "^\* Applying" | \
        while IFS= read -r line; do printf "  ${DIM}%s${RST}\n" "$line"; done || true
fi

ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
ok "sysctl applied  [CC=${ACTIVE_CC} · qdisc=${QD_CHOICE}]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — QDISC
# ══════════════════════════════════════════════════════════════════════════════
# fq_codel target:
#   - RTT AIS 4G = 40–80ms
#   - target ควรเป็น ~50% ของ RTT min → 20ms
#   - interval = 10× target → 200ms
#   - limit/flows เล็กลง เพราะ 128kbps ไม่ต้องการ queue ใหญ่
# ══════════════════════════════════════════════════════════════════════════════

_confirm "ตั้ง qdisc → ${QD_CHOICE}?" || warn "ข้าม qdisc"
step "Set qdisc → $QD_CHOICE (tuned for 4G RTT)"
run tc qdisc del dev "$IFACE" root 2>/dev/null || true

if $CAP_FQCODEL; then
    run tc qdisc add dev "$IFACE" root fq_codel \
        limit 512 flows 512 target 20ms interval 200ms ecn
    ok "fq_codel  target=20ms · interval=200ms · ecn=on  [4G RTT optimized]"
else
    run tc qdisc add dev "$IFACE" root fq limit 512 flow_limit 50
    warn "fq_codel unavailable → fq fallback (limit=512 · flow_limit=50)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — NFTABLES
# port 80 เปิดแน่นอน สำหรับ WS None-TLS
# ══════════════════════════════════════════════════════════════════════════════

phase "FIREWALL"
_confirm "ตั้ง nftables? (SSH:${SSH_PORT} · 80 · panel:${XUI_PORT})" || warn "ข้าม firewall"
step "nftables — transactional apply"

NFT_TMP=$(mktemp /tmp/nft-ais-XXXXXX.conf)

if $NFT_SAFE_MODE; then
cat > "$NFT_TMP" << NFTEOF
# AIS VPS — incremental table (Docker/WG/Tailscale preserved)
table inet ais_filter {
    chain input {
        type filter hook input priority 1; policy drop;
        iif lo accept
        ct state established,related accept
        ip  protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept
        tcp dport ${SSH_PORT}  ct state new limit rate 10/minute accept
        tcp dport 80           accept   # WS None-TLS inbound
        tcp dport ${XUI_PORT}  accept   # 3x-ui web panel
        log prefix "ais-drop: " flags all limit rate 5/minute
    }
    chain forward { type filter hook forward priority 1; policy accept; }
    chain output  { type filter hook output  priority 1; policy accept; }
}
NFTEOF
else
cat > "$NFT_TMP" << NFTEOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        ip  protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept
        tcp dport ${SSH_PORT}  ct state new limit rate 10/minute accept
        tcp dport 80           accept   # WS None-TLS inbound
        tcp dport ${XUI_PORT}  accept   # 3x-ui web panel
        log prefix "nft-drop: " flags all limit rate 5/minute
        drop
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
NFTEOF
fi

if ! "$DRY_RUN"; then
    nft -c -f "$NFT_TMP" 2>/dev/null \
        || { rm -f "$NFT_TMP"; die "nftables syntax error — ruleset NOT applied"; }
    ok "Syntax validated (nft -c)"

    DEADMAN_JOB=""; _ROLLBACK_SCRIPT="/tmp/ais-rollback-$$.sh"
    if command -v at &>/dev/null; then
        cat > "$_ROLLBACK_SCRIPT" << RBEOF
#!/bin/bash
nft flush ruleset 2>/dev/null || true
[[ -f "${BACKUP_DIR}/nftables.conf" ]] && nft -f "${BACKUP_DIR}/nftables.conf" 2>/dev/null || true
rm -f "$_ROLLBACK_SCRIPT"
RBEOF
        chmod +x "$_ROLLBACK_SCRIPT"
        DEADMAN_JOB=$(at now + 2 minutes < "$_ROLLBACK_SCRIPT" 2>&1 | awk '/job/ {print $2}')
        info "Deadman armed  (job #${DEADMAN_JOB} · fires in 2 min if SSH lost)"
    fi

    cp "$NFT_TMP" /etc/nftables.conf
    systemctl enable nftables --quiet
    systemctl restart nftables
    sleep 3

    if ss -ltn 2>/dev/null | grep -q ":${SSH_PORT}"; then
        [[ -n "${DEADMAN_JOB:-}" ]] && {
            atrm "$DEADMAN_JOB" 2>/dev/null
            rm -f "$_ROLLBACK_SCRIPT" 2>/dev/null || true
        }
        ok "Deadman disarmed — SSH alive :${SSH_PORT}"
        ok "nftables live  [SSH:${SSH_PORT} · WS:80 · panel:${XUI_PORT} · $(
            $NFT_SAFE_MODE && echo incremental || echo full)]"
    else
        warn "SSH :${SSH_PORT} ไม่ตอบ — deadman fires ใน <2 min"
        warn "ถ้า lock out: รอ 2 min auto-rollback หรือใช้ VPS console"
    fi
fi
rm -f "$NFT_TMP"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — DNSMASQ
# ══════════════════════════════════════════════════════════════════════════════

phase "DNS"
_confirm "ตั้ง dnsmasq DNS cache?" || warn "ข้าม DNS"
step "dnsmasq — resolver-safe migration"
run systemctl stop dnsmasq 2>/dev/null || true

if ! "$DRY_RUN"; then
    if ! command -v dnsmasq &>/dev/null; then
        warn "dnsmasq not installed — DNS step skipped"
    else
        chattr -i /etc/resolv.conf 2>/dev/null || true
        printf 'nameserver 127.0.0.1\noptions timeout:1 attempts:2\n' > /etc/resolv.conf
        ok "resolv.conf → 127.0.0.1"

        mkdir -p /etc/dnsmasq.d
        cat > /etc/dnsmasq.d/ais.conf << 'EOF'
# AIS WS VPS — dnsmasq config
no-resolv
server=1.1.1.1
server=1.0.0.1
cache-size=2000
neg-ttl=30
dns-forward-max=150
no-poll
bogus-priv
domain-needed
listen-address=127.0.0.1
bind-interfaces
# pin WS host ในกรณีที่ DNS ขัดข้อง ป้องกัน WS drop
# (อัปเดต IP ด้วย: dig th.speedtest.net +short)
EOF
        systemctl daemon-reload 2>/dev/null || true

        if systemctl cat dnsmasq.service &>/dev/null; then
            systemctl enable dnsmasq --quiet
            systemctl restart dnsmasq \
                && ok "dnsmasq ready  [127.0.0.1 → 1.1.1.1 / 1.0.0.1 · cache=2000]" || {
                warn "dnsmasq restart failed — check: journalctl -u dnsmasq -n 20"
                printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
            }
        else
            DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -qq dnsmasq 2>/dev/null \
                && systemctl daemon-reload \
                && systemctl enable dnsmasq --quiet \
                && systemctl restart dnsmasq \
                && ok "dnsmasq ready (reinstalled)" || {
                warn "dnsmasq unavailable — resolv.conf → 1.1.1.1 direct"
                printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
            }
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — ZRAM
# ══════════════════════════════════════════════════════════════════════════════

phase "MEMORY"
_confirm "เปิด ZRAM swap?" || warn "ข้าม ZRAM"
step "ZRAM compressed swap (256 MB)"

if $CAP_ZRAM; then
    if swapon --show 2>/dev/null | grep -q zram0; then
        ok "ZRAM already active — skipped (idempotent)"
    else
        run modprobe zram 2>/dev/null || true
        if ! "$DRY_RUN" && [[ -b /dev/zram0 ]]; then
            swapon --show 2>/dev/null | grep -q /dev/zram0 \
                || echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        fi

        run bash -c "cat > /etc/systemd/system/zram.service << 'EOF'
[Unit]
Description=ZRAM compressed swap 256MB
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    modprobe zram 2>/dev/null || true; \
    swapon --show 2>/dev/null | grep -q zram0 && exit 0; \
    [[ -b /dev/zram0 ]] && echo 1 > /sys/block/zram0/reset 2>/dev/null || true; \
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null \
        || echo lzo > /sys/block/zram0/comp_algorithm 2>/dev/null \
        || true; \
    echo 268435456 > /sys/block/zram0/disksize; \
    mkswap /dev/zram0 && swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
EOF"
        run systemctl daemon-reload
        run systemctl enable zram --quiet
        run systemctl start zram || warn "ZRAM start failed — activates on reboot"
        ok "ZRAM online  [256 MB · lz4/lzo · priority=100]"
    fi
else
    warn "ZRAM unavailable — skipped  (container VPS หรือ kernel ไม่รองรับ)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — X-UI TUNING
# GOGC=100 เหมาะกับ WS workload — GC บ่อยขึ้นนิดหน่อย แต่ pause สั้นกว่า
# GOMAXPROCS=1 เพราะ 1 vCPU
# ══════════════════════════════════════════════════════════════════════════════

phase "X-UI / XRAY"
_confirm "ปรับ x-ui systemd unit?" || warn "ข้าม x-ui tuning"
step "Tune x-ui systemd unit"

run mkdir -p /etc/systemd/system/x-ui.service.d
run bash -c "cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
# 1 vCPU — GOMAXPROCS=1 ลด goroutine scheduling overhead
Environment=GOMAXPROCS=1
# GOGC=100 (default) — balance GC pause vs memory สำหรับ WS workload
Environment=GOGC=100
LimitNOFILE=65536
LimitNPROC=4096
# OOMScoreAdjust ต่ำ = kernel จะ kill process อื่นก่อน x-ui
OOMScoreAdjust=-500
Restart=always
RestartSec=3
EOF"

run systemctl daemon-reload
run systemctl enable x-ui --quiet
run systemctl restart x-ui
ok "x-ui tuned  [GOMAXPROCS=1 · GOGC=100 · NOFILE=65536 · Restart=3s]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — THP
# ══════════════════════════════════════════════════════════════════════════════

step "Transparent HugePage → never"
run bash -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true"
run bash -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true"
ok "THP disabled  [ลด latency spike จาก memory defrag]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 13 — CPU GOVERNOR
# ══════════════════════════════════════════════════════════════════════════════

step "CPU governor → performance"
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    run bash -c "echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true"
    ok "CPU governor: performance"
else
    ok "CPU governor not exposed  (hypervisor-managed — ปกติบน KVM/OpenVZ VPS)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 14 — BOOT PERSISTENCE
# ══════════════════════════════════════════════════════════════════════════════

phase "BOOT PERSISTENCE"
_confirm "ตั้ง boot persistence (ais-net.service)?" || warn "ข้าม boot persistence"
step "ais-net.service"

QDISC_CMD=$($CAP_FQCODEL \
    && echo "tc qdisc add dev ${IFACE} root fq_codel limit 512 flows 512 target 20ms interval 200ms ecn" \
    || echo "tc qdisc add dev ${IFACE} root fq limit 512 flow_limit 50")

run bash -c "cat > /etc/systemd/system/ais-net.service << EOF
[Unit]
Description=AIS VPS Network Tuning (qdisc + THP)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    tc qdisc del dev ${IFACE} root 2>/dev/null || true; \
    ${QDISC_CMD}; \
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; \
    echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF"

run systemctl daemon-reload
run systemctl enable ais-net.service --quiet
ok "ais-net.service enabled  [survives reboot]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 15 — HOUSEKEEPING
# ══════════════════════════════════════════════════════════════════════════════

step "Housekeeping"
run mkdir -p /etc/systemd/journald.conf.d
run bash -c "printf '[Journal]\nSystemMaxUse=50M\nRuntimeMaxUse=20M\n' \
    > /etc/systemd/journald.conf.d/limit.conf"
run systemctl restart systemd-journald
for svc in apport ufw; do
    systemctl disable "$svc" 2>/dev/null || true
    systemctl stop    "$svc" 2>/dev/null || true
done
ok "Journal ≤50MB · apport/ufw disabled"

# ══════════════════════════════════════════════════════════════════════════════
# HEALTH CHECKS
# ══════════════════════════════════════════════════════════════════════════════

phase "HEALTH CHECKS"
FAIL_COUNT=0; PASS_COUNT=0

_check() {
    local label="$1" cmd="$2" t0
    t0=$(_now_ms)
    if eval "$cmd" &>/dev/null 2>&1; then
        printf "  ${BGRN}✔${RST}  %-46s ${DIM}%dms${RST}\n" "$label" "$(( $(_now_ms) - t0 ))"
        (( PASS_COUNT++ )) || true; _log OK "HEALTH: $label"
    else
        printf "  ${BRED}✖${RST}  %-46s ${BRED}FAIL${RST}\n" "$label"
        (( FAIL_COUNT++ )) || true; _log WARN "HEALTH FAIL: $label"
    fi
}

echo ""
if ! "$DRY_RUN"; then
    sleep 2
    _check "Network reachable (1.1.1.1)"            "ping -c1 -W3 1.1.1.1"
    _check "WS Host reachable (${WS_HOST})"          "ping -c1 -W5 ${WS_HOST}"
    _check "WS port 80 open on NIC"                  "ss -ltn | grep -q ':80'"
    _check "DNS resolving via dnsmasq"               "dig +short +timeout=3 google.com @127.0.0.1 | grep -qE '[0-9]'"
    _check "dnsmasq service active"                  "systemctl is-active dnsmasq | grep -q '^active'"
    _check "x-ui service active"                     "systemctl is-active x-ui | grep -q '^active'"
    _check "x-ui panel :${XUI_PORT} listening"       "ss -ltn | grep -q ':${XUI_PORT}'"
    _check "nftables ruleset loaded"                 "nft list ruleset | grep -q 'chain'"
    _check "BBR/cubic congestion control"            "sysctl -n net.ipv4.tcp_congestion_control | grep -qE 'bbr|cubic'"
    _check "fq_codel/fq qdisc applied"              "tc qdisc show dev $IFACE | grep -qE 'fq_codel|fq'"
    _check "ZRAM swap active"                        "swapon --show 2>/dev/null | grep -q zram || ! ${CAP_ZRAM}"
    _check "tcp_keepalive_time = 60"                 "sysctl -n net.ipv4.tcp_keepalive_time | grep -q '^60$'"
    _check "ECN enabled"                             "sysctl -n net.ipv4.tcp_ecn | grep -q '^1$'"
else
    info "[DRY] Health checks skipped"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# MISSION COMPLETE
# ══════════════════════════════════════════════════════════════════════════════

ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
ACTIVE_QDISC=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}' || echo unknown)

echo ""; _rule "═" "$BCYN"
printf "${BG_BLK}${BCYN}${BOLD}%*s  ◈  MISSION COMPLETE — VPS ONLINE  ◈  %*s${RST}\n" \
    "$(( ($(_cols) - 38) / 2 ))" "" "$(( ($(_cols) - 38) / 2 ))" ""
_rule "═" "$BCYN"; echo ""

printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}  ${DIM}CC=%s · qdisc=%s${RST}\n" \
    "Network"  "$IFACE" "$ACTIVE_CC" "$ACTIVE_QDISC"
printf "  ${DIM}%-24s${RST}  ${BWHT}nftables${RST}  ${DIM}SSH:${SSH_PORT} · WS:80 · panel:${XUI_PORT}${RST}\n" \
    "Firewall"
printf "  ${DIM}%-24s${RST}  ${BWHT}dnsmasq${RST}  ${DIM}127.0.0.1 → 1.1.1.1 / 1.0.0.1${RST}\n" \
    "DNS"
printf "  ${DIM}%-24s${RST}  ${BWHT}%s${RST}\n" \
    "ZRAM" "$($CAP_ZRAM && echo '256 MB (lz4/lzo · priority=100)' || echo 'unavailable on this VPS')"
printf "  ${DIM}%-24s${RST}  " "Health"
[[ $FAIL_COUNT -eq 0 ]] \
    && printf "${BGRN}✔ all %d checks passed${RST}\n" "$PASS_COUNT" \
    || printf "${BRED}✖ %d failed · %d passed — see above${RST}\n" "$FAIL_COUNT" "$PASS_COUNT"
printf "  ${DIM}%-24s${RST}  ${DIM}%s${RST}\n" "Log" "$LOG_FILE"

# ── 3x-ui panel access ──────────────────────────────────────────────────────
echo ""; _rule "─" "$DIM"; echo ""
printf "  ${BCYN}${BOLD}3X-UI PANEL ACCESS${RST}\n"
printf "  ${BWHT}http://%s:%s/<webBasePath>${RST}  ${DIM}(ดู webBasePath จาก installer output)${RST}\n" \
    "${PUBLIC_IP:-<YOUR-IP>}" "$XUI_PORT"
echo ""

# ── Inbound setup guide ─────────────────────────────────────────────────────
_rule "─" "$DIM"; echo ""
printf "  ${BCYN}${BOLD}ตั้งค่า Inbound ใน 3x-ui panel (สร้าง 2 inbound):${RST}\n\n"

printf "  ${BGRN}[Inbound 1]${RST}  VLESS + WebSocket\n"
printf "  ${DIM}  Protocol :${RST}  ${BWHT}VLESS${RST}\n"
printf "  ${DIM}  Port     :${RST}  ${BWHT}%s  (None TLS)${RST}\n"       "$WS_PORT"
printf "  ${DIM}  Network  :${RST}  ${BWHT}ws${RST}\n"
printf "  ${DIM}  WS Path  :${RST}  ${BWHT}%s${RST}\n"                   "$XUI_WS_PATH"
printf "  ${DIM}  WS Host  :${RST}  ${BWHT}%s${RST}\n"                   "$WS_HOST"
printf "  ${DIM}  TLS      :${RST}  ${BWHT}none${RST}\n"
echo ""

printf "  ${BGRN}[Inbound 2]${RST}  VMess + WebSocket\n"
printf "  ${DIM}  Protocol :${RST}  ${BWHT}VMess${RST}\n"
printf "  ${DIM}  Port     :${RST}  ${BWHT}%s  (None TLS)${RST}\n"       "$WS_PORT"
printf "  ${DIM}  Network  :${RST}  ${BWHT}ws${RST}\n"
printf "  ${DIM}  WS Path  :${RST}  ${BWHT}%s${RST}  ${DIM}(ใช้ path ต่างกันกับ VLESS เช่น /vmws)${RST}\n"  "$XUI_WS_PATH"
printf "  ${DIM}  WS Host  :${RST}  ${BWHT}%s${RST}\n"                   "$WS_HOST"
printf "  ${DIM}  TLS      :${RST}  ${BWHT}none${RST}\n"
echo ""

printf "  ${BYLW}⚠  VLESS และ VMess บน port 80 เดียวกันต้องใช้ WS Path ต่างกัน${RST}\n"
printf "     ${DIM}เช่น VLESS → /vws  │  VMess → /mws${RST}\n"

# ── Verify commands ─────────────────────────────────────────────────────────
echo ""; _rule "─" "$DIM"; echo ""
printf "  ${DIM}VERIFY    ${RST}tc qdisc show dev ${IFACE}  ${DIM}# ดู target=20ms${RST}\n"
printf "            ${DIM}sysctl net.ipv4.tcp_congestion_control${RST}\n"
printf "            ${DIM}sysctl net.ipv4.tcp_keepalive_time  # ต้องได้ 60${RST}\n"
printf "            ${DIM}sysctl net.ipv4.tcp_ecn             # ต้องได้ 1${RST}\n"
printf "            ${DIM}systemctl status x-ui dnsmasq${RST}\n"
printf "            ${DIM}nft list ruleset | grep dport${RST}\n"
printf "            ${DIM}swapon --show${RST}\n"
echo ""
printf "  ${DIM}WS TEST   ${RST}curl -v -H 'Host: ${WS_HOST}' http://${PUBLIC_IP:-<IP>}${XUI_WS_PATH}\n"
printf "            ${DIM}# ควรได้ HTTP 101 Switching Protocols ถ้า 3x-ui พร้อม${RST}\n"
echo ""
printf "  ${DIM}ROLLBACK  ${RST}sudo bash ais128k-ws-tuning.sh --rollback\n"
echo ""; _rule "─" "$DIM"
printf "\n  ${BYLW}⚠  REBOOT เพื่อให้ sysctl + ZRAM + ais-net.service มีผลสมบูรณ์${RST}\n\n"
_rule "═" "$BCYN"; echo ""
printf '\a'
