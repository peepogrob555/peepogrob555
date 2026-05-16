#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/3x-ui-ais128k.log
CERT_DIR=/etc/ssl/xray
SCRIPT_VER="3.3"
BW_KBIT=116

BGRN='\033[1;32m'; BCYN='\033[1;36m'; BYLW='\033[1;33m'
BRED='\033[1;31m'; BMAG='\033[1;35m'; RST='\033[0m'

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
info() { echo -e "${BCYN}  $*${RST}";         log "INFO: $*"; }
ok()   { echo -e "${BGRN}  ✓ $*${RST}";       log "OK: $*"; }
warn() { echo -e "${BYLW}  ⚠ $*${RST}";       log "WARN: $*"; }
die()  { echo -e "${BRED}[FATAL] $*${RST}";   log "FATAL: $*"; exit 1; }
step() { echo -e "\n${BMAG}━━━ $* ━━━${RST}"; log "STEP: $*"; }

run()  { "$@" >> "$LOG" 2>&1 || true; }
must() { "$@" >> "$LOG" 2>&1 || die "Failed: $*"; }

# show output on screen AND log — for slow steps so user sees progress
loud() {
  local label="$1"; shift
  info "$label"
  "$@" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}
loud_must() {
  local label="$1"; shift
  info "$label"
  "$@" 2>&1 | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "Failed: $*"
}

[ "$EUID" -ne 0 ] && die "Run as root"
touch "$LOG"
log "===== v${SCRIPT_VER} started ====="

step "Pre-flight"

VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
case "$VIRT_TYPE" in
  lxc|openvz) VIRT_RESTRICTED=1; warn "Restricted virt: $VIRT_TYPE" ;;
  *)           VIRT_RESTRICTED=0; info "Virt: $VIRT_TYPE" ;;
esac

TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
CONNTRACK_MAX=$(( TOTAL_RAM_MB * 8 ))
[ "$CONNTRACK_MAX" -lt 8192  ] && CONNTRACK_MAX=8192
[ "$CONNTRACK_MAX" -gt 65536 ] && CONNTRACK_MAX=65536

TC_BIN=$(command -v tc || echo "/usr/sbin/tc")

info "RAM: ${TOTAL_RAM_MB}MB | Kernel: $(uname -r) | Conntrack: $CONNTRACK_MAX"
info "BW target: ${BW_KBIT}kbit (128kbps FUP minus 9% TLS/Reality/ACK overhead)"

step "Input"

while true; do
  printf "${BCYN}  Domain (FQDN): ${RST}"; read -r SERVER_DOMAIN
  [[ "$SERVER_DOMAIN" =~ \. ]] \
    && [[ ! "$SERVER_DOMAIN" =~ \  ]] \
    && [[ ! "$SERVER_DOMAIN" =~ ^http ]] \
    && [[ ! "$SERVER_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  echo -e "${BRED}  Invalid — FQDN only, no IP, no spaces, no http${RST}"
done

DETECTED_SSH=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | head -1 || true)
if [ -n "$DETECTED_SSH" ]; then
  printf "${BCYN}  SSH port [detected: ${DETECTED_SSH}] (Enter to keep): ${RST}"; read -r SSH_INPUT
  SSH_PORT="${SSH_INPUT:-$DETECTED_SSH}"
else
  printf "${BCYN}  SSH port: ${RST}"; read -r SSH_PORT
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be numeric"
[ -z "$SSH_PORT" ]            && die "SSH port empty"

echo ""
echo -e "${BCYN}╔═══════════════════════════════════════════════╗${RST}"
echo -e "${BCYN}║   AIS 128kbps Long-Download Setup — v${SCRIPT_VER}   ║${RST}"
echo -e "${BCYN}╠═══════════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "Domain"     "$SERVER_DOMAIN"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "SSH Port"   "$SSH_PORT"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "BW shape"   "${BW_KBIT}kbit egress fq"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "Panel Port" "2053"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "VLESS Port" "443"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "SNI"        "th.speedtest.net"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "Virt"       "$VIRT_TYPE"
printf "${BCYN}║${RST}  %-20s : %-23s${BCYN}║${RST}\n" "Conntrack"  "$CONNTRACK_MAX"
echo -e "${BCYN}╚═══════════════════════════════════════════════╝${RST}"
printf "${BYLW}  Proceed? [y/N]: ${RST}"; read -r CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

step "[1] System update + packages"

loud_must "apt-get update..." \
  apt-get update

loud_must "apt-get upgrade (this may take a few minutes)..." \
  apt-get upgrade -y

loud_must "Installing required packages..." \
  apt-get install -y \
    nftables dnsmasq iproute2 curl wget \
    ca-certificates gnupg dnsutils \
    certbot python3-certbot \
    "linux-modules-extra-$(uname -r)" \
  || warn "linux-modules-extra unavailable"

ok "Packages ready"

step "[2] 3x-ui install"

echo -e "${BCYN}"
echo "  ┌──────────────────────────────────────────┐"
echo "  │  When 3x-ui installer prompts:           │"
echo "  │   Panel Port  → 2053                     │"
echo "  │   Username    → your choice              │"
echo "  │   Password    → your choice              │"
echo "  │   Base Path   → note it down             │"
echo "  └──────────────────────────────────────────┘"
echo -e "${RST}"

set +e
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 \
  | tee -a "$LOG"
XI="${PIPESTATUS[0]}"
set -e
[ "$XI" -ne 0 ] && warn "Installer exit $XI — verifying binary"

which x-ui >> "$LOG"       || die "x-ui binary not found"
systemctl is-active x-ui | grep -q "^active$" || die "x-ui not active"
ok "3x-ui running"

step "[3] TLS certificate"

CERT_LIVE="/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem"

if [ -f "$CERT_LIVE" ]; then
  info "Revoking old cert for fresh issue..."
  run certbot revoke --cert-path "$CERT_LIVE" --non-interactive
  run certbot delete --cert-name "$SERVER_DOMAIN" --non-interactive
fi

SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null \
         || curl -s4 ifconfig.me 2>/dev/null \
         || echo "")
RESOLVED_IP=$(dig +short "$SERVER_DOMAIN" A | tail -1)

if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
  warn "DNS mismatch: $SERVER_DOMAIN → $RESOLVED_IP  server: $SERVER_IP"
  printf "  Continue anyway? [y/N]: "; read -r dns_ok
  [ "${dns_ok,,}" = "y" ] || die "Fix DNS and re-run"
fi

run systemctl start nftables
nft add rule inet filter input tcp dport 80 accept comment '"certbot-temp"' 2>/dev/null || true

mkdir -p "$CERT_DIR"
info "Requesting TLS certificate from Let's Encrypt..."
certbot certonly \
  --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email \
  -d "$SERVER_DOMAIN" 2>&1 | tee -a "$LOG" \
  || die "certbot failed — check DNS + port 80. Log: $LOG"

HANDLE=$(nft -a list chain inet filter input 2>/dev/null \
           | awk '/certbot-temp/{print $NF}')
[ -n "$HANDLE" ] && run nft delete rule inet filter input handle "$HANDLE"

ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/fullchain.pem" "$CERT_DIR/fullchain.pem"
ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/privkey.pem"   "$CERT_DIR/key.pem"
ln -sf "/etc/letsencrypt/live/$SERVER_DOMAIN/cert.pem"      "$CERT_DIR/cert.pem"
chmod 750 "$CERT_DIR"
chmod 750 "/etc/letsencrypt/live/$SERVER_DOMAIN"

x-ui setting -certFile "$CERT_DIR/fullchain.pem" \
             -keyFile  "$CERT_DIR/key.pem" 2>/dev/null \
  || warn "x-ui CLI cert flags unsupported — set cert manually in panel UI"
must systemctl restart x-ui

cat > /etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh << 'EOF'
#!/bin/bash
systemctl restart x-ui
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh

CERT_EXPIRY=$(openssl x509 -enddate -noout \
  -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "unknown")
ok "Cert issued — expires: $CERT_EXPIRY"

step "[4] DNS benchmark + dnsmasq"

bench_dns() {
  dig +tries=2 +time=2 google.com @"$1" 2>/dev/null \
    | awk '/Query time:/{print $4}' | head -1 || echo "9999"
}

info "Benchmarking resolvers (takes ~15s)..."
RESOLVERS=(
  "94.140.14.140" "94.140.14.141"
  "1.1.1.1"       "1.0.0.1"
  "8.8.8.8"       "8.8.4.4"
  "9.9.9.9"       "101.101.101.101"
)
declare -A DNS_MS
for r in "${RESOLVERS[@]}"; do
  ms=$(bench_dns "$r")
  DNS_MS["$r"]="$ms"
  info "  $r → ${ms}ms"
done

SORTED=$(for r in "${!DNS_MS[@]}"; do
  echo "${DNS_MS[$r]} $r"
done | sort -n | awk '{print $2}')

DNS1=$(echo "$SORTED" | sed -n '1p')
DNS2=$(echo "$SORTED" | sed -n '2p')
DNS3=$(echo "$SORTED" | sed -n '3p')
DNS1_MS="${DNS_MS[$DNS1]}"
ok "Best: $DNS1 (${DNS1_MS}ms)"

run systemctl stop systemd-resolved
run systemctl stop dnsmasq

if grep -q "^DNSStubListener" /etc/systemd/resolved.conf 2>/dev/null; then
  sed -i 's/^DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
else
  echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
fi
must systemctl restart systemd-resolved

cat > /etc/dnsmasq.conf << EOF
listen-address=127.0.0.1
bind-interfaces
port=53
server=${DNS1}
server=${DNS2}
server=${DNS3}
cache-size=2048
min-cache-ttl=30
neg-ttl=10
dns-forward-max=150
no-resolv
EOF

chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf

if ! chattr +i /etc/resolv.conf 2>/dev/null; then
  warn "chattr unsupported — locking via systemd-resolved"
  mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no\n' \
    > /etc/systemd/resolved.conf.d/99-dnsmasq.conf
  if [ -d /etc/NetworkManager/conf.d ]; then
    printf '[main]\ndns=none\n' \
      > /etc/NetworkManager/conf.d/99-dns-none.conf
    run systemctl reload NetworkManager
  fi
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

must systemctl enable --now dnsmasq

DIG_OUT=$(dig +short google.com @127.0.0.1 2>/dev/null | head -1)
[ -n "$DIG_OUT" ] \
  && ok "dnsmasq: google.com → $DIG_OUT" \
  || warn "dnsmasq: google.com failed"

SNI_OUT=$(dig +short th.speedtest.net @127.0.0.1 2>/dev/null | head -1)
[ -n "$SNI_OUT" ] \
  && ok "dnsmasq: th.speedtest.net → $SNI_OUT" \
  || warn "th.speedtest.net failed — Reality reconnects cost extra RTT"

step "[5] sysctl — BBR + AIS 128kbps long-download profile"

modprobe tcp_bbr 2>/dev/null || true
lsmod | grep -q tcp_bbr \
  && ok "BBR module loaded" \
  || warn "BBR unavailable — check kernel"

cat > /etc/sysctl.d/99-ais128k.conf << EOF
net.ipv4.tcp_congestion_control    = bbr
net.core.default_qdisc             = fq

net.core.rmem_max                  = 4194304
net.core.wmem_max                  = 4194304
net.ipv4.tcp_rmem                  = 4096 87380 4194304
net.ipv4.tcp_wmem                  = 4096 16384 4194304

net.ipv4.tcp_notsent_lowat         = 16384
net.ipv4.tcp_limit_output_bytes    = 65536

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn                   = 1
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_fastopen              = 1

net.ipv4.tcp_keepalive_time        = 600
net.ipv4.tcp_keepalive_intvl       = 60
net.ipv4.tcp_keepalive_probes      = 5

net.core.optmem_max                = 131072
net.core.netdev_max_backlog        = 1000
net.core.somaxconn                 = 1024
net.ipv4.tcp_max_syn_backlog       = 1024

net.ipv4.ip_forward                = 1
net.ipv6.conf.all.forwarding       = 1

vm.swappiness                      = 10
EOF

if [ "${VIRT_RESTRICTED:-0}" != "1" ]; then
  cat >> /etc/sysctl.d/99-ais128k.conf << EOF
net.netfilter.nf_conntrack_max                     = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30
net.netfilter.nf_conntrack_udp_timeout             = 30
EOF
fi

info "Applying sysctl..."
sysctl --system 2>&1 | grep -E "^(net\.|vm\.)" | tee -a "$LOG"
ok "sysctl applied"

step "[6] qdisc — fq egress"

IFACE=$(ip route show default | awk 'NR==1{print $5}')
[ -z "$IFACE" ] && die "Cannot detect default interface"
info "Interface: $IFACE"

"$TC_BIN" qdisc del dev "$IFACE" root 2>/dev/null || true

if "$TC_BIN" qdisc add dev "$IFACE" root fq \
     maxrate "${BW_KBIT}kbit" quantum 1514 flow_limit 100 \
     >> "$LOG" 2>&1; then
  QDISC_APPLIED="fq maxrate ${BW_KBIT}kbit flow_limit 100"
  ok "Egress: fq maxrate ${BW_KBIT}kbit on $IFACE"
else
  warn "fq maxrate failed — falling back to fq_codel"
  "$TC_BIN" qdisc add dev "$IFACE" root fq_codel \
    limit 512 target 5ms interval 100ms quantum 300 >> "$LOG" 2>&1
  QDISC_APPLIED="fq_codel fallback"
fi

info "qdisc status:"
"$TC_BIN" qdisc show dev "$IFACE" | tee -a "$LOG"

systemctl stop ais-qdisc 2>/dev/null || true
rm -f /etc/systemd/system/ais-qdisc.service

cat > /etc/systemd/system/ais-qdisc.service << EOF
[Unit]
Description=AIS ${BW_KBIT}kbit egress shaping
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-${TC_BIN} qdisc del dev ${IFACE} root
ExecStart=${TC_BIN} qdisc add dev ${IFACE} root fq maxrate ${BW_KBIT}kbit quantum 1514 flow_limit 100

[Install]
WantedBy=multi-user.target
EOF

must systemctl daemon-reload
must systemctl enable --now ais-qdisc
ok "ais-qdisc service enabled"

step "[7] nftables"

[ -z "${SSH_PORT:-}" ] && die "SSH_PORT empty"

cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  set ssh_block {
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
    ip saddr @ssh_block drop
    tcp dport ${SSH_PORT} ct state new limit rate over 20/minute burst 10 packets \
      add @ssh_block { ip saddr timeout 1h }
    tcp dport ${SSH_PORT} ct state new limit rate 20/minute burst 15 packets accept
    tcp dport 80  accept
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
  chain postrouting {
    type filter hook postrouting priority -150;
    oifname "${IFACE}" tcp flags & (syn|ack) == syn tcp option maxseg size set rt mtu
  }
}
NFTEOF

must nft -f /etc/nftables.conf
must systemctl enable nftables

info "nftables ruleset:"
nft list ruleset | tee -a "$LOG"

ok "nftables loaded — SSH:${SSH_PORT} VLESS:443 Panel:2053 MSS-clamp:on"

step "[8] x-ui limits + Xray hints"

grep -q "xray-limits" /etc/security/limits.conf 2>/dev/null \
  && sed -i '/xray-limits/,+4d' /etc/security/limits.conf

cat >> /etc/security/limits.conf << 'EOF'
# xray-limits
root    soft    nofile  65535
root    hard    nofile  65535
*       soft    nofile  65535
*       hard    nofile  65535
EOF

mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65535
LimitNPROC=65535
Nice=-5
EOF

must systemctl daemon-reload
must systemctl restart x-ui
ok "x-ui restarted (FD:65535 Nice:-5)"

cat > /root/xray-inbound-hint.txt << 'EOF'
VLESS+Reality — AIS 128kbps long-download profile
==================================================

Protocol     : VLESS
Port         : 443
Network      : tcp
Security     : reality
Flow         : xtls-rprx-vision
Dest / SNI   : th.speedtest.net:443
SNI fallback : www.speedtest.net:443
uTLS         : firefox

sockopt:
  tcpNoDelay          : false   (Nagle on — fewer tiny packets, less radio burst)
  tcpKeepAliveInterval: 60

Do NOT enable:
  mux        — HoL blocking destroys long downloads
  sniffing   — overhead with zero benefit at 128kbps
EOF
ok "Xray hints → /root/xray-inbound-hint.txt"

step "[DONE] Summary"

XUI_STATUS=$(systemctl is-active x-ui      2>/dev/null || echo "inactive")
NFT_STATUS=$(systemctl is-active nftables  2>/dev/null || echo "inactive")
DNS_STATUS=$(systemctl is-active dnsmasq   2>/dev/null || echo "inactive")
QDS_STATUS=$(systemctl is-active ais-qdisc 2>/dev/null || echo "inactive")
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
TCP_QD=$("$TC_BIN" qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')

echo ""
echo -e "${BCYN}╔══════════════════════════════════════╦════════════════════════════════════════╗${RST}"
echo -e "${BCYN}║ Item                                 ║ Value                                  ║${RST}"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "3x-ui"              "$XUI_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Domain"             "$SERVER_DOMAIN"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Server IP"          "$SERVER_IP"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Panel URL"          "https://$SERVER_DOMAIN:2053/"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Cert expires"       "$CERT_EXPIRY"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "TCP CC"             "$TCP_CC"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Egress qdisc"       "${TCP_QD} on ${IFACE}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "BW shape"           "$QDISC_APPLIED"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "ais-qdisc service"  "$QDS_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Conntrack max"      "$CONNTRACK_MAX"
echo -e "${BCYN}╠══════════════════════════════════════╬════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "nftables"           "$NFT_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "dnsmasq"            "$DNS_STATUS"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Best DNS"           "${DNS1} (${DNS1_MS}ms)"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Log"                "$LOG"
printf "${BCYN}║${RST} %-36s ${BCYN}║${RST} %-38s ${BCYN}║${RST}\n" "Xray hints"         "/root/xray-inbound-hint.txt"
echo -e "${BCYN}╚══════════════════════════════════════╩════════════════════════════════════════╝${RST}"
echo ""
echo -e "${BGRN}══════ NEXT STEPS ══════════════════════════════════════════════${RST}"
echo -e "  1. Panel  : ${BCYN}https://$SERVER_DOMAIN:2053/<your-path>/${RST}"
echo    "  2. Panel Settings → Panel Certificate"
echo    "       Certificate : $CERT_DIR/fullchain.pem"
echo    "       Private Key : $CERT_DIR/key.pem"
echo    "  3. Add Inbound → see /root/xray-inbound-hint.txt"
echo    "  4. VLESS | 443 | Reality | xtls-rprx-vision | firefox | th.speedtest.net"
echo -e "${BGRN}════════════════════════════════════════════════════════════════${RST}"
echo ""

log "===== v${SCRIPT_VER} completed ====="
