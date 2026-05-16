#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/3x-ui-ais-setup.log
CERT_DIR=/etc/ssl/xray
SCRIPT_VER="3.0"

BGRN='\033[1;32m'
BCYN='\033[1;36m'
BYLW='\033[1;33m'
BRED='\033[1;31m'
BMAG='\033[1;35m'
RST='\033[0m'

QDISC_APPLIED="unknown"
IFACE=""
BW_KBIT=128
VIRT_TYPE="unknown"
DNS_BEST=""

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
info()    { echo -e "${BCYN}$*${RST}"; log "INFO: $*"; }
ok()      { echo -e "${BGRN}✓ $*${RST}"; log "OK:   $*"; }
warn()    { echo -e "${BYLW}⚠ WARNING: $*${RST}"; log "WARN: $*"; }
die()     { echo -e "${BRED}[FATAL] $*${RST}"; log "FATAL: $*"; echo "See full log: $LOG"; exit 1; }
step()    { echo -e "\n${BMAG}━━━ $* ━━━${RST}"; log "STEP: $*"; }
tee_run() { "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }

[ "$EUID" -ne 0 ] && die "Run as root: sudo bash $0"
touch "$LOG"
log "========== Script v${SCRIPT_VER} started =========="

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
    lxc|openvz) warn "Detected $VIRT_TYPE — CAKE/IFB may be restricted"; VIRT_RESTRICTED=1 ;;
    kvm|qemu|vmware|xen|microsoft) info "Detected VM: $VIRT_TYPE"; VIRT_RESTRICTED=0 ;;
    *) info "Detected: bare-metal or unknown ($VIRT_TYPE)"; VIRT_RESTRICTED=0 ;;
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
info "Auto conntrack_max: ${CONNTRACK_MAX}"
info "Virt: ${VIRT_TYPE} | Restricted: ${VIRT_RESTRICTED:-0}"

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
echo -e "${BCYN}║      CONFIGURATION SUMMARY v${SCRIPT_VER} — DOWNLOAD PROFILE       ║${RST}"
echo -e "${BCYN}╠══════════════════════════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "SERVER_DOMAIN"   "$SERVER_DOMAIN"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "SSH_PORT"        "$SSH_PORT"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "PROFILE"         "2-user download-heavy"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "TARGET_BW"       "${BW_KBIT}kbps"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "PANEL_PORT"      "2053"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "VLESS_PORT"      "443"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "SNI"             "speed.cloudflare.com"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "CERT_DIR"        "$CERT_DIR"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "VIRT_TYPE"       "$VIRT_TYPE"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "RAM"             "${TOTAL_RAM_MB}MB"
printf "${BCYN}║${RST}  %-24s : %-34s${BCYN}║${RST}\n" "CONNTRACK_MAX"   "$CONNTRACK_MAX"
echo -e "${BCYN}╚══════════════════════════════════════════════════════════════╝${RST}"
echo ""
echo -e -n "${BYLW}Proceed? [y/N]: ${RST}"
read -r CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

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
  || warn "linux-modules-extra failed — CAKE may be unavailable"

if command -v x-ui &>/dev/null && systemctl is-active --quiet x-ui; then
  ok "[STEP 1] 3x-ui already installed and running — skipping ✓"
else
  echo -e "${BCYN}"
  echo "  ══════════════════════════════════════════════════"
  echo "  3x-ui installer:"
  echo "  Panel Port    → 2053"
  echo "  Username      → choose your own"
  echo "  Password      → choose your own"
  echo "  Web Base Path → note it down"
  echo "  ══════════════════════════════════════════════════"
  echo -e "${RST}"
  set +e
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  INSTALL_EXIT=$?
  set -e
  [ $INSTALL_EXIT -ne 0 ] && warn "3x-ui installer exited $INSTALL_EXIT"
fi

which x-ui | tee -a "$LOG" || die "step1: x-ui binary not found"
x-ui status 2>/dev/null || true
systemctl is-active x-ui | grep -q "^active$" || die "step1: x-ui not active"
ok "[STEP 1] Done"

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
    [ -n "$handle" ] && nft delete rule inet filter input handle "$handle" 2>/dev/null || true
  }
  trap _remove_port80 EXIT
  nft add rule inet filter input tcp dport 80 accept comment \"certbot-temp\" 2>/dev/null || true

  mkdir -p "$CERT_DIR"
  info "Running certbot ..."
  tee_run certbot certonly \
    --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email \
    -d "$SERVER_DOMAIN" \
    || die "step2: certbot failed. See $LOG"

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
  warn "x-ui CLI cert not supported — set manually in panel"
}
systemctl restart x-ui

HOOK_FILE="/etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh"
[ ! -f "$HOOK_FILE" ] && cat > "$HOOK_FILE" << 'EOF'
#!/bin/bash
systemctl restart x-ui
EOF
chmod +x "$HOOK_FILE"

info "Running certbot dry-run ..."
nft add rule inet filter input tcp dport 80 accept 2>/dev/null || true
tee_run certbot renew --dry-run && ok "certbot dry-run passed" || warn "certbot dry-run failed"

for f in fullchain.pem key.pem cert.pem; do
  [ -L "$CERT_DIR/$f" ] && [ -f "$CERT_DIR/$f" ] \
    && ok "Symlink OK: $CERT_DIR/$f" \
    || warn "Symlink broken: $CERT_DIR/$f"
done

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$SERVER_DOMAIN:2053/" --connect-timeout 5 || true)
[[ "$HTTP_CODE" =~ ^(200|301|302|400|401|403|404)$ ]] \
  && ok "Panel HTTPS reachable (HTTP $HTTP_CODE)" \
  || warn "Panel HTTPS not reachable yet (code: $HTTP_CODE)"

ok "[STEP 2] Done"

step "[STEP 3] DNS benchmark + dnsmasq"

benchmark_dns() {
  local resolver=$1 ms
  ms=$(dig +tries=2 +time=2 google.com @"$resolver" 2>/dev/null \
    | awk '/Query time:/{print $4}' | head -1)
  echo "${ms:-9999}"
}

info "Benchmarking DNS resolvers (~10s) ..."

declare -A DNS_LATENCY
RESOLVERS=(
  "1.1.1.1" "1.0.0.1"
  "8.8.8.8" "8.8.4.4"
  "9.9.9.9"
  "94.140.14.140" "94.140.14.141"
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
  while IFS= read -r r; do echo "server=$r"; done <<< "$TOP3_DNS"
  cat << 'DNSEOF'
cache-size=4096
min-cache-ttl=60
neg-ttl=15
dns-forward-max=300
no-resolv
DNSEOF
} > /etc/dnsmasq.conf

chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf

if chattr +i /etc/resolv.conf 2>/dev/null; then
  ok "resolv.conf locked (chattr +i)"
else
  warn "chattr not supported — using systemd-resolved fallback"
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-dnsmasq.conf << 'RESEOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
ReadEtcHosts=yes
RESEOF
  if [ -d /etc/NetworkManager/conf.d ]; then
    cat > /etc/NetworkManager/conf.d/99-dns-none.conf << 'NMEOF'
[main]
dns=none
NMEOF
    systemctl reload NetworkManager 2>/dev/null || true
  fi
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
  ok "resolv.conf set to 127.0.0.1 (systemd-resolved + NM)"
fi

info "Enabling dnsmasq ..."
tee_run systemctl enable --now dnsmasq \
  || die "step3: dnsmasq failed"

DIG_RESULT=$(dig +short google.com @127.0.0.1 2>/dev/null | head -1)
[ -n "$DIG_RESULT" ] && ok "dnsmasq: google.com → $DIG_RESULT" || warn "dnsmasq: google.com failed"

SNI_RESULT=$(dig +short speed.cloudflare.com @127.0.0.1 2>/dev/null | head -1)
[ -n "$SNI_RESULT" ] && ok "dnsmasq: speed.cloudflare.com → $SNI_RESULT" \
  || warn "speed.cloudflare.com DNS failed"

ok "[STEP 3] Done"

step "[STEP 4] sysctl tuning — download-heavy 2-user profile"

rm -f /etc/sysctl.d/99-ais-128k.conf 2>/dev/null || true
SYSCTL_FILE="/etc/sysctl.d/99-ais-dl.conf"
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s) 2>/dev/null || true

RMEM_MAX=8388608
WMEM_MAX=8388608

cat > "$SYSCTL_FILE" << EOF
net.ipv4.tcp_congestion_control    = bbr
net.core.default_qdisc             = fq

net.core.rmem_default              = 262144
net.core.wmem_default              = 262144
net.core.rmem_max                  = ${RMEM_MAX}
net.core.wmem_max                  = ${WMEM_MAX}
net.core.optmem_max                = 131072

net.ipv4.tcp_rmem                  = 8192 262144 ${RMEM_MAX}
net.ipv4.tcp_wmem                  = 8192 262144 ${WMEM_MAX}
net.ipv4.tcp_mem                   = 65536 131072 262144

net.ipv4.tcp_adv_win_scale         = 2
net.ipv4.tcp_moderate_rcvbuf       = 1
net.ipv4.tcp_window_scaling        = 1

net.ipv4.tcp_notsent_lowat         = 131072
net.ipv4.tcp_limit_output_bytes    = 0

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn                   = 1
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_sack                  = 1
net.ipv4.tcp_dsack                 = 1
net.ipv4.tcp_timestamps            = 1

net.ipv4.tcp_keepalive_time        = 600
net.ipv4.tcp_keepalive_intvl       = 30
net.ipv4.tcp_keepalive_probes      = 5

net.ipv4.tcp_retries2              = 8
net.ipv4.tcp_orphan_retries        = 2
net.ipv4.tcp_fin_timeout           = 15
net.ipv4.tcp_tw_reuse              = 1

net.ipv4.tcp_max_syn_backlog       = 2048
net.core.somaxconn                 = 2048
net.core.netdev_max_backlog        = 10000

net.ipv4.ip_forward                = 1
net.ipv6.conf.all.forwarding       = 1

vm.swappiness                      = 10
vm.dirty_ratio                     = 20
vm.dirty_background_ratio          = 5
EOF

if [ "${VIRT_RESTRICTED:-0}" != "1" ]; then
  cat >> "$SYSCTL_FILE" << EOF
net.netfilter.nf_conntrack_max                     = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 15
net.netfilter.nf_conntrack_udp_timeout             = 30
EOF
fi

modprobe tcp_bbr 2>/dev/null || true
info "Applying sysctl settings ..."
tee_run sysctl --system

info "Live sysctl values:"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_notsent_lowat
sysctl net.ipv4.tcp_limit_output_bytes
sysctl net.ipv4.tcp_adv_win_scale
sysctl net.core.rmem_max

lsmod | grep -q tcp_bbr \
  && ok "BBR module loaded" \
  || warn "BBR not in lsmod (may be built-in)"

ok "[STEP 4] Done"

step "[STEP 5] qdisc — fq egress (download-optimized)"

IFACE=$(ip route show default | awk 'NR==1{print $5}')
[ -z "$IFACE" ] && die "step5: cannot detect default interface"
info "Default interface: $IFACE"

tc qdisc del dev "$IFACE" root 2>/dev/null || true
info "Applying fq egress on $IFACE ..."
tee_run tc qdisc replace dev "$IFACE" root fq \
  limit 20000 \
  flow_limit 2000 \
  quantum 1514 \
  initial_quantum 15140 \
  maxrate "${BW_KBIT}kbit"

QDISC_APPLIED="fq (limit 20000 quantum 1514 maxrate ${BW_KBIT}kbit)"
ok "fq egress applied on $IFACE"

EGRESS_CMD="tc qdisc replace dev ${IFACE} root fq limit 20000 flow_limit 2000 quantum 1514 initial_quantum 15140 maxrate ${BW_KBIT}kbit"

SERVICE_FILE="/etc/systemd/system/ais-qdisc.service"
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AIS ${BW_KBIT}kbps download-optimized qdisc
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '${EGRESS_CMD}'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
info "Enabling ais-qdisc service ..."
tee_run systemctl enable --now ais-qdisc

info "qdisc status on $IFACE:"
tc qdisc show dev "$IFACE"

ok "[STEP 5] Done"

step "[STEP 6] nftables firewall"

[ -z "${SSH_PORT:-}" ] && die "step6: SSH_PORT empty"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "step6: SSH_PORT not numeric: $SSH_PORT"

cp /etc/nftables.conf /etc/nftables.conf.bak.$(date +%s) 2>/dev/null || true

cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
flush ruleset

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
    tcp dport 80  accept comment "certbot-renew"
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
    tcp dport 443 ip dscp set cs3
    tcp dport 80  ip dscp set cs3
    udp dport 53  ip dscp set cs5
    tcp flags == ack ip length < 80 ip dscp set cs4
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
tee_run nft -f /etc/nftables.conf || die "step6: nft failed"
tee_run systemctl enable nftables

nft list ruleset | grep -E "dport.*${SSH_PORT}" \
  && ok "SSH port ${SSH_PORT} in ruleset" || warn "SSH port rule not visible"
nft list ruleset | grep -E "oifname.*${IFACE}" \
  && ok "NAT interface ${IFACE} in ruleset" || warn "NAT interface rule not visible"

ok "[STEP 6] Done"

step "[STEP 7] Xray OS-level + x-ui tuning"

XRAY_BIN=$(command -v xray 2>/dev/null \
  || find /usr/local/x-ui /usr/local/bin -name "xray" 2>/dev/null | head -1 \
  || find /root/.config/3x-ui -name "xray" 2>/dev/null | head -1 \
  || echo "")
if [ -n "$XRAY_BIN" ]; then
  ok "Xray binary found: $XRAY_BIN"
else
  warn "Xray binary not found — embedded in x-ui (normal)"
fi

LIMITS_CONF="/etc/security/limits.conf"
if ! grep -q "xray-limits" "$LIMITS_CONF" 2>/dev/null; then
  cat >> "$LIMITS_CONF" << 'EOF'

# xray-limits
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
rm -f "$SYSCTL_XRAY" 2>/dev/null || true
cat > "$SYSCTL_XRAY" << 'EOF'
net.core.optmem_max             = 131072
net.ipv4.tcp_keepalive_time     = 600
net.ipv4.tcp_keepalive_intvl    = 30
net.ipv4.tcp_keepalive_probes   = 5
EOF
tee_run sysctl --system
ok "Xray sockopt sysctl applied"

systemctl daemon-reload
info "Restarting x-ui ..."
tee_run systemctl restart x-ui
ok "x-ui restarted with new limits"

XRAY_HINT_FILE="/root/xray-inbound-settings.txt"
cat > "$XRAY_HINT_FILE" << 'EOF'
=== Xray Inbound — Download-Heavy Profile v3.0 ===

Stream Settings:
  network  : tcp
  security : reality
  flow     : xtls-rprx-vision

Sockopt (streamSettings → sockopt):
  tcpNoDelay         : false
  tcpKeepAliveIdle   : 600
  tcpKeepAliveIntvl  : 30
  tcpMaxSeg          : 1380
  mark               : 0

DO NOT enable:
  mux / sniffing / httpUpgrade / splitHTTP

Reality SNI:
  speed.cloudflare.com:443
  uTLS: chrome

Android (v2rayNG / Hiddify / Netmod):
  MTU      : 1350
  mux      : off
  fragment : off

DNS in Xray (optional):
  { "servers": ["127.0.0.1"], "queryStrategy": "UseIPv4" }
EOF
ok "Xray hints saved to $XRAY_HINT_FILE"

ok "[STEP 7] Done"

step "[STEP 8] Final summary"

XUI_VER=$(journalctl -u x-ui -n 100 2>/dev/null \
  | grep -oP 'Starting x-ui \K[0-9]+\.[0-9]+\.[0-9]+' | tail -1 \
  || echo "3.x")
XUI_STATUS=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || curl -s4 ifconfig.me 2>/dev/null || echo "unknown")
CERT_EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null \
              | cut -d= -f2 || echo "unknown")
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
TCP_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
NFT_STATUS=$(systemctl is-active nftables 2>/dev/null || echo "inactive")
DNS_STATUS=$(systemctl is-active dnsmasq 2>/dev/null || echo "inactive")

echo ""
echo -e "${BCYN}╔══════════════════════════════════════╦════════════════════════════════════════╗${RST}"
echo -e "${BCYN}║ Setting                              ║ Value                                  ║${RST}"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "3x-ui version"          "$XUI_VER"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "3x-ui service"          "$XUI_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Profile"                "2-user download-heavy v3.0"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Server domain"          "$SERVER_DOMAIN"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Server IP"              "$SERVER_IP"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Panel URL"              "https://$SERVER_DOMAIN:2053/<path>/"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TLS cert expires"       "$CERT_EXPIRY"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Cert dir"               "$CERT_DIR/"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "qdisc"                  "$QDISC_APPLIED"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP CC"                 "$TCP_CC"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "default_qdisc"          "$TCP_QDISC"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Conntrack max"          "$CONNTRACK_MAX"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "nftables"               "$NFT_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "dnsmasq"                "$DNS_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Best DNS"               "$DNS_BEST (${DNS_LATENCY[$DNS_BEST]:-?}ms)"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Virtualization"         "$VIRT_TYPE"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Log file"               "$LOG"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Xray hints"             "/root/xray-inbound-settings.txt"
echo -e "${BCYN}╚══════════════════════════════════════╩════════════════════════════════════════╝${RST}"
echo ""
echo -e "${BGRN}══════════════════════════════════════════════════════════════════${RST}"
echo -e "${BGRN}  NEXT STEPS — Configure VLESS+Reality inside 3x-ui panel${RST}"
echo -e "${BGRN}══════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "  1. Open panel: ${BCYN}https://$SERVER_DOMAIN:2053/<your-path>/${RST}"
echo    "     → Panel Settings → Panel Certificate"
echo    "       Certificate : $CERT_DIR/fullchain.pem"
echo    "       Private Key : $CERT_DIR/key.pem"
echo    "     → Save → restart panel"
echo ""
echo    "  2. Add Inbound:"
echo    "     Protocol    : VLESS | Port : 443 | Security : Reality"
echo    "     Destination : speed.cloudflare.com:443"
echo    "     uTLS        : chrome | Flow : xtls-rprx-vision"
echo    "     tcpNoDelay  : false | tcpMaxSeg : 1380"
echo ""
echo    "  3. Android: MTU 1350 | mux off | fragment off"
echo    "  4. Xray hints: cat /root/xray-inbound-settings.txt"
echo    "  5. Cert auto-renews via certbot cron + restart hook"
echo ""
echo -e "${BGRN}══════════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "${BCYN}   AIS 128Kbps Download Profile v3.0 — By (IG:peepogrob555  FB:Shogun)${RST}"
echo ""

log "========== Script v${SCRIPT_VER} completed successfully =========="
