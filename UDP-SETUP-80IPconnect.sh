#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

RTT_MS="${RTT_MS:-80}"
TUNNEL_MTU="${TUNNEL_MTU:-1500}"
CAKE_OVERHEAD="${CAKE_OVERHEAD:-18}"
MAX_USERS="${MAX_USERS:-80}"
FLOWS_PER_USER="${FLOWS_PER_USER:-30}"
SWAP_GB="${SWAP_GB:-4}"
UDPGW_PORT="${UDPGW_PORT:-7300}"

DOWNLOAD_SHAPE_MBIT="${DOWNLOAD_SHAPE_MBIT:-321}"
UPLOAD_SHAPE_MBIT="${UPLOAD_SHAPE_MBIT:-321}"

TOTAL_RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 6144)
TOTAL_RAM_MB="${TOTAL_RAM_MB:-6144}"
NCPU=$(nproc)

TCP_SAFE_BUDGET_MB="${TCP_SAFE_BUDGET_MB:-$(( TOTAL_RAM_MB * 90 / 100 ))}"
UDP_CUSTOM_MEM_HIGH_MB="${UDP_CUSTOM_MEM_HIGH_MB:-$(( TOTAL_RAM_MB * 85 / 100 ))}"
UDP_CUSTOM_MEM_MAX_MB="${UDP_CUSTOM_MEM_MAX_MB:-$(( TOTAL_RAM_MB * 90 / 100 ))}"

JOURNAL_MAX_RETENTION="${JOURNAL_MAX_RETENTION:-1d}"
JOURNAL_DISK_MAX_MB="${JOURNAL_DISK_MAX_MB:-512}"
DAILY_CLEAR_TIME="${DAILY_CLEAR_TIME:-00:00:00}"

UDP_CUSTOM_CONFIG="/root/udp/config.json"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

if [ ! -f "$UDP_CUSTOM_CONFIG" ]; then
  echo -e "${RED}ไม่พบ ${UDP_CUSTOM_CONFIG} กรุณาติดตั้ง udp-custom ก่อน${NC}"
  exit 1
fi

OS_VER=$(grep -oP '(?<=^VERSION_ID=")[^"]+' /etc/os-release 2>/dev/null || true)

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
  echo -e "${RED}หา default interface ไม่เจอ ยกเลิก${NC}"
  exit 1
fi

DNS_LABEL="Cloudflare+Google"
DNS_V4_A="1.1.1.1"; DNS_V4_B="8.8.8.8"
DNS_V6_A="2606:4700:4700::1111"; DNS_V6_B="2001:4860:4860::8888"

echo "IFACE=${IFACE} | RAM=${TOTAL_RAM_MB}MB | vCPU=${NCPU} | DNS=${DNS_LABEL} | MTU=${TUNNEL_MTU} | Pipe: Down=${DOWNLOAD_SHAPE_MBIT}mbit Up=${UPLOAD_SHAPE_MBIT}mbit (best-effort ไม่หารตายตัว รองรับสูงสุด ${MAX_USERS} IP/connect) | RTT=${RTT_MS}ms"

UDP_CUSTOM_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CUSTOM_CONFIG" || true)
if [ -z "$UDP_CUSTOM_PORT" ]; then
  read -rp "ใส่พอร์ต UDP ที่ udp-custom ใช้จริง: " UDP_CUSTOM_PORT
fi

cat > /etc/tunnel-qos.conf << EOF
IFACE=${IFACE}
DOWNLOAD_SHAPE_MBIT=${DOWNLOAD_SHAPE_MBIT}
UPLOAD_SHAPE_MBIT=${UPLOAD_SHAPE_MBIT}
RTT_MS=${RTT_MS}
TUNNEL_MTU=${TUNNEL_MTU}
CAKE_OVERHEAD=${CAKE_OVERHEAD}
MAX_USERS=${MAX_USERS}
DNS_LABEL=${DNS_LABEL}
DNS_V4_A=${DNS_V4_A}
DNS_V4_B=${DNS_V4_B}
DNS_V6_A=${DNS_V6_A}
DNS_V6_B=${DNS_V6_B}
UDP_CUSTOM_PORT=${UDP_CUSTOM_PORT}
FAIRSHARE_MODE=0
EOF

apt-get update -qq
apt-get install -y ufw iptables conntrack ethtool iproute2 jq irqbalance rsyslog cmake build-essential git > /dev/null 2>&1

modprobe sch_cake 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tunnel.conf

systemctl enable --now irqbalance > /dev/null 2>&1 || true

if ! swapon --show | grep -q .; then
  AVAIL_KB=$(df --output=avail -k / | tail -1)
  NEED_KB=$(( SWAP_GB * 1024 * 1024 ))
  if [ "$AVAIL_KB" -gt "$((NEED_KB + 2097152))" ]; then
    fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

ufw --force reset > /dev/null
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw default deny routed > /dev/null
for p in 21 23 25 111 135 137 138 139 445 512 513 514 1433 2049 3306 3389 5432 5900 6379 11211 27017; do
  ufw deny "${p}/tcp" > /dev/null
done
for p in 19 69 111 123 137 138 161 162 1900 3389 5353 11211; do
  ufw deny "${p}/udp" > /dev/null
done
ufw allow 1:65535/tcp > /dev/null
ufw allow 1:65535/udp > /dev/null
ufw allow out to "$DNS_V4_A" port 53 > /dev/null
ufw allow out to "$DNS_V4_B" port 53 > /dev/null
ufw allow out to "$DNS_V6_A" port 53 > /dev/null
ufw allow out to "$DNS_V6_B" port 53 > /dev/null
ufw deny out to any port 53 > /dev/null
ufw deny out to any port 853 > /dev/null
ufw --force enable > /dev/null

rm -f /etc/netplan/90-dns-override.yaml

mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << 'EOF'
network: {config: disabled}
EOF

for f in /etc/netplan/*.yaml; do
  [ -f "$f" ] || continue
  cp "$f" "${f}.bak.$(date +%s)"
  ORIG_PERM=$(stat -c '%a' "$f" 2>/dev/null || echo 600)
  awk '
  {
    match($0, /^[ ]*/); indent = RLENGTH
    if (skip) {
      if (indent > skip_indent) next
      skip = 0
    }
    if ($0 ~ /^[ ]*nameservers:[ ]*$/) {
      skip = 1
      skip_indent = indent
      next
    }
    print
  }' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  chmod "$ORIG_PERM" "$f" 2>/dev/null || true
done

sed -i \
  -e 's/1\.0\.0\.1/8.8.8.8/g' \
  -e 's/8\.8\.4\.4/1.1.1.1/g' \
  -e 's/2606:4700:4700::1001/2001:4860:4860::8888/g' \
  -e 's/2001:4860:4860::8844/2606:4700:4700::1111/g' \
  /etc/netplan/*.yaml 2>/dev/null || true

mkdir -p /etc/systemd/resolved.conf.d
rm -rf /etc/systemd/resolved.conf.d/* 2>/dev/null
cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=${DNS_V4_A} ${DNS_V4_B} ${DNS_V6_A} ${DNS_V6_B}
FallbackDNS=
Domains=~.
DNSStubListener=yes
LLMNR=no
MulticastDNS=no
DNSSEC=no
DNSOverTLS=no
EOF

command -v netplan >/dev/null 2>&1 && netplan apply 2>/dev/null || true
systemctl restart systemd-resolved 2>/dev/null || true
systemctl restart systemd-networkd 2>/dev/null || true

ip link set dev "$IFACE" mtu "$TUNNEL_MTU" 2>/dev/null || true
cat > /etc/systemd/system/set-mtu.service << EOF
[Unit]
Description=Set tunnel MTU
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${IFACE} mtu ${TUNNEL_MTU}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/set-multiqueue.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true
NCPU=$(nproc)
Q=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/ {print $2; exit}')
if [ -n "$Q" ] && [ "$Q" -gt 1 ] 2>/dev/null && [ "$Q" != "$NCPU" ]; then
  ethtool -L "$IFACE" combined "$NCPU" 2>/dev/null || true
fi
ethtool -C "$IFACE" adaptive-rx off adaptive-tx off rx-usecs 8 tx-usecs 8 2>/dev/null || true
RUNTIME
chmod +x /usr/local/sbin/set-multiqueue.sh

cat > /etc/systemd/system/set-multiqueue.service << 'EOF'
[Unit]
Description=Restore NIC multi-queue (combined) count across all vCPU after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set-multiqueue.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now set-multiqueue.service > /dev/null 2>&1

MSS_V4=$((TUNNEL_MTU - 40))
cat > /usr/local/sbin/mss-clamp.sh << EOF
#!/bin/bash
MSS_V4=${MSS_V4}
apply() {
  local table="\$1" chain="\$2"; shift 2
  iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null || iptables -t "\$table" -A "\$chain" "\$@"
}
apply mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V4"
apply mangle OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V4"
if command -v ip6tables >/dev/null 2>&1; then
  MSS_V6=\$((MSS_V4 - 20))
  apply6() {
    local chain="\$1"; shift
    ip6tables -t mangle -C "\$chain" "\$@" 2>/dev/null || ip6tables -t mangle -A "\$chain" "\$@"
  }
  apply6 FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V6" 2>/dev/null || true
  apply6 OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V6" 2>/dev/null || true
fi
EOF
chmod +x /usr/local/sbin/mss-clamp.sh
/usr/local/sbin/mss-clamp.sh

cat > /etc/systemd/system/mss-clamp.service << EOF
[Unit]
Description=Clamp TCP MSS to match tunnel MTU
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mss-clamp.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now set-mtu.service mss-clamp.service > /dev/null 2>&1

RMEM_MIN=262144
RMEM_CEILING=50331648

BDP_FULLPIPE_DOWN=$(( DOWNLOAD_SHAPE_MBIT * 1000000 / 8 * RTT_MS / 1000 ))
BDP_FULLPIPE_UP=$(( UPLOAD_SHAPE_MBIT * 1000000 / 8 * RTT_MS / 1000 ))
RMEM_MAX=$(( BDP_FULLPIPE_DOWN * 4 ))
WMEM_MAX=$(( BDP_FULLPIPE_UP * 4 ))
[ "$RMEM_MAX" -lt "$RMEM_MIN" ]     && RMEM_MAX=$RMEM_MIN
[ "$RMEM_MAX" -gt "$RMEM_CEILING" ] && RMEM_MAX=$RMEM_CEILING
[ "$WMEM_MAX" -lt "$RMEM_MIN" ]     && WMEM_MAX=$RMEM_MIN
[ "$WMEM_MAX" -gt "$RMEM_CEILING" ] && WMEM_MAX=$RMEM_CEILING

VM_MIN_FREE_KB=$(( TOTAL_RAM_MB * 1024 * 2 / 100 ))
[ "$VM_MIN_FREE_KB" -lt 65536 ] && VM_MIN_FREE_KB=65536

NF_CONNTRACK_MAX=$(( MAX_USERS * 5000 ))
[ "$NF_CONNTRACK_MAX" -lt 20000 ] && NF_CONNTRACK_MAX=20000
NF_CONNTRACK_HASHSIZE=$(( NF_CONNTRACK_MAX / 4 ))

AVG_SHARE_DOWN_MBIT=$(( DOWNLOAD_SHAPE_MBIT / MAX_USERS ))
AVG_SHARE_UP_MBIT=$(( UPLOAD_SHAPE_MBIT / MAX_USERS ))
[ "$AVG_SHARE_DOWN_MBIT" -lt 1 ] && AVG_SHARE_DOWN_MBIT=1
[ "$AVG_SHARE_UP_MBIT" -lt 1 ]   && AVG_SHARE_UP_MBIT=1

BDP_AVG_DOWN=$(( AVG_SHARE_DOWN_MBIT * 1000000 / 8 * RTT_MS / 1000 ))
BDP_AVG_UP=$(( AVG_SHARE_UP_MBIT * 1000000 / 8 * RTT_MS / 1000 ))

TOTAL_FLOWS=$(( MAX_USERS * FLOWS_PER_USER ))
BUDGET_PER_FLOW=$(( TCP_SAFE_BUDGET_MB * 1024 * 1024 / TOTAL_FLOWS / 2 ))
BUDGET_PER_USER=$(( TCP_SAFE_BUDGET_MB * 1024 * 1024 / MAX_USERS / 2 ))

TCP_DEFAULT_RMEM=$(( BDP_AVG_DOWN * 2 ))
TCP_DEFAULT_WMEM=$(( BDP_AVG_UP * 2 ))
[ "$TCP_DEFAULT_RMEM" -lt 87380 ] && TCP_DEFAULT_RMEM=87380
[ "$TCP_DEFAULT_WMEM" -lt 65536 ] && TCP_DEFAULT_WMEM=65536
[ "$TCP_DEFAULT_RMEM" -gt "$RMEM_MAX" ]       && TCP_DEFAULT_RMEM=$RMEM_MAX
[ "$TCP_DEFAULT_WMEM" -gt "$WMEM_MAX" ]       && TCP_DEFAULT_WMEM=$WMEM_MAX
[ "$TCP_DEFAULT_RMEM" -gt "$BUDGET_PER_FLOW" ] && TCP_DEFAULT_RMEM=$BUDGET_PER_FLOW
[ "$TCP_DEFAULT_WMEM" -gt "$BUDGET_PER_FLOW" ] && TCP_DEFAULT_WMEM=$BUDGET_PER_FLOW

UDP_CUSTOM_RBUF=$(( BDP_FULLPIPE_DOWN * 4 ))
[ "$UDP_CUSTOM_RBUF" -gt "$BUDGET_PER_USER" ] && UDP_CUSTOM_RBUF=$BUDGET_PER_USER
[ "$UDP_CUSTOM_RBUF" -lt 262144 ]             && UDP_CUSTOM_RBUF=262144

UDP_CUSTOM_SBUF=$(( BDP_FULLPIPE_UP * 4 ))
[ "$UDP_CUSTOM_SBUF" -gt "$BUDGET_PER_USER" ] && UDP_CUSTOM_SBUF=$BUDGET_PER_USER
[ "$UDP_CUSTOM_SBUF" -lt 131072 ]             && UDP_CUSTOM_SBUF=131072

cat > /etc/sysctl.d/99-tunnel-optimize.conf << EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake
net.ipv4.ip_forward = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.ipv4.tcp_rmem = 4096 ${TCP_DEFAULT_RMEM} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_DEFAULT_WMEM} ${WMEM_MAX}
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 5000
net.core.rps_sock_flow_entries = 32768
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
fs.file-max = 1048576
vm.swappiness = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = ${VM_MIN_FREE_KB}
EOF
echo "options nf_conntrack hashsize=${NF_CONNTRACK_HASHSIZE}" > /etc/modprobe.d/nf_conntrack.conf
echo "$NF_CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true

if [ -f /etc/sysctl.conf ]; then
  cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)"
  for key in net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.ip_forward \
             net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
             net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs net.core.somaxconn \
             net.ipv4.tcp_max_syn_backlog net.core.rps_sock_flow_entries net.ipv4.tcp_frto \
             net.ipv4.tcp_ecn net.ipv4.tcp_syncookies net.ipv4.tcp_keepalive_time \
             net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
             vm.dirty_ratio vm.dirty_background_ratio vm.min_free_kbytes \
             net.netfilter.nf_conntrack_max fs.file-max vm.swappiness; do
    esc_key=$(printf '%s' "$key" | sed 's/\./\\./g')
    sed -i -E "/^[[:space:]]*${esc_key}[[:space:]]*=/d" /etc/sysctl.conf
  done
fi

sysctl --system > /dev/null 2>&1 || true

cat > /usr/local/sbin/set-thp-madvise.sh << 'RUNTIME'
#!/bin/bash
[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
[ -f /sys/kernel/mm/transparent_hugepage/defrag ]  && echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
RUNTIME
chmod +x /usr/local/sbin/set-thp-madvise.sh

cat > /etc/systemd/system/set-thp-madvise.service << 'EOF'
[Unit]
Description=Keep THP in madvise mode to avoid compaction stalls under high memory pressure
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set-thp-madvise.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now set-thp-madvise.service > /dev/null 2>&1

cat > /usr/local/sbin/qos-root-init.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf

modprobe sch_cake 2>/dev/null || true
modprobe ifb numifbs=1 2>/dev/null || true
ip link set dev ifb0 up 2>/dev/null || true

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

tc qdisc add dev "$IFACE" root cake \
  bandwidth "${DOWNLOAD_SHAPE_MBIT}"mbit rtt "${RTT_MS}"ms overhead "${CAKE_OVERHEAD}" \
  besteffort flows ack-filter

tc qdisc add dev "$IFACE" handle ffff: ingress
tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

tc qdisc add dev ifb0 root cake \
  bandwidth "${UPLOAD_SHAPE_MBIT}"mbit rtt "${RTT_MS}"ms overhead "${CAKE_OVERHEAD}" \
  besteffort flows ack-filter
RUNTIME
chmod +x /usr/local/sbin/qos-root-init.sh

cat > /etc/systemd/system/tunnel-shaper.service << 'EOF'
[Unit]
Description=CAKE best-effort QoS
After=network-online.target set-multiqueue.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qos-root-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tunnel-shaper.service > /dev/null 2>&1
systemctl restart tunnel-shaper.service

cat > /usr/local/sbin/set-rps.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true
NCPU=$(nproc)
MASK=$(printf '%x' $(( (1 << NCPU) - 1 )))
for rx in /sys/class/net/"${IFACE}"/queues/rx-*/rps_cpus; do
  [ -e "$rx" ] && echo "$MASK" > "$rx" 2>/dev/null || true
done
for rx in /sys/class/net/ifb0/queues/rx-*/rps_cpus; do
  [ -e "$rx" ] && echo "$MASK" > "$rx" 2>/dev/null || true
done
for rf in /sys/class/net/"${IFACE}"/queues/rx-*/rps_flow_cnt; do
  [ -e "$rf" ] && echo 4096 > "$rf" 2>/dev/null || true
done
for rf in /sys/class/net/ifb0/queues/rx-*/rps_flow_cnt; do
  [ -e "$rf" ] && echo 4096 > "$rf" 2>/dev/null || true
done
for tx in /sys/class/net/"${IFACE}"/queues/tx-*/xps_cpus; do
  [ -e "$tx" ] && echo "$MASK" > "$tx" 2>/dev/null || true
done
for tx in /sys/class/net/ifb0/queues/tx-*/xps_cpus; do
  [ -e "$tx" ] && echo "$MASK" > "$tx" 2>/dev/null || true
done
RUNTIME
chmod +x /usr/local/sbin/set-rps.sh

cat > /etc/systemd/system/set-rps.service << 'EOF'
[Unit]
Description=Spread RX+TX packet steering across all CPU cores
After=network-online.target set-multiqueue.service tunnel-shaper.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/set-rps.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now set-rps.service > /dev/null 2>&1

cat > /usr/local/sbin/tunnel-selfheal.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true

CUR_MTU=$(cat /sys/class/net/"${IFACE}"/mtu 2>/dev/null || echo 0)
[ "$CUR_MTU" != "$TUNNEL_MTU" ] && ip link set dev "${IFACE}" mtu "$TUNNEL_MTU" 2>/dev/null || true

if ! tc qdisc show dev "${IFACE}" 2>/dev/null | grep -q "qdisc cake" || \
   ! tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc cake"; then
  /usr/local/sbin/qos-root-init.sh >/dev/null 2>&1
fi

/usr/local/sbin/set-multiqueue.sh >/dev/null 2>&1
/usr/local/sbin/set-rps.sh >/dev/null 2>&1
RUNTIME
chmod +x /usr/local/sbin/tunnel-selfheal.sh

cat > /etc/systemd/system/tunnel-selfheal.service << 'EOF'
[Unit]
Description=Detect and silently repair tunnel network config drift (MTU/CAKE/multiqueue/RPS)
After=tunnel-shaper.service set-rps.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tunnel-selfheal.sh
EOF

cat > /etc/systemd/system/tunnel-selfheal.timer << 'EOF'
[Unit]
Description=Run tunnel-selfheal every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now tunnel-selfheal.timer > /dev/null 2>&1

cp "$UDP_CUSTOM_CONFIG" "${UDP_CUSTOM_CONFIG}.bak.$(date +%s)"
jq --argjson rb "$UDP_CUSTOM_RBUF" --argjson sb "$UDP_CUSTOM_SBUF" \
  '.receive_buffer=$rb | .stream_buffer=$sb' \
  "$UDP_CUSTOM_CONFIG" > "${UDP_CUSTOM_CONFIG}.tmp" && mv "${UDP_CUSTOM_CONFIG}.tmp" "$UDP_CUSTOM_CONFIG"

UDP_CUSTOM_SERVICE="/etc/systemd/system/udp-custom.service"
if [ -f "$UDP_CUSTOM_SERVICE" ]; then
  cp "$UDP_CUSTOM_SERVICE" "${UDP_CUSTOM_SERVICE}.bak.$(date +%s)"
  sed -i '/99-tunnel-optimize/d' "$UDP_CUSTOM_SERVICE" 2>/dev/null || true

  mkdir -p "${UDP_CUSTOM_SERVICE}.d"
  cat > "${UDP_CUSTOM_SERVICE}.d/99-tuning.conf" << EOF
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Environment=GOMAXPROCS=${NCPU}
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2
OOMScoreAdjust=-500
LimitNOFILE=1048576
MemoryHigh=${UDP_CUSTOM_MEM_HIGH_MB}M
MemoryMax=${UDP_CUSTOM_MEM_MAX_MB}M
CPUWeight=600
Restart=always
RestartSec=2
ExecStartPost=/bin/bash -c 'sleep 3; sysctl -p /etc/sysctl.d/99-tunnel-optimize.conf >/dev/null 2>&1; /usr/local/sbin/set-rps.sh >/dev/null 2>&1'
EOF
  systemctl daemon-reload
fi

if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
  rm -rf /usr/local/src/badvpn
  git clone --depth 1 https://github.com/ambrop72/badvpn.git /usr/local/src/badvpn > /dev/null 2>&1
  mkdir -p /usr/local/src/badvpn/badvpn-build
  cd /usr/local/src/badvpn/badvpn-build
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
  make -j"$(nproc)" > /dev/null 2>&1
  cp udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
  cd /
fi

UDPGW_MAX_CLIENTS=$(( MAX_USERS + 3 ))
UDPGW_MAX_CONN_PER_CLIENT=64

cat > /etc/systemd/system/udpgw.service << EOF
[Unit]
Description=BadVPN UDPGW
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients ${UDPGW_MAX_CLIENTS} --max-connections-for-client ${UDPGW_MAX_CONN_PER_CLIENT}
Restart=always
RestartSec=2
LimitNOFILE=51200
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2
OOMScoreAdjust=-500
CPUWeight=300
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now udpgw.service > /dev/null 2>&1
systemctl restart udp-custom 2>/dev/null || true
systemctl restart udpgw 2>/dev/null || true
systemctl restart tunnel-shaper.service

systemctl disable --now safe-reboot.timer > /dev/null 2>&1 || true
rm -f /etc/systemd/system/safe-reboot.timer /etc/systemd/system/safe-reboot.service /usr/local/sbin/safe-reboot.sh

systemctl disable --now log-clear.timer > /dev/null 2>&1 || true
systemctl disable --now log-watchdog.timer > /dev/null 2>&1 || true
systemctl disable --now log-age-clear.timer > /dev/null 2>&1 || true
rm -f /etc/systemd/system/log-clear.timer /etc/systemd/system/log-clear.service \
      /etc/systemd/system/log-watchdog.service /etc/systemd/system/log-watchdog.timer \
      /etc/systemd/system/log-age-clear.service /etc/systemd/system/log-age-clear.timer \
      /usr/local/sbin/log-watchdog.sh /usr/local/sbin/log-clear.sh /usr/local/sbin/log-age-clear.sh

systemctl disable --now logrotate.timer > /dev/null 2>&1 || true
[ -f /etc/cron.daily/logrotate ] && chmod -x /etc/cron.daily/logrotate

if mountpoint -q /var/log; then
  FSTYPE=$(findmnt -no FSTYPE /var/log 2>/dev/null || true)
  if [ "$FSTYPE" = "tmpfs" ]; then
    umount /var/log 2>/dev/null || umount -l /var/log 2>/dev/null || true
  fi
fi
sed -i '/^tmpfs \/var\/log tmpfs/d' /etc/fstab

mkdir -p /etc/systemd/journald.conf.d
rm -f /etc/systemd/journald.conf.d/ram-only.conf
cat > /etc/systemd/journald.conf.d/disk-hourly.conf << EOF
[Journal]
Storage=persistent
SystemMaxUse=${JOURNAL_DISK_MAX_MB}M
SystemMaxFileSize=$((JOURNAL_DISK_MAX_MB / 4))M
MaxRetentionSec=${JOURNAL_MAX_RETENTION}
ForwardToSyslog=yes
EOF
systemctl restart systemd-journald

mkdir -p /etc/tmpfiles.d
rm -f /etc/tmpfiles.d/varlog-ram.conf
cat > /etc/tmpfiles.d/varlog-perms.conf << 'EOF'
d /var/log/apt 0755 root root -
d /var/log/private 0700 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/varlog-perms.conf > /dev/null 2>&1 || true

cat > /usr/local/sbin/daily-cache-log-clear.sh << 'RUNTIME'
#!/bin/bash
journalctl --rotate > /dev/null 2>&1 || true
journalctl --vacuum-time=1s > /dev/null 2>&1 || true
find /var/log -maxdepth 4 -type f -exec truncate -s 0 {} \; 2>/dev/null || true
apt-get clean > /dev/null 2>&1 || true
find /tmp -mindepth 1 -mtime +1 -delete 2>/dev/null || true
sync
echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
RUNTIME
chmod +x /usr/local/sbin/daily-cache-log-clear.sh

cat > /etc/systemd/system/daily-cache-log-clear.service << 'EOF'
[Unit]
Description=Daily full log + cache clear

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/daily-cache-log-clear.sh
EOF

cat > /etc/systemd/system/daily-cache-log-clear.timer << EOF
[Unit]
Description=Run daily-cache-log-clear every day at ${DAILY_CLEAR_TIME}

[Timer]
OnCalendar=*-*-* ${DAILY_CLEAR_TIME}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now daily-cache-log-clear.timer > /dev/null 2>&1

systemctl restart rsyslog 2>/dev/null || true
systemctl restart cron 2>/dev/null || true
systemctl restart ssh 2>/dev/null || true

echo ""
echo "=================================================="
echo -e "${GREEN}ติดตั้ง/ปรับจูนระบบเรียบร้อย | RAM ${TOTAL_RAM_MB}MB /${NCPU}vCPU (ใช้เต็มถึง 90%, ${UDP_CUSTOM_MEM_HIGH_MB}MB เป็นจุดหน่วงก่อนแตะเพดาน ${UDP_CUSTOM_MEM_MAX_MB}MB) | MTU ${TUNNEL_MTU} | pipe ${DOWNLOAD_SHAPE_MBIT}↓/${UPLOAD_SHAPE_MBIT}↑ Mbit @ RTT ${RTT_MS}ms | best-effort เต็มสปีดต่อคน ให้ cake แบ่งเอง | สูงสุด ${MAX_USERS} IP/connect, ${FLOWS_PER_USER} flow/user | UDPGW พอร์ต ${UDPGW_PORT} | GOMAXPROCS=${NCPU} + CPUWeight/priority สูงให้ udp-custom/udpgw + auto-restart | ECN+syncookies+keepalive+dirty-ratio+min_free_kbytes(${VM_MIN_FREE_KB}KB)+THP=madvise | self-heal watchdog เช็ค MTU/CAKE/RPS ทุก 5 นาที | log เก็บดิสก์ ล้าง log+cache เต็มทุกวัน ${DAILY_CLEAR_TIME} น. | ตั้งค่าทั้งหมดรอดรีบูต${NC}"
echo "=================================================="
