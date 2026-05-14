#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/ais-vps-setup.log
exec > >(tee -a "$LOG") 2>&1

R='\033[1;31m' G='\033[1;32m' Y='\033[1;33m' C='\033[1;36m' W='\033[1;37m' N='\033[0m'

PORT=443 SNI=th.speedtest.net FP=firefox FLOW=xtls-rprx-vision
NET=tcp SEC=reality ENC=none SPX=/

die()  { echo -e "${R}[FATAL] $*${N}"; echo "log → $LOG"; exit 1; }
ok()   { echo -e "${G}[OK]${N} $*"; }
info() { echo -e "${C}[>>]${N} $*"; }
warn() { echo -e "${Y}[!!]${N} $*"; }
sep()  { printf "${W}%54s${N}\n" | tr ' ' '─'; }

[[ $EUID -ne 0 ]] && die "root required"

# ── INPUT ────────────────────────────────────

clear; sep
echo -e "${W}  AIS · xray-reality · 128kbps${N}"; sep; echo

read -rp "  domain/IP   : " SERVER_DOMAIN
[[ -z ${SERVER_DOMAIN:-} ]] && die "SERVER_DOMAIN empty"

_ssh=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}') || true
if [[ -n ${_ssh:-} ]]; then
  read -rp "  SSH port    : [detected: $_ssh] " _in
  SSH_PORT=${_in:-$_ssh}
else
  read -rp "  SSH port    : " SSH_PORT
fi
[[ -z ${SSH_PORT:-} ]] && die "SSH_PORT unknown"

read -rp "  users       : [2] " USER_COUNT
USER_COUNT=${USER_COUNT:-2}
[[ $USER_COUNT =~ ^[0-9]+$ ]] && [[ $USER_COUNT -ge 1 ]] || die "USER_COUNT must be int >= 1"

declare -a TAGS=()
for ((i=1; i<=USER_COUNT; i++)); do
  read -rp "  tag user $i  : " TAGS[$i]
done

echo; sep
printf "  %-18s %s\n" domain     "$SERVER_DOMAIN"
printf "  %-18s %s\n" ssh-port   "$SSH_PORT"
printf "  %-18s %s\n" vless-port "$PORT"
printf "  %-18s %s\n" sni        "$SNI"
printf "  %-18s %s\n" fp         "$FP"
printf "  %-18s %s\n" flow       "$FLOW"
printf "  %-18s %s\n" users      "$USER_COUNT"
sep
read -rp "  proceed? [y/N] : " _c
[[ ${_c:-} =~ ^[Yy]$ ]] || { echo "abort."; exit 0; }
echo

# ── STEP 1 · packages ────────────────────────

info "step 1 · packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  nftables dnsmasq iproute2 curl wget ca-certificates gnupg dnsutils openssl

_xray_install=$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
  || die "failed to fetch xray install script"
bash -c "$_xray_install" @ install || die "xray install failed"
command -v xray &>/dev/null || die "xray binary not found"
ok "xray $(xray version 2>/dev/null | awk 'NR==1{print $2}')"

# ── STEP 2 · credentials ─────────────────────

info "step 2 · credentials"
_kp=$(xray x25519 2>/dev/null)
PRIV=$(awk '/Private/{print $3}' <<<"$_kp")
PUB=$(awk '/Public/{print $3}'   <<<"$_kp")
[[ -z ${PRIV:-} || -z ${PUB:-} ]] && die "x25519 keygen failed"

declare -a UUIDS=() SIDS=()
for ((i=1; i<=USER_COUNT; i++)); do
  UUIDS[$i]=$(xray uuid 2>/dev/null) || die "uuid gen failed user $i"
  SIDS[$i]=$(openssl rand -hex 8)    || die "sid gen failed user $i"
done

sep
printf "  %-8s %-36s %s\n" tag uuid shortId; sep
for ((i=1; i<=USER_COUNT; i++)); do
  printf "  %-8s %-36s %s\n" "${TAGS[$i]}" "${UUIDS[$i]}" "${SIDS[$i]}"
done
echo -e "  pubkey  ${W}${PUB}${N}"; sep

# ── STEP 3 · xray config ─────────────────────

info "step 3 · xray config"
CFG=/usr/local/etc/xray/config.json
mkdir -p /usr/local/etc/xray /var/log/xray

WRITE=1
if [[ -f $CFG ]] && systemctl is-active --quiet xray 2>/dev/null; then
  read -rp "  overwrite existing config? [y/N] : " _ow
  if [[ ${_ow:-} =~ ^[Yy]$ ]]; then
    cp "$CFG" "$CFG.bak.$(date +%s)"
  else
    WRITE=0
    warn "step 3 skipped — existing config kept"
  fi
fi

if [[ $WRITE -eq 1 ]]; then
  _clients="" _sids=""
  for ((i=1; i<=USER_COUNT; i++)); do
    _clients+="{\"id\":\"${UUIDS[$i]}\",\"flow\":\"$FLOW\"}"
    _sids+="\"${SIDS[$i]}\""
    if (( i < USER_COUNT )); then
      _clients+=","
      _sids+=","
    fi
  done

  cat > "$CFG" <<JSON
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [$_clients],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "$NET",
      "security": "$SEC",
      "realitySettings": {
        "dest": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": [$_sids],
        "fingerprint": "$FP"
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
JSON

  systemctl enable xray &>/dev/null
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray 2>/dev/null || {
    journalctl -u xray -n 20 --no-pager
    die "xray failed to start"
  }
  ok "xray active"
else
  ok "xray unchanged · $(systemctl is-active xray 2>/dev/null || echo unknown)"
fi

# ── STEP 4 · sysctl ──────────────────────────

info "step 4 · sysctl"
cat > /etc/sysctl.d/99-ais-128k.conf <<EOF
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 87380 4194304
net.ipv4.tcp_wmem=4096 16384 4194304
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_thin_linear_timeouts=1
net.netfilter.nf_conntrack_max=32768
vm.swappiness=10
EOF
sysctl --system &>/dev/null
ok "cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) · notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"

# ── STEP 5 · qdisc ───────────────────────────

info "step 5 · qdisc"
IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
[[ -z ${IFACE:-} ]] && die "cannot detect default interface"

QDISC=fq_codel
TC_CMD="tc qdisc replace dev $IFACE root fq_codel limit 512 target 5ms interval 100ms quantum 300"
if tc qdisc add dev lo root cake 2>/dev/null; then
  tc qdisc del dev lo root 2>/dev/null || true
  QDISC=cake
  TC_CMD="tc qdisc replace dev $IFACE root cake bandwidth 128kbit diffserv4 nat flowblind"
fi
$TC_CMD || die "qdisc apply failed"

cat > /etc/systemd/system/ais-qdisc.service <<EOF
[Unit]
Description=AIS qdisc latency tuning
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$TC_CMD

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ais-qdisc &>/dev/null
_q=$(tc qdisc show dev "$IFACE" 2>/dev/null | awk 'NR==1{print $2}')
ok "$QDISC on $IFACE · active=${_q:-unknown}"

# ── STEP 6 · nftables ────────────────────────

info "step 6 · nftables"
[[ -z ${SSH_PORT:-} ]] && die "SSH_PORT unset — aborting to prevent lockout"
cp /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%s)" 2>/dev/null || true

cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    ct state established,related accept
    ip  protocol icmp  limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept
    tcp dport $SSH_PORT limit rate 6/minute burst 10 packets accept
    tcp dport $PORT accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}

table inet mangle {
  chain prerouting {
    type filter hook prerouting priority -150;
    udp dport 53 ip dscp set cs5
    udp dport { 5000-5100, 7000-8999, 27000-27050, 5672, 17500, 3478-3480, 3074 } ip dscp set cs5
    udp length < 128 ip dscp set cs5
    tcp flags == ack ip length < 80 ip dscp set cs4
    tcp dport { 80, 443 } ip length > 1000 ip dscp set cs3
  }
}

table inet nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oif != "lo" masquerade
  }
}
EOF

nft -f /etc/nftables.conf || die "nftables load failed"
systemctl enable nftables &>/dev/null
ok "nftables active · ssh=$SSH_PORT · vless=$PORT"

# ── STEP 7 · dnsmasq ─────────────────────────

info "step 7 · dnsmasq"
if grep -q DNSStubListener /etc/systemd/resolved.conf 2>/dev/null; then
  sed -i 's/^#*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
else
  echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
fi
systemctl restart systemd-resolved

cp /etc/dnsmasq.conf "/etc/dnsmasq.conf.bak.$(date +%s)" 2>/dev/null || true
cat > /etc/dnsmasq.conf <<EOF
listen-address=127.0.0.1
bind-interfaces
port=53
server=94.140.14.140
server=94.140.14.141
server=1.1.1.1
server=1.0.0.1
server=8.8.8.8
cache-size=2048
min-cache-ttl=30
neg-ttl=10
dns-forward-max=150
no-resolv
EOF

chattr -i /etc/resolv.conf 2>/dev/null || true
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf

systemctl enable --now dnsmasq &>/dev/null
if dig +short google.com @127.0.0.1 2>/dev/null | grep -q .; then
  ok "dnsmasq resolving"
else
  warn "dnsmasq verify failed — check manually"
fi

# ── STEP 8 · client URIs ─────────────────────

info "step 8 · client URIs"
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
  || curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
  || echo unknown)
URI_FILE=/root/vless-clients.txt
: > "$URI_FILE"

sep
for ((i=1; i<=USER_COUNT; i++)); do
  URI="vless://${UUIDS[$i]}@${SERVER_DOMAIN}:${PORT}?security=${SEC}&encryption=${ENC}&pbk=${PUB}&headerType=&fp=${FP}&spx=${SPX}&type=${NET}&flow=${FLOW}&sni=${SNI}&sid=${SIDS[$i]}#${TAGS[$i]}"
  echo -e "  ${G}${URI}${N}"
  echo "$URI" >> "$URI_FILE"
done
chmod 600 "$URI_FILE"
sep

# ── SUMMARY ──────────────────────────────────

echo; sep
printf "  %-22s %s\n" xray-version  "$(xray version 2>/dev/null | awk 'NR==1{print $2}')"
printf "  %-22s %s\n" server-domain "$SERVER_DOMAIN"
printf "  %-22s %s\n" server-ip     "$SERVER_IP"
printf "  %-22s %s\n" vless-port    "$PORT"
printf "  %-22s %s\n" sni           "$SNI"
printf "  %-22s %s\n" fingerprint   "$FP"
printf "  %-22s %s\n" users         "$USER_COUNT"
printf "  %-22s %s\n" qdisc         "$QDISC"
printf "  %-22s %s\n" tcp-cc        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "  %-22s %s\n" nftables      "$(systemctl is-active nftables 2>/dev/null)"
printf "  %-22s %s\n" dnsmasq       "$(systemctl is-active dnsmasq 2>/dev/null)"
printf "  %-22s %s\n" uri-file      "$URI_FILE"
printf "  %-22s %s\n" log           "$LOG"
sep
echo -e "\n  ${G}done.${N}\n"
