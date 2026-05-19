#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VER="4.3-production"
readonly LOG=/var/log/3x-ui-vpn.log
readonly BACKUP_DIR=/var/backups/3x-ui-vpn
readonly CERT_DIR=/etc/ssl/xray
readonly SWAP_FILE=/swapfile
readonly SWAP_SIZE_MB=512
readonly IFB_DEV=ifb0
readonly QDISC_SCRIPT=/usr/local/bin/apply-qdisc.sh
readonly SLICE_CONF=/etc/systemd/system/xray.slice
readonly XUI_OVERRIDE=/etc/systemd/system/x-ui.service.d/override.conf
readonly SYSCTL_FILE=/etc/sysctl.d/99-vpn.conf
readonly NFT_CONF=/etc/nftables.conf
readonly NFT_BACKUP="${BACKUP_DIR}/nftables.conf.bak"
readonly ROLLBACK_DELAY_MIN=3
readonly XUI_SCRIPT_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/main/install.sh"
readonly XUI_SCRIPT_SHA256="SKIP"
XUI_VERSION_LABEL="main"

BGRN='\033[1;32m'; BCYN='\033[1;36m'; BYLW='\033[1;33m'
BRED='\033[1;31m'; BMAG='\033[1;35m'; RST='\033[0m'

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
CONNTRACK_MAX=32768
COMPUTED_MSS=1240
SERVER_IPV6=""
HAS_IPV6=0
CAKE_EGRESS_BW="380mbit"
CAKE_INGRESS_BW="900mbit"
NIC_SPEED_MBIT=0

log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
info()   { echo -e "${BCYN}  $*${RST}";          log "INFO:  $*"; }
ok()     { echo -e "${BGRN}✓ $*${RST}";          log "OK:    $*"; }
warn()   { echo -e "${BYLW}⚠ $*${RST}";          log "WARN:  $*"; }
die()    { echo -e "${BRED}[FATAL] $*${RST}" >&2; log "FATAL: $*"; cleanup_on_die; exit 1; }
step()   { echo -e "\n${BMAG}━━━ $* ━━━${RST}";  log "STEP:  $*"; }
metric() { echo -e "${BYLW}  ► $*${RST}";        log "METRIC: $*"; }

tee_run() {
  local cmd=("$@")
  local ret=0
  { "${cmd[@]}" 2>&1; ret=${PIPESTATUS[0]}; } | tee -a "$LOG"
  return "$ret"
}
run()  { "$@" >> "$LOG" 2>&1 || true; }
must() { "$@" >> "$LOG" 2>&1 || die "Command failed: $*"; }

cleanup_on_die() {
  log "cleanup_on_die triggered"
  cancel_rollback 2>/dev/null || true
  echo -e "${BRED}Script exited with error. Check: $LOG${RST}"
  echo -e "${BYLW}If nftables is broken: reboot VPS from provider console.${RST}"
}

preflight() {
  step "Pre-flight checks"

  [ "$EUID" -ne 0 ] && die "Run as root: sudo bash $0"

  mkdir -p "$BACKUP_DIR"
  touch "$LOG"
  log "========== Script v${SCRIPT_VER} started =========="

  if [ -f /etc/os-release ]; then
    source /etc/os-release
    [[ "${ID:-}" =~ ^(ubuntu|debian)$ ]] || warn "Untested OS: ${ID:-unknown}"
    log "OS: ${PRETTY_NAME:-unknown}"
  fi

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

  TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  CPU_COUNT=$(nproc)

  info "RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_COUNT} | Kernel: $(uname -r)"
  info "Conntrack max: ${CONNTRACK_MAX} | Virt: ${VIRT_TYPE}"

  IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
  [ -z "$IFACE" ] && die "Cannot detect default network interface"
  info "Interface: $IFACE"

  detect_kernel_caps
  detect_bandwidth
  ok "Pre-flight done"
}

detect_kernel_caps() {
  step "Kernel capability detection"

  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    BBR_AVAILABLE=1; ok "BBR: available"
  elif modprobe tcp_bbr >> "$LOG" 2>&1; then
    BBR_AVAILABLE=1; ok "BBR: loaded via modprobe"
  else
    BBR_AVAILABLE=0; warn "BBR: not available — will use CUBIC"
  fi

  if modprobe sch_cake >> "$LOG" 2>&1 || tc qdisc add dev lo root cake 2>/dev/null; then
    CAKE_AVAILABLE=1
    tc qdisc del dev lo root 2>/dev/null || true
    ok "CAKE: available"
  else
    CAKE_AVAILABLE=0; warn "CAKE: not available — will use fq_codel fallback"
  fi

  if [ "$VIRT_RESTRICTED" -eq 0 ] && modprobe ifb >> "$LOG" 2>&1; then
    IFB_AVAILABLE=1; ok "IFB: available (ingress shaping enabled)"
  else
    IFB_AVAILABLE=0; warn "IFB: not available — egress-only shaping"
  fi

  if ! nft --check /dev/null 2>/dev/null; then
    warn "nft --check failed — nftables may have limited features"
  fi

  if command -v at &>/dev/null && systemctl is-active --quiet atd 2>/dev/null; then
    ok "atd: available (firewall rollback enabled)"
  else
    warn "atd: not running — firewall rollback disabled"
  fi
}


detect_bandwidth() {
  step "Bandwidth auto-detection"

  local nic_speed=0

  # Method 1: ethtool (most reliable on KVM)
  if command -v ethtool &>/dev/null; then
    local raw
    raw=$(ethtool "$IFACE" 2>/dev/null | awk '/Speed:/{print $2}')
    if [[ "$raw" =~ ^([0-9]+)(Mb|Gb)/?s$ ]]; then
      local val="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
      [ "$unit" = "Gb" ] && nic_speed=$(( val * 1000 )) || nic_speed="$val"
    fi
  fi

  # Method 2: /sys/class/net (works when ethtool fails on VPS)
  if [ "$nic_speed" -eq 0 ]; then
    local sys_speed
    sys_speed=$(cat "/sys/class/net/${IFACE}/speed" 2>/dev/null || echo 0)
    [[ "$sys_speed" =~ ^[0-9]+$ ]] && [ "$sys_speed" -gt 0 ] && nic_speed="$sys_speed"
  fi

  # Method 3: speedtest-cli quick single-server test (optional, skip if slow)
  local speedtest_mbit=0
  if [ "$nic_speed" -le 0 ] && command -v speedtest-cli &>/dev/null; then
    info "Running speedtest (single server, 10s timeout)..."
    local st_result
    st_result=$(timeout 30 speedtest-cli --simple --secure 2>/dev/null || true)
    speedtest_mbit=$(echo "$st_result" | awk '/Upload:/{gsub(/[^0-9.]/,"",$2); printf "%d", $2+0}')
    [ "${speedtest_mbit:-0}" -gt 0 ] && info "speedtest upload: ${speedtest_mbit} Mbit/s"
  fi

  NIC_SPEED_MBIT="$nic_speed"

  # Derive CAKE bandwidths
  # Egress: 95% of detected uplink so CAKE owns the bottleneck
  # Ingress: capped at 950mbit (1G NIC headroom) or 2x uplink if asymmetric VPS
  if [ "$nic_speed" -gt 0 ]; then
    local egress_raw=$(( nic_speed * 95 / 100 ))
    local ingress_raw=$(( nic_speed * 95 / 100 ))
    # Floor at 50mbit, ceil at 950mbit
    [ "$egress_raw"  -lt 50   ] && egress_raw=50
    [ "$egress_raw"  -gt 950  ] && egress_raw=950
    [ "$ingress_raw" -lt 50   ] && ingress_raw=50
    [ "$ingress_raw" -gt 950  ] && ingress_raw=950
    CAKE_EGRESS_BW="${egress_raw}mbit"
    CAKE_INGRESS_BW="${ingress_raw}mbit"
    ok "Auto BW: NIC ${nic_speed}Mbit → egress=${CAKE_EGRESS_BW} ingress=${CAKE_INGRESS_BW}"
  elif [ "${speedtest_mbit:-0}" -gt 0 ]; then
    local egress_raw=$(( speedtest_mbit * 90 / 100 ))
    [ "$egress_raw" -lt 50  ] && egress_raw=50
    [ "$egress_raw" -gt 950 ] && egress_raw=950
    CAKE_EGRESS_BW="${egress_raw}mbit"
    CAKE_INGRESS_BW="${egress_raw}mbit"
    ok "Auto BW (speedtest): upload=${speedtest_mbit}Mbit → egress=${CAKE_EGRESS_BW}"
  else
    warn "Cannot detect NIC speed — using conservative defaults: egress=380mbit ingress=900mbit"
    CAKE_EGRESS_BW="380mbit"
    CAKE_INGRESS_BW="900mbit"
  fi

  log "BW_DETECT: nic=${NIC_SPEED_MBIT}Mbit egress=${CAKE_EGRESS_BW} ingress=${CAKE_INGRESS_BW}"
  ok "Bandwidth detection done"
}

collect_input() {
  step "Input collection"

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

  printf "${BCYN}[INPUT] Your IP for panel port 2053 whitelist (Enter to skip):${RST} "
  read -r ADMIN_IP
  if [[ -n "$ADMIN_IP" ]] \
      && ! [[ "$ADMIN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
    warn "Invalid IP — panel will use rate-limiting only"
    ADMIN_IP=""
  fi

  local cc_label qdisc_label ingress_label
  cc_label=$([ "$BBR_AVAILABLE" -eq 1 ] && echo "BBR" || echo "CUBIC (fallback)")
  qdisc_label=$([ "$CAKE_AVAILABLE" -eq 1 ] && echo "CAKE diffserv4 dual-host" || echo "fq_codel (fallback)")
  ingress_label=$([ "$IFB_AVAILABLE" -eq 1 ] && echo "IFB+CAKE" || echo "egress-only")

  echo ""
  echo -e "${BCYN}╔══════════════════════════════════════════════════════════════╗${RST}"
  echo -e "${BCYN}║       3x-ui VPN PRODUCTION STACK v${SCRIPT_VER}         ║${RST}"
  echo -e "${BCYN}╠══════════════════════════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "DOMAIN"         "$SERVER_DOMAIN"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "SSH_PORT"       "$SSH_PORT"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "ADMIN_IP"       "${ADMIN_IP:-any (rate-limited)}"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "PROFILE"        "balanced — 2 users 200Mbps/user"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "CC"             "$cc_label"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "QDISC"          "$qdisc_label"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "INGRESS"        "$ingress_label"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "EGRESS BW"      "$CAKE_EGRESS_BW (CAKE owns queue)"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "XUI_VERSION"    "${XUI_VERSION_LABEL}"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "ROLLBACK"       "${ROLLBACK_DELAY_MIN}min auto-safety"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "SWAP"           "${SWAP_SIZE_MB}MB"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "PANEL_PORT"     "2053"
  printf "${BCYN}║${RST}  %-26s : %-32s${BCYN}║${RST}\n" "VLESS_PORT"     "443"
  echo -e "${BCYN}╚══════════════════════════════════════════════════════════════╝${RST}"
  echo ""
  printf "${BYLW}Proceed? [y/N]: ${RST}"
  read -r CONFIRM
  [ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }
}

step_backup() {
  step "[1] Backup existing configs"

  local ts
  ts=$(date '+%Y%m%d_%H%M%S')

  [ -f "$NFT_CONF" ]     && cp "$NFT_CONF"    "${BACKUP_DIR}/nftables_${ts}.conf"
  [ -f "$SYSCTL_FILE" ]  && cp "$SYSCTL_FILE" "${BACKUP_DIR}/sysctl_${ts}.conf"
  [ -d /usr/local/x-ui ] && tar -czf "${BACKUP_DIR}/x-ui_${ts}.tar.gz" \
    /usr/local/x-ui 2>/dev/null || true

  nft list ruleset 2>/dev/null > "${BACKUP_DIR}/nftables_live_${ts}.nft" || true
  sysctl -a 2>/dev/null        > "${BACKUP_DIR}/sysctl_live_${ts}.txt"   || true
  cp "$NFT_CONF" "$NFT_BACKUP" 2>/dev/null || true

  ok "Backup → $BACKUP_DIR (ts: $ts)"
}

step_swap() {
  step "[2] Swap"

  if swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
    ok "Swap already active"; return
  fi

  [ -f "$SWAP_FILE" ] && { swapoff "$SWAP_FILE" 2>/dev/null || true; rm -f "$SWAP_FILE"; }

  info "Creating ${SWAP_SIZE_MB}MB swapfile..."
  dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_SIZE_MB" status=none
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >> "$LOG" 2>&1
  swapon  "$SWAP_FILE"
  grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

  ok "Swap ${SWAP_SIZE_MB}MB active"
}

fix_mirrors() {
  step "[3a] Fix APT mirrors"

  local sources="/etc/apt/sources.list"
  local official="http://archive.ubuntu.com/ubuntu"

  if apt-get update -qq >> "$LOG" 2>&1; then
    ok "APT mirrors: OK"; return
  fi

  warn "APT update failed — replacing mirrors with official Ubuntu"
  cp "$sources" "${BACKUP_DIR}/sources.list.bak" 2>/dev/null || true

  local codename
  codename=$(lsb_release -sc 2>/dev/null || echo "jammy")

  cat > "$sources" << EOF
deb ${official} ${codename} main restricted universe multiverse
deb ${official} ${codename}-updates main restricted universe multiverse
deb ${official} ${codename}-backports main restricted universe multiverse
deb ${official} ${codename}-security main restricted universe multiverse
EOF

  if [ -d /etc/apt/sources.list.d ]; then
    for f in /etc/apt/sources.list.d/*.list; do
      [ -f "$f" ] || continue
      grep -qv "^#" "$f" 2>/dev/null && mv "$f" "${f}.disabled" 2>/dev/null || true
    done
  fi

  tee_run apt-get update -qq || die "APT update still failing after mirror fix"
  ok "[3a] Mirrors fixed → $official"
}

step_packages() {
  step "[3] System update + packages"

  fix_mirrors
  tee_run apt-get update -qq
  tee_run apt-get upgrade -y -qq
  tee_run apt-get install -y -qq \
    nftables iproute2 curl wget ca-certificates gnupg \
    dnsutils certbot python3-certbot \
    at \
    "linux-modules-extra-$(uname -r)" \
    || warn "Some packages unavailable — continuing"

  systemctl enable --now atd >> "$LOG" 2>&1 \
    && ok "atd: enabled" || warn "atd: failed to start"

  ok "[3] Done"
}

step_install_xui() {
  step "[4] 3x-ui install"

  if command -v x-ui &>/dev/null && systemctl is-active --quiet x-ui; then
    ok "3x-ui already running — skip install"; return
  fi

  local install_script="/tmp/3x-ui-install.sh"
  info "Downloading 3x-ui (latest main)..."
  curl -fsSLo "$install_script" "$XUI_SCRIPT_URL" \
    || die "Download failed: $XUI_SCRIPT_URL"

  if [ "$XUI_SCRIPT_SHA256" != "SKIP" ]; then
    echo "${XUI_SCRIPT_SHA256}  ${install_script}" | sha256sum -c \
      || die "SHA256 mismatch — possible supply-chain compromise"
    ok "SHA256 verified"
  else
    warn "SHA256 verification SKIPPED"
  fi

  echo -e "${BCYN}  3x-ui prompts → Panel Port: 2053${RST}"
  set +e; bash "$install_script"; local xi=$?; set -e
  rm -f "$install_script"
  [ $xi -ne 0 ] && warn "3x-ui installer exit $xi — verifying binary"

  command -v x-ui >> "$LOG" || die "x-ui binary not found after install"
  systemctl is-active x-ui | grep -q "^active$" || die "x-ui not active after install"

  ok "[4] Done"
}

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
      ok "Cert valid ${days_left} days — skip reissue"; skip_cert=1
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
      printf "Continue anyway? [y/N]: "; read -r dns_ok
      [ "${dns_ok,,}" = "y" ] || die "Fix DNS and re-run"
    else
      ok "DNS OK: $SERVER_DOMAIN → $SERVER_IP"
    fi

    run systemctl start nftables
    nft add rule inet filter input tcp dport 80 accept comment '"certbot-temp"' 2>/dev/null || true

    mkdir -p "$CERT_DIR"
    tee_run certbot certonly \
      --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email \
      -d "$SERVER_DOMAIN" \
      || die "certbot failed — check DNS + port 80"

    local handle
    handle=$(nft -a list chain inet filter input 2>/dev/null | awk '/certbot-temp/{print $NF}')
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

  if openssl s_client \
      -connect "${SERVER_DOMAIN}:443" -servername "${SERVER_DOMAIN}" \
      -verify_return_error </dev/null >> "$LOG" 2>&1; then
    ok "TLS handshake verified on ${SERVER_DOMAIN}:443"
  else
    warn "TLS verify failed — xray may not be configured yet"
  fi

  systemctl enable certbot.timer >> "$LOG" 2>&1 && ok "certbot.timer enabled" || {
    cat > /etc/cron.d/certbot-renew << 'CRON'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl restart x-ui"
CRON
    ok "certbot cron fallback"
  }

  ok "[5] Done — cert expires: $CERT_EXPIRY"
}

benchmark_dns_single() {
  local r="$1" total=0 count=0 ms avg=9999
  for _ in 1 2 3 4 5; do
    ms=$(dig +tries=1 +time=2 google.com @"$r" 2>/dev/null \
      | awk '/Query time:/{print $4}' | head -1)
    [[ "$ms" =~ ^[0-9]+$ ]] && { total=$(( total + ms )); count=$(( count + 1 )); }
  done
  [ "$count" -gt 0 ] && avg=$(( total / count ))
  echo "$avg $r"
}
export -f benchmark_dns_single

step_dns() {
  step "[6] DNS benchmark + systemd-resolved"

  local resolvers=(
    "94.140.14.140" "94.140.14.141"
    "1.1.1.1"       "1.0.0.1"
    "8.8.8.8"       "8.8.4.4"
    "9.9.9.9"       "101.101.101.101"
  )

  info "Benchmarking ${#resolvers[@]} resolvers in parallel..."
  local results
  results=$(printf '%s\n' "${resolvers[@]}" \
    | xargs -P8 -I{} bash -c 'benchmark_dns_single "$@"' _ {} 2>/dev/null | sort -n)

  while IFS=' ' read -r ms r; do
    info "  $r → ${ms}ms"; log "DNS_BENCH: $r = ${ms}ms"
  done <<< "$results"

  DNS_BEST=$(echo "$results" | head -1 | awk '{print $2}')
  DNS_BEST_MS=$(echo "$results" | head -1 | awk '{print $1}')
  local top3
  top3=$(echo "$results" | head -3 | awk '{print $2}')
  ok "Best DNS: $DNS_BEST (${DNS_BEST_MS}ms)"

  local top1 top2 top3_list
  top1=$(echo "$results" | awk "NR==1{print \$2}")
  top2=$(echo "$results" | awk "NR==2{print \$2}")
  top3_list=$(echo "$results" | head -3 | awk "{print \$2}" | tr "\n" " ")

  # Use systemd-resolved native (no dnsmasq, no chattr)
  # This is safer across VPS providers and distros
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-vpn-dns.conf << REOF
[Resolve]
DNS=${top1} ${top2}
FallbackDNS=1.1.1.1 8.8.8.8
DNSStubListener=yes
DNSSEC=allow-downgrade
Cache=yes
ReadEtcHosts=yes
REOF

  must systemctl restart systemd-resolved

  # Point resolv.conf at resolved stub (standard path — no chattr needed)
  local stub_link="/etc/resolv.conf"
  local resolved_stub="/run/systemd/resolve/stub-resolv.conf"
  if [ -f "$resolved_stub" ]; then
    ln -sf "$resolved_stub" "$stub_link" 2>/dev/null || {
      echo "nameserver 127.0.0.53" > "$stub_link"
    }
    ok "resolv.conf → systemd-resolved stub (127.0.0.53)"
  else
    echo "nameserver ${top1}" > "$stub_link"
    warn "resolved stub not ready — writing top DNS directly"
  fi

  # Disable NetworkManager DNS override if present (gentle — not aggressive)
  if [ -d /etc/NetworkManager/conf.d ]; then
    printf "[main]\ndns=systemd-resolved\n"       > /etc/NetworkManager/conf.d/99-dns-resolved.conf
    run systemctl reload NetworkManager
  fi

  local dig_r
  dig_r=$(dig +short +time=3 google.com 2>/dev/null | head -1)
  [ -n "$dig_r" ]     && ok "DNS resolved: google.com → $dig_r (via resolved, top DNS: $top1)"     || warn "DNS lookup failed — check systemd-resolved"

  info "Top 3 DNS used: $top3_list"
  ok "[6] Done"
}

step_sysctl() {
  step "[7] sysctl — BBR + balanced profile"

  local cc="cubic"
  [ "$BBR_AVAILABLE" -eq 1 ] && cc="bbr"

  local qdisc="fq_codel"
  [ "$CAKE_AVAILABLE" -eq 1 ] && qdisc="cake"

  cat > "$SYSCTL_FILE" << EOF
net.core.default_qdisc             = ${qdisc}
net.ipv4.tcp_congestion_control    = ${cc}

net.core.rmem_max                  = 16777216
net.core.wmem_max                  = 16777216
net.ipv4.tcp_rmem                  = 4096 262144 16777216
net.ipv4.tcp_wmem                  = 4096 262144 16777216

net.ipv4.tcp_notsent_lowat         = 131072

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn                   = 1
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_fastopen              = 3

net.ipv4.tcp_keepalive_time        = 60
net.ipv4.tcp_keepalive_intvl       = 10
net.ipv4.tcp_keepalive_probes      = 5

net.ipv4.tcp_syn_retries           = 4
net.ipv4.tcp_synack_retries        = 3

net.core.optmem_max                = 65536
net.core.netdev_max_backlog        = 5000
net.core.somaxconn                 = 2048
net.ipv4.tcp_max_syn_backlog       = 2048

net.ipv4.ip_forward                = 1
net.ipv6.conf.all.forwarding       = 1
net.ipv6.conf.default.forwarding   = 1

net.ipv4.conf.all.rp_filter        = 1
net.ipv4.conf.default.rp_filter    = 1

net.ipv4.conf.all.accept_redirects  = 0
net.ipv6.conf.all.accept_redirects  = 0
net.ipv4.conf.all.send_redirects    = 0
net.ipv4.conf.all.accept_source_route = 0

net.ipv6.conf.all.use_tempaddr     = 0

vm.swappiness                      = 10
vm.vfs_cache_pressure              = 50
EOF

  if [ "$VIRT_RESTRICTED" -ne 1 ]; then
    cat >> "$SYSCTL_FILE" << EOF
net.netfilter.nf_conntrack_max                     = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 15
net.netfilter.nf_conntrack_udp_timeout             = 30
net.netfilter.nf_conntrack_udp_timeout_stream      = 120
EOF
  fi

  sysctl --system >> "$LOG" 2>&1

  local actual_cc actual_qdisc
  actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")

  [ "$actual_cc" = "$cc" ] \
    && ok "CC verified: $actual_cc" || warn "CC mismatch: expected $cc got $actual_cc"
  [ "$actual_qdisc" = "$qdisc" ] \
    && ok "default_qdisc verified: $actual_qdisc" || warn "qdisc mismatch: expected $qdisc got $actual_qdisc"

  local fwd
  fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
  [ "$fwd" = "1" ] && ok "ip_forward: 1" || warn "ip_forward not set"

  ok "[7] Done"
}

probe_mtu_mss() {
  step "[8] PMTU probe → MSS"

  local target="8.8.8.8"
  local probed_mtu=1500

  if command -v tracepath &>/dev/null; then
    local tp_mtu
    tp_mtu=$(tracepath -n "$target" 2>/dev/null \
      | awk '/pmtu/{match($0,/pmtu ([0-9]+)/,a); if(a[1]) print a[1]}' | tail -1)
    if [[ "$tp_mtu" =~ ^[0-9]+$ ]] && [ "$tp_mtu" -gt 576 ]; then
      probed_mtu="$tp_mtu"
      info "tracepath PMTU: ${probed_mtu}"
    fi
  fi

  COMPUTED_MSS=$(( probed_mtu - 60 ))
  [ "$COMPUTED_MSS" -lt 576  ] && COMPUTED_MSS=576
  [ "$COMPUTED_MSS" -gt 1420 ] && COMPUTED_MSS=1420

  info "PMTU: ${probed_mtu} → MSS clamp: ${COMPUTED_MSS}"
  log "PMTU_PROBE: mtu=$probed_mtu mss=$COMPUTED_MSS"
  ok "[8] MSS: $COMPUTED_MSS"
}

step_qdisc() {
  step "[9] qdisc — CAKE + IFB ingress"

  local cake_egress_opts="bandwidth ${CAKE_EGRESS_BW} diffserv4 dual-srchost dual-dsthost nat wash overhead 40 mpu 64 target 5ms interval 50ms"
  local cake_ingress_opts="bandwidth ${CAKE_INGRESS_BW} diffserv4 dual-srchost dual-dsthost nat wash overhead 40 mpu 64 target 5ms interval 50ms"

  cat > "$QDISC_SCRIPT" << QEOF
#!/usr/bin/env bash
set -euo pipefail
TC=/sbin/tc
IFACE=\$(ip route show default 2>/dev/null | awk 'NR==1{print \$5}')
[ -z "\$IFACE" ] && { echo "No default interface"; exit 1; }

\$TC qdisc del dev "\$IFACE" root    2>/dev/null || true
\$TC qdisc del dev "\$IFACE" ingress 2>/dev/null || true

if \$TC qdisc add dev "\$IFACE" root cake ${cake_egress_opts} 2>/dev/null; then
  echo "CAKE egress applied on \$IFACE (${CAKE_EGRESS_BW})"
else
  \$TC qdisc add dev "\$IFACE" root fq_codel \
    limit 1000 target 5ms interval 50ms quantum 1514 2>/dev/null || true
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
  \$TC qdisc add dev ifb0 root cake ${cake_ingress_opts} 2>/dev/null \
    && echo "CAKE ingress applied via ifb0 (${CAKE_INGRESS_BW})" \
    || echo "ifb0 CAKE failed — ingress unmanaged"
fi
QEOF
  chmod +x "$QDISC_SCRIPT"

  bash "$QDISC_SCRIPT" 2>&1 | tee -a "$LOG"

  local applied
  applied=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  QDISC_APPLIED="${applied} on ${IFACE}"
  [ "$IFB_AVAILABLE" -eq 1 ] && QDISC_APPLIED+=" + IFB ingress"

  rm -f /etc/systemd/system/vpn-qdisc.service
  cat > /etc/systemd/system/vpn-qdisc.service << EOF
[Unit]
Description=CAKE qdisc — balanced 2-user 200Mbps fair-share
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
  must systemctl enable vpn-qdisc
  ok "[9] qdisc: $QDISC_APPLIED"
}

step_nat() {
  step "[9b] Full-tunnel NAT + routing verification"

  SERVER_IPV6=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null     | awk '/inet6/{print $2; exit}' | cut -d/ -f1 || true)

  if [ -n "$SERVER_IPV6" ]; then
    HAS_IPV6=1
    ok "IPv6 detected: $SERVER_IPV6"
  else
    HAS_IPV6=0
    warn "No global IPv6 on $IFACE — IPv6 NAT will be skipped"
  fi

  if ! modprobe nf_nat 2>/dev/null && ! modprobe nf_nat_ipv4 2>/dev/null; then
    warn "nf_nat module not loaded — masquerade may fail on older kernels"
  else
    ok "nf_nat: loaded"
  fi

  [ "$HAS_IPV6" -eq 1 ] && modprobe nf_nat_ipv6 >> "$LOG" 2>&1 || true

  local v4_fwd
  v4_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  [ "$v4_fwd" = "1" ] && ok "ip_forward: verified" || die "ip_forward not active"

  local rp
  rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "?")
  info "rp_filter: $rp"

  ping -c1 -W3 8.8.8.8 >> "$LOG" 2>&1     && ok "Outbound IPv4: reachable" || warn "Outbound IPv4: ping failed (may be filtered)"

  [ "$HAS_IPV6" -eq 1 ] && {
    ping6 -c1 -W3 2001:4860:4860::8888 >> "$LOG" 2>&1       && ok "Outbound IPv6: reachable" || warn "Outbound IPv6: ping6 failed"
  }

  ok "[9b] Done — full-tunnel NAT ready"
}

schedule_rollback() {
  if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd 2>/dev/null; then
    warn "atd unavailable — no automatic firewall rollback"; return
  fi
  AT_JOB_ID=$(echo "systemctl stop nftables && nft flush ruleset" \
    | at "now + ${ROLLBACK_DELAY_MIN} minutes" 2>&1 | awk '/^job/{print $2}')
  if [ -n "$AT_JOB_ID" ]; then
    warn "ROLLBACK SCHEDULED: nftables clears in ${ROLLBACK_DELAY_MIN}min (job #${AT_JOB_ID})"
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
  step "[10] nftables — dual-stack ruleset"

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

    ct state established,related accept
    ct state invalid drop

    iifname "${IFACE}" oifname "${IFACE}" drop

    ct state new oifname "${IFACE}" accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100;

    oifname "${IFACE}" masquerade fully-random
  }
}

table ip6 nat {
  chain postrouting {
    type nat hook postrouting priority 100;

    oifname "${IFACE}" masquerade fully-random
  }
}

table inet mangle {
  chain prerouting {
    type filter hook prerouting priority -150;

    tcp dport 443 ip  dscp set cs4
    udp dport 443 ip  dscp set cs4
    tcp dport 443 ip6 dscp set cs4
    udp dport 443 ip6 dscp set cs4
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
      && ok "SSH port ${SSH_PORT} rule: present" || warn "SSH port ${SSH_PORT} rule not found"
    echo "$ruleset" | grep -qE "dport.*443" \
      && ok "Port 443 rule: present" || warn "Port 443 rule not found"
    echo "$ruleset" | grep -qE "ssh_blocklist" \
      && ok "SSH blocklist sets: present" || warn "SSH blocklist sets not found"

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

step_xui_tuning() {
  step "[11] x-ui resource isolation"

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
    && ok "x-ui active" || warn "x-ui not active after restart"

  local xui_pid xui_fdlimit
  xui_pid=$(pgrep -f x-ui | head -1 || true)
  if [ -n "$xui_pid" ]; then
    xui_fdlimit=$(cat "/proc/${xui_pid}/limits" 2>/dev/null \
      | awk '/Max open files/{print $4}' || echo "?")
    ok "x-ui PID $xui_pid — FD limit: $xui_fdlimit"
  fi

  cat > /root/xray-settings.txt << 'XEOF'
VLESS+Reality — Balanced Profile (2 users / 200 Mbps each)
===========================================================

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
  bufferSize : 64 (kb)

Users: 2 — no bandwidth cap needed in panel
CAKE dual-srchost/dsthost handles fair-share automatically
Each user gets up to ~190 Mbps (380Mbps CAKE / 2 users)
Gaming traffic prioritized via diffserv4 + cs4 DSCP

Expected performance (client RTT 25-45ms):
  ROV/DOTA2  : excellent  — low-latency tier in CAKE
  Valorant   : excellent  — UDP 443 gets cs4 priority
  YouTube    : excellent  — CAKE fills available bandwidth
  Discord    : excellent  — voice gets cs4 tier
  Downloads  : good       — bulk gets fair share, no starvation
XEOF

  ok "[11] Done"
}

step_health_check() {
  step "[12] Health verification"

  local pass=0 fail=0
  check_pass() { ok "  CHECK ✓ $*";   (( pass++ )) || true; }
  check_fail() { warn "  CHECK ✗ $*"; (( fail++ )) || true; }

  systemctl is-active x-ui      | grep -q "^active$" \
    && check_pass "x-ui: active"           || check_fail "x-ui: not active"
  systemctl is-active nftables   | grep -q "^active$" \
    && check_pass "nftables: active"       || check_fail "nftables: not active"
  systemctl is-active systemd-resolved | grep -q "^active$" \
    && check_pass "systemd-resolved: active" || check_fail "systemd-resolved: not active"
  systemctl is-active vpn-qdisc  | grep -q "^active$" \
    && check_pass "vpn-qdisc: active"      || check_fail "vpn-qdisc: not active"

  ss -tlnp 2>/dev/null | grep -q ":443 " \
    && check_pass "Port 443: bound"        || check_fail "Port 443: not bound"
  ss -tlnp 2>/dev/null | grep -q ":2053 " \
    && check_pass "Port 2053: bound"       || check_fail "Port 2053: not bound"

  local panel_code
  panel_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
    "https://${SERVER_DOMAIN}:2053/" 2>/dev/null || echo "000")
  [[ "$panel_code" =~ ^(200|301|302|401|403)$ ]] \
    && check_pass "Panel HTTP: $panel_code" || check_fail "Panel HTTP: $panel_code"

  local dns_r
  dns_r=$(dig +short +time=3 google.com 2>/dev/null | head -1)
  [ -n "$dns_r" ] \
    && check_pass "DNS: google.com → $dns_r" || check_fail "DNS: lookup failed"

  local qdisc_active
  qdisc_active=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  [ -n "$qdisc_active" ] \
    && check_pass "qdisc: $qdisc_active on $IFACE" || check_fail "qdisc: none on $IFACE"

  local actual_cc
  actual_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  [ "$actual_cc" = "bbr" ] \
    && check_pass "TCP CC: bbr" || check_fail "TCP CC: $actual_cc (not bbr)"

  nft list ruleset 2>/dev/null | grep -qE "dport.*443" \
    && check_pass "nftables port 443" || check_fail "nftables port 443 missing"

  nft list ruleset 2>/dev/null | grep -q "masquerade" \
    && check_pass "NAT masquerade: present" || check_fail "NAT masquerade: missing"

  nft list ruleset 2>/dev/null | grep -q "ct state new oifname" \
    && check_pass "Forward rule: present" || check_fail "Forward rule: missing"

  local v4_fwd
  v4_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  [ "$v4_fwd" = "1" ] \
    && check_pass "ip_forward: 1" || check_fail "ip_forward: not set"

  swapon --show 2>/dev/null | grep -q "$SWAP_FILE" \
    && check_pass "Swap: active" || check_fail "Swap: not active"

  echo ""
  info "Health: ${pass} passed, ${fail} failed"
  log "HEALTH: pass=$pass fail=$fail"
  [ "$fail" -gt 0 ] && warn "Some checks failed — review above" || ok "All health checks passed"
}

step_observability() {
  step "[13] Observability snapshot"

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
    wc -l /proc/net/nf_conntrack 2>/dev/null | \
      xargs -I{} echo "conntrack entries: {}" | tee -a "$LOG" || true
  fi

  metric "=== TCP sockets ==="
  ss -s 2>/dev/null | tee -a "$LOG"

  metric "=== Memory ==="
  free -m 2>/dev/null | tee -a "$LOG"

  metric "=== Swap ==="
  swapon --show 2>/dev/null | tee -a "$LOG"

  ok "[13] Snapshot saved to $LOG"
}

step_summary() {
  step "[14] Final summary"

  local xui_status nft_status dns_status qds_status tcp_cc tcp_qd swap_info
  xui_status=$(systemctl is-active x-ui        2>/dev/null || echo "inactive")
  nft_status=$(systemctl is-active nftables    2>/dev/null || echo "inactive")
  dns_status=$(systemctl is-active systemd-resolved 2>/dev/null || echo "inactive")
  qds_status=$(systemctl is-active vpn-qdisc   2>/dev/null || echo "inactive")
  tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
  tcp_qd=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
  swap_info=$(swapon --show 2>/dev/null | grep -c "$SWAP_FILE" \
    && echo "${SWAP_SIZE_MB}MB active" || echo "inactive") 2>/dev/null || swap_info="inactive"

  echo ""
  echo -e "${BCYN}╔══════════════════════════════════════╦════════════════════════════════════════╗${RST}"
  echo -e "${BCYN}║ Setting                              ║ Value                                  ║${RST}"
  echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "x-ui"           "$xui_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Panel URL"      "https://$SERVER_DOMAIN:2053/"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Cert expires"   "$CERT_EXPIRY"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Admin IP"       "${ADMIN_IP:-any (rate-limited)}"
  echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP CC"         "$tcp_cc"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "qdisc egress"   "${tcp_qd} on ${IFACE} (${CAKE_EGRESS_BW})"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "qdisc ingress"  "$( ip link show ifb0 &>/dev/null 2>/dev/null && echo "CAKE on ifb0 (${CAKE_INGRESS_BW})" || echo "none" )"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "NIC speed"      "${NIC_SPEED_MBIT}Mbit → egress=${CAKE_EGRESS_BW} ingress=${CAKE_INGRESS_BW}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "CAKE mode"      "diffserv4 dual-srchost dual-dsthost"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "NAT masquerade" "ip + ip6 → $IFACE (full tunnel)"
  local ipv6_label; [ "$HAS_IPV6" -eq 1 ] && ipv6_label="$SERVER_IPV6" || ipv6_label="none detected"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "IPv6"           "$ipv6_label"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "MSS clamp"      "${COMPUTED_MSS}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Swap"           "$swap_info"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Conntrack max"  "$CONNTRACK_MAX"
  echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "nftables"       "$nft_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "systemd-resolved" "$dns_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Best DNS"       "${DNS_BEST} (${DNS_BEST_MS}ms)"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "vpn-qdisc"      "$qds_status"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "XUI version"    "${XUI_VERSION_LABEL}"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Backup"         "$BACKUP_DIR"
  printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Log"            "$LOG"
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
  echo    "     bufferSize: 64"
  echo ""
  echo    "  3. Add 2 users — NO bandwidth cap in panel"
  echo    "     Fair-share handled by CAKE dual-srchost/dsthost"
  echo    "  4. cat /root/xray-settings.txt"
  echo ""
  echo -e "${BGRN}══════════════════════════════════════════════════════${RST}"

  log "========== Script v${SCRIPT_VER} completed =========="
}

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
  step_nat
  step_nftables
  step_xui_tuning
  step_health_check
  step_observability
  step_summary
}

main "$@"
