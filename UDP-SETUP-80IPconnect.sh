#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

TOTAL_RAM_MB=6144
NCPU=4

RTT_MS=65
TUNNEL_MTU=1500
CAKE_OVERHEAD=40
SWAP_GB=4
UDPGW_PORT=7300

# ปรับจำกัดท่อหลักเป็น 300 Mbps ให้เหมาะกับสเปคเครื่อง
DOWNLOAD_SHAPE_MBIT=300
UPLOAD_SHAPE_MBIT=300
PER_USER_DOWN_MBIT=20
PER_USER_UP_MBIT=20
PER_USER_GUAR_MBIT=2
HASH_DIVISOR=1024

# MSS ของ IPv4 (MTU=1500 - 40 byte header - 20 byte กันชนสำหรับ overhead ของ tunnel)
TCP_MSS_V4=1440

TCP_RMEM_DEFAULT=131072
TCP_RMEM_MAX=2097152
TCP_WMEM_DEFAULT=131072
TCP_WMEM_MAX=2097152

UDP_CUSTOM_RBUF=2097152
UDP_CUSTOM_SBUF=2097152

NF_CONNTRACK_MAX=1000000
NF_CONNTRACK_HASHSIZE=250000
NF_CONNTRACK_UDP_TIMEOUT=10
NF_CONNTRACK_UDP_TIMEOUT_STREAM=120
NF_CONNTRACK_TCP_TIMEOUT_ESTABLISHED=3600
UDPGW_MAX_CLIENTS=2048
UDPGW_MAX_CONN_PER_CLIENT=256

NETDEV_MAX_BACKLOG=65536
NETDEV_BUDGET=1000
NETDEV_BUDGET_USECS=3000
RPS_SOCK_FLOW_ENTRIES=65536
SOMAXCONN=32768
TCP_MAX_SYN_BACKLOG=32768
TCP_RETRIES2=10
TCP_SYN_RETRIES=4

UDP_CUSTOM_MEM_HIGH_MB=4915
UDP_CUSTOM_MEM_MAX_MB=5530
VM_MIN_FREE_KB=125829

JOURNAL_MAX_RETENTION=1d
JOURNAL_DISK_MAX_MB=4096
DAILY_CLEAR_TIME=00:00:00
CLEAR_TIMEZONE=Asia/Bangkok

UDP_CUSTOM_CONFIG="/root/udp/config.json"

RESERVE_LAST_CPU_FOR_UDPGW=1
UDPGW_RT_PRIORITY=15
TXQUEUELEN=10000
SELFHEAL_INTERVAL_SEC=10
HEALTHCHECK_FAIL_STREAK_LIMIT=3

UDP_KERNEL_MEM_MIN_MB=256
UDP_KERNEL_MEM_PRESSURE_MB=512
UDP_KERNEL_MEM_MAX_MB=4096
UDP_RMEM_MIN=131072
UDP_WMEM_MIN=131072

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}ต้องรันด้วย root: sudo bash $0${NC}"
  exit 1
fi

if [ ! -f "$UDP_CUSTOM_CONFIG" ]; then
  echo -e "${RED}ไม่พบ ${UDP_CUSTOM_CONFIG} กรุณาติดตั้ง udp-custom ก่อน${NC}"
  exit 1
fi

IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
  echo -e "${RED}หา default interface ไม่เจอ ยกเลิก${NC}"
  exit 1
fi

APP_CPU=-1
if [ "$RESERVE_LAST_CPU_FOR_UDPGW" -eq 1 ] && [ "$NCPU" -ge 3 ]; then
  APP_CPU=$((NCPU-1))
fi
if [ "$APP_CPU" -ge 0 ]; then
  UDPCUSTOM_GOMAXPROCS=$((NCPU-1))
  UDPCUSTOM_CPU_RANGE="0-$((NCPU-2))"
else
  UDPCUSTOM_GOMAXPROCS=$NCPU
  UDPCUSTOM_CPU_RANGE=""
fi

NAT_MODE=0
if command -v iptables >/dev/null 2>&1; then
  iptables -t nat -S 2>/dev/null | grep -qi masquerade && NAT_MODE=1
fi

# ===== IPv4 only: ไม่มี DNS v6 อีกต่อไป =====
DNS_LABEL="Cloudflare+Google (IPv4 only)"
DNS_V4_A="1.1.1.1"; DNS_V4_B="8.8.8.8"

echo "SPEC: RAM=${TOTAL_RAM_MB}MB vCPU=${NCPU} | IFACE=${IFACE} | MTU=${TUNNEL_MTU} | Pipeline Down/Up=${DOWNLOAD_SHAPE_MBIT}/${UPLOAD_SHAPE_MBIT} Mbps | Per-User=${PER_USER_DOWN_MBIT}/${PER_USER_UP_MBIT} Mbps | IPv4-only | MSS=${TCP_MSS_V4}"

if grep -qm1 aes /proc/cpuinfo 2>/dev/null; then
  echo -e "${GREEN}AES-NI: พร้อมใช้งาน${NC}"
else
  echo -e "${YELLOW}AES-NI: ไม่พบ flag ใน /proc/cpuinfo${NC}"
fi

UDP_CUSTOM_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CUSTOM_CONFIG" || true)
if [ -z "$UDP_CUSTOM_PORT" ]; then
  read -rp "ใส่พอร์ต UDP ที่ udp-custom ใช้จริง: " UDP_CUSTOM_PORT
fi

cat > /etc/tunnel-qos.conf << EOF
IFACE=${IFACE}
DOWNLOAD_SHAPE_MBIT=${DOWNLOAD_SHAPE_MBIT}
UPLOAD_SHAPE_MBIT=${UPLOAD_SHAPE_MBIT}
PER_USER_DOWN_MBIT=${PER_USER_DOWN_MBIT}
PER_USER_UP_MBIT=${PER_USER_UP_MBIT}
PER_USER_GUAR_MBIT=${PER_USER_GUAR_MBIT}
HASH_DIVISOR=${HASH_DIVISOR}
RTT_MS=${RTT_MS}
TUNNEL_MTU=${TUNNEL_MTU}
CAKE_OVERHEAD=${CAKE_OVERHEAD}
DNS_LABEL=${DNS_LABEL}
DNS_V4_A=${DNS_V4_A}
DNS_V4_B=${DNS_V4_B}
UDP_CUSTOM_PORT=${UDP_CUSTOM_PORT}
UDPGW_PORT=${UDPGW_PORT}
NCPU=${NCPU}
APP_CPU=${APP_CPU}
TXQUEUELEN=${TXQUEUELEN}
NAT_MODE=${NAT_MODE}
HEALTHCHECK_FAIL_STREAK_LIMIT=${HEALTHCHECK_FAIL_STREAK_LIMIT}
EOF

apt-get update -qq
apt-get install -y ufw iptables conntrack ethtool iproute2 jq irqbalance rsyslog cmake build-essential git netcat-openbsd linux-modules-extra-$(uname -r) > /dev/null 2>&1 || true

modprobe sch_htb 2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true
modprobe cls_flow 2>/dev/null || true
modprobe cls_u32 2>/dev/null || true
modprobe act_mirred 2>/dev/null || true
modprobe ifb numifbs=1 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tunnel.conf

if [ "$APP_CPU" -ge 0 ]; then
  mkdir -p /etc/default
  if [ -f /etc/default/irqbalance ]; then
    sed -i '/^IRQBALANCE_BANNED_CPULIST=/d' /etc/default/irqbalance
  fi
  echo "IRQBALANCE_BANNED_CPULIST=${APP_CPU}" >> /etc/default/irqbalance
fi
systemctl enable --now irqbalance > /dev/null 2>&1 || true
systemctl restart irqbalance > /dev/null 2>&1 || true

ZRAM_ACTIVE=0
swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram' && ZRAM_ACTIVE=1

if ! swapon --show | grep -qv '^/dev/zram' 2>/dev/null; then
  AVAIL_KB=$(df --output=avail -k / | tail -1)
  NEED_KB=$(( SWAP_GB * 1024 * 1024 ))
  if [ "$AVAIL_KB" -gt "$((NEED_KB + 2097152))" ]; then
    fallocate -l "${SWAP_GB}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    if [ "$ZRAM_ACTIVE" -eq 1 ]; then
      swapon -p 0 /swapfile
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=0 0 0' >> /etc/fstab
    else
      swapon /swapfile
      grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi
fi

# ===== UFW: บังคับปิด IPv6 ในตัว ufw เอง =====
ufw --force reset > /dev/null
if grep -q '^IPV6=' /etc/default/ufw; then
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
else
  echo 'IPV6=no' >> /etc/default/ufw
fi
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw default deny routed > /dev/null
for p in 23 111 135 137 138 139 445 3389 6379 11211; do
  ufw deny "${p}/tcp" > /dev/null
done
for p in 111 137 138 3389 11211; do
  ufw deny "${p}/udp" > /dev/null
done
ufw allow 1:65535/tcp > /dev/null
ufw allow 1:65535/udp > /dev/null
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

# เหลือแค่แก้ไอพี DNS ฝั่ง IPv4 เท่านั้น (ไม่มี IPv6 ให้แก้แล้ว)
sed -i \
  -e 's/1\.0\.0\.1/8.8.8.8/g' \
  -e 's/8\.8\.4\.4/1.1.1.1/g' \
  /etc/netplan/*.yaml 2>/dev/null || true

mkdir -p /etc/systemd/resolved.conf.d
rm -rf /etc/systemd/resolved.conf.d/* 2>/dev/null
cat > /etc/systemd/resolved.conf << EOF
[Resolve]
DNS=${DNS_V4_A} ${DNS_V4_B}
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
Q=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/ {print $2; exit}')
if [ -n "$Q" ] && [ "$Q" -gt 1 ] 2>/dev/null && [ "$Q" != "$NCPU" ]; then
  ethtool -L "$IFACE" combined "$NCPU" 2>/dev/null || true
fi
ethtool -K "$IFACE" gro on gso on tso on 2>/dev/null || true
RUNTIME
chmod +x /usr/local/sbin/set-multiqueue.sh

cat > /etc/systemd/system/set-multiqueue.service << 'EOF'
[Unit]
Description=Restore NIC multi-queue combined count across all vCPU after reboot
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

# ===== MSS clamp: IPv4 เท่านั้น ไม่มี ip6tables อีกต่อไป =====
cat > /usr/local/sbin/mss-clamp.sh << EOF
#!/bin/bash
MSS_V4=${TCP_MSS_V4}
apply() {
  local table="\$1" chain="\$2"; shift 2
  iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null || iptables -t "\$table" -A "\$chain" "\$@"
}
apply mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V4"
apply mangle OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V4"

# กันหลุด: ลบกฎ ip6tables MSS เดิม (ถ้ามีจากรันครั้งก่อน) เพราะปิด IPv6 ทั้งระบบแล้ว
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -t mangle -F FORWARD 2>/dev/null || true
  ip6tables -t mangle -F OUTPUT 2>/dev/null || true
fi
EOF
chmod +x /usr/local/sbin/mss-clamp.sh
/usr/local/sbin/mss-clamp.sh

cat > /etc/systemd/system/mss-clamp.service << EOF
[Unit]
Description=Clamp TCP MSS to fixed value (${TCP_MSS_V4}, IPv4 only)
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

UDP_MEM_MIN_PAGES=$(( UDP_KERNEL_MEM_MIN_MB * 1024 * 1024 / 4096 ))
UDP_MEM_PRESSURE_PAGES=$(( UDP_KERNEL_MEM_PRESSURE_MB * 1024 * 1024 / 4096 ))
UDP_MEM_MAX_PAGES=$(( UDP_KERNEL_MEM_MAX_MB * 1024 * 1024 / 4096 ))

cat > /etc/sysctl.d/99-tunnel-optimize.conf << EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_codel
net.ipv4.ip_forward = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 4096
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 45
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_retries2 = ${TCP_RETRIES2}
net.ipv4.tcp_syn_retries = ${TCP_SYN_RETRIES}
net.core.rmem_max = ${TCP_RMEM_MAX}
net.core.wmem_max = ${TCP_WMEM_MAX}
net.core.rmem_default = ${TCP_RMEM_DEFAULT}
net.core.wmem_default = ${TCP_WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${TCP_RMEM_DEFAULT} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_WMEM_DEFAULT} ${TCP_WMEM_MAX}
net.ipv4.udp_mem = ${UDP_MEM_MIN_PAGES} ${UDP_MEM_PRESSURE_PAGES} ${UDP_MEM_MAX_PAGES}
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN}
net.core.netdev_max_backlog = ${NETDEV_MAX_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}
net.core.rps_sock_flow_entries = ${RPS_SOCK_FLOW_ENTRIES}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}
net.netfilter.nf_conntrack_udp_timeout = ${NF_CONNTRACK_UDP_TIMEOUT}
net.netfilter.nf_conntrack_udp_timeout_stream = ${NF_CONNTRACK_UDP_TIMEOUT_STREAM}
net.netfilter.nf_conntrack_tcp_timeout_established = ${NF_CONNTRACK_TCP_TIMEOUT_ESTABLISHED}
fs.file-max = 1048576
vm.swappiness = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = ${VM_MIN_FREE_KB}
vm.overcommit_memory = 1
# ===== ปิด IPv6 ทั้งระบบ (ทันที ไม่ต้องรีบูต) =====
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
echo "options nf_conntrack hashsize=${NF_CONNTRACK_HASHSIZE}" > /etc/modprobe.d/nf_conntrack.conf
echo "$NF_CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true

if [ -f /etc/sysctl.conf ]; then
  cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)"
  for key in net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.ip_forward \
             net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
             net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.udp_mem net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min \
             net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs net.core.somaxconn \
             net.ipv4.tcp_max_syn_backlog net.core.rps_sock_flow_entries net.ipv4.tcp_frto \
             net.ipv4.tcp_ecn net.ipv4.tcp_syncookies net.ipv4.tcp_keepalive_time \
             net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes net.ipv4.tcp_retries2 net.ipv4.tcp_syn_retries \
             vm.dirty_ratio vm.dirty_background_ratio vm.min_free_kbytes vm.overcommit_memory \
             net.netfilter.nf_conntrack_max net.netfilter.nf_conntrack_udp_timeout \
             net.netfilter.nf_conntrack_udp_timeout_stream net.netfilter.nf_conntrack_tcp_timeout_established \
             fs.file-max vm.swappiness net.ipv4.tcp_notsent_lowat net.ipv4.tcp_autocorking \
             net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
    esc_key=$(printf '%s' "$key" | sed 's/\./\\./g')
    sed -i -E "/^[[:space:]]*${esc_key}[[:space:]]*=/d" /etc/sysctl.conf
  done
fi

sysctl --system > /dev/null 2>&1 || true

# ===== ปิด IPv6 ระดับ kernel/bootloader ให้ถาวร (มีผลเต็มที่หลังรีบูต) =====
if [ -f /etc/default/grub ]; then
  cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
  if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
      sed -i -E 's/^GRUB_CMDLINE_LINUX="(.*)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
    fi
  else
    echo 'GRUB_CMDLINE_LINUX="ipv6.disable=1"' >> /etc/default/grub
  fi
  (update-grub > /dev/null 2>&1 || grub2-mkconfig -o /boot/grub2/grub.cfg > /dev/null 2>&1) || true
fi

cat > /usr/local/sbin/set-thp-madvise.sh << 'RUNTIME'
#!/bin/bash
[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
[ -f /sys/kernel/mm/transparent_hugepage/defrag ]  && echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
RUNTIME
chmod +x /usr/local/sbin/set-thp-madvise.sh

cat > /etc/systemd/system/set-thp-madvise.service << 'EOF'
[Unit]
Description=Keep THP in madvise mode
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

# ===== สคริปต์ qos-root-init.sh ที่แก้ไขสมบูรณ์แล้ว =====
cat > /usr/local/sbin/qos-root-init.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true

IFACE="${IFACE:-eth0}"
DOWNLOAD_SHAPE_MBIT="${DOWNLOAD_SHAPE_MBIT:-300}"
UPLOAD_SHAPE_MBIT="${UPLOAD_SHAPE_MBIT:-300}"
PER_USER_DOWN_MBIT="${PER_USER_DOWN_MBIT:-20}"
PER_USER_UP_MBIT="${PER_USER_UP_MBIT:-20}"
PER_USER_GUAR_MBIT="${PER_USER_GUAR_MBIT:-2}"
HASH_DIVISOR="${HASH_DIVISOR:-1024}"
TXQUEUELEN="${TXQUEUELEN:-10000}"

# โหลด modules ที่จำเป็น
modprobe sch_htb 2>/dev/null || true
modprobe sch_fq_codel 2>/dev/null || true
modprobe cls_flow 2>/dev/null || true
modprobe cls_u32 2>/dev/null || true
modprobe act_mirred 2>/dev/null || true
modprobe ifb numifbs=1 2>/dev/null || true

# ตั้งค่า txqueuelen
ip link set dev "$IFACE" txqueuelen "$TXQUEUELEN" 2>/dev/null || true

# ล้าง Qdisc เก่า
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

DIV=$HASH_DIVISOR
GUAR=$PER_USER_GUAR_MBIT
BASE=16
BASE_HEX=$(printf '%x' $BASE)

# 1. Download Traffic Shaping (eth0)
tc qdisc add dev "$IFACE" root handle 1: htb default 1 2>/dev/null || true
tc class add dev "$IFACE" parent 1: classid 1:1 htb rate "${DOWNLOAD_SHAPE_MBIT}mbit" ceil "${DOWNLOAD_SHAPE_MBIT}mbit" 2>/dev/null || true

for i in $(seq 0 $((DIV-1))); do
  MINOR=$(printf '%x' $((BASE+i)))
  HANDLE=$(printf '%x' $((0x2000+i)))
  tc class add dev "$IFACE" parent 1:1 classid 1:"$MINOR" htb rate "${GUAR}mbit" ceil "${PER_USER_DOWN_MBIT}mbit" quantum 1514 prio 1 2>/dev/null || true
  tc qdisc add dev "$IFACE" parent 1:"$MINOR" handle "$HANDLE": fq_codel target 3ms interval 40ms ecn 2>/dev/null || true
done
tc filter add dev "$IFACE" parent 1: protocol ip prio 1 handle 1 flow hash keys dst divisor "$DIV" baseclass 1:"$BASE_HEX" 2>/dev/null || true

# 2. Upload Traffic Shaping (ifb0)
if ip link show ifb0 >/dev/null 2>&1; then
  ip link set dev ifb0 up 2>/dev/null || true
  ip link set dev ifb0 txqueuelen "$TXQUEUELEN" 2>/dev/null || true

  tc qdisc add dev "$IFACE" handle ffff: ingress 2>/dev/null || true
  tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true

  tc qdisc add dev ifb0 root handle 1: htb default 1 2>/dev/null || true
  tc class add dev ifb0 parent 1: classid 1:1 htb rate "${UPLOAD_SHAPE_MBIT}mbit" ceil "${UPLOAD_SHAPE_MBIT}mbit" 2>/dev/null || true

  for i in $(seq 0 $((DIV-1))); do
    MINOR=$(printf '%x' $((BASE+i)))
    HANDLE=$(printf '%x' $((0x3000+i)))
    tc class add dev ifb0 parent 1:1 classid 1:"$MINOR" htb rate "${GUAR}mbit" ceil "${PER_USER_UP_MBIT}mbit" quantum 1514 prio 1 2>/dev/null || true
    tc qdisc add dev ifb0 parent 1:"$MINOR" handle "$HANDLE": fq_codel target 3ms interval 40ms ecn 2>/dev/null || true
  done
  tc filter add dev ifb0 parent 1: protocol ip prio 1 handle 1 flow hash keys src divisor "$DIV" baseclass 1:"$BASE_HEX" 2>/dev/null || true
fi

exit 0
RUNTIME
chmod +x /usr/local/sbin/qos-root-init.sh

cat > /etc/systemd/system/tunnel-shaper.service << 'EOF'
[Unit]
Description=Low-latency Per-User Rate Limiter QoS (HTB + FQ_CoDel)
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
FULL_MASK=$(( (1 << NCPU) - 1 ))
if [ -n "$APP_CPU" ] && [ "$APP_CPU" -ge 0 ] 2>/dev/null; then
  RPS_MASK_DEC=$(( FULL_MASK & ~(1 << APP_CPU) ))
  [ "$RPS_MASK_DEC" -eq 0 ] && RPS_MASK_DEC=$FULL_MASK
else
  RPS_MASK_DEC=$FULL_MASK
fi
MASK=$(printf '%x' "$RPS_MASK_DEC")
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
Description=Spread RX+TX packet steering across CPU cores reserved for networking
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
STATE_FILE=/run/tunnel-selfheal.state
FAILS=0
[ -f "$STATE_FILE" ] && FAILS=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

CUR_MTU=$(cat /sys/class/net/"${IFACE}"/mtu 2>/dev/null || echo 0)
[ "$CUR_MTU" != "$TUNNEL_MTU" ] && ip link set dev "${IFACE}" mtu "$TUNNEL_MTU" 2>/dev/null || true

QDISC_OK=1
tc qdisc show dev "${IFACE}" 2>/dev/null | grep -q "qdisc htb" || QDISC_OK=0
tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb" || QDISC_OK=0
[ "$QDISC_OK" -eq 0 ] && /usr/local/sbin/qos-root-init.sh >/dev/null 2>&1

/usr/local/sbin/set-multiqueue.sh >/dev/null 2>&1
/usr/local/sbin/set-rps.sh >/dev/null 2>&1

UDP_CUSTOM_OK=1
UDPGW_OK=1
systemctl is-active --quiet udp-custom 2>/dev/null || UDP_CUSTOM_OK=0
systemctl is-active --quiet udpgw 2>/dev/null || UDPGW_OK=0

if [ -n "$UDPGW_PORT" ] && command -v nc >/dev/null 2>&1; then
  timeout 1 nc -u -z 127.0.0.1 "$UDPGW_PORT" >/dev/null 2>&1 || UDPGW_OK=0
fi

if [ "$UDP_CUSTOM_OK" -eq 0 ] || [ "$UDPGW_OK" -eq 0 ]; then
  FAILS=$((FAILS+1))
else
  FAILS=0
fi
echo "$FAILS" > "$STATE_FILE"

[ "$UDP_CUSTOM_OK" -eq 0 ] && systemctl restart udp-custom >/dev/null 2>&1 || true
[ "$UDPGW_OK" -eq 0 ] && systemctl restart udpgw >/dev/null 2>&1 || true

if [ "$FAILS" -ge "${HEALTHCHECK_FAIL_STREAK_LIMIT:-3}" ]; then
  systemctl restart tunnel-shaper.service >/dev/null 2>&1 || true
  systemctl restart set-rps.service >/dev/null 2>&1 || true
  echo 0 > "$STATE_FILE"
fi
RUNTIME
chmod +x /usr/local/sbin/tunnel-selfheal.sh

cat > /etc/systemd/system/tunnel-selfheal.service << 'EOF'
[Unit]
Description=Detect and repair tunnel network config drift and restart dead tunnel services
After=tunnel-shaper.service set-rps.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tunnel-selfheal.sh
EOF

cat > /etc/systemd/system/tunnel-selfheal.timer << EOF
[Unit]
Description=Run tunnel-selfheal every ${SELFHEAL_INTERVAL_SEC} seconds

[Timer]
OnBootSec=${SELFHEAL_INTERVAL_SEC}s
OnUnitActiveSec=${SELFHEAL_INTERVAL_SEC}s
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

  UDPCUSTOM_CPU_DIRECTIVE=""
  if [ -n "$UDPCUSTOM_CPU_RANGE" ]; then
    UDPCUSTOM_CPU_DIRECTIVE="CPUAffinity=${UDPCUSTOM_CPU_RANGE}"
  fi

  mkdir -p "${UDP_CUSTOM_SERVICE}.d"
  cat > "${UDP_CUSTOM_SERVICE}.d/99-tuning.conf" << EOF
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
Environment=GOMAXPROCS=${UDPCUSTOM_GOMAXPROCS}
Environment=GOGC=400
Environment=GOMEMLIMIT=${UDP_CUSTOM_MEM_HIGH_MB}MiB
${UDPCUSTOM_CPU_DIRECTIVE}
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2
OOMScoreAdjust=-500
LimitNOFILE=1048576
MemoryHigh=${UDP_CUSTOM_MEM_HIGH_MB}M
MemoryMax=${UDP_CUSTOM_MEM_MAX_MB}M
CPUWeight=600
Restart=always
RestartSec=1
ExecStartPost=/bin/bash -c 'sleep 3; sysctl -p /etc/sysctl.d/99-tunnel-optimize.conf >/dev/null 2>&1; /usr/local/sbin/set-rps.sh >/dev/null 2>&1'
EOF
  systemctl daemon-reload
fi

if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
  rm -rf /usr/local/src/badvpn
  git clone --depth 1 https://github.com/ambrop72/badvpn.git /usr/local/src/badvpn > /dev/null 2>&1 || true
  if [ -d /usr/local/src/badvpn ]; then
    mkdir -p /usr/local/src/badvpn/badvpn-build
    cd /usr/local/src/badvpn/badvpn-build
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1 || true
    make -j4 > /dev/null 2>&1 || true
    [ -f udpgw/badvpn-udpgw ] && cp udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw || true
    cd /
  fi
fi

UDPGW_CPU_DIRECTIVES=""
if [ "$APP_CPU" -ge 0 ]; then
  UDPGW_CPU_DIRECTIVES="CPUAffinity=${APP_CPU}
CPUSchedulingPolicy=rr
CPUSchedulingPriority=${UDPGW_RT_PRIORITY}"
fi

cat > /etc/systemd/system/udpgw.service << EOF
[Unit]
Description=BadVPN UDPGW
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=20

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients ${UDPGW_MAX_CLIENTS} --max-connections-for-client ${UDPGW_MAX_CONN_PER_CLIENT}
Restart=always
RestartSec=1
LimitNOFILE=51200
${UDPGW_CPU_DIRECTIVES}
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
systemctl restart set-rps.service

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
Description=Run daily-cache-log-clear every day at ${DAILY_CLEAR_TIME} ${CLEAR_TIMEZONE}

[Timer]
OnCalendar=*-*-* ${DAILY_CLEAR_TIME} ${CLEAR_TIMEZONE}
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
echo -e "${GREEN}ปรับแต่งระบบสำเร็จ | Tunnel Pipeline: ${DOWNLOAD_SHAPE_MBIT}Mbit↓ / ${UPLOAD_SHAPE_MBIT}Mbit↑ | Per-User: ${PER_USER_DOWN_MBIT}Mbit↓ / ${PER_USER_UP_MBIT}Mbit↑ | MSS(v4)=${TCP_MSS_V4} | IPv6=DISABLED (sysctl+ufw+grub)${NC}"
echo -e "${YELLOW}หมายเหตุ: ปิด IPv6 ผ่าน sysctl มีผลทันที ส่วนพารามิเตอร์ kernel (ipv6.disable=1 ใน GRUB) จะสมบูรณ์ 100% หลัง reboot เครื่องหนึ่งครั้ง${NC}"
echo "=================================================="
