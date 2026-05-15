#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
#
#    █████╗ ██╗███████╗    ██╗██████╗  █████╗ ██╗  ██╗██████╗ ██████╗ ███████╗
#   ██╔══██╗██║██╔════╝   ███║╚════██╗╚════██╗██║ ██╔╝██╔══██╗██╔══██╗██╔════╝
#   ███████║██║███████╗   ╚██║ █████╔╝ █████╔╝█████╔╝ ██████╔╝██████╔╝███████╗
#   ██╔══██║██║╚════██║    ██║██╔═══╝  ╚═══██╗██╔═██╗ ██╔══██╗██╔═══╝ ╚════██║
#   ██║  ██║██║███████║    ██║███████╗ █████╔╝██║  ██╗██████╔╝██║     ███████║
#   ╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝╚══════╝ ╚════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝     ╚══════╝
#
#   AIS 128Kbps — Anti-Bufferbloat VPS Setup for 3x-ui + VLESS+Reality
#   By (IG:peepogrob555  FB:Shogun)
#
#   v2.3 — Full Production Grade
#   Features: Dual CAKE (ingress+egress), adaptive bandwidth probe, DNS
#             benchmarking, TCP pacing, Xray sockopt tuning, virt detection,
#             dynamic conntrack, IFB ingress shaping
#   Changes v2.1: removed email prompt (--register-unsafely-without-email),
#                 full verbose output on all steps (tee to log)
#   Changes v2.2: fix chattr crash on KVM providers that don't support it,
#                 fallback to systemd-resolved + NetworkManager dns=none
#   Changes v2.3: add port 80 in nftables for certbot renewal,
#                 pre-open port 80 before dry-run test,
#                 fix x-ui version detection (no longer prints menu)
# ═══════════════════════════════════════════════════════════════════════════════

LOG=/var/log/3x-ui-ais-setup.log
CERT_DIR=/etc/ssl/xray
SCRIPT_VER="2.3"

BGRN='\033[1;32m'
BCYN='\033[1;36m'
BYLW='\033[1;33m'
BRED='\033[1;31m'
BMAG='\033[1;35m'
RST='\033[0m'

QDISC_APPLIED="unknown"
INGRESS_APPLIED="none"
IFACE=""
BW_KBIT=128
VIRT_TYPE="unknown"
CAKE_OK=0
DNS_BEST=""

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
info() { echo -e "${BCYN}$*${RST}"; log "INFO: $*"; }
ok()   { echo -e "${BGRN}✓ $*${RST}"; log "OK:   $*"; }
warn() { echo -e "${BYLW}⚠ WARNING: $*${RST}"; log "WARN: $*"; }
die()  { echo -e "${BRED}[FATAL] $*${RST}"; log "FATAL: $*"; echo "See full log: $LOG"; exit 1; }
step() { echo -e "\n${BMAG}━━━ $* ━━━${RST}"; log "STEP: $*"; }

# tee_run: run a command and show output on screen AND save to log
tee_run() { "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

[ "$EUID" -ne 0 ] && die "Run as root: sudo bash $0"
touch "$LOG"
log "========== Script v${SCRIPT_VER} started =========="

# ═══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT: Virtualization + Hardware Detection
# ═══════════════════════════════════════════════════════════════════════════════

step "Pre-flight: environment detection"

detect_virt() {
  if command -v systemd-detect-virt &>/dev/null; then
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
  elif [ -f /proc/1/environ ] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    VIRT_TYPE="lxc"
  elif grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
    VIRT_TYPE="kvm"
  else
    VIRT_TYPE="none"
  fi

  case "$VIRT_TYPE" in
    lxc|openvz)
      warn "Detected $VIRT_TYPE — some kernel features may be restricted"
      warn "CAKE/IFB/tc may not work. Script will auto-fallback."
      VIRT_RESTRICTED=1
      ;;
    kvm|qemu|vmware|xen|microsoft)
      info "Detected VM: $VIRT_TYPE — full kernel access expected"
      VIRT_RESTRICTED=0
      ;;
    none|*)
      info "Detected: bare-metal or unknown ($VIRT_TYPE)"
      VIRT_RESTRICTED=0
      ;;
  esac
}
detect_virt

TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
CPU_COUNT=$(nproc)
KERNEL_VER=$(uname -r)

CONNTRACK_MAX=$(( TOTAL_RAM_MB * 8 ))
[ "$CONNTRACK_MAX" -lt 8192  ] && CONNTRACK_MAX=8192
[ "$CONNTRACK_MAX" -gt 65536 ] && CONNTRACK_MAX=65536

info "RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_COUNT} | Kernel: ${KERNEL_VER}"
info "Auto conntrack_max: ${CONNTRACK_MAX} (based on RAM)"
info "Virt: ${VIRT_TYPE} | Restricted: ${VIRT_RESTRICTED:-0}"

# ═══════════════════════════════════════════════════════════════════════════════
# USER INPUT PHASE
# ═══════════════════════════════════════════════════════════════════════════════

step "Input collection"

while true; do
  echo -e "${BCYN}[INPUT] Server domain (FQDN, e.g. cdn1.example.com):${RST} "
  read -r SERVER_DOMAIN
  [[ "$SERVER_DOMAIN" =~ \. ]] \
    && [[ ! "$SERVER_DOMAIN" =~ \  ]] \
    && [[ ! "$SERVER_DOMAIN" =~ ^http ]] \
    && [[ ! "$SERVER_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    && break
  echo -e "${BRED}Invalid domain — must be FQDN, no IP, no spaces, no http://${RST}"
done

DETECTED_SSH=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | head -1 || true)
if [ -n "$DETECTED_SSH" ]; then
  echo -e "${BCYN}[INPUT] Detected SSH port: ${DETECTED_SSH}. Press Enter or type new port:${RST} "
  read -r SSH_INPUT
  SSH_PORT="${SSH_INPUT:-$DETECTED_SSH}"
else
  echo -e "${BCYN}[INPUT] SSH port not auto-detected. Enter SSH port:${RST} "
  read -r SSH_PORT
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT must be numeric: $SSH_PORT"
[ -z "$SSH_PORT" ] && die "SSH_PORT empty — aborting to prevent lockout"

echo -e "${BCYN}[INPUT] AIS target bandwidth kbps (default 128, range 64-512):${RST} "
read -r BW_INPUT
if [[ "$BW_INPUT" =~ ^[0-9]+$ ]] && [ "$BW_INPUT" -ge 64 ] && [ "$BW_INPUT" -le 512 ]; then
  BW_KBIT="$BW_INPUT"
else
  BW_KBIT=128
  info "Using default 128kbps"
fi

echo ""
echo -e "${BCYN}╔══════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BCYN}║              CONFIGURATION SUMMARY v${SCRIPT_VER}                   ║${RST}"
echo -e "${BCYN}╠══════════════════════════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "SERVER_DOMAIN"   "$SERVER_DOMAIN"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "SSH_PORT"        "$SSH_PORT"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "ADMIN_EMAIL"     "(none — unsafely-without-email)"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "TARGET_BW"       "${BW_KBIT}kbps"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "PANEL_PORT"      "2053"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "VLESS_PORT"      "443"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "SNI"             "th.speedtest.net"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "CERT_DIR"        "$CERT_DIR"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "VIRT_TYPE"       "$VIRT_TYPE"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "RAM"             "${TOTAL_RAM_MB}MB"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "CONNTRACK_MAX"   "$CONNTRACK_MAX"
echo -e "${BCYN}╚══════════════════════════════════════════════════════════════╝${RST}"
echo ""
echo -e -n "${BYLW}Proceed? [y/N]: ${RST}"
read -r CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1 — System Update + 3x-ui Install
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 1] System update + 3x-ui install"

info "Running apt-get update ..."
tee_run apt-get update

info "Running apt-get upgrade ..."
tee_run apt-get upgrade -y

info "Installing required packages ..."
tee_run apt-get install -y \
  nftables dnsmasq iproute2 curl wget \
  ca-certificates gnupg dnsutils \
  certbot python3-certbot \
  "linux-modules-extra-$(uname -r)" \
  || warn "linux-modules-extra failed — CAKE may be unavailable (fq_codel fallback used)"

if command -v x-ui &>/dev/null && systemctl is-active --quiet x-ui; then
  ok "[STEP 1] 3x-ui already installed and running — skipping ✓"
else
  echo -e "${BCYN}"
  echo "  ══════════════════════════════════════════════════"
  echo "  3x-ui installer — answer the prompts:"
  echo "  Panel Port    → enter: 2053"
  echo "  Username      → choose your own"
  echo "  Password      → choose your own"
  echo "  Web Base Path → note it down"
  echo "  ══════════════════════════════════════════════════"
  echo -e "${RST}"
  set +e
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  INSTALL_EXIT=$?
  set -e
  [ $INSTALL_EXIT -ne 0 ] && warn "3x-ui installer exited $INSTALL_EXIT — verifying binary"
fi

which x-ui | tee -a "$LOG" || die "step1: x-ui binary not found"
x-ui status 2>/dev/null || true
systemctl is-active x-ui | grep -q "^active$" || die "step1: x-ui not active"

ok "[STEP 1] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2 — TLS Certificate
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 2] TLS certificate"

CERT_LIVE="/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem"

if [ -f "$CERT_LIVE" ]; then
  CERT_EXPIRY_CHECK=$(openssl x509 -enddate -noout -in "$CERT_LIVE" 2>/dev/null | cut -d= -f2 || echo "unknown")
  ok "[STEP 2] Certificate exists (expires: $CERT_EXPIRY_CHECK) — skipping certbot"
else
  RESOLVED_IP=$(dig +short "$SERVER_DOMAIN" A | tail -1)
  SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || curl -s4 ifconfig.me 2>/dev/null || echo "")

  if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    warn "DNS: $SERVER_DOMAIN → $RESOLVED_IP but server IP is $SERVER_IP"
    echo -n "Continue anyway? [y/N]: "
    read -r dns_confirm
    [ "${dns_confirm,,}" = "y" ] || die "step2: DNS mismatch — fix DNS first"
  else
    ok "DNS check: $SERVER_DOMAIN → $SERVER_IP"
  fi

  systemctl start nftables 2>/dev/null || true

  _remove_port80() {
    local handle
    handle=$(nft -a list chain inet filter input 2>/dev/null | awk '/certbot-temp/{print $NF}')
    [ -n "$handle" ] && nft delete rule inet filter input handle "$handle" 2>/dev/null \
      && log "certbot-temp port 80 removed" || true
  }
  trap _remove_port80 EXIT
  nft add rule inet filter input tcp dport 80 accept comment \"certbot-temp\" 2>/dev/null || true

  mkdir -p "$CERT_DIR"
  info "Running certbot (--register-unsafely-without-email) ..."
  tee_run certbot certonly \
    --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email \
    -d "$SERVER_DOMAIN" \
    || die "step2: certbot failed — check DNS + port 80. See $LOG"

  _remove_port80
  trap - EXIT
fi

mkdir -p "$CERT_DIR"
ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/privkey.pem"   "$CERT_DIR/key.pem"
ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/cert.pem"      "$CERT_DIR/cert.pem"

chmod 750 "$CERT_DIR"
chmod 750 "/etc/letsencrypt/live/$SERVER_DOMAIN"
chmod 640 "/etc/letsencrypt/live/$SERVER_DOMAIN"/*.pem 2>/dev/null || true

x-ui setting -certFile "$CERT_DIR/fullchain.pem" -keyFile "$CERT_DIR/key.pem" 2>/dev/null || {
  warn "x-ui CLI cert flags not supported — set manually in panel:"
  warn "  Panel Settings → Panel Certificate"
  warn "  Certificate : $CERT_DIR/fullchain.pem  |  Private Key : $CERT_DIR/key.pem"
}
systemctl restart x-ui

HOOK_FILE="/etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh"
[ ! -f "$HOOK_FILE" ] && cat > "$HOOK_FILE" << 'EOF'
#!/bin/bash
systemctl restart x-ui
EOF
chmod +x "$HOOK_FILE"

info "Running certbot dry-run ..."
# Temporarily allow port 80 in case nftables is active (certbot standalone needs it)
nft add rule inet filter input tcp dport 80 accept 2>/dev/null || true
tee_run certbot renew --dry-run && ok "certbot dry-run passed" || warn "certbot dry-run failed — check $LOG"

for f in fullchain.pem key.pem cert.pem; do
  [ -L "$CERT_DIR/$f" ] && [ -f "$CERT_DIR/$f" ] \
    && ok "Symlink OK: $CERT_DIR/$f" \
    || warn "Symlink broken: $CERT_DIR/$f"
done

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$SERVER_DOMAIN:2053/" --connect-timeout 5 || true)
[[ "$HTTP_CODE" =~ ^(200|301|302|400|401|403|404)$ ]] \
  && ok "Panel HTTPS reachable (HTTP $HTTP_CODE)" \
  || warn "Panel HTTPS not reachable yet (code: $HTTP_CODE) — configure cert in panel UI"

ok "[STEP 2] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3 — DNS Benchmark + dnsmasq
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 3] DNS benchmark + dnsmasq"

benchmark_dns() {
  local resolver=$1
  local ms
  ms=$(dig +tries=2 +time=2 google.com @"$resolver" 2>/dev/null \
    | awk '/Query time:/{print $4}' | head -1)
  echo "${ms:-9999}"
}

info "Benchmarking DNS resolvers (this takes ~10s) ..."

declare -A DNS_LATENCY
RESOLVERS=(
  "94.140.14.140"
  "94.140.14.141"
  "1.1.1.1"
  "1.0.0.1"
  "8.8.8.8"
  "8.8.4.4"
  "9.9.9.9"
  "101.101.101.101"
)

for r in "${RESOLVERS[@]}"; do
  ms=$(benchmark_dns "$r")
  DNS_LATENCY["$r"]="$ms"
  info "  $r → ${ms}ms"
  log "DNS_BENCH: $r = ${ms}ms"
done

SORTED_RESOLVERS=$(
  for r in "${!DNS_LATENCY[@]}"; do
    echo "${DNS_LATENCY[$r]} $r"
  done | sort -n | awk '{print $2}'
)

DNS_BEST=$(echo "$SORTED_RESOLVERS" | head -1)
ok "Best DNS resolver: $DNS_BEST (${DNS_LATENCY[$DNS_BEST]}ms)"

TOP3_DNS=$(echo "$SORTED_RESOLVERS" | head -3)

if systemctl is-active --quiet dnsmasq \
   && grep -q "listen-address=127.0.0.1" /etc/dnsmasq.conf 2>/dev/null; then
  ok "[STEP 3] dnsmasq already configured — refreshing resolver order"
fi

RESOLVED_CONF="/etc/systemd/resolved.conf"
if grep -q "^DNSStubListener" "$RESOLVED_CONF" 2>/dev/null; then
  sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' "$RESOLVED_CONF"
else
  echo "DNSStubListener=no" >> "$RESOLVED_CONF"
fi
info "Restarting systemd-resolved ..."
tee_run systemctl restart systemd-resolved

cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%s) 2>/dev/null || true

{
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "port=53"
  while IFS= read -r r; do
    echo "server=$r"
  done <<< "$TOP3_DNS"
  cat << 'DNSEOF'
cache-size=2048
min-cache-ttl=30
neg-ttl=10
dns-forward-max=150
no-resolv
DNSEOF
} > /etc/dnsmasq.conf

chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Try chattr lock — gracefully skip if filesystem doesn't support it (some KVM providers)
if chattr +i /etc/resolv.conf 2>/dev/null; then
  ok "resolv.conf locked to 127.0.0.1 (chattr +i)"
else
  warn "chattr not supported on this filesystem — using systemd-resolved static config instead"
  # Lock via systemd-resolved: set DNS to 127.0.0.1 and disable dynamic updates
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-dnsmasq.conf << 'RESEOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
ReadEtcHosts=yes
RESEOF
  # Also drop a NetworkManager override to prevent it from rewriting resolv.conf
  if [ -d /etc/NetworkManager/conf.d ]; then
    cat > /etc/NetworkManager/conf.d/99-dns-none.conf << 'NMEOF'
[main]
dns=none
NMEOF
    systemctl reload NetworkManager 2>/dev/null || true
  fi
  # Re-write resolv.conf since chattr failed
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
  ok "resolv.conf set to 127.0.0.1 (systemd-resolved + NM override)"
fi

info "Enabling dnsmasq ..."
tee_run systemctl enable --now dnsmasq \
  || die "step3: dnsmasq failed — check: journalctl -u dnsmasq"

DIG_RESULT=$(dig +short google.com @127.0.0.1 2>/dev/null | head -1)
[ -n "$DIG_RESULT" ] && ok "dnsmasq: google.com → $DIG_RESULT" || warn "dnsmasq: google.com failed"

SNI_RESULT=$(dig +short th.speedtest.net @127.0.0.1 2>/dev/null | head -1)
[ -n "$SNI_RESULT" ] && ok "dnsmasq: th.speedtest.net → $SNI_RESULT" \
  || warn "th.speedtest.net failed — Reality handshakes +40ms per connection"

ok "[STEP 3] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Adaptive Bandwidth Probe + sysctl Tuning
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 4] Adaptive bandwidth probe + sysctl tuning"

probe_bandwidth() {
  info "Probing actual available bandwidth to calibrate CAKE ..."

  local probe_url="http://speedtest.truemoveh.com/1MB.bin"
  local alt_url="http://speed.hetzner.de/1MB.bin"
  local bytes ms_elapsed kbps url

  url="$probe_url"
  local start_ms end_ms
  start_ms=$(date +%s%3N)

  info "  Downloading from $url ..."
  bytes=$(curl -s -m 8 --max-filesize 524288 -w "%{size_download}" \
    -o /dev/null "$url" 2>/dev/null || echo "0")

  end_ms=$(date +%s%3N)
  ms_elapsed=$(( end_ms - start_ms ))
  info "  → ${bytes} bytes in ${ms_elapsed}ms"

  if [ "$bytes" -lt 10240 ] || [ "$ms_elapsed" -lt 100 ]; then
    info "Primary probe insufficient, trying fallback ($alt_url) ..."
    start_ms=$(date +%s%3N)
    bytes=$(curl -s -m 8 --max-filesize 524288 -w "%{size_download}" \
      -o /dev/null "$alt_url" 2>/dev/null || echo "0")
    end_ms=$(date +%s%3N)
    ms_elapsed=$(( end_ms - start_ms ))
    info "  → ${bytes} bytes in ${ms_elapsed}ms"
  fi

  if [ "$bytes" -gt 10240 ] && [ "$ms_elapsed" -gt 100 ]; then
    kbps=$(( (bytes * 8) / ms_elapsed ))
    log "Probe: ${bytes}B in ${ms_elapsed}ms = ${kbps}kbps"

    if [ "$kbps" -gt 30 ] && [ "$kbps" -lt 2000 ]; then
      local safe_bw=$(( kbps * 90 / 100 ))
      [ "$safe_bw" -lt 64 ] && safe_bw=64
      info "Probed bandwidth: ${kbps}kbps → CAKE shaping at ${safe_bw}kbps (90%)"
      BW_KBIT="$safe_bw"
      return 0
    fi
  fi

  info "Probe inconclusive — using user-specified ${BW_KBIT}kbps"
  return 1
}

echo -e "${BCYN}Run adaptive bandwidth probe? (takes ~10s) [Y/n]: ${RST}"
read -r DO_PROBE
if [ "${DO_PROBE,,}" != "n" ]; then
  probe_bandwidth || true
fi

ok "CAKE bandwidth target: ${BW_KBIT}kbps"

SYSCTL_FILE="/etc/sysctl.d/99-ais-128k.conf"

if [ -f "$SYSCTL_FILE" ] \
   && sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$" \
   && sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null | grep -q "^16384$"; then
  ok "[STEP 4] sysctl already applied — skipping write"
else
  cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s) 2>/dev/null || true

  NOTSENT_LOWAT=16384
  RMEM_MAX=4194304
  WMEM_MAX=4194304

  if [ "${VIRT_RESTRICTED:-0}" = "1" ]; then
    warn "Restricted virt ($VIRT_TYPE): skipping nf_conntrack_max (may be locked)"
  fi

  cat > "$SYSCTL_FILE" << EOF
net.ipv4.tcp_congestion_control    = bbr
net.core.default_qdisc             = fq_codel
net.core.rmem_max                  = ${RMEM_MAX}
net.core.wmem_max                  = ${WMEM_MAX}
net.ipv4.tcp_rmem                  = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem                  = 4096 16384 ${WMEM_MAX}
net.ipv4.tcp_notsent_lowat         = ${NOTSENT_LOWAT}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_thin_linear_timeouts  = 1
net.ipv4.tcp_ecn                   = 1
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.ip_forward                = 1
net.ipv6.conf.all.forwarding       = 1
net.core.netdev_max_backlog        = 5000
net.core.somaxconn                 = 1024
net.ipv4.tcp_max_syn_backlog       = 1024
net.ipv4.tcp_limit_output_bytes    = 131072
vm.swappiness                      = 10
EOF

  if [ "${VIRT_RESTRICTED:-0}" != "1" ]; then
    echo "net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}" >> "$SYSCTL_FILE"
    echo "net.netfilter.nf_conntrack_tcp_timeout_established = 600" >> "$SYSCTL_FILE"
    echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30" >> "$SYSCTL_FILE"
    echo "net.netfilter.nf_conntrack_udp_timeout = 30" >> "$SYSCTL_FILE"
  fi
fi

info "Applying sysctl settings ..."
tee_run sysctl --system

info "Live sysctl values:"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_notsent_lowat
sysctl net.ipv4.tcp_slow_start_after_idle
sysctl net.ipv4.tcp_ecn
sysctl net.ipv4.tcp_limit_output_bytes

lsmod | grep -q tcp_bbr \
  && ok "BBR module loaded" \
  || { modprobe tcp_bbr 2>/dev/null && ok "BBR loaded on demand" \
       || warn "BBR unavailable — kernel may not support it"; }

ok "[STEP 4] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5 — qdisc: Dual CAKE (Egress + IFB Ingress)
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 5] qdisc — dual CAKE egress + IFB ingress"

IFACE=$(ip route show default | awk 'NR==1{print $5}')
[ -z "$IFACE" ] && die "step5: cannot detect default interface"
info "Default interface: $IFACE"

CURRENT_QDISC=$(tc qdisc show dev "$IFACE" | head -1)
if echo "$CURRENT_QDISC" | grep -qE "(cake|fq_codel)"; then
  ok "[STEP 5] qdisc already applied ($CURRENT_QDISC) — skipping"
  QDISC_APPLIED="$CURRENT_QDISC (pre-existing)"
else
  if tc qdisc add dev lo root cake 2>/dev/null; then
    CAKE_OK=1
    tc qdisc del dev lo root 2>/dev/null || true
    ok "CAKE module available"
  else
    CAKE_OK=0
    warn "CAKE not available — fq_codel fallback"
  fi

  if [ "$CAKE_OK" = "1" ]; then
    info "Applying CAKE egress on $IFACE at ${BW_KBIT}kbit ..."
    tee_run tc qdisc replace dev "$IFACE" root cake \
      bandwidth "${BW_KBIT}kbit" diffserv4 nat flowblind
    QDISC_APPLIED="CAKE egress (${BW_KBIT}kbit diffserv4 nat flowblind)"
    ok "CAKE egress applied on $IFACE at ${BW_KBIT}kbit"
  else
    info "Applying fq_codel egress on $IFACE ..."
    tee_run tc qdisc replace dev "$IFACE" root fq_codel \
      limit 512 target 5ms interval 100ms quantum 300
    QDISC_APPLIED="fq_codel (limit 512 target 5ms quantum 300)"
    warn "fq_codel egress applied (CAKE unavailable)"
  fi
fi

IFB_DEV="ifb0"
INGRESS_APPLIED="none"

if [ "$CAKE_OK" = "1" ] && [ "${VIRT_RESTRICTED:-0}" != "1" ]; then
  info "Setting up IFB ingress shaping ..."

  modprobe ifb numifbs=1 2>/dev/null || true
  ip link add "$IFB_DEV" type ifb 2>/dev/null || true
  ip link set "$IFB_DEV" up 2>/dev/null || true

  if ip link show "$IFB_DEV" &>/dev/null; then
    tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
    tc qdisc add dev "$IFACE" handle ffff: ingress

    tc filter add dev "$IFACE" parent ffff: protocol ip \
      u32 match u32 0 0 action mirred egress redirect dev "$IFB_DEV"

    INGRESS_BW=$(( BW_KBIT * 4 ))
    info "Applying CAKE ingress on $IFB_DEV at ${INGRESS_BW}kbit ..."
    tee_run tc qdisc replace dev "$IFB_DEV" root cake \
      bandwidth "${INGRESS_BW}kbit" diffserv4 nat ingress

    INGRESS_APPLIED="CAKE ingress on $IFB_DEV (${INGRESS_BW}kbit diffserv4)"
    ok "IFB ingress CAKE applied at ${INGRESS_BW}kbit (4x egress for download)"
  else
    warn "IFB device not available — skipping ingress shaping"
    INGRESS_APPLIED="unavailable (IFB device failed)"
  fi
else
  if [ "${VIRT_RESTRICTED:-0}" = "1" ]; then
    warn "IFB ingress skipped — restricted virt ($VIRT_TYPE)"
    INGRESS_APPLIED="skipped (restricted virt)"
  else
    warn "IFB ingress skipped — CAKE unavailable"
    INGRESS_APPLIED="skipped (CAKE unavailable)"
  fi
fi

if [ "$CAKE_OK" = "1" ]; then
  EGRESS_CMD="tc qdisc replace dev ${IFACE} root cake bandwidth ${BW_KBIT}kbit diffserv4 nat flowblind"
  INGRESS_BW_PERSIST=$(( BW_KBIT * 4 ))
  IFB_CMD="modprobe ifb numifbs=1; ip link set ifb0 up; tc qdisc del dev ${IFACE} ingress 2>/dev/null || true; tc qdisc add dev ${IFACE} handle ffff: ingress; tc filter add dev ${IFACE} parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0; tc qdisc replace dev ifb0 root cake bandwidth ${INGRESS_BW_PERSIST}kbit diffserv4 nat ingress"
else
  EGRESS_CMD="tc qdisc replace dev ${IFACE} root fq_codel limit 512 target 5ms interval 100ms quantum 300"
  IFB_CMD=""
fi

SERVICE_FILE="/etc/systemd/system/ais-qdisc.service"
if [ ! -f "$SERVICE_FILE" ] || ! grep -qF "ExecStart=${EGRESS_CMD}" "$SERVICE_FILE"; then
  cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AIS ${BW_KBIT}kbps anti-bufferbloat qdisc
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '${EGRESS_CMD}'
$([ -n "$IFB_CMD" ] && echo "ExecStart=/bin/bash -c '${IFB_CMD}'")

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi
info "Enabling ais-qdisc service ..."
tee_run systemctl enable --now ais-qdisc

info "qdisc status on $IFACE:"
tc qdisc show dev "$IFACE"
[ "$INGRESS_APPLIED" != "none" ] && tc qdisc show dev "$IFB_DEV" 2>/dev/null || true

ok "[STEP 5] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6 — nftables Firewall
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 6] nftables firewall"

[ -z "${SSH_PORT:-}" ] && die "step6: SSH_PORT empty"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "step6: SSH_PORT not numeric: $SSH_PORT"

cp /etc/nftables.conf /etc/nftables.conf.bak.$(date +%s) 2>/dev/null || true

cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
flush ruleset

# AIS 128 kbps — nftables ruleset v${SCRIPT_VER}

table inet filter {
  set ssh_blocklist {
    type ipv4_addr
    flags dynamic,timeout
    timeout 1h
    gc-interval 10m
  }

  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip  protocol icmp  limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept
    ip saddr @ssh_blocklist drop
    tcp dport SSH_PORT_PLACEHOLDER ct state new \
      limit rate over 10/minute burst 5 packets \
      add @ssh_blocklist { ip saddr timeout 1h }
    tcp dport SSH_PORT_PLACEHOLDER ct state new limit rate 6/minute burst 10 packets accept
    tcp dport 80 accept comment "certbot-renew"
    tcp dport 443 accept
    tcp dport 2053 limit rate 30/minute burst 20 packets accept
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
    udp dport 53 ip dscp set cs5
    udp dport { 5000-5100, 7000-8999, 27000-27050, 5672, 17500, 3478-3480, 3074 } ip dscp set cs5
    udp length < 128 ip dscp set cs5
    tcp flags == ack ip length < 80 ip dscp set cs4
    tcp dport { 80, 443 } ip length > 1000 ip dscp set cs3
    tcp dport 443 ip length <= 1000 ip dscp set cs4
  }
}

table inet nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "IFACE_PLACEHOLDER" masquerade
  }
}
NFTEOF

sed -i \
  -e "s/SSH_PORT_PLACEHOLDER/${SSH_PORT}/g" \
  -e "s/IFACE_PLACEHOLDER/${IFACE}/g" \
  /etc/nftables.conf

info "Loading nftables ruleset ..."
tee_run nft -f /etc/nftables.conf || die "step6: nft failed — check /etc/nftables.conf"
tee_run systemctl enable nftables

nft list ruleset | grep -E "dport.*${SSH_PORT}" \
  && ok "SSH port ${SSH_PORT} in ruleset" || warn "SSH port rule not visible"
nft list ruleset | grep -E "oifname.*${IFACE}" \
  && ok "NAT interface ${IFACE} in ruleset" || warn "NAT interface rule not visible"

ok "[STEP 6] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Xray OS-Level Tuning
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 7] Xray OS-level sockopt tuning"

XUI_DB=$(find /etc/x-ui /usr/local/x-ui -name "*.db" 2>/dev/null | head -1 || echo "")
XRAY_BIN=$(command -v xray 2>/dev/null \
  || find /usr/local/x-ui /usr/local/bin -name "xray" 2>/dev/null | head -1 \
  || find /root/.config/3x-ui -name "xray" 2>/dev/null | head -1 \
  || echo "")

if [ -n "$XRAY_BIN" ]; then
  ok "Xray binary found: $XRAY_BIN"
else
  warn "Xray binary not found — xray may be embedded inside x-ui"
  warn "OS-level tuning via limits.conf will still apply"
fi

LIMITS_CONF="/etc/security/limits.conf"
XRAY_LIMITS_MARKER="# xray-limits"
if ! grep -q "$XRAY_LIMITS_MARKER" "$LIMITS_CONF" 2>/dev/null; then
  cat >> "$LIMITS_CONF" << EOF

$XRAY_LIMITS_MARKER
root    soft    nofile  65535
root    hard    nofile  65535
*       soft    nofile  65535
*       hard    nofile  65535
EOF
  ok "File descriptor limits set to 65535"
else
  ok "File descriptor limits already set"
fi

SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/x-ui.service.d"
mkdir -p "$SYSTEMD_OVERRIDE_DIR"
OVERRIDE_FILE="${SYSTEMD_OVERRIDE_DIR}/override.conf"
if [ ! -f "$OVERRIDE_FILE" ]; then
  cat > "$OVERRIDE_FILE" << 'EOF'
[Service]
LimitNOFILE=65535
LimitNPROC=65535
EOF
  ok "x-ui systemd limits override written"
else
  ok "x-ui systemd limits override already present"
fi

SYSCTL_XRAY="/etc/sysctl.d/99-xray-sockopt.conf"
if [ ! -f "$SYSCTL_XRAY" ]; then
  cat > "$SYSCTL_XRAY" << EOF
net.core.optmem_max             = 131072
net.ipv4.tcp_keepalive_time     = 600
net.ipv4.tcp_keepalive_intvl    = 60
net.ipv4.tcp_keepalive_probes   = 5
EOF
  info "Applying xray sockopt sysctl ..."
  tee_run sysctl --system
  ok "Xray sockopt sysctl applied"
else
  ok "Xray sockopt sysctl already present"
fi

systemctl daemon-reload
info "Restarting x-ui ..."
tee_run systemctl restart x-ui
ok "x-ui restarted with new limits"

XRAY_HINT_FILE="/root/xray-inbound-settings.txt"
cat > "$XRAY_HINT_FILE" << EOF
# Xray Inbound Settings Hints (apply inside 3x-ui panel / JSON)
# Generated by 3x-ui-ais-setup.sh v${SCRIPT_VER}

Recommended sockopt for VLESS+Reality inbound:
  "tcpNoDelay": true
  "tcpKeepAliveInterval": 60
  "tcpMaxSeg": 1440

Recommended stream settings for AIS 128kbps:
  "network": "tcp"
  "security": "reality"
  "flow": "xtls-rprx-vision"

For Vision flow — DO NOT enable:
  - mux (conflicts with xtls-rprx-vision)
  - sniffing (adds latency per packet)

DNS in Xray config (optional, since dnsmasq handles it):
  "dns": {
    "servers": ["127.0.0.1"],
    "queryStrategy": "UseIPv4"
  }
EOF
ok "Xray tuning hints saved to $XRAY_HINT_FILE"

ok "[STEP 7] Done"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Final Summary
# ═══════════════════════════════════════════════════════════════════════════════

step "[STEP 8] Final summary"

XUI_VER=$(systemctl show x-ui --property=ExecStart 2>/dev/null | grep -oP 'x-ui \K[0-9]+\.[0-9]+\.[0-9]+' | head -1 \
  || grep -oP 'Starting x-ui \K[0-9]+\.[0-9]+\.[0-9]+' /var/log/3x-ui-ais-setup.log 2>/dev/null | tail -1 \
  || journalctl -u x-ui -n 50 2>/dev/null | grep -oP 'Starting x-ui \K[0-9]+\.[0-9]+\.[0-9]+' | tail -1 \
  || echo "3.x (embedded)")
XUI_STATUS=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || curl -s4 ifconfig.me 2>/dev/null || echo "unknown")
CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null \
              | cut -d= -f2 || echo "unknown")
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
TCP_ECN=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "unknown")
TCP_LIMIT=$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo "unknown")
NFT_STATUS=$(systemctl is-active nftables 2>/dev/null || echo "inactive")
DNS_STATUS=$(systemctl is-active dnsmasq 2>/dev/null || echo "inactive")

echo ""
echo -e "${BCYN}╔══════════════════════════════════════╦════════════════════════════════════════╗${RST}"
echo -e "${BCYN}║ Setting                              ║ Value                                  ║${RST}"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "3x-ui version"             "$XUI_VER"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "3x-ui service"             "$XUI_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Server domain"             "$SERVER_DOMAIN"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Server IP"                 "$SERVER_IP"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Panel URL"                 "https://$SERVER_DOMAIN:2053/<path>/"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TLS cert expires"          "$CERT_EXPIRY"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Cert dir"                  "$CERT_DIR/"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "CAKE egress"               "$QDISC_APPLIED"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "CAKE ingress (IFB)"        "$INGRESS_APPLIED"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP congestion control"    "$TCP_CC"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP ECN"                   "$TCP_ECN"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP limit output bytes"    "$TCP_LIMIT"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Conntrack max"             "$CONNTRACK_MAX"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "nftables"                  "$NFT_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "dnsmasq"                   "$DNS_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Best DNS resolver"         "$DNS_BEST (${DNS_LATENCY[$DNS_BEST]:-?}ms)"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Virtualization"            "$VIRT_TYPE"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Log file"                  "$LOG"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Xray hints"                "/root/xray-inbound-settings.txt"
echo -e "${BCYN}╚══════════════════════════════════════╩════════════════════════════════════════╝${RST}"
echo ""

echo -e "${BGRN}══════════════════════════════════════════════════════════════════${RST}"
echo -e "${BGRN}  NEXT STEPS — Configure VLESS+Reality inside 3x-ui panel${RST}"
echo -e "${BGRN}══════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "  1. Open panel: ${BCYN}https://$SERVER_DOMAIN:2053/<your-path>/${RST}"
echo -e "     (fallback)  ${BCYN}http://$SERVER_IP:2053/<path>/${RST}"
echo    "     → Panel Settings → Panel Certificate"
echo    "       Certificate : $CERT_DIR/fullchain.pem"
echo    "       Private Key : $CERT_DIR/key.pem"
echo    "     → Save → restart panel → use HTTPS URL"
echo ""
echo    "  2. Add Inbound:"
echo    "     Protocol    : VLESS"
echo    "     Port        : 443"
echo    "     Security    : Reality"
echo    "     Destination : th.speedtest.net:443"
echo    "     uTLS        : firefox"
echo    "     Flow        : xtls-rprx-vision"
echo    "     Generate    : UUID + keypair + shortId via panel"
echo    "     tcpNoDelay  : true  (in Advanced / Stream Settings)"
echo ""
echo    "  3. Add users → panel generates client URIs + QR codes"
echo ""
echo    "  4. Xray tuning hints: cat /root/xray-inbound-settings.txt"
echo ""
echo    "  5. Cert auto-renews via certbot cron + restart hook"
echo ""
echo -e "${BGRN}══════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BCYN}   AIS 128Kbps  —  By (IG:peepogrob555  FB:Shogun)${RST}"
echo ""

log "========== Script v${SCRIPT_VER} completed successfully =========="
