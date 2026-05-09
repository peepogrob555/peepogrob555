#!/usr/bin/env bash
# ██████████████████████████████████████████████████████████████████████████████
#
#   ░█████╗░██╗░██████╗  ██╗░░░██╗██████╗░░██████╗
#   ██╔══██╗██║██╔════╝  ██║░░░██║██╔══██╗██╔════╝
#   ███████║██║╚█████╗░  ╚██╗░██╔╝██████╔╝╚█████╗░
#   ██╔══██║██║░╚═══██╗  ░╚████╔╝░██╔═══╝░░╚═══██╗
#   ██║░░██║██║██████╔╝  ░░╚██╔╝░░██║░░░░░██████╔╝
#   ╚═╝░░╚═╝╚═╝╚═════╝░  ░░░╚═╝░░░╚═╝░░░░░╚═════╝░
#
#   128 kbps · Thailand VPS · VLESS Reality · 3x-ui · v2.1
#
#   USAGE  : sudo bash ais128k-tuning.sh [--dry-run | --rollback]
# ██████████████████████████████████████████████████████████████████████████████

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# TERMINAL PALETTE
# ══════════════════════════════════════════════════════════════════════════════

RST='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[0;31m'; BRED='\033[1;31m'
GRN='\033[0;32m'; BGRN='\033[1;32m'
YLW='\033[0;33m'; BYLW='\033[1;33m'
CYN='\033[0;36m'; BCYN='\033[1;36m'
WHT='\033[0;37m'; BWHT='\033[1;37m'
BG_BLK='\033[40m'; BG_YLW='\033[43m'
BLK='\033[0;30m'

# ══════════════════════════════════════════════════════════════════════════════
# GLOBALS
# ══════════════════════════════════════════════════════════════════════════════

DRY_RUN=false
LOG_FILE="/var/log/ais128k-tuning.log"
BACKUP_DIR="/etc/ais128k-backup"
STEP_NUM=0
STEP_TOTAL=14
PHASE_START_MS=0

# ══════════════════════════════════════════════════════════════════════════════
# TUI ENGINE
# ══════════════════════════════════════════════════════════════════════════════

_now_ms() { date +%s%3N; }
_log()    { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }

_cols()   { tput cols 2>/dev/null || echo 80; }

_rule() {
    local char="${1:--}" color="${2:-$DIM}"
    local line; line=$(printf "%$(_cols)s" | tr ' ' "$char")
    echo -e "${color}${line}${RST}"
}

phase() {
    PHASE_START_MS=$(_now_ms)
    local title="$1"
    local cols; cols=$(_cols)
    local inner=$(( cols - 4 ))
    local pad=$(( (inner - ${#title} - 6) / 2 ))
    echo ""
    _rule "═" "$BCYN"
    printf "${BG_BLK}${BCYN}${BOLD}%${pad}s  ◈  %s  ◈  %${pad}s${RST}\n" "" "$title" ""
    _rule "═" "$BCYN"
    _log INFO "=== PHASE: $title ==="
}

step() {
    (( STEP_NUM++ )) || true
    local pct=$(( STEP_NUM * 100 / STEP_TOTAL ))
    local filled=$(( pct * 24 / 100 ))
    local bar="" i
    for (( i=0; i<filled; i++ ));      do bar+="█"; done
    for (( i=filled; i<24; i++ ));   do bar+="░"; done
    printf "\n${BCYN}  [%02d/%02d]${RST}  ${BOLD}%s${RST}\n" "$STEP_NUM" "$STEP_TOTAL" "$1"
    printf "          ${DIM}[${RST}${BGRN}%s${RST}${DIM}] %3d%%${RST}\n" "$bar" "$pct"
    _log INFO "STEP $STEP_NUM/$STEP_TOTAL: $1"
}

ok() {
    local elapsed=$(( $(_now_ms) - PHASE_START_MS ))
    printf "  ${BGRN}✔${RST}  %-50s ${DIM}+%dms${RST}\n" "$*" "$elapsed"
    _log OK "$*"
}
info() { printf "  ${BCYN}·${RST}  %s\n" "$*"; _log INFO "$*"; }
warn() { printf "  ${BYLW}⚠${RST}  ${BYLW}%s${RST}\n" "$*"; _log WARN "$*"; }
die()  { printf "\n  ${BRED}✖  FATAL: %s${RST}\n\n" "$*" >&2; _log FAIL "$*"; exit 1; }

spinner() {
    local pid=$1 label="${2:-working}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BCYN}%s${RST}  %s..." "${frames[$((i % 10))]}" "$label"
        (( i++ )) || true
        sleep 0.08
    done
    printf "\r%-70s\r" ""
}

run() {
    if "$DRY_RUN"; then
        printf "  ${BYLW}○${RST}  ${DIM}[DRY]${RST} %s\n" "$*"
        return 0
    fi
    "$@"
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
printf "    ${DIM}128 kbps · Thailand VPS · VLESS Reality · 3x-ui · v2.1${RST}\n\n"
_rule "─" "$DIM"
echo ""

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
        sleep 0.4
        ;;
    --rollback) : ;;
    "") : ;;
    *) die "Usage: $0 [--dry-run|--rollback]" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# ROLLBACK
# ══════════════════════════════════════════════════════════════════════════════

if [[ "${1:-}" == "--rollback" ]]; then
    phase "ROLLBACK"
    [[ -d "$BACKUP_DIR" ]] || die "No backup at $BACKUP_DIR"

    local_job=$(atq 2>/dev/null | awk '{print $1}' | head -1)
    [[ -n "${local_job:-}" ]] && { atrm "$local_job" 2>/dev/null; ok "Deadman timer cancelled (job #$local_job)"; }

    if [[ -f "$BACKUP_DIR/resolv.conf.meta" ]]; then
        mode=$(cat "$BACKUP_DIR/resolv.conf.meta")
        chattr -i /etc/resolv.conf 2>/dev/null || true
        case "$mode" in
            symlink:*)
                target="${mode#symlink:}"
                rm -f /etc/resolv.conf
                ln -sf "$target" /etc/resolv.conf
                ok "resolv.conf symlink restored → $target"
                ;;
            file)
                cp "$BACKUP_DIR/resolv.conf" /etc/resolv.conf
                ok "resolv.conf static file restored"
                ;;
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
    ok "ais-net + zram services disabled"

    [[ -f /etc/systemd/system/x-ui.service.d/override.conf ]] && {
        rm -f /etc/systemd/system/x-ui.service.d/override.conf
        systemctl daemon-reload
        systemctl restart x-ui 2>/dev/null || true
        ok "x-ui override removed"
    }

    echo ""
    _rule "═" "$BGRN"
    printf "${BGRN}${BOLD}  ROLLBACK COMPLETE${RST}  — reboot recommended\n"
    _rule "═" "$BGRN"
    echo ""
    exit 0
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

echo ""
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Interface"   "$IFACE"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Public IP"   "${PUBLIC_IP:-unknown}"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "SSH Port"    "$SSH_PORT"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "Kernel"      "$(uname -r)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "OS"          "$(lsb_release -ds 2>/dev/null || uname -s)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "RAM"         "$(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
printf "  ${DIM}%-20s${RST}  ${BWHT}%s${RST}\n" "vCPU"        "$(nproc) × $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo ""

HAS_DOCKER=false; HAS_WIREGUARD=false; HAS_TAILSCALE=false
systemctl is-active docker     &>/dev/null && HAS_DOCKER=true
systemctl is-active wg-quick@* &>/dev/null && HAS_WIREGUARD=true
systemctl is-active tailscaled &>/dev/null && HAS_TAILSCALE=true

NFT_SAFE_MODE=false
$HAS_DOCKER    && { warn "Docker detected    → nftables incremental mode"; NFT_SAFE_MODE=true; }
$HAS_WIREGUARD && { warn "WireGuard detected → nftables incremental mode"; NFT_SAFE_MODE=true; }
$HAS_TAILSCALE && { warn "Tailscale detected → nftables incremental mode"; NFT_SAFE_MODE=true; }
$NFT_SAFE_MODE || info "No conflicting stacks → full nftables ruleset"

if [[ -L /etc/resolv.conf ]]; then
    RESOLVER_MODE="symlink"
    RESOLVER_TARGET=$(readlink -f /etc/resolv.conf)
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
        printf "  ${BGRN}✔${RST}  %-22s ${BGRN}AVAILABLE${RST}\n" "$name"
        return 0
    else
        printf "  ${BYLW}–${RST}  %-22s ${DIM}not supported${RST}\n" "$name"
        return 1
    fi
}

echo ""
_cap "BBR"      "sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr" && CAP_BBR=true
_cap "fq_codel" "tc qdisc add dev lo root fq_codel 2>/dev/null; tc qdisc del dev lo root 2>/dev/null" && CAP_FQCODEL=true
_cap "ZRAM"     "modprobe -n zram" && CAP_ZRAM=true
_cap "nftables" "command -v nft"
echo ""
ok "Probe complete"

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

[[ -f /etc/nftables.conf ]]             && run cp /etc/nftables.conf "$BACKUP_DIR/nftables.conf" || true
[[ -f /etc/sysctl.d/99-ais-128k.conf ]] && run cp /etc/sysctl.d/99-ais-128k.conf "$BACKUP_DIR/99-ais-128k.conf" || true
ok "Backup saved → $BACKUP_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — PACKAGES
# ══════════════════════════════════════════════════════════════════════════════

phase "PACKAGES"
step "Install dependencies"

# ── Step 1a: stop resolved & set temporary resolver BEFORE touching apt ──────
run systemctl stop systemd-resolved    2>/dev/null || true
run systemctl disable systemd-resolved 2>/dev/null || true

if ! "$DRY_RUN"; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    # Always write a known-good static resolver so apt can reach mirrors
    rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true   # pin — dnsmasq will unpin later
    info "Temporary resolver → 1.1.1.1 / 1.0.0.1 (pinned for apt)"

    # Flush any stale apt lists from a broken mirror session
    rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
fi

# ── Step 1b: apt-get update + install ────────────────────────────────────────
# Required packages: script will die if these are missing after install
APT_REQUIRED="curl wget ethtool dnsmasq sqlite3 jq nftables dnsutils ca-certificates iproute2 iputils-ping"
# Optional packages: installed if available; absence is warned, not fatal
APT_OPTIONAL="cron socat at"

if ! "$DRY_RUN"; then
    APT_LOG=$(mktemp /tmp/ais-apt-XXXXXX.log)

    # Update package index — retry once with main Ubuntu mirrors if custom mirror fails
    { apt-get update -qq 2>&1 || \
      { warn "apt update had errors — retrying with Ubuntu default mirrors"
        sed -i 's|http://mirrors\.bangmod\.cloud/ubuntu|http://archive.ubuntu.com/ubuntu|g' \
            /etc/apt/sources.list 2>/dev/null || true
        apt-get update -qq 2>&1; }
    } >> "$APT_LOG" 2>&1 &
    spinner $! "apt update"

    # Install required packages — die on failure
    { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_REQUIRED 2>&1; } \
        >> "$APT_LOG" 2>&1 &
    spinner $! "apt install (required)"
    wait $! || { cat "$APT_LOG" >&2; die "apt install failed for required packages — see log above"; }

    # Install optional packages — warn only
    { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $APT_OPTIONAL 2>&1; } \
        >> "$APT_LOG" 2>&1 || \
        warn "Optional packages ($APT_OPTIONAL) not fully installed — deadman timer may be unavailable"
    rm -f "$APT_LOG"

    # Verify critical binaries exist
    for bin in nft dnsmasq sqlite3; do
        command -v "$bin" &>/dev/null || die "Binary '$bin' not found after install — cannot continue"
    done
else
    info "[DRY] apt-get install $APT_REQUIRED $APT_OPTIONAL"
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
# STEP 3 — 3X-UI  (interactive-safe)
# ══════════════════════════════════════════════════════════════════════════════

phase "3X-UI PANEL"
step "Collect panel settings before installer runs"

# ── รับค่าจากผู้ใช้ก่อนเรียก installer ────────────────────────────────────────
# installer ของ 3x-ui มี interactive prompt (โดเมน, port, ฯลฯ)
# เราถามเองก่อน แล้วตอบ prompt ผ่าน expect หรือ pipe อัตโนมัติ

if ! "$DRY_RUN"; then
    echo ""
    _rule "─" "$BCYN"
    printf "  ${BCYN}${BOLD}กรอกค่าสำหรับ 3X-UI Panel${RST}\n"
    _rule "─" "$BCYN"
    echo ""

    # Panel port
    while true; do
        printf "  ${BWHT}Panel port${RST} ${DIM}(default: 2053):${RST} "
        read -r XUI_PORT </dev/tty
        XUI_PORT="${XUI_PORT:-2053}"
        if [[ "$XUI_PORT" =~ ^[0-9]+$ ]] && (( XUI_PORT >= 1 && XUI_PORT <= 65535 )); then
            break
        fi
        printf "  ${BRED}ต้องเป็นตัวเลข 1-65535${RST}\n"
    done

    # Panel path (web base path)
    printf "  ${BWHT}Panel path${RST} ${DIM}(default: /):${RST} "
    read -r XUI_PATH </dev/tty
    XUI_PATH="${XUI_PATH:-/}"
    # ทำให้ขึ้นต้นด้วย / เสมอ
    [[ "$XUI_PATH" == /* ]] || XUI_PATH="/$XUI_PATH"

    # Username
    printf "  ${BWHT}Username${RST} ${DIM}(default: admin):${RST} "
    read -r XUI_USER </dev/tty
    XUI_USER="${XUI_USER:-admin}"

    # Password (ซ่อน input)
    while true; do
        printf "  ${BWHT}Password${RST} ${DIM}(min 6 ตัว):${RST} "
        read -rs XUI_PASS </dev/tty; echo ""
        (( ${#XUI_PASS} >= 6 )) && break
        printf "  ${BRED}รหัสผ่านสั้นเกินไป${RST}\n"
    done

    echo ""
    printf "  ${DIM}Port  :${RST} ${BWHT}%s${RST}\n" "$XUI_PORT"
    printf "  ${DIM}Path  :${RST} ${BWHT}%s${RST}\n" "$XUI_PATH"
    printf "  ${DIM}User  :${RST} ${BWHT}%s${RST}\n" "$XUI_USER"
    printf "  ${DIM}Pass  :${RST} ${BWHT}%s${RST}\n" "$(printf '%*s' ${#XUI_PASS} | tr ' ' '*')"
    echo ""
    printf "  ${BYLW}ยืนยันค่าข้างต้น? [Y/n]:${RST} "
    read -r _confirm </dev/tty
    [[ "${_confirm:-Y}" =~ ^[Yy]$ ]] || die "ยกเลิกโดยผู้ใช้ — รันใหม่เพื่อกรอกค่าอีกครั้ง"
    _rule "─" "$DIM"
    echo ""
else
    XUI_PORT=2053; XUI_PATH="/"; XUI_USER="admin"; XUI_PASS="admin123"
    info "[DRY] Panel port=$XUI_PORT path=$XUI_PATH user=$XUI_USER"
fi

step "Install / update 3x-ui"

if "$DRY_RUN"; then
    info "[DRY] bash <(curl -Ls .../install.sh)"
else
    # ดาวน์โหลด installer ก่อน แล้วค่อยรัน foreground เต็มๆ (ไม่ background)
    # เพื่อให้ TTY ส่งผ่านได้ปกติ — spinner ไม่ถูกใช้ที่นี่โดยตั้งใจ
    XUI_INSTALL_SCRIPT=$(mktemp /tmp/xui-install-XXXXXX.sh)
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
        -o "$XUI_INSTALL_SCRIPT" 2>/dev/null \
        || die "ดาวน์โหลด 3x-ui installer ล้มเหลว — ตรวจสอบ internet"
    chmod +x "$XUI_INSTALL_SCRIPT"

    info "กำลังรัน 3x-ui installer (foreground)..."
    echo ""
    bash "$XUI_INSTALL_SCRIPT"
    rm -f "$XUI_INSTALL_SCRIPT"
fi
ok "3x-ui installed / updated"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — PANEL PORT / USER / PATH (sqlite3 patch หลัง install)
# ══════════════════════════════════════════════════════════════════════════════

step "Apply panel settings → port:${XUI_PORT} path:${XUI_PATH} user:${XUI_USER}"
X_UI_DB="/etc/x-ui/x-ui.db"

if ! "$DRY_RUN"; then
    # รอให้ x-ui สร้าง DB ถ้าเพิ่ง install ครั้งแรก (max 10 วิ)
    for _i in $(seq 1 10); do
        [[ -f "$X_UI_DB" ]] && break
        sleep 1
    done

    if [[ -f "$X_UI_DB" ]]; then
        run systemctl stop x-ui 2>/dev/null || true
        sleep 1

        # Patch settings ผ่าน sqlite3
        _db_set() {
            local key="$1" val="$2"
            if sqlite3 "$X_UI_DB" "SELECT key FROM settings WHERE key='${key}';" 2>/dev/null \
                    | grep -q "${key}"; then
                sqlite3 "$X_UI_DB" "UPDATE settings SET value='${val}' WHERE key='${key}';"
                ok "  DB: ${key} → ${val}"
            else
                # key ไม่มี → INSERT
                sqlite3 "$X_UI_DB" "INSERT INTO settings(key,value) VALUES('${key}','${val}');" 2>/dev/null \
                    && ok "  DB: ${key} → ${val} (inserted)" \
                    || warn "  DB: ไม่พบ key '${key}' — ตั้งค่าใน panel เอง"
            fi
        }

        _db_set "webPort"     "$XUI_PORT"
        _db_set "webBasePath" "$XUI_PATH"
        _db_set "webUsername" "$XUI_USER"
        _db_set "webPassword" "$XUI_PASS"

        run systemctl start x-ui
        ok "Panel settings applied  [port:${XUI_PORT} · path:${XUI_PATH} · user:${XUI_USER}]"
    else
        warn "x-ui.db ยังไม่ถูกสร้าง — ตั้งค่า port/user ใน panel เอง"
    fi
else
    info "[DRY] sqlite3 patch: port=$XUI_PORT path=$XUI_PATH user=$XUI_USER"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — SYSCTL
# ══════════════════════════════════════════════════════════════════════════════

phase "KERNEL TUNING"
step "Write sysctl (kernel-aware)"

CC_CHOICE=$(if $CAP_BBR; then echo bbr; else echo cubic; fi)
QD_CHOICE=$(if $CAP_FQCODEL; then echo fq_codel; else echo fq; fi)

if ! "$DRY_RUN"; then
SYSCTL_CONTENT="# AIS 128kbps VPS — Low Latency Tuning
# Generated: $(date)
# Keys verified against running kernel

# ── Congestion Control ──────────────────────────────
net.core.default_qdisc          = ${QD_CHOICE}
net.ipv4.tcp_congestion_control = ${CC_CHOICE}

# ── TCP Buffers ─────────────────────────────────────
net.core.rmem_max     = 16777216
net.core.wmem_max     = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem     = 4096 87380 16777216
net.ipv4.tcp_wmem     = 4096 65536 16777216

# ── TCP Latency ─────────────────────────────────────
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_notsent_lowat         = 16384
net.ipv4.tcp_autocorking           = 0
net.ipv4.tcp_moderate_rcvbuf       = 1
net.ipv4.tcp_sack                  = 1
net.ipv4.tcp_timestamps            = 1
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_rfc1337               = 1

# ── Connections ─────────────────────────────────────
net.core.somaxconn            = 4096
net.core.netdev_max_backlog   = 4096
net.ipv4.tcp_max_syn_backlog  = 4096
net.ipv4.tcp_fin_timeout      = 15
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 3

# ── Conntrack (VPN / proxy) ─────────────────────────
net.netfilter.nf_conntrack_max                     = 65535
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30

# ── Memory (1 GB RAM) ───────────────────────────────
vm.swappiness             = 10
vm.vfs_cache_pressure     = 50
vm.dirty_ratio            = 15
vm.dirty_background_ratio = 5

# ── Security ────────────────────────────────────────
net.ipv4.tcp_syncookies              = 1
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

# ── Forwarding (proxy / VPN) ────────────────────────
net.ipv4.ip_forward = 1
"
    if sysctl -n net.ipv4.tcp_fastopen &>/dev/null 2>&1; then
        SYSCTL_CONTENT+=$'\nnet.ipv4.tcp_fastopen = 3\n'
    else
        warn "tcp_fastopen unavailable on this kernel — skipped"
    fi
    echo "$SYSCTL_CONTENT" > /etc/sysctl.d/99-ais-128k.conf
fi

run sysctl --system -q 2>/dev/null
ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
ok "sysctl applied  [CC=${ACTIVE_CC}  qdisc=${QD_CHOICE}]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — QDISC
# ══════════════════════════════════════════════════════════════════════════════

step "Set qdisc → $QD_CHOICE"
run tc qdisc del dev "$IFACE" root 2>/dev/null || true

if $CAP_FQCODEL; then
    run tc qdisc add dev "$IFACE" root fq_codel limit 1024 flows 1024 target 10ms interval 100ms ecn
    ok "fq_codel  target=10ms · ecn=on · no bandwidth cap"
else
    run tc qdisc add dev "$IFACE" root fq limit 1024 flow_limit 100
    warn "fq_codel unavailable → fq fallback"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — NFTABLES (transactional + deadman)
# ══════════════════════════════════════════════════════════════════════════════

phase "FIREWALL"
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
        ip  protocol icmp icmp  type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr  icmpv6     accept
        tcp dport ${SSH_PORT} ct state new limit rate 10/minute accept
        tcp dport 443  accept
        tcp dport 2053 accept
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
        ip  protocol icmp icmp  type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr  icmpv6     accept
        tcp dport ${SSH_PORT} ct state new limit rate 10/minute accept
        tcp dport 443  accept
        tcp dport 2053 accept
        log prefix "nft-drop: " flags all limit rate 5/minute
        drop
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output  priority 0; policy accept; }
}
NFTEOF
fi

if ! "$DRY_RUN"; then
    nft -c -f "$NFT_TMP" 2>/dev/null || { rm -f "$NFT_TMP"; die "nftables syntax validation failed — ruleset NOT applied"; }
    ok "Syntax validated (nft -c)"

    # ── Deadman rollback ──────────────────────────────────────────────────
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
        info "Deadman armed  (at job #${DEADMAN_JOB} · fires in 2 min if SSH lost)"
    fi

    cp "$NFT_TMP" /etc/nftables.conf
    systemctl enable nftables --quiet
    systemctl restart nftables
    sleep 3

    if ss -ltn 2>/dev/null | grep -q ":${SSH_PORT}"; then
        [[ -n "$DEADMAN_JOB" ]] && {
            atrm "$DEADMAN_JOB" 2>/dev/null
            rm -f "$_ROLLBACK_SCRIPT" 2>/dev/null || true
        }
        ok "Deadman disarmed — SSH alive :${SSH_PORT}"
        ok "nftables live  [SSH:${SSH_PORT} · 443 · 2053 · $(if $NFT_SAFE_MODE; then echo incremental; else echo full; fi)]"
    else
        warn "SSH :${SSH_PORT} not detected — deadman fires in <2 min"
        warn "If locked out: wait 2 min for auto-rollback OR use VPS console"
    fi
fi
rm -f "$NFT_TMP"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — DNSMASQ
# ══════════════════════════════════════════════════════════════════════════════

phase "DNS"
step "dnsmasq — resolver-safe migration"

run systemctl stop dnsmasq 2>/dev/null || true

if ! "$DRY_RUN"; then
    # Guard: dnsmasq binary must exist (apt install may have failed for optional pkgs)
    if ! command -v dnsmasq &>/dev/null; then
        warn "dnsmasq not installed — DNS step skipped; resolv.conf left pointing to 1.1.1.1"
        _log WARN "dnsmasq missing — DNS phase skipped"
    else
        # Unpin resolv.conf that was locked during apt phase
        chattr -i /etc/resolv.conf 2>/dev/null || true
        # resolv.conf was already converted to static file in apt phase; just update it
        printf 'nameserver 127.0.0.1\noptions timeout:1 attempts:2\n' > /etc/resolv.conf
        ok "resolv.conf → 127.0.0.1"

        mkdir -p /etc/dnsmasq.d
        cat > /etc/dnsmasq.d/ais.conf << 'EOF'
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
EOF

        # systemctl enable will error if unit file absent — check first
        if systemctl list-unit-files dnsmasq.service &>/dev/null | grep -q dnsmasq; then
            systemctl enable dnsmasq --quiet
            systemctl restart dnsmasq
            ok "dnsmasq ready  [127.0.0.1 → 1.1.1.1 / 1.0.0.1 · cache=2000]"
        else
            warn "dnsmasq.service unit not found — service not enabled (resolv.conf still → 1.1.1.1)"
            printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
        fi
    fi
else
    run mkdir -p /etc/dnsmasq.d
    run bash -c "cat > /etc/dnsmasq.d/ais.conf << 'EOF'
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
EOF"
    run systemctl enable dnsmasq --quiet
    run systemctl restart dnsmasq
    ok "dnsmasq ready  [127.0.0.1 → 1.1.1.1 / 1.0.0.1 · cache=2000]"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — ZRAM
# ══════════════════════════════════════════════════════════════════════════════

phase "MEMORY"
step "ZRAM compressed swap (256 MB)"

if $CAP_ZRAM; then
    if swapon --show 2>/dev/null | grep -q zram0; then
        ok "ZRAM already active — skipped (idempotent)"
    else
        run modprobe zram 2>/dev/null || true

        if ! "$DRY_RUN" && [[ -b /dev/zram0 ]]; then
            swapon --show 2>/dev/null | grep -q /dev/zram0 || \
                echo 1 > /sys/block/zram0/reset 2>/dev/null || true
        fi

        run bash -c "cat > /etc/systemd/system/zram.service << 'EOF'
[Unit]
Description=ZRAM compressed swap (256MB)
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
        run systemctl start zram || warn "ZRAM start failed — activates on next reboot"
        ok "ZRAM online  [256 MB · lz4/lzo · priority=100]"
    fi
else
    warn "ZRAM: kernel module unavailable — skipped"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — X-UI TUNING
# ══════════════════════════════════════════════════════════════════════════════

phase "X-UI / XRAY"
step "Tune x-ui systemd unit"

run mkdir -p /etc/systemd/system/x-ui.service.d
run bash -c "cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
Environment=GOMAXPROCS=1
Environment=GOGC=80
LimitNOFILE=65536
LimitNPROC=4096
OOMScoreAdjust=-500
Restart=always
RestartSec=3
EOF"

run systemctl daemon-reload
run systemctl enable x-ui --quiet
run systemctl restart x-ui
ok "x-ui tuned  [GOMAXPROCS=1 · GOGC=80 · LimitNOFILE=65536 · Restart=3s]"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 11 — THP
# ══════════════════════════════════════════════════════════════════════════════

step "Transparent HugePage → never"
run bash -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true"
run bash -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true"
ok "THP disabled"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 12 — CPU GOVERNOR
# ══════════════════════════════════════════════════════════════════════════════

step "CPU governor → performance"
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    run bash -c "echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true"
    ok "CPU governor: performance"
else
    ok "CPU governor not exposed (hypervisor-managed — normal for KVM VPS)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 13 — BOOT PERSISTENCE
# ══════════════════════════════════════════════════════════════════════════════

phase "BOOT PERSISTENCE"
step "ais-net.service"

QDISC_CMD=$(if $CAP_FQCODEL; then
    echo "tc qdisc add dev ${IFACE} root fq_codel limit 1024 flows 1024 target 10ms interval 100ms ecn"
else
    echo "tc qdisc add dev ${IFACE} root fq limit 1024 flow_limit 100"
fi)

run bash -c "cat > /etc/systemd/system/ais-net.service << EOF
[Unit]
Description=AIS VPS Network Tuning (qdisc + THP)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'tc qdisc del dev ${IFACE} root 2>/dev/null || true; \\
    ${QDISC_CMD}; \\
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; \\
    echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF"

run systemctl daemon-reload
run systemctl enable ais-net.service --quiet
ok "ais-net.service enabled (survives reboot)"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 14 — HOUSEKEEPING
# ══════════════════════════════════════════════════════════════════════════════

step "Housekeeping"
run mkdir -p /etc/systemd/journald.conf.d
run bash -c "printf '[Journal]\nSystemMaxUse=50M\nRuntimeMaxUse=20M\n' > /etc/systemd/journald.conf.d/limit.conf"
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
    local label="$1" cmd="$2"
    local t0; t0=$(_now_ms)
    if eval "$cmd" &>/dev/null 2>&1; then
        printf "  ${BGRN}✔${RST}  %-42s ${DIM}%dms${RST}\n" "$label" "$(( $(_now_ms) - t0 ))"
        (( PASS_COUNT++ )) || true
        _log OK "HEALTH: $label"
    else
        printf "  ${BRED}✖${RST}  %-42s ${BRED}FAIL — verify manually${RST}\n" "$label"
        (( FAIL_COUNT++ )) || true
        _log WARN "HEALTH FAIL: $label"
    fi
}

echo ""
if ! "$DRY_RUN"; then
    sleep 2
    _check "Network reachable (1.1.1.1)"     "ping -c1 -W3 1.1.1.1"
    _check "DNS resolving via dnsmasq"        "dig +short +timeout=3 google.com @127.0.0.1 | grep -qE '[0-9]'"
    _check "dnsmasq service active"           "systemctl is-active dnsmasq | grep -q '^active'"
    _check "x-ui service active"              "systemctl is-active x-ui | grep -q '^active'"
    _check "x-ui panel :2053 listening"       "ss -ltn | grep -q ':2053'"
    _check "Proxy :443 listening"             "ss -ltn | grep -q ':443'"
    _check "nftables ruleset loaded"          "nft list ruleset | grep -q 'chain'"
    _check "Congestion control (BBR/cubic)"   "sysctl -n net.ipv4.tcp_congestion_control | grep -qE 'bbr|cubic'"
    _check "qdisc (fq_codel/fq) applied"     "tc qdisc show dev $IFACE | grep -qE 'fq_codel|fq'"
    _check "ZRAM swap active"                 "swapon --show 2>/dev/null | grep -q zram || ! ${CAP_ZRAM}"
else
    info "[DRY] Health checks skipped"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# MISSION COMPLETE
# ══════════════════════════════════════════════════════════════════════════════

ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
ACTIVE_QDISC=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}' || echo unknown)

echo ""
_rule "═" "$BCYN"
printf "${BG_BLK}${BCYN}${BOLD}%*s  ◈  MISSION COMPLETE — VPS ONLINE  ◈  %*s${RST}\n" \
    "$(( ($(_cols) - 38) / 2 ))" "" "$(( ($(_cols) - 38) / 2 ))" ""
_rule "═" "$BCYN"
echo ""

printf "  ${DIM}%-22s${RST}  ${BWHT}%s${RST}  ${DIM}CC=%s · qdisc=%s${RST}\n" \
    "Network" "$IFACE" "$ACTIVE_CC" "$ACTIVE_QDISC"
printf "  ${DIM}%-22s${RST}  ${BWHT}nftables${RST}  ${DIM}SSH:%s · 443 · 2053 · %s${RST}\n" \
    "Firewall" "$SSH_PORT" "$(if $NFT_SAFE_MODE; then echo incremental; else echo full; fi)"
printf "  ${DIM}%-22s${RST}  ${BWHT}dnsmasq${RST}  ${DIM}127.0.0.1 → 1.1.1.1 / 1.0.0.1${RST}\n" \
    "DNS"
printf "  ${DIM}%-22s${RST}  ${BWHT}%s${RST}\n" \
    "ZRAM" "$(if $CAP_ZRAM; then echo '256 MB (lz4/lzo · priority=100)'; else echo 'unavailable on this VPS'; fi)"
printf "  ${DIM}%-22s${RST}  " "Health"
if [[ $FAIL_COUNT -eq 0 ]]; then
    printf "${BGRN}✔ all %d checks passed${RST}\n" "$PASS_COUNT"
else
    printf "${BRED}✖ %d failed · %d passed — see above${RST}\n" "$FAIL_COUNT" "$PASS_COUNT"
fi
printf "  ${DIM}%-22s${RST}  ${DIM}%s${RST}\n" "Log" "$LOG_FILE"

echo ""
_rule "─" "$DIM"
echo ""
printf "  ${BCYN}${BOLD}3X-UI PANEL${RST}\n"
printf "  ${BWHT}http://${PUBLIC_IP}:2053${RST}\n"
printf "  ${DIM}สร้าง Inbound → VLESS → Reality ใน panel${RST}\n"
echo ""
_rule "─" "$DIM"
echo ""
printf "  ${DIM}VERIFY  ${RST}tc qdisc show dev ${IFACE}\n"
printf "          ${DIM}sysctl net.ipv4.tcp_congestion_control${RST}\n"
printf "          ${DIM}systemctl status x-ui dnsmasq${RST}\n"
printf "          ${DIM}nft list ruleset · swapon --show${RST}\n"
echo ""
printf "  ${DIM}ROLLBACK  ${RST}sudo bash ais128k-tuning.sh --rollback\n"
echo ""
_rule "─" "$DIM"
printf "\n  ${BYLW}⚠  REBOOT เพื่อให้ sysctl + ZRAM + ais-net.service มีผลสมบูรณ์${RST}\n\n"
_rule "═" "$BCYN"
echo ""

printf '\a'   # terminal bell
