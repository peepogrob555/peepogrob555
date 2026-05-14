#!/usr/bin/env bash
set -euo pipefail

BRED='\033[1;31m'
BGRN='\033[1;32m'
BYLW='\033[1;33m'
BCYN='\033[1;36m'
RST='\033[0m'

LOG="/var/log/ais-vps-setup.log"

PORT=443
SNI="th.speedtest.net"
FINGERPRINT="firefox"
FLOW="xtls-rprx-vision"
NETWORK="tcp"
SECURITY="reality"
ENCRYPTION="none"
SPX="/"

if [[ $EUID -ne 0 ]]; then
  echo -e "${BRED}[FATAL] Must run as root${RST}"
  exit 1
fi

exec > >(tee -a "$LOG") 2>&1

clear
echo "================================================="
echo " AIS 128kbps Xray Reality Optimizer"
echo "================================================="
echo

read -rp "SERVER_DOMAIN (domain or IP): " SERVER_DOMAIN
[[ -z "$SERVER_DOMAIN" ]] && { echo -e "${BRED}[FATAL] SERVER_DOMAIN cannot be empty${RST}"; exit 1; }

DETECTED_SSH=$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | head -n1 || true)
if [[ -n "$DETECTED_SSH" ]]; then
  echo "Detected SSH port: $DETECTED_SSH"
  read -rp "Use detected SSH port $DETECTED_SSH? [Y/n]: " SSH_CONFIRM
  if [[ "$SSH_CONFIRM" =~ ^[Nn]$ ]]; then
    read -rp "Enter SSH port manually: " SSH_PORT
  else
    SSH_PORT="$DETECTED_SSH"
  fi
else
  read -rp "SSH port detection failed. Enter SSH port manually: " SSH_PORT
fi
[[ -z "$SSH_PORT" ]] && { echo -e "${BRED}[FATAL] Cannot determine SSH port${RST}"; exit 1; }

read -rp "Concurrent users [default=2]: " USER_COUNT
USER_COUNT=${USER_COUNT:-2}
if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [[ "$USER_COUNT" -lt 1 ]]; then
  echo -e "${BRED}[FATAL] USER_COUNT must be integer >= 1${RST}"
  exit 1
fi

declare -a USER_TAGS
for ((i=1; i<=USER_COUNT; i++)); do
  read -rp "Tag for user $i (e.g. phone): " TAG
  USER_TAGS[$i]="$TAG"
done

clear
echo "================ SUMMARY ================"
printf "%-20s %s\n" "Server domain"  "$SERVER_DOMAIN"
printf "%-20s %s\n" "SSH port"       "$SSH_PORT"
printf "%-20s %s\n" "Users"          "$USER_COUNT"
printf "%-20s %s\n" "VLESS port"     "$PORT"
printf "%-20s %s\n" "SNI"            "$SNI"
printf "%-20s %s\n" "Fingerprint"    "$FINGERPRINT"
printf "%-20s %s\n" "Flow"           "$FLOW"
printf "%-20s %s\n" "Security"       "$SECURITY"
echo "========================================="
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo -e "\n${BCYN}[STEP 1] Starting system_update ...${RST}"
apt-get update && apt-get upgrade -y
apt-get install -y nftables dnsmasq iproute2 curl wget ca-certificates gnupg dnsutils openssl
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
which xray >/dev/null 2>&1 || { echo -e "${BRED}[FATAL] xray binary not found${RST}"; exit 1; }
XRAY_VERSION=$(xray version | head -n1)
echo "$XRAY_VERSION"
echo -e "${BGRN}[STEP 1] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 2] Generating credentials ...${RST}"
KEYPAIR=$(xray x25519)
SERVER_PRIVKEY=$(echo "$KEYPAIR" | awk '/Private key/{print $3}')
SERVER_PUBKEY=$(echo "$KEYPAIR"  | awk '/Public key/{print $3}')

declare -a USER_UUIDS
declare -a USER_SIDS
for ((i=1; i<=USER_COUNT; i++)); do
  USER_UUIDS[$i]=$(xray uuid)
  USER_SIDS[$i]=$(openssl rand -hex 8)
done

printf "┌────────┬──────────────────────────────────────┬──────────────────┐\n"
printf "│ User   │ UUID                                 │ shortId          │\n"
printf "├────────┼──────────────────────────────────────┼──────────────────┤\n"
for ((i=1; i<=USER_COUNT; i++)); do
  printf "│ %-6s │ %-36s │ %-16s │\n" "${USER_TAGS[$i]}" "${USER_UUIDS[$i]}" "${USER_SIDS[$i]}"
done
printf "└────────┴──────────────────────────────────────┴──────────────────┘\n"
printf "Public key (shared): %s\n" "$SERVER_PUBKEY"
echo -e "${BGRN}[STEP 2] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 3] Configuring Xray ...${RST}"
CONFIG_PATH="/usr/local/etc/xray/config.json"
if [[ -f "$CONFIG_PATH" ]] && systemctl is-active --quiet xray; then
  read -rp "Overwrite existing xray config? [y/N]: " OVERWRITE
  if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
    echo -e "${BYLW}[STEP 3] Skipped (existing config kept)${RST}"
  else
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak.$(date +%s)"
    WRITE_CONFIG=1
  fi
else
  WRITE_CONFIG=1
fi

if [[ "${WRITE_CONFIG:-0}" -eq 1 ]]; then
  mkdir -p /usr/local/etc/xray /var/log/xray

  CLIENTS_JSON=""
  SHORTIDS_JSON=""
  for ((i=1; i<=USER_COUNT; i++)); do
    CLIENTS_JSON+="{\"id\":\"${USER_UUIDS[$i]}\",\"flow\":\"${FLOW}\"}"
    SHORTIDS_JSON+="\"${USER_SIDS[$i]}\""
    if [[ $i -lt $USER_COUNT ]]; then
      CLIENTS_JSON+=","
      SHORTIDS_JSON+=","
    fi
  done

  cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ ${CLIENTS_JSON} ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "${NETWORK}",
        "security": "${SECURITY}",
        "realitySettings": {
          "dest": "${SNI}:443",
          "serverNames": ["${SNI}"],
          "privateKey": "${SERVER_PRIVKEY}",
          "shortIds": [ ${SHORTIDS_JSON} ],
          "fingerprint": "${FINGERPRINT}"
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  systemctl enable xray
  systemctl restart xray
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 20
    echo -e "${BRED}[FATAL] xray failed to start${RST}"
    exit 1
  fi
fi
echo -e "${BGRN}[STEP 3] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 4] Applying sysctl tuning ...${RST}"
cat > /etc/sysctl.d/99-ais-128k.conf <<EOF
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 16384 4194304
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_thin_linear_timeouts = 1
net.netfilter.nf_conntrack_max = 32768
vm.swappiness = 10
EOF
sysctl --system
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_notsent_lowat
echo -e "${BGRN}[STEP 4] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 5] Setting up qdisc ...${RST}"
IFACE=$(ip route show default | awk 'NR==1{print $5}')
[[ -z "$IFACE" ]] && { echo -e "${BRED}[FATAL] Cannot detect network interface${RST}"; exit 1; }

CAKE_OK=0
if tc qdisc add dev lo root cake 2>/dev/null; then
  CAKE_OK=1
  tc qdisc del dev lo root 2>/dev/null
fi

if [[ "$CAKE_OK" -eq 1 ]]; then
  Q_CMD="tc qdisc replace dev ${IFACE} root cake bandwidth 128kbit diffserv4 nat flowblind"
  QDISC_NAME="CAKE"
else
  Q_CMD="tc qdisc replace dev ${IFACE} root fq_codel limit 512 target 5ms interval 100ms quantum 300"
  QDISC_NAME="fq_codel"
fi
$Q_CMD

cat > /etc/systemd/system/ais-qdisc.service <<EOF
[Unit]
Description=AIS qdisc latency tuning
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${Q_CMD}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ais-qdisc
tc qdisc show dev "$IFACE"
echo -e "${BGRN}[STEP 5] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 6] Setting up nftables ...${RST}"
[[ -z "$SSH_PORT" ]] && { echo -e "${BRED}[FATAL] Cannot determine SSH port. Aborting nftables.${RST}"; exit 1; }

cp /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%s)" 2>/dev/null || true

cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    policy drop;
    iif "lo" accept
    ct state established,related accept
    ip  protocol icmp  limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept
    tcp dport ${SSH_PORT} limit rate 6/minute burst 10 packets accept
    tcp dport ${PORT} accept
  }
  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }
  chain output {
    type filter hook output priority 0;
    policy accept;
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
  }
}

table inet nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oif != "lo" masquerade
  }
}
EOF

nft -f /etc/nftables.conf
systemctl enable nftables
nft list ruleset | head -60
echo -e "${BGRN}[STEP 6] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 7] Configuring dnsmasq ...${RST}"
if grep -q "DNSStubListener" /etc/systemd/resolved.conf; then
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

systemctl enable --now dnsmasq

if dig +short google.com @127.0.0.1 | grep -q .; then
  echo "DNS verify: OK"
else
  echo -e "${BYLW}[WARNING] dnsmasq verify failed — check manually${RST}"
fi
echo -e "${BGRN}[STEP 7] Done ✓${RST}"

echo -e "\n${BCYN}[STEP 8] Generating client URIs ...${RST}"
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org || curl -s4 --max-time 5 ifconfig.me || echo "unknown")

URI_FILE="/root/vless-clients.txt"
> "$URI_FILE"

for ((i=1; i<=USER_COUNT; i++)); do
  URI="vless://${USER_UUIDS[$i]}@${SERVER_DOMAIN}:${PORT}?security=${SECURITY}&encryption=${ENCRYPTION}&pbk=${SERVER_PUBKEY}&headerType=&fp=${FINGERPRINT}&spx=${SPX}&type=${NETWORK}&flow=${FLOW}&sni=${SNI}&sid=${USER_SIDS[$i]}#${USER_TAGS[$i]}"
  echo -e "${BGRN}${URI}${RST}"
  echo "$URI" >> "$URI_FILE"
done

chmod 600 "$URI_FILE"
echo "Client URIs saved to $URI_FILE"
echo -e "${BGRN}[STEP 8] Done ✓${RST}"

echo
printf "┌─────────────────────────┬──────────────────────────────────┐\n"
printf "│ %-23s │ %-32s │\n" "Setting" "Value"
printf "├─────────────────────────┼──────────────────────────────────┤\n"
printf "│ %-23s │ %-32s │\n" "Xray version"    "$(xray version | head -n1 | awk '{print $2}')"
printf "│ %-23s │ %-32s │\n" "Server domain"   "$SERVER_DOMAIN"
printf "│ %-23s │ %-32s │\n" "Server IP"       "$SERVER_IP"
printf "│ %-23s │ %-32s │\n" "VLESS port"      "$PORT"
printf "│ %-23s │ %-32s │\n" "SNI"             "$SNI"
printf "│ %-23s │ %-32s │\n" "Fingerprint"     "$FINGERPRINT"
printf "│ %-23s │ %-32s │\n" "Users configured" "$USER_COUNT"
printf "│ %-23s │ %-32s │\n" "qdisc applied"   "$QDISC_NAME"
printf "│ %-23s │ %-32s │\n" "TCP congestion"  "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "│ %-23s │ %-32s │\n" "nftables"        "$(systemctl is-active nftables)"
printf "│ %-23s │ %-32s │\n" "dnsmasq"         "$(systemctl is-active dnsmasq)"
printf "│ %-23s │ %-32s │\n" "Client URI file" "$URI_FILE"
printf "│ %-23s │ %-32s │\n" "Log file"        "$LOG"
printf "└─────────────────────────┴──────────────────────────────────┘\n"
echo
echo -e "${BGRN}Setup completed successfully.${RST}"
