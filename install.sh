#!/usr/bin/env bash
# =============================================================================
# 3x-ui Gaming VPN — Production-Grade Narrowband Stack
# Version : 3.0-production
# Target  : Ubuntu 22.04/24.04 KVM — 128kbps/user adaptive — 2 users
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------
readonly SCRIPT_VER="3.0-production"
readonly LOG=/var/log/3x-ui-gaming.log
readonly BACKUP_DIR=/var/backups/3x-ui-gaming
readonly CERT_DIR=/etc/ssl/xray
readonly SWAP_FILE=/swapfile
readonly SWAP_SIZE_MB=1024
readonly IFB_DEV=ifb0
readonly QDISC_SCRIPT=/usr/local/bin/apply-qdisc.sh
readonly SLICE_CONF=/etc/systemd/system/xray.slice
readonly XUI_OVERRIDE=/etc/systemd/system/x-ui.service.d/override.conf
readonly SYSCTL_FILE=/etc/sysctl.d/99-gaming.conf
readonly NFT_CONF=/etc/nftables.conf
readonly NFT_BACKUP="${BACKUP_DIR}/nftables.conf.bak"
readonly ROLLBACK_DELAY_MIN=3

# FIX: ใช้ main branch แทน commit hash ที่ 404
readonly XUI_SCRIPT_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/main/install.sh"
readonly XUI_SCRIPT_SHA256="SKIP"
# ใช้สำหรับ display เท่านั้น
XUI_VERSION_LABEL="main"

# -----------------------------------------------------------------------------
# COLORS
# -----------------------------------------------------------------------------
BGRN='\033[1;32m'; BCYN='\033[1;36m'; BYLW='\033[1;33m'
BRED='\033[1;31m'; BMAG='\033[1;35m'; RST='\033[0m'

# -----------------------------------------------------------------------------
# STATE
# -----------------------------------------------------------------------------
IFACE=""
VIRT_TYPE="unknown"
VIRT_RESTRICTED=0
DNS_BEST=""
DNS_BEST_MS="9999"
QDISC_APPLIED="none"
CAKE_AVAILABLE=0
BBR_AVAILABLE=0
IFB_AVAILABLE=0
AT_JOB_ID=""
SERVER_IP=""
SERVER_DOMAIN=""
SSH_PORT=""
ADMIN_IP=""
CERT_EXPIRY="unknown"
TOTAL_RAM_MB=0
CPU_COUNT=0
CONNTRACK_MAX=0
COMPUTED_MSS=1240

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
info()   { echo -e "${BCYN}  $*${RST}";               log "INFO:  $*"; }
ok()     { echo -e "${BGRN}✓ $*${RST}";               log "OK:    $*"; }
warn()   { echo -e "${BYLW}⚠ WARNING: $*${RST}";      log "WARN:  $*"; }
die()    { echo -e "${BRED}[FATAL] $*${RST}" >&2;      log "FATAL: $*"; cleanup_on_die; exit 1; }
step()   { echo -e "\n${BMAG}━━━ $* ━━━${RST}";       log "STEP:  $*"; }
metric() { echo -e "${BYLW}  ► $*${RST}";             log "METRIC: $*"; }

tee_run() {
  local cmd=("$@")
  local ret=0
  { "${cmd[@]}" 2>&1; ret=${PIPESTATUS[0]}; } | tee -a "$LOG"
  return "$ret"
}
run()  { "$@" >> "$LOG" 2>&1 || true; }
must() { "$@" >> "$LOG" 2>&1 || die "Command failed: $*"; }

# -----------------------------------------------------------------------------
# CLEANUP ON DIE
# -----------------------------------------------------------------------------
cleanup_on_die() {
  log "cleanup_on_die: cancelling rollback job if any"
  cancel_rollback 2>/dev/null || true
  echo ""
  echo -e "${BRED}Script exited with error. Check: $LOG${RST}"
  echo -e "${BYLW}If nftables is broken, SSH may be unreachable.${RST}"
  echo -e "${BYLW}Emergency: reboot VPS from provider console.${RST}"
}

# -----------------------------------------------------------------------------
# PRE-FLIGHT
# -----------------------------------------------------------------------------
preflight() {
  step "Pre-flight checks"

  [ "$EUID" -ne 0 ] && die "Run as root: sudo bash $0"

  mkdir -p "$BACKUP_DIR"
  touch "$LOG"
  log "========== Script v${SCRIPT_VER} started =========="

  # OS check
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" =~ ^(ubuntu|debian)$ ]] || warn "Untested OS: ${ID:-unknown}"
    log "OS: ${PRETTY_NAME:-unknown}"
  fi

  # Virtualization
  if command -v systemd-detect-virt &>/dev/null; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
  elif grep -q "hypervisor" /proc/cpuinfo 2>/dev/null; then
    VIRT_TYPE="kvm"
  else
    VIRT_TYPE="none"
  fi
  case "$VIRT_TYPE" in
    lxc|openvz)
      warn "Restricted virt: $VIRT_TYPE — tc/conntrack/IFB may be unavailable"
      VIRT_RESTRICTED=1 ;;
    *)
      info "Virt: $VIRT_TYPE"
      VIRT_RESTRICTED=0 ;;
  esac

  # Hardware
  TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  CPU_COUNT=$(nproc)
  CONNTRACK_MAX=$(( TOTAL_RAM_MB * 8 ))
  [ "$CONNTRACK_MAX" -lt 16384 ] && CONNTRACK_MAX=16384
  [ "$CONNTRACK_MAX" -gt 131072 ] && CONNTRACK_MAX=131072

  info "RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_COUNT} | Kernel: $(uname -r)"
  info "Conntrack max: ${CONNTRACK_MAX} | Virt: ${VIRT_TYPE}"

  # Default interface — detect early, used in multiple steps
  IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
  [ -z "$IFACE" ] && die "Cannot detect default network interface"
  info "Interface: $IFACE"

  # Kernel capability detection
  detect_kernel_caps

  ok "Pre-flight done"
}

# -----------------------------------------------------------------------------
# KERNEL CAPABILITY DETECTION
# -----------------------------------------------------------------------------
detect_kernel_caps() {
  step "Kernel capability detection"

  # BBR
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null \
      | grep -q bbr; then
    BBR_AVAILABLE=1
    ok "BBR: available"
  elif modprobe tcp_bbr >> "$LOG" 2>&1; then
    BBR_AVAILABLE=1
    ok "BBR: loaded via modprobe"
  else
    BBR_AVAILABLE=0
    warn "BBR: not available — will use CUBIC"
  fi

  # CAKE
  if modprobe sch_cake >> "$LOG" 2>&1 \
      || tc qdisc add dev lo root cake 2>/dev/null; then
    CAKE_AVAILABLE=1
    tc qdisc del dev lo root 2>/dev/null || true
    ok "CAKE: available"
  else
    CAKE_AVAILABLE=0
    warn "CAKE: not available — will use fq_codel fallback"
  fi

  # IFB (ingress shaping)
  if [ "$VIRT_RESTRICTED" -eq 0 ] \
      && modprobe ifb >> "$LOG" 2>&1; then
    IFB_AVAILABLE=1
    ok "IFB: available (ingress shaping enabled)"
  else
    IFB_AVAILABLE=0
    warn "IFB: not available — egress-only shaping"
  fi

  # nft capabilities
  if ! nft --check /dev/null 2>/dev/null; then
    warn "nft --check failed — nftables may have limited features"
  fi

  # AT daemon (rollback)
  if command -v at &>/dev/null && systemctl is-active --quiet atd 2>/dev/null; then
    ok "atd: available (firewall rollback enabled)"
  else
    warn "atd: not running — firewall rollback disabled (install 'at' package)"
  fi
}

# -----------------------------------------------------------------------------
# INPUT COLLECTION
# -----------------------------------------------------------------------------
collect_input() {
  step "Input collection"

  # Domain
  while true; do
    printf "${BCYN}[INPUT] Server FQDN (e.g. vpn.example.com):${RST} "
    read -r SERVER_DOMAIN
    [[ "$SERVER_DOMAIN" =~ \. ]] \
      && [[ ! "$SERVER_DOMAIN" =~ [[:space:]] ]] \
      && [[ ! "$SERVER_DOMAIN" =~ ^https?:// ]] \
      && [[ ! "$SERVER_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      && break
    echo -e "${BRED}  Invalid — FQDN only, no IP/spaces/http${RST}"
  done

  # SSH port
  local detected_ssh=""
  detected_ssh=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  if [ -n "$detected_ssh" ]; then
    printf "${BCYN}[INPUT] SSH port (detected: %s, Enter to keep):${RST} " "$detected_ssh"
    read -r SSH_INPUT
    SSH_PORT="${SSH_INPUT:-$detected_ssh}"
  else
    printf "${BCYN}[INPUT] SSH port:${RST} "
    read -r SSH_PORT
  fi
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT must be numeric"

  # Admin IP for panel whitelist
  printf "${BCYN}[INPUT] Your IP for panel port 2053 whitelist (Enter to skip):${RST} "
  read -r ADMIN_IP
  if [[ -n "$ADMIN_IP" ]] \
      && ! [[ "$ADMIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
    warn "Invalid IP — panel will use rate-limiting only"
    ADMIN_IP=""
  fi

  # Confirmation box
  echo ""
  echo -e "${BCYN}╔══════════════════════════════════════════════════════════════╗${RST}"
  echo -e "${BCYN}║     3x-ui PRODUCTION NARROWBAND STACK v${SCRIPT_VER}      ║${RST}"
  echo -e "${BCYN}╠══════════════════════════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "DOMAIN"        "$SERVER_DOMAIN"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "SSH_PORT"      "$SSH_PORT"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "ADMIN_IP"      "${ADMIN_IP:-any (rate-limited)}"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "PROFILE"       "128kbps/user adaptive 2 users"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "CC"            "$( [ "$BBR_AVAILABLE" -eq 1 ] && echo "BBR" || echo "CUBIC (fallback)" )"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "QDISC"         "$( [ "$CAKE_AVAILABLE" -eq 1 ] && echo "CAKE diffserv4 no-ceiling" || echo "fq_codel (fallback)" )"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "INGRESS SHAPE" "$( [ "$IFB_AVAILABLE" -eq 1 ] && echo "IFB+CAKE" || echo "egress-only" )"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "XUI_VERSION"   "${XUI_VERSION_LABEL}"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "ROLLBACK"      "${ROLLBACK_DELAY_MIN}min auto-safety"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "SWAP"          "${SWAP_SIZE_MB}MB"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "PANEL_PORT"    "2053"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "VLESS_PORT"    "443"
  echo -e "${BCYN}╚══════════════════════════════════════════════════════════════╝${RST}"
  echo ""
  printf "${BYLW}Proceed? [y/N]: ${RST}"
  read -r CONFIRM
  [ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }
}

# -----------------------------------------------------------------------------
# STEP 1: BACKUP
# -----------------------------------------------------------------------------
step_backup() {
  step "[1] Backup existing configs"

  local ts
  ts=$(date '+%Y%m%d_%H%M%S')

  [ -f "$NFT_CONF" ]     && cp "$NFT_CONF"     "${BACKUP_DIR}/nftables_${ts}.conf"
  [ -f "$SYSCTL_FILE" ]  && cp "$SYSCTL_FILE"  "${BACKUP_DIR}/sysctl_${ts}.conf"
  [ -d /usr/local/x-ui ] && tar -czf "${BACKUP_DIR}/x-ui_${ts}.tar.gz" \
    /usr/local/x-ui 2>/dev/null || true

  nft list ruleset 2>/dev/null > "${BACKUP_DIR}/nftables_live_${ts}.nft" || true
  sysctl -a 2>/dev/null        > "${BACKUP_DIR}/sysctl_live_${ts}.txt"   || true

  cp "$NFT_CONF" "$NFT_BACKUP" 2>/dev/null || true

  ok "Backup → $BACKUP_DIR (ts: $ts)"
}

# -----------------------------------------------------------------------------
# STEP 2: SWAP
# -----------------------------------------------------------------------------
step_swap() {
  step "[2] Swap — OOM guard"

  if swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
    ok "Swap already active"
    return
  fi

  [ -f "$SWAP_FILE" ] && { swapoff "$SWAP_FILE" 2>/dev/null || true; rm -f "$SWAP_FILE"; }

  info "Creating ${SWAP_SIZE_MB}MB swapfile..."
  dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=none
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"  >> "$LOG" 2>&1
  swapon  "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab \
    || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

  ok "Swap ${SWAP_SIZE_MB}MB active"
}

# -----------------------------------------------------------------------------
# STEP 3: PACKAGES
# FIX: ลบ ifupdown2 (ไม่มีใน Ubuntu 22.04), เพิ่ม at และ install ก่อน start atd
# -----------------------------------------------------------------------------
step_packages() {
  step "[3] System update + packages"

  tee_run apt-get update -qq
  tee_run apt-get upgrade -y -qq
  tee_run apt-get install -y -qq \
    nftables iproute2 curl wget ca-certificates gnupg \
    dnsutils dnsmasq certbot python3-certbot \
    at \
    "linux-modules-extra-$(uname -r)" \
    || warn "Some packages unavailable — continuing"

  # FIX: install at ก่อน แล้วค่อย enable+start atd
  systemctl enable --now atd >> "$LOG" 2>&1 \
    && ok "atd: enabled" || warn "atd: failed to start"

  ok "[3] Done"
}

# -----------------------------------------------------------------------------
# STEP 4: 3x-ui INSTALL
# FIX: ใช้ main branch URL แทน commit hash ที่ 404
# -----------------------------------------------------------------------------
step_install_xui() {
  step "[4] 3x-ui install"

  if command -v x-ui &>/dev/null && systemctl is-active --quiet x-ui; then
    ok "3x-ui already running — skip install"
    return
  fi

  local install_script="/tmp/3x-ui-install.sh"

  info "Downloading 3x-ui (latest main)..."
  curl -fsSLo "$install_script" "$XUI_SCRIPT_URL" \
    || die "Download failed: $XUI_SCRIPT_URL"

  # SHA256 verify — set XUI_SCRIPT_SHA256 to actual hash to enable
  if [ "$XUI_SCRIPT_SHA256" != "SKIP" ]; then
    echo "${XUI_SCRIPT_SHA256}  ${install_script}" | sha256sum -c \
      || die "SHA256 mismatch — possible supply-chain compromise. Aborting."
    ok "SHA256 verified"
  else
    warn "SHA256 verification SKIPPED"
  fi

  echo -e "${BCYN}  3x-ui prompts → Panel Port: 2053${RST}"
  set +e
  bash "$install_script"
  local xi=$?
  set -e
  rm -f "$install_script"
  [ $xi -ne 0 ] && warn "3x-ui installer exit $xi — verifying binary"

  command -v x-ui >> "$LOG" || die "x-ui binary not found after install"
  systemctl is-active x-ui | grep -q "^active$" || die "x-ui not active after install"

  ok "[4] Done"
}

# -----------------------------------------------------------------------------
# STEP 5: TLS CERTIFICATE
# -----------------------------------------------------------------------------
step_tls() {
  step "[5] TLS certificate"

  local cert_live="/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem"
  local skip_cert=0

  if [ -f "$cert_live" ]; then
    local expiry_ts now_ts days_left
    expiry_ts=$(openssl x509 -enddate -noout -in "$cert_live" 2>/dev/null \
      | cut -d= -f2 | xargs -I{} date -d '{}' +%s 2>/dev/null || echo 0)
    now_ts=$(date +%s)
    days_left=$(( (expiry_ts - now_ts) / 86400 ))
    if [ "$days_left" -gt 7 ]; then
      ok "Cert valid ${days_left} days — skip reissue"
      skip_cert=1
    else
      info "Cert expires in ${days_left} days — reissuing"
      run certbot delete --cert-name "$SERVER_DOMAIN" --non-interactive
    fi
  fi

  if [ "$skip_cert" -eq 0 ]; then
    SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -s4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
    local resolved
    resolved=$(dig +short +time=3 "$SERVER_DOMAIN" A 2>/dev/null | tail -1)

    if [ "$resolved" != "$SERVER_IP" ]; then
      warn "DNS mismatch: $SERVER_DOMAIN → $resolved  server: $SERVER_IP"
      printf "Continue anyway? [y/N]: "
      read -r dns_ok
      [ "${dns_ok,,}" = "y" ] || die "Fix DNS and re-run"
    else
      ok "DNS OK: $SERVER_DOMAIN → $SERVER_IP"
    fi

    run systemctl start nftables
    nft add rule inet filter input tcp dport 80 accept \
      comment '"certbot-temp"' 2>/dev/null || true

    mkdir -p "$CERT_DIR"
    tee_run certbot certonly \
      --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email \
      -d "$SERVER_DOMAIN" \
      || die "certbot failed — check DNS + port 80"

    local handle
    handle=$(nft -a list chain inet filter input 2>/dev/null \
      | awk '/certbot-temp/{print $NF}')
    [ -n "$handle" ] && run nft delete rule inet filter input handle "$handle"
  fi

  mkdir -p "$CERT_DIR"
  ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
  ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/privkey.pem"   "$CERT_DIR/key.pem"
  ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/cert.pem"      "$CERT_DIR/cert.pem"
  chmod 750 "$CERT_DIR"
  chmod 750 "/etc/letsencrypt/live/$SERVER_DOMAIN"
  chmod 640 "/etc/letsencrypt/live/$SERVER_DOMAIN"/*.pem 2>/dev/null || true

  x-ui setting -certFile "$CERT_DIR/fullchain.pem" \
               -keyFile  "$CERT_DIR/key.pem" 2>/dev/null \
    || warn "x-ui CLI cert — set manually in panel"
  tee_run systemctl restart x-ui

  cat > /etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh << 'HOOK'
#!/bin/bash
systemctl restart x-ui
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh

  CERT_EXPIRY=$(openssl x509 -enddate -noout \
    -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "unknown")

  local tls_ok=0
  if openssl s_client \
      -connect "${SERVER_DOMAIN}:443" \
      -servername "${SERVER_DOMAIN}" \
      -verify_return_error \
      </dev/null >> "$LOG" 2>&1; then
    tls_ok=1
    ok "TLS handshake verified on ${SERVER_DOMAIN}:443"
  else
    warn "TLS verify failed — xray may not be configured yet (expected at this stage)"
  fi
  log "TLS verify: $tls_ok | cert_expiry: $CERT_EXPIRY"

  systemctl enable certbot.timer >> "$LOG" 2>&1 \
    && ok "certbot.timer enabled" \
    || {
      cat > /etc/cron.d/certbot-renew << 'CRON'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl restart x-ui"
CRON
      ok "certbot cron fallback"
    }

  ok "[5] Done — cert expires: $CERT_EXPIRY"
}

# -----------------------------------------------------------------------------
# STEP 6: DNS BENCHMARK + DNSMASQ
# -----------------------------------------------------------------------------
benchmark_dns_single() {
  local r="$1"
  local total=0 count=0 ms
  for _ in 1 2 3 4 5; do
    ms=$(dig +tries=1 +time=2 google.com @"$r" 2>/dev/null \
      | awk '/Query time:/{print $4}' | head -1)
    if [[ "$ms" =~ ^[0-9]+$ ]]; then
      total=$(( total + ms ))
      count=$(( count + 1 ))
    fi
  done
  local avg=9999
  [ "$count" -gt 0 ] && avg=$(( total / count ))
  echo "$avg $r"
}
export -f benchmark_dns_single

step_dns() {
  step "[6] DNS benchmark (parallel) + dnsmasq"

  local resolvers=(
    "94.140.14.140" "94.140.14.141"
    "1.1.1.1"       "1.0.0.1"
    "8.8.8.8"       "8.8.4.4"
    "9.9.9.9"       "101.101.101.101"
  )

  info "Benchmarking ${#resolvers[@]} resolvers in parallel (5 rounds each)..."
  local results
  results=$(printf '%s\n' "${resolvers[@]}" \
    | xargs -P8 -I{} bash -c 'benchmark_dns_single "$@"' _ {} 2>/dev/null \
    | sort -n)

  while IFS=' ' read -r ms r; do
    info "  $r → ${ms}ms"
    log "DNS_BENCH: $r = ${ms}ms"
  done <<< "$results"

  DNS_BEST=$(echo "$results" | head -1 | awk '{print $2}')
  DNS_BEST_MS=$(echo "$results" | head -1 | awk '{print $1}')
  local top3
  top3=$(echo "$results" | head -3 | awk '{print $2}')
  ok "Best DNS: $DNS_BEST (${DNS_BEST_MS}ms)"

  run systemctl stop systemd-resolved || true
  run systemctl stop dnsmasq          || true

  grep -q "^DNSStubListener" /etc/systemd/resolved.conf 2>/dev/null \
    && sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf \
    || echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
  must systemctl restart systemd-resolved

  {
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "port=53"
    while IFS= read -r r; do echo "server=$r"; done <<< "$top3"
    cat << 'DEOF'
cache-size=4096
min-cache-ttl=120
neg-ttl=10
dns-forward-max=300
no-resolv
DEOF
  } > /etc/dnsmasq.conf

  chattr -i /etc/resolv.conf 2>/dev/null || true
  echo "nameserver 127.0.0.1" > /etc/resolv.conf

  if chattr +i /etc/resolv.conf 2>/dev/null; then
    ok "resolv.conf locked (chattr +i)"
  else
    warn "chattr unsupported — using resolved override"
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no\nReadEtcHosts=yes\n' \
      > /etc/systemd/resolved.conf.d/99-dnsmasq.conf
    [ -d /etc/NetworkManager/conf.d ] && {
      printf '[main]\ndns=none\n' > /etc/NetworkManager/conf.d/99-dns-none.conf
      run systemctl reload NetworkManager
    }
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
  fi

  must systemctl enable --now dnsmasq || die "dnsmasq failed to start"

  local dig_r
  dig_r=$(dig +short google.com @127.0.0.1 2>/dev/null | head -1)
  [ -n "$dig_r" ] && ok "dnsmasq: google.com → $dig_r" \
    || warn "dnsmasq: google.com lookup failed"

  ok "[6] Done"
}

# -----------------------------------------------------------------------------
# STEP 7: SYSCTL — BBR + ADAPTIVE PROFILE
# -----------------------------------------------------------------------------
step_sysctl() {
  step "[7] sysctl — BBR + adaptive profile"

  local cc="cubic"
  [ "$BBR_AVAILABLE" -eq 1 ] && cc="bbr"

  local qdisc="fq_codel"
  [ "$CAKE_AVAILABLE" -eq 1 ] && qdisc="cake"

  cat > "$SYSCTL_FILE" << EOF
net.core.default_qdisc             = ${qdisc}
net.ipv4.tcp_congestion_control    = ${cc}

net.core.rmem_max                  = 8388608
net.core.wmem_max                  = 8388608
net.ipv4.tcp_rmem                  = 4096 87380 8388608
net.ipv4.tcp_wmem                  = 4096 65536 8388608

net.ipv4.tcp_notsent_lowat         = 8192
net.ipv4.tcp_limit_output_bytes    = 65536

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn                   = 2
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_fastopen              = 3

net.ipv4.tcp_keepalive_time        = 60
net.ipv4.tcp_keepalive_intvl       = 10
net.ipv4.tcp_keepalive_probes      = 5

net.ipv4.tcp_syn_retries           = 3
net.ipv4.tcp_retries2              = 8

net.core.optmem_max                = 131072
net.core.netdev_max_backlog        = 2000
net.core.somaxconn                 = 2048
net.ipv4.tcp_max_syn_backlog       = 2048

net.ipv4.ip_forward                = 1
net.ipv6.conf.all.forwarding       = 1

vm.swappiness                      = 10
vm.vfs_cache_pressure              = 50
EOF

  if [ "$VIRT_RESTRICTED" -ne 1 ]; then
    cat >> "$SYSCTL_FILE" << EOF
net.netfilter.nf_conntrack_max                     = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 15
net.netfilter.nf_conntrack_udp_timeout             = 15
net.netfilter.nf_conntrack_udp_timeout_stream      = 60
EOF
  fi

  sysctl --system >> "$LOG" 2>&1

  local actual_cc actual_qdisc
  actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")

  [ "$actual_cc" = "$cc" ] \
    && ok "CC verified: $actual_cc" \
    || warn "CC mismatch: expected $cc got $actual_cc"

  [ "$actual_qdisc" = "$qdisc" ] \
    && ok "default_qdisc verified: $actual_qdisc" \
    || warn "qdisc mismatch: expected $qdisc got $actual_qdisc"

  local fwd
  fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
  [ "$fwd" = "1" ] && ok "ip_forward: 1" || warn "ip_forward not set"

  ok "[7] Done"
}

# -----------------------------------------------------------------------------
# STEP 8: PMTU PROBE + MSS CALCULATION
# -----------------------------------------------------------------------------
probe_mtu_mss() {
  step "[8] PMTU probe → MSS calculation"

  local target="8.8.8.8"
  local probed_mtu=1500

  if command -v tracepath &>/dev/null; then
    local tp_mtu
    tp_mtu=$(tracepath -n "$target" 2>/dev/null \
      | awk '/pmtu/{match($0,/pmtu ([0-9]+)/,a); if(a[1]) print a[1]}' \
      | tail -1)
    if [[ "$tp_mtu" =~ ^[0-9]+$ ]] && [ "$tp_mtu" -gt 576 ]; then
      probed_mtu="$tp_mtu"
      info "tracepath PMTU: ${probed_mtu}"
    fi
  fi

  COMPUTED_MSS=$(( probed_mtu - 120 ))
  [ "$COMPUTED_MSS" -lt 576  ] && COMPUTED_MSS=576
  [ "$COMPUTED_MSS" -gt 1380 ] && COMPUTED_MSS=1380

  info "PMTU: ${probed_mtu} → MSS clamp: ${COMPUTED_MSS}"
  log "PMTU_PROBE: mtu=$probed_mtu mss=$COMPUTED_MSS"

  ok "[8] MSS: $COMPUTED_MSS"
}

# -----------------------------------------------------------------------------
# STEP 9: QDISC — CAKE + IFB INGRESS
# -----------------------------------------------------------------------------
step_qdisc() {
  step "[9] qdisc — CAKE adaptive + IFB ingress"

  local cake_opts="diffserv4 nat wash overhead 40 mpu 64"

  cat > "$QDISC_SCRIPT" << QEOF
#!/usr/bin/env bash
set -euo pipefail
TC=/sbin/tc
IFACE=\$(ip route show default 2>/dev/null | awk 'NR==1{print \$5}')
[ -z "\$IFACE" ] && { echo "No default interface"; exit 1; }

\$TC qdisc del dev "\$IFACE" root    2>/dev/null || true
\$TC qdisc del dev "\$IFACE" ingress 2>/dev/null || true

if \$TC qdisc add dev "\$IFACE" root cake ${cake_opts} 2>/dev/null; then
  echo "CAKE egress applied on \$IFACE"
else
  \$TC qdisc add dev "\$IFACE" root fq_codel \
    limit 500 target 8ms interval 80ms quantum 300 2>/dev/null || true
  echo "fq_codel egress fallback on \$IFACE"
fi

if modprobe ifb 2>/dev/null && ip link show ifb0 &>/dev/null; then
  ip link set dev ifb0 up 2>/dev/null || true
  \$TC qdisc del dev "\$IFACE" ingress 2>/dev/null || true
  \$TC qdisc add dev "\$IFACE" handle ffff: ingress
  \$TC filter add dev "\$IFACE" parent ffff: protocol ip u32 \
    match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true
  \$TC filter add dev "\$IFACE" parent ffff: protocol ipv6 u32 \
    match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true
  \$TC qdisc del dev ifb0 root 2>/dev/null || true
  \$TC qdisc add dev ifb0 root cake ${cake_opts} 2>/dev/null \
    && echo "CAKE ingress applied via ifb0" \
    || echo "ifb0 CAKE failed — ingress unmanaged"
fi
QEOF
  chmod +x "$QDISC_SCRIPT"

  bash "$QDISC_SCRIPT" 2>&1 | tee -a "$LOG"

  local applied
  applied=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  QDISC_APPLIED="${applied} on ${IFACE}"
  [ "$IFB_AVAILABLE" -eq 1 ] && QDISC_APPLIED+=" + IFB ingress"

  rm -f /etc/systemd/system/gaming-qdisc.service
  cat > /etc/systemd/system/gaming-qdisc.service << EOF
[Unit]
Description=Adaptive CAKE qdisc — per-user 128kbps
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${QDISC_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

  must systemctl daemon-reload
  must systemctl enable gaming-qdisc

  ok "[9] qdisc: $QDISC_APPLIED"
}

# -----------------------------------------------------------------------------
# STEP 10: NFTABLES — FULL DUAL-STACK + ROLLBACK SAFETY
# -----------------------------------------------------------------------------
schedule_rollback() {
  if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd 2>/dev/null; then
    warn "atd unavailable — no automatic firewall rollback"
    return
  fi
  AT_JOB_ID=$(echo "systemctl stop nftables && nft flush ruleset" \
    | at "now + ${ROLLBACK_DELAY_MIN} minutes" 2>&1 \
    | awk '/^job/{print $2}')
  if [ -n "$AT_JOB_ID" ]; then
    warn "ROLLBACK SCHEDULED: nftables will be cleared in ${ROLLBACK_DELAY_MIN}min (job #${AT_JOB_ID})"
    warn "If SSH works, run: atrm ${AT_JOB_ID}"
  fi
}

cancel_rollback() {
  if [ -n "$AT_JOB_ID" ]; then
    atrm "$AT_JOB_ID" 2>/dev/null && ok "Rollback job #${AT_JOB_ID} cancelled" || true
    AT_JOB_ID=""
  fi
}

step_nftables() {
  step "[10] nftables — dual-stack production ruleset"

  local panel_rule_v4 panel_rule_v6

  if [ -n "$ADMIN_IP" ]; then
    panel_rule_v4="ip saddr ${ADMIN_IP} tcp dport 2053 accept"
    panel_rule_v6=""
  else
    panel_rule_v4="tcp dport 2053 limit rate 10/minute burst 8 packets accept"
    panel_rule_v6="tcp dport 2053 limit rate 10/minute burst 8 packets accept"
  fi

  schedule_rollback

  cat > "$NFT_CONF" << NFTEOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  set ssh_blocklist4 {
    type ipv4_addr
    flags dynamic,timeout
    timeout 1h
    gc-interval 10m
  }

  set ssh_blocklist6 {
    type ipv6_addr
    flags dynamic,timeout
    timeout 1h
    gc-interval 10m
  }

  chain input {
    type filter hook input priority 0; policy drop;

    iif "lo" accept

    ct state established,related accept
    ct state invalid drop

    ip  protocol icmp  icmp  type { echo-request, echo-reply, destination-unreachable, time-exceeded } limit rate 10/second accept
    ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert } limit rate 10/second accept

    ip  saddr @ssh_blocklist4 drop
    ip6 saddr @ssh_blocklist6 drop
    tcp dport ${SSH_PORT} ct state new limit rate over 15/minute burst 8 packets \
      add @ssh_blocklist4 { ip  saddr timeout 1h } \
      add @ssh_blocklist6 { ip6 saddr timeout 1h }
    tcp dport ${SSH_PORT} ct state new limit rate 15/minute burst 10 packets accept

    tcp dport 80  accept
    tcp dport 443 accept
    udp dport 443 accept

    ${panel_rule_v4}

    ${panel_rule_v6}
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table inet mangle {
  chain prerouting {
    type filter hook prerouting priority -150;

    tcp dport 443 ip  dscp set cs5
    udp dport 443 ip  dscp set cs5
    tcp dport 443 ip6 dscp set cs5
    udp dport 443 ip6 dscp set cs5
  }

  chain postrouting {
    type filter hook postrouting priority -150;

    oifname "${IFACE}" tcp flags & (syn|ack) == syn \
      tcp option maxseg size set ${COMPUTED_MSS}
  }
}
NFTEOF

  if tee_run nft -f "$NFT_CONF"; then
    ok "nftables ruleset loaded"
    tee_run systemctl enable nftables

    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null)

    echo "$ruleset" | grep -qE "dport.*${SSH_PORT}" \
      && ok "SSH port ${SSH_PORT} rule: present" \
      || warn "SSH port ${SSH_PORT} rule not found in ruleset"

    echo "$ruleset" | grep -qE "dport.*443" \
      && ok "Port 443 rule: present" \
      || warn "Port 443 rule not found"

    echo "$ruleset" | grep -qE "ssh_blocklist" \
      && ok "SSH blocklist sets: present" \
      || warn "SSH blocklist sets not found"

    cancel_rollback
  else
    warn "nft load failed — restoring backup"
    [ -f "$NFT_BACKUP" ] && nft -f "$NFT_BACKUP" && ok "Backup restored" \
      || warn "Backup restore also failed"
    cancel_rollback
    die "nftables configuration failed"
  fi

  ok "[10] Done"
}

# -----------------------------------------------------------------------------
# STEP 11: x-ui SYSTEMD SLICE + RESOURCE ISOLATION
# -----------------------------------------------------------------------------
step_xui_tuning() {
  step "[11] x-ui resource isolation + limits"

  cat > "$SLICE_CONF" << 'EOF'
[Unit]
Description=Xray VPN Slice

[Slice]
CPUQuota=80%
MemoryMax=512M
MemorySwapMax=256M
IOWeight=100
TasksMax=512
EOF

  local limits_conf="/etc/security/limits.conf"
  sed -i '/# xray-limits/,+4d' "$limits_conf" 2>/dev/null || true
  cat >> "$limits_conf" << 'EOF'
# xray-limits
root    soft    nofile  32768
root    hard    nofile  32768
*       soft    nofile  32768
*       hard    nofile  32768
EOF

  mkdir -p "$(dirname "$XUI_OVERRIDE")"
  cat > "$XUI_OVERRIDE" << EOF
[Unit]
Slice=xray.slice

[Service]
LimitNOFILE=32768
LimitNPROC=16384
Nice=-10
OOMScoreAdjust=-500
Restart=on-failure
RestartSec=5
EOF

  must systemctl daemon-reload
  tee_run systemctl restart x-ui
  sleep 2

  systemctl is-active x-ui | grep -q "^active$" \
    && ok "x-ui active" \
    || warn "x-ui not active after restart"

  local xui_pid xui_fdlimit
  xui_pid=$(pgrep -f x-ui | head -1 || true)
  if [ -n "$xui_pid" ]; then
    xui_fdlimit=$(cat "/proc/${xui_pid}/limits" 2>/dev/null \
      | awk '/Max open files/{print $4}' || echo "?")
    ok "x-ui PID $xui_pid — FD limit: $xui_fdlimit"
  fi

  cat > /root/xray-production-settings.txt << 'XEOF'
VLESS+Reality — Production Narrowband (128kbps/user, 2 users)
==============================================================

Protocol    : VLESS
Port        : 443
Network     : tcp
Security    : reality
Flow        : xtls-rprx-vision
Dest / SNI  : th.speedtest.net:443
uTLS        : firefox

sockopt:
  tcpNoDelay          : true
  tcpKeepAliveInterval: 15
  mark                : 255

Inbound:
  sniffing   : DISABLE
  mux        : DISABLE
  bufferSize : 16 (kb)

Per-user bandwidth limit in panel:
  NONE — each user has independent 128kbps link
  BBR self-regulates per session automatically

Expected performance per user at 128kbps:
  ROV/DOTA2  : excellent   (20-50kbps avg)
  Valorant   : good        (40-80kbps avg)
  YouTube 144p: usable     (80-100kbps, tight)
  Discord voice: good      (32-64kbps Opus)
  Browsing   : good
  Streaming HD: not possible at 128kbps
XEOF

  ok "[11] Done"
}

# -----------------------------------------------------------------------------
# STEP 12: HEALTH CHECK SYSTEM
# -----------------------------------------------------------------------------
step_health_check() {
  step "[12] Health verification"

  local pass=0 fail=0

  check_pass() { ok "  CHECK ✓ $*"; (( pass++ )) || true; }
  check_fail() { warn "  CHECK ✗ $*"; (( fail++ )) || true; }

  systemctl is-active x-ui      | grep -q "^active$" \
    && check_pass "x-ui: active"            || check_fail "x-ui: not active"
  systemctl is-active nftables   | grep -q "^active$" \
    && check_pass "nftables: active"        || check_fail "nftables: not active"
  systemctl is-active dnsmasq    | grep -q "^active$" \
    && check_pass "dnsmasq: active"         || check_fail "dnsmasq: not active"
  systemctl is-active gaming-qdisc | grep -q "^active$" \
    && check_pass "gaming-qdisc: active"   || check_fail "gaming-qdisc: not active"

  ss -tlnp 2>/dev/null | grep -q ":443 " \
    && check_pass "Port 443: bound"         || check_fail "Port 443: not bound"
  ss -tlnp 2>/dev/null | grep -q ":2053 " \
    && check_pass "Port 2053: bound"        || check_fail "Port 2053: not bound"

  local panel_code
  panel_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
    "https://${SERVER_DOMAIN}:2053/" 2>/dev/null || echo "000")
  [[ "$panel_code" =~ ^(200|301|302|401|403)$ ]] \
    && check_pass "Panel HTTP: $panel_code" \
    || check_fail "Panel HTTP: $panel_code (may need manual cert config)"

  local dns_r
  dns_r=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | head -1)
  [ -n "$dns_r" ] \
    && check_pass "dnsmasq DNS: google.com → $dns_r" \
    || check_fail "dnsmasq DNS: google.com lookup failed"

  local qdisc_active
  qdisc_active=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  [ -n "$qdisc_active" ] \
    && check_pass "qdisc: $qdisc_active on $IFACE" \
    || check_fail "qdisc: none detected on $IFACE"

  local actual_cc
  actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  [ "$actual_cc" = "bbr" ] \
    && check_pass "TCP CC: bbr"             || check_fail "TCP CC: $actual_cc (not bbr)"

  nft list ruleset 2>/dev/null | grep -qE "dport.*443" \
    && check_pass "nftables port 443 rule"  || check_fail "nftables port 443 missing"

  swapon --show 2>/dev/null | grep -q "$SWAP_FILE" \
    && check_pass "Swap: active"            || check_fail "Swap: not active"

  echo ""
  info "Health: ${pass} passed, ${fail} failed"
  log "HEALTH: pass=$pass fail=$fail"

  [ "$fail" -gt 0 ] && warn "Some checks failed — review above" || ok "All health checks passed"
}

# -----------------------------------------------------------------------------
# STEP 13: OBSERVABILITY SNAPSHOT
# -----------------------------------------------------------------------------
step_observability() {
  step "[13] Observability snapshot"

  echo ""
  metric "=== qdisc stats ==="
  tc -s qdisc show dev "$IFACE" 2>/dev/null | tee -a "$LOG"

  if ip link show "$IFB_DEV" &>/dev/null 2>/dev/null; then
    metric "=== IFB ingress stats ==="
    tc -s qdisc show dev "$IFB_DEV" 2>/dev/null | tee -a "$LOG"
  fi

  metric "=== conntrack ==="
  if command -v conntrack &>/dev/null; then
    conntrack -C 2>/dev/null | tee -a "$LOG" || true
  else
    cat /proc/net/nf_conntrack 2>/dev/null | wc -l | \
      xargs -I{} echo "conntrack entries: {}" | tee -a "$LOG" || true
  fi

  metric "=== TCP sockets ==="
  ss -s 2>/dev/null | tee -a "$LOG"

  metric "=== Memory ==="
  free -m 2>/dev/null | tee -a "$LOG"

  metric "=== Swap usage ==="
  swapon --show 2>/dev/null | tee -a "$LOG"

  ok "[13] Snapshot saved to $LOG"
}

# -----------------------------------------------------------------------------
# STEP 14: FINAL SUMMARY
# -----------------------------------------------------------------------------
step_summary() {
  step "[14] Final summary"

  local xui_status nft_status dns_status qds_status tcp_cc tcp_qd swap_info
  xui_status=$(systemctl is-active x-ui          2>/dev/null || echo "inactive")
  nft_status=$(systemctl is-active nftables      2>/dev/null || echo "inactive")
  dns_status=$(systemctl is-active dnsmasq       2>/dev/null || echo "inactive")
  qds_status=$(systemctl is-active gaming-qdisc  2>/dev/null || echo "inactive")
  tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  tcp_qd=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  swap_info=$(swapon --show 2>/dev/null | grep -c "$SWAP_FILE" \
    && echo "${SWAP_SIZE_MB}MB active" || echo "inactive") 2>/dev/null || swap_info="inactive"

  echo ""
  echo -e "${BCYN}╔══════════════════════════════════════╦════════════════════════════════════════╗${RST}"
  echo -e "${BCYN}║ Setting                              ║ Value                                  ║${RST}"
  echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "x-ui"              "$xui_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Panel URL"         "https://$SERVER_DOMAIN:2053/"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Cert expires"      "$CERT_EXPIRY"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Admin IP"          "${ADMIN_IP:-any (rate-limited)}"
  echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP CC"            "$tcp_cc"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "qdisc egress"      "${tcp_qd} on ${IFACE}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "qdisc ingress"     "$( ip link show ifb0 &>/dev/null 2>/dev/null && echo "CAKE on ifb0" || echo "none" )"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "MSS clamp"         "${COMPUTED_MSS} (PMTU-derived)"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Swap"              "$swap_info"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Conntrack max"     "$CONNTRACK_MAX"
  echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "nftables"          "$nft_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "dnsmasq"           "$dns_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Best DNS"          "${DNS_BEST} (${DNS_BEST_MS}ms)"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "gaming-qdisc"      "$qds_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "XUI version"       "${XUI_VERSION_LABEL}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Backup"            "$BACKUP_DIR"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Log"               "$LOG"
  echo -e "${BCYN}╚══════════════════════════════════════╩════════════════════════════════════════╝${RST}"

  echo ""
  echo -e "${BGRN}══════════════════════════════════════════════════════${RST}"
  echo -e "${BGRN}  NEXT — 3x-ui panel config${RST}"
  echo -e "${BGRN}══════════════════════════════════════════════════════${RST}"
  echo ""
  echo -e "  1. Panel: ${BCYN}https://${SERVER_DOMAIN}:2053/${RST}"
  echo    "     Settings → Cert: $CERT_DIR/fullchain.pem"
  echo    "     Settings → Key : $CERT_DIR/key.pem"
  echo    "     Save → Restart panel"
  echo ""
  echo    "  2. Add Inbound:"
  echo    "     VLESS | Port 443 | Reality | xtls-rprx-vision"
  echo    "     SNI: th.speedtest.net | uTLS: firefox"
  echo    "     tcpNoDelay: ON | sniffing: OFF | mux: OFF"
  echo    "     bufferSize: 16"
  echo ""
  echo    "  3. Add 2 users — NO bandwidth cap (each has 128kbps own link)"
  echo    "  4. cat /root/xray-production-settings.txt"
  echo ""
  echo -e "${BGRN}══════════════════════════════════════════════════════${RST}"

  log "========== Script v${SCRIPT_VER} completed =========="
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
  preflight
  collect_input
  step_backup
  step_swap
  step_packages
  step_install_xui
  step_tls
  step_dns
  step_sysctl
  probe_mtu_mss
  step_qdisc
  step_nftables
  step_xui_tuning
  step_health_check
  step_observability
  step_summary
}

main "$@"
