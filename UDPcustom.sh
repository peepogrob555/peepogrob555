#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

VPS_USER="shogun"
VPS_PASS='Q7m@L2vR9x#T4z$K8p'
UDP_LISTEN_PORT=50000
BADVPN_PORT=7300
TCP_ALLOWED_PORTS=(22 109 143 442 777 8080 8443)

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root${NC}"
  exit 1
fi

apt-get update -qq
apt-get install -y ufw iptables-persistent netfilter-persistent build-essential cmake git > /dev/null 2>&1

id "$VPS_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$VPS_USER"
echo "${VPS_USER}:${VPS_PASS}" | chpasswd

mkdir -p /root/udp
cat > /root/udp/config.json << EOF
{
  "listen": ":${UDP_LISTEN_PORT}",
  "stream_buffer": 209715200,
  "receive_buffer": 209715200,
  "auth": {
    "mode": "passwords"
  }
}
EOF

mkdir -p /etc/systemd/system/udp-custom.service.d
cat > /etc/systemd/system/udp-custom.service.d/override.conf << 'EOF'
[Service]
WorkingDirectory=/root/udp
EOF

systemctl daemon-reload
systemctl enable udp-custom
systemctl restart udp-custom
sleep 2

if ! command -v badvpn-udpgw >/dev/null 2>&1; then
  rm -rf /usr/local/src/badvpn
  git clone --depth 1 https://github.com/ambrop72/badvpn /usr/local/src/badvpn > /dev/null 2>&1
  mkdir -p /usr/local/src/badvpn/build
  cd /usr/local/src/badvpn/build
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
  make -j"$(nproc)" > /dev/null 2>&1
  cp udpgw/badvpn-udpgw /usr/local/bin/
  cd - > /dev/null
fi

cat > /etc/systemd/system/badvpn-udpgw.service << EOF
[Unit]
Description=BadVPN UDP Gateway
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${BADVPN_PORT} --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now badvpn-udpgw

DETECTED_TCP=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un)
for p in $DETECTED_TCP; do
  if [[ ! " ${TCP_ALLOWED_PORTS[*]} " =~ " ${p} " ]]; then
    TCP_ALLOWED_PORTS+=("$p")
  fi
done

ufw --force reset > /dev/null
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw

if modprobe xt_hashlimit 2>/dev/null; then
  echo "xt_hashlimit" > /etc/modules-load.d/xt_hashlimit.conf
  if ! grep -q "UDP-RATE-LIMIT" /etc/ufw/before.rules; then
    awk '/^COMMIT$/ && !d {
      print "# UDP-RATE-LIMIT";
      print "-A ufw-before-input -p udp -m conntrack --ctstate NEW -m hashlimit --hashlimit-name udpnew --hashlimit-above 200/sec --hashlimit-mode srcip --hashlimit-burst 400 -j DROP";
      d=1
    } { print }' /etc/ufw/before.rules > /tmp/before.rules.tmp
    mv /tmp/before.rules.tmp /etc/ufw/before.rules
  fi
fi

ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

for p in "${TCP_ALLOWED_PORTS[@]}"; do
  ufw allow "${p}/tcp"
done

ufw allow 1:65535/udp
DANGEROUS_UDP=(19 69 111 123 137 138 161 162 1900 3389 5353 11211)
for p in "${DANGEROUS_UDP[@]}"; do
  ufw deny "${p}/udp"
done

ufw allow out to 1.1.1.1 port 53
ufw allow out to 1.0.0.1 port 53
ufw allow out to 2606:4700:4700::1111 port 53
ufw allow out to 2606:4700:4700::1001 port 53
ufw deny out to any port 53
ufw deny out to any port 853

ufw --force enable

if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/cloudflare-dns.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=
Domains=~.
DNSStubListener=no
DNSOverTLS=yes
EOF
  systemctl restart systemd-resolved
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
else
  chattr -i /etc/resolv.conf 2>/dev/null || true
  printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf
  chattr +i /etc/resolv.conf 2>/dev/null || true
fi

if ! ip -6 route show default 2>/dev/null | grep -q default; then
  ip6tables -P OUTPUT DROP 2>/dev/null || true
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -d 2606:4700:4700::1111 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -d 2606:4700:4700::1001 -p udp --dport 53 -j ACCEPT 2>/dev/null || true
fi

modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
echo "sch_fq_codel" > /etc/modules-load.d/sch_fq_codel.conf

cat > /etc/modprobe.d/nf_conntrack.conf << 'EOF'
options nf_conntrack hashsize=524288
EOF

cat > /etc/sysctl.d/99-udpcustom-optimize.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_codel
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 8388608
net.ipv4.tcp_wmem = 4096 1048576 8388608
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 8192
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1 || true

DEFAULT_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
if [ -n "$DEFAULT_IF" ]; then
  tc qdisc replace dev "$DEFAULT_IF" root fq_codel 2>/dev/null || true
fi

iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440 2>/dev/null || \
  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440

cat > /etc/security/limits.d/99-udpcustom.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

sleep 2
NAT_DUP_COUNT=$(iptables -t nat -L PREROUTING -n | grep -c "REDIRECT.*udp")
if [ "$NAT_DUP_COUNT" -gt 0 ]; then
  for i in $(seq "$NAT_DUP_COUNT" -1 1); do
    RULE_NUM=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "REDIRECT.*udp" | head -1 | awk '{print $1}')
    [ -n "$RULE_NUM" ] && iptables -t nat -D PREROUTING "$RULE_NUM" 2>/dev/null || true
  done
fi

netfilter-persistent save > /dev/null 2>&1

echo ""
systemctl status udp-custom --no-pager | head -6
echo ""
systemctl status badvpn-udpgw --no-pager | head -6
echo ""
ss -ulnp | grep -E "${UDP_LISTEN_PORT}|${BADVPN_PORT}"
echo ""
iptables -t nat -L PREROUTING -n -v
echo ""
ufw status verbose | head -20
echo ""
echo -e "${GREEN}เสร็จสมบูรณ์${NC}"
echo -e "${YELLOW}แนะนำ reboot: reboot${NC}"
