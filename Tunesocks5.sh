#!/bin/bash
set -uo pipefail
[ "$EUID" -ne 0 ] && { echo "ต้องรันด้วย root: sudo bash $0"; exit 1; }

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; NC='\033[0m'
ok(){ echo -e "${G}  ✓ $1${NC}"; }
warn(){ echo -e "${Y}  ! $1${NC}"; }
bad(){ echo -e "${R}  ✗ $1${NC}"; }
step(){ echo -e "\n${C}== $1 ==${NC}"; }

CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

UDP_DIR="/root/udp"
UDP_CFG="${UDP_DIR}/config.json"
SSHMGR_DB="/etc/ssh-manager/db"
SOCKS5_PORT_FILE="/etc/ssh-manager/socks5-port"
SOCKS5_CONF="/etc/danted.conf"

step "1/10 — อ่านสเปคเครื่องจริง + คำนวณความจุ (capacity calculator)"
TOTAL_RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
NCPU=$(nproc)
IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
[ -z "$IFACE" ] && IFACE=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}')
if [ -z "$IFACE" ]; then bad "หา default network interface ไม่เจอ ยกเลิก"; exit 1; fi

CAPACITY_PER_VCPU="${CAPACITY_PER_VCPU:-25}"
MAX_CAPACITY_USERS=$(( NCPU * CAPACITY_PER_VCPU ))

CURRENT_USERS=0
if [ -f "$SSHMGR_DB" ]; then
    CURRENT_USERS=$(wc -l < "$SSHMGR_DB" 2>/dev/null)
elif [ -d "$SSHMGR_DB" ]; then
    CURRENT_USERS=$(find "$SSHMGR_DB" -maxdepth 1 -type f 2>/dev/null | wc -l)
fi
CURRENT_USERS=$(printf '%s' "$CURRENT_USERS" | tr -cd '0-9')
[ -z "$CURRENT_USERS" ] && CURRENT_USERS=0

PIPE_BYTES=39375000
if [ -f "$UDP_CFG" ] && command -v jq >/dev/null 2>&1; then
    JSON_BUF=$(jq -r '.stream_buffer // empty' "$UDP_CFG" 2>/dev/null)
    [ -n "$JSON_BUF" ] && [ "$JSON_BUF" -gt 0 ] 2>/dev/null && PIPE_BYTES="$JSON_BUF"
fi
PIPE_MBIT=$(( PIPE_BYTES * 8 / 1000000 ))
DOWNLOAD_SHAPE_MBIT=$PIPE_MBIT
UPLOAD_SHAPE_MBIT=$PIPE_MBIT
RTT_MS="${RTT_MS:-65}"
TUNNEL_MTU="${TUNNEL_MTU:-1500}"
TCP_MSS_V4="${TCP_MSS_V4:-1360}"
SWAP_GB="${SWAP_GB:-4}"
DNS_V4_A="${DNS_V4_A:-1.1.1.1}"
DNS_V4_B="${DNS_V4_B:-8.8.8.8}"

HASH_DIVISOR=256
if [ "$MAX_CAPACITY_USERS" -gt "$HASH_DIVISOR" ]; then
    warn "ความจุที่ออกแบบ (${MAX_CAPACITY_USERS} คน) มากกว่าจำนวน hash bucket สูงสุดที่ kernel รองรับ (256)"
    warn "ผู้ใช้จะยัง shaping ได้ปกติ แต่หลายคนอาจ hash ตกบักเก็ตเดียวกัน (แชร์ guarantee กัน) เมื่อคนเกิน 256"
fi

PER_USER_GUAR_KBIT=$(( PIPE_MBIT * 1000 / MAX_CAPACITY_USERS ))
[ "$PER_USER_GUAR_KBIT" -lt 256 ] && PER_USER_GUAR_KBIT=256
PER_USER_CEIL_MBIT="${PER_USER_CEIL_MBIT:-20}"

NF_CONNTRACK_MAX=$(( MAX_CAPACITY_USERS * 4000 ))
[ "$NF_CONNTRACK_MAX" -lt 131072 ] && NF_CONNTRACK_MAX=131072
[ "$NF_CONNTRACK_MAX" -gt 2000000 ] && NF_CONNTRACK_MAX=2000000
NF_CONNTRACK_HASHSIZE=$(( NF_CONNTRACK_MAX / 4 ))

RESERVE_LAST_CPU_FOR_PROXY="${RESERVE_LAST_CPU_FOR_PROXY:-1}"
APP_CPU=-1
if [ "$RESERVE_LAST_CPU_FOR_PROXY" -eq 1 ] && [ "$NCPU" -ge 3 ]; then APP_CPU=$((NCPU-1)); fi
PROXY_CPU_RANGE=""
[ "$NCPU" -ge 3 ] && PROXY_CPU_RANGE="0-$((NCPU-2))"

ok "RAM=${TOTAL_RAM_MB}MB  vCPU=${NCPU}  IFACE=${IFACE}"
ok "ความจุออกแบบไว้ = ${NCPU} vCPU x ${CAPACITY_PER_VCPU} คน/vCPU = ${MAX_CAPACITY_USERS} คนสูงสุด  (ผู้ใช้จริงตอนนี้ใน smng: ${CURRENT_USERS} คน)"
[ "$CURRENT_USERS" -gt "$MAX_CAPACITY_USERS" ] && bad "ผู้ใช้จริง (${CURRENT_USERS}) เกินความจุที่สเปครองรับ (${MAX_CAPACITY_USERS}) แล้ว! ควรอัพ vCPU หรือลดผู้ใช้"
ok "Pool แบนด์วิดท์ = ${DOWNLOAD_SHAPE_MBIT}Mbit (คงค่าเดิม ไม่ผูกกับสเปคเครื่อง) | guarantee/user = ${PER_USER_GUAR_KBIT}kbit | ceil/user = ${PER_USER_CEIL_MBIT}mbit"
ok "conntrack = ${NF_CONNTRACK_MAX} (ผูกกับความจุออกแบบ ${MAX_CAPACITY_USERS} คน x 4000)"

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo -e "\n${Y}--check-only: ข้ามไปตรวจสุขภาพระบบทันที (ไม่แก้ไขอะไร)${NC}"
fi

step "2/10 — ติดตั้งแพ็กเกจ/kernel module ที่จำเป็น"
if [ "$CHECK_ONLY" -eq 0 ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y iptables conntrack ethtool iproute2 jq irqbalance rsyslog \
        netcat-openbsd nftables dropbear dante-server curl coreutils zip unzip \
        "linux-modules-extra-$(uname -r)" > /dev/null 2>&1 || true

    for m in sch_fq_codel sch_htb cls_u32 act_mirred ifb tcp_bbr; do
        modprobe "$m" 2>/dev/null || true
    done
    echo "tcp_bbr" > /etc/modules-load.d/tunnel.conf
    echo "ifb numifbs=1" > /etc/modules-load.d/ifb.conf
    ok "แพ็กเกจ/module พร้อมใช้งาน"
else
    ok "(ข้าม — check-only)"
fi

step "3/10 — [FIX-2] เคลียร์ ufw กับ nftables ที่ชนกัน (สาเหตุ 'หลุดสุ่ม' หลักที่สุด)"
UFW_ACTIVE=0
systemctl is-active ufw >/dev/null 2>&1 && UFW_ACTIVE=1
systemctl is-enabled ufw >/dev/null 2>&1 && UFW_ACTIVE=1

if [ "$UFW_ACTIVE" -eq 1 ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
        bad "ufw ยังทำงานอยู่คู่กับ nftables -> เสี่ยงพอร์ตหลุดสุ่มตอน nftables restart (flush ruleset ล้าง ufw ด้วย)"
    else
        warn "เจอ ufw ทำงานอยู่คู่กับ nftables -> จะปิด ufw เหลือ nftables ตัวเดียว"
        DROPBEAR_PORT=$(grep -oP 'DROPBEAR_PORT=\K[0-9]+' /etc/default/dropbear 2>/dev/null); [ -z "$DROPBEAR_PORT" ] && DROPBEAR_PORT=2345
        SOCKS5_PORT=$(cat "$SOCKS5_PORT_FILE" 2>/dev/null); [ -z "$SOCKS5_PORT" ] && SOCKS5_PORT=1080
        UDP_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CFG" 2>/dev/null); [ -z "$UDP_PORT" ] && UDP_PORT=36712

        [ -f /etc/nftables.conf ] || cat > /etc/nftables.conf << 'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    set blocked_tcp { type inet_service; flags interval; }
    set blocked_udp { type inet_service; flags interval; }
    chain input {
        type filter hook input priority 0; policy accept;
        ct state established,related accept
        iif "lo" accept
        tcp dport @blocked_tcp drop
        udp dport @blocked_udp drop
    }
    chain forward { type filter hook forward priority 0; policy accept; }
    chain output  { type filter hook output priority 0; policy accept; }
}
NFTEOF
        cp /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%s)"
        SAFE=1
        if ! grep -q 'tunnel-stack-master-safety' /etc/nftables.conf; then
            TMP_NFT=$(mktemp)
            cp /etc/nftables.conf "$TMP_NFT"
            sed -i "/chain input {/a\\        tcp dport { ${DROPBEAR_PORT}, ${SOCKS5_PORT} } accept comment \"tunnel-stack-master-safety\"\\n        udp dport ${UDP_PORT} accept comment \"tunnel-stack-master-safety\"" "$TMP_NFT"
            if nft -c -f "$TMP_NFT" >/dev/null 2>&1; then
                cp "$TMP_NFT" /etc/nftables.conf
            else
                bad "nftables.conf ใหม่ syntax ผิด -> จะไม่ปิด ufw รอบนี้ กันล็อกตัวเองออก"
                SAFE=0
            fi
            rm -f "$TMP_NFT"
        fi
        if [ "$SAFE" -eq 1 ] && nft -c -f /etc/nftables.conf >/dev/null 2>&1 && nft -f /etc/nftables.conf 2>/dev/null && systemctl restart nftables 2>/dev/null; then
            systemctl enable nftables >/dev/null 2>&1
            ufw --force disable >/dev/null 2>&1 || true
            systemctl disable --now ufw >/dev/null 2>&1 || true
            ok "ปิด ufw แล้ว — ยืนยันแล้วว่าพอร์ต dropbear(${DROPBEAR_PORT})/socks5(${SOCKS5_PORT})/udp-custom(${UDP_PORT}) ยัง accept อยู่ใน nftables"
        else
            bad "โหลด nftables.conf ไม่ผ่าน -> ไม่ปิด ufw รอบนี้ ตรวจมือ: nft -c -f /etc/nftables.conf"
        fi
    fi
else
    ok "ไม่มี ufw ทำงานอยู่แล้ว — nftables เป็นไฟร์วอลล์เดียว (ถูกต้องแล้ว)"
fi

step "4/10 — MTU / DNS / netplan cleanup"
if [ "$CHECK_ONLY" -eq 0 ]; then
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
    systemctl restart systemd-resolved 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now set-mtu.service >/dev/null 2>&1
    ok "MTU=${TUNNEL_MTU} ตั้งค่าถาวรผ่าน systemd + DNS=${DNS_V4_A},${DNS_V4_B}"
else
    ok "(ข้าม — check-only)"
fi

step "5/10 — [FIX-3] รวม sysctl เป็นไฟล์เดียว (ลบไฟล์เก่าที่ชนกันทิ้ง)"
if [ "$CHECK_ONLY" -eq 0 ]; then
    rm -f /etc/sysctl.d/99-smng-proxy.conf /etc/sysctl.d/99-tunnel-optimize.conf /etc/sysctl.d/99-tunnel-stability.conf

    BDP_BYTES=$(( PIPE_BYTES * RTT_MS / 1000 ))
    TCP_RMEM_MAX=$(( BDP_BYTES * 2 ))
    TCP_WMEM_MAX=$(( BDP_BYTES * 2 ))
    RAM_BYTES=$(( TOTAL_RAM_MB * 1024 * 1024 ))
    UDP_MEM_MAX_BYTES=$(( RAM_BYTES * 5 / 100 ))
    UDP_MEM_PRESSURE_BYTES=$(( UDP_MEM_MAX_BYTES * 3 / 4 ))
    UDP_MEM_MIN_BYTES=$(( UDP_MEM_MAX_BYTES / 8 ))
    UDP_MEM_MIN_PAGES=$(( UDP_MEM_MIN_BYTES / 4096 ))
    UDP_MEM_PRESSURE_PAGES=$(( UDP_MEM_PRESSURE_BYTES / 4096 ))
    UDP_MEM_MAX_PAGES=$(( UDP_MEM_MAX_BYTES / 4096 ))
    VM_MIN_FREE_KB=$(( TOTAL_RAM_MB * 1024 * 2 / 100 ))

    cat > /etc/sysctl.d/99-tunnel-final.conf << EOF
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
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_fin_timeout = 12
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = ${TCP_RMEM_MAX}
net.core.wmem_max = ${TCP_WMEM_MAX}
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.ipv4.tcp_rmem = 4096 131072 ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 131072 ${TCP_WMEM_MAX}
net.ipv4.udp_mem = ${UDP_MEM_MIN_PAGES} ${UDP_MEM_PRESSURE_PAGES} ${UDP_MEM_MAX_PAGES}
net.ipv4.udp_rmem_min = 262144
net.ipv4.udp_wmem_min = 262144
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 1000
net.core.netdev_budget_usecs = 3000
net.core.rps_sock_flow_entries = 65536
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}
net.netfilter.nf_conntrack_udp_timeout = 10
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
fs.file-max = 2097152
vm.swappiness = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = ${VM_MIN_FREE_KB}
vm.overcommit_memory = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    echo "options nf_conntrack hashsize=${NF_CONNTRACK_HASHSIZE}" > /etc/modprobe.d/nf_conntrack.conf
    echo "$NF_CONNTRACK_HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    sysctl --system >/dev/null 2>&1

    if [ -f /etc/default/grub ] && ! grep -q 'ipv6.disable=1' /etc/default/grub; then
        cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
        if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
            sed -i -E 's/^GRUB_CMDLINE_LINUX="(.*)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX="ipv6.disable=1"' >> /etc/default/grub
        fi
        (update-grub >/dev/null 2>&1 || grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1) || true
        warn "แก้ GRUB (ipv6.disable=1) แล้ว — ต้อง reboot 1 ครั้งถึงจะสมบูรณ์ 100%"
    fi
    ok "sysctl ไฟล์เดียว: conntrack=${NF_CONNTRACK_MAX}, rmem/wmem_max=${TCP_RMEM_MAX}B (BDP=${BDP_BYTES}B), vm.min_free_kbytes=${VM_MIN_FREE_KB}KB"
else
    ok "(ข้าม — check-only)"
fi

step "6/10 — [FIX-1] HTB per-user shaping ด้วย divisor ที่ kernel รองรับจริง (256)"
if [ "$CHECK_ONLY" -eq 0 ]; then
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

    cat > /usr/local/sbin/mss-clamp.sh << EOF
#!/bin/bash
MSS_V4=${TCP_MSS_V4}
apply() {
  local table="\$1" chain="\$2"; shift 2
  iptables -t "\$table" -C "\$chain" "\$@" 2>/dev/null || iptables -t "\$table" -A "\$chain" "\$@"
}
apply mangle FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V4"
apply mangle OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "\$MSS_V4"
EOF
    chmod +x /usr/local/sbin/mss-clamp.sh
    cat > /etc/systemd/system/mss-clamp.service << EOF
[Unit]
Description=Clamp TCP MSS (${TCP_MSS_V4}, IPv4 only)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mss-clamp.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/sbin/qos-root-init.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true
IFACE="${IFACE:-eth0}"
DOWNLOAD_SHAPE_MBIT="${DOWNLOAD_SHAPE_MBIT:-315}"
UPLOAD_SHAPE_MBIT="${UPLOAD_SHAPE_MBIT:-315}"
TXQUEUELEN="${TXQUEUELEN:-10000}"
HASH_DIVISOR="${HASH_DIVISOR:-256}"
PER_USER_GUAR_KBIT="${PER_USER_GUAR_KBIT:-1000}"
PER_USER_CEIL_MBIT="${PER_USER_CEIL_MBIT:-20}"

modprobe sch_fq_codel 2>/dev/null || true
modprobe sch_htb 2>/dev/null || true
modprobe cls_u32 2>/dev/null || true
modprobe act_mirred 2>/dev/null || true
modprobe ifb numifbs=1 2>/dev/null || true

ip link set dev "$IFACE" txqueuelen "$TXQUEUELEN" 2>/dev/null || true
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

build_per_user_htb() {
  local dev="$1" total_mbit="$2" match_field="$3"
  local hk_off=16
  [ "$match_field" = "src" ] && hk_off=12
  local batch; batch=$(mktemp)
  {
    echo "qdisc add dev $dev root handle 1: htb default 2"
    echo "class add dev $dev parent 1: classid 1:1 htb rate ${total_mbit}mbit ceil ${total_mbit}mbit"
    echo "class add dev $dev parent 1:1 classid 1:2 htb rate 1mbit ceil ${total_mbit}mbit"
    echo "qdisc add dev $dev parent 1:2 handle 20: fq_codel limit 10240 flows 1024 target 4ms interval 100ms quantum 1514 ecn"
    echo "filter add dev $dev parent 1: protocol ip prio 1 handle 8: u32 divisor ${HASH_DIVISOR}"
    echo "filter add dev $dev parent 1: protocol ip prio 1 u32 match ip ${match_field} 0.0.0.0/0 hashkey mask 0x0000ffff at ${hk_off} link 8:"
    for ((i = 0; i < HASH_DIVISOR; i++)); do
      hexid=$(printf '%x' $((0x100 + i)))
      bkt=$(printf '%x' "$i")
      echo "class add dev $dev parent 1:1 classid 1:${hexid} htb rate ${PER_USER_GUAR_KBIT}kbit ceil ${PER_USER_CEIL_MBIT}mbit burst 15k cburst 30k"
      echo "qdisc add dev $dev parent 1:${hexid} handle ${hexid}0: fq_codel limit 1024 flows 128 target 4ms interval 100ms quantum 1514 ecn"
      echo "filter add dev $dev parent 1: protocol ip prio 1 u32 ht 8:${bkt}: match u32 0 0 classid 1:${hexid}"
    done
  } > "$batch"

  if ! tc -force -batch "$batch"; then
    echo "  ✗ tc batch มี error บางบรรทัดบน ${dev} — เช็ค: tc -force -batch ${batch}" >&2
    logger -t qos-root-init "tc batch มี error บางบรรทัดบน ${dev} — batch เก็บไว้ที่ ${batch}"
    return 1
  fi

  local linked; linked=$(tc filter show dev "$dev" 2>/dev/null | grep -c "ht 8:")
  if [ "$linked" -lt "$HASH_DIVISOR" ]; then
    echo "  ✗ per-user hash filter บน ${dev} ผูกได้แค่ ${linked}/${HASH_DIVISOR} bucket — shaping ไม่สมบูรณ์" >&2
    logger -t qos-root-init "${dev}: linked ${linked}/${HASH_DIVISOR} hash buckets — batch เก็บไว้ที่ ${batch}"
    return 1
  fi

  rm -f "$batch"
  return 0
}

DL_OK=1; UL_OK=1
build_per_user_htb "$IFACE" "$DOWNLOAD_SHAPE_MBIT" "dst" || DL_OK=0

if ip link show ifb0 >/dev/null 2>&1; then
  ip link set dev ifb0 up 2>/dev/null || true
  ip link set dev ifb0 txqueuelen "$TXQUEUELEN" 2>/dev/null || true
  tc qdisc add dev "$IFACE" handle ffff: ingress 2>/dev/null || true
  tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true
  build_per_user_htb ifb0 "$UPLOAD_SHAPE_MBIT" "src" || UL_OK=0
fi
[ "$DL_OK" -eq 1 ] && [ "$UL_OK" -eq 1 ] && exit 0
exit 1
RUNTIME
    chmod +x /usr/local/sbin/qos-root-init.sh

    cat > /etc/systemd/system/tunnel-shaper.service << 'EOF'
[Unit]
Description=Per-user hashed HTB shaping with fq_codel AQM
After=network-online.target set-multiqueue.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qos-root-init.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    cat > /usr/local/sbin/set-rps.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true
FULL_MASK=$(( (1 << NCPU) - 1 ))
if [ -n "${APP_CPU:-}" ] && [ "$APP_CPU" -ge 0 ] 2>/dev/null; then
  RPS_MASK_DEC=$(( FULL_MASK & ~(1 << APP_CPU) ))
  [ "$RPS_MASK_DEC" -eq 0 ] && RPS_MASK_DEC=$FULL_MASK
else
  RPS_MASK_DEC=$FULL_MASK
fi
MASK=$(printf '%x' "$RPS_MASK_DEC")
for path in /sys/class/net/"${IFACE}"/queues/rx-*/rps_cpus /sys/class/net/ifb0/queues/rx-*/rps_cpus; do
  [ -e "$path" ] && echo "$MASK" > "$path" 2>/dev/null || true
done
for path in /sys/class/net/"${IFACE}"/queues/rx-*/rps_flow_cnt /sys/class/net/ifb0/queues/rx-*/rps_flow_cnt; do
  [ -e "$path" ] && echo 4096 > "$path" 2>/dev/null || true
done
for path in /sys/class/net/"${IFACE}"/queues/tx-*/xps_cpus /sys/class/net/ifb0/queues/tx-*/xps_cpus; do
  [ -e "$path" ] && echo "$MASK" > "$path" 2>/dev/null || true
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
    systemctl enable --now set-mtu.service mss-clamp.service set-multiqueue.service >/dev/null 2>&1
    /usr/local/sbin/mss-clamp.sh
    ok "สร้างสคริปต์ HTB/RPS/MTU/MSS ครบ (ยังไม่รัน — จะรันตอนขั้นตอน 9 หลัง config เสร็จ)"
else
    ok "(ข้าม — check-only)"
fi

step "7/10 — ตรวจสอบ/ตั้งค่า dropbear + danted(SOCKS5 TCP/UDP) + udp-custom"
if [ "$CHECK_ONLY" -eq 0 ]; then
    if ! grep -q 'DROPBEAR_PORT=2345' /etc/default/dropbear 2>/dev/null; then
        cat > /etc/default/dropbear << 'EOF'
NO_START=0
DROPBEAR_PORT=2345
DROPBEAR_EXTRA_ARGS="-p 2345"
EOF
    fi
    mkdir -p /etc/systemd/system/dropbear.service.d
    cat > /etc/systemd/system/dropbear.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -R -F -p 2345
EOF
    DROPBEAR_PORT=2345

    SOCKS5_PORT=$(cat "$SOCKS5_PORT_FILE" 2>/dev/null); [ -z "$SOCKS5_PORT" ] && SOCKS5_PORT=1080
    if command -v danted >/dev/null 2>&1; then
        HOLDER=$(ss -lntup 2>/dev/null | awk -v p=":$SOCKS5_PORT" '$4 ~ p"$" {print $0}')
        if [ -n "$HOLDER" ] && ! echo "$HOLDER" | grep -q danted; then
            warn "พอร์ต ${SOCKS5_PORT} มีโปรแกรมอื่นถือครองอยู่ (ไม่ใช่ danted): ${HOLDER}"
        fi
        if [ ! -f "$SOCKS5_CONF" ] || ! grep -q 'command: connect udpassociate bind' "$SOCKS5_CONF"; then
            cat > "$SOCKS5_CONF" << EOF
logoutput: syslog
internal: 0.0.0.0 port = ${SOCKS5_PORT}
external: ${IFACE}
socksmethod: none
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    command: connect udpassociate bind
    log: connect disconnect error
}
EOF
            chmod 644 "$SOCKS5_CONF"
        fi
        mkdir -p /etc/systemd/system/danted.service.d
        rm -f /etc/systemd/system/danted.service.d/override.conf
        echo "$SOCKS5_PORT" > "$SOCKS5_PORT_FILE" 2>/dev/null
        ok "danted config พร้อม (protocol tcp+udp, udpassociate เปิดอยู่) พอร์ต ${SOCKS5_PORT}"
    else
        warn "ไม่พบ danted ติดตั้งอยู่ (ตรวจสอบว่า install-server.sh รันสำเร็จหรือยัง)"
    fi

    UDP_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CFG" 2>/dev/null); [ -z "$UDP_PORT" ] && UDP_PORT=36712
    if [ -x "${UDP_DIR}/udp-custom" ]; then
        if [ ! -f /etc/systemd/system/udp-custom.service ]; then
            cat > /etc/systemd/system/udp-custom.service << EOF
[Unit]
Description=UDP Custom (hev-socks5-tunnel compatible server)
[Service]
User=root
Type=simple
ExecStart=${UDP_DIR}/udp-custom server
WorkingDirectory=${UDP_DIR}/
Restart=always
RestartSec=2s
[Install]
WantedBy=default.target
EOF
        fi
        ok "udp-custom binary พบแล้วที่ ${UDP_DIR}/udp-custom (พอร์ต ${UDP_PORT})"
    else
        warn "ไม่พบ ${UDP_DIR}/udp-custom — ยังไม่เคยติดตั้งจาก smng/install-server.sh หรือรันจากคนละเครื่อง"
        warn "รัน: sudo bash install-server.sh (จาก smng.zip) ก่อน 1 ครั้ง แล้วค่อยรันไฟล์นี้ใหม่"
    fi

    if [ -f /etc/nftables.conf ] && ! grep -q 'tunnel-stack-master-ports' /etc/nftables.conf; then
        sed -i "/chain input {/a\\        tcp dport { ${DROPBEAR_PORT}, ${SOCKS5_PORT} } accept comment \"tunnel-stack-master-ports\"\\n        udp dport { ${SOCKS5_PORT}, ${UDP_PORT} } accept comment \"tunnel-stack-master-ports\"" /etc/nftables.conf
        nft -c -f /etc/nftables.conf >/dev/null 2>&1 && nft -f /etc/nftables.conf 2>/dev/null && systemctl restart nftables 2>/dev/null
    fi

    systemctl daemon-reload
    systemctl enable dropbear danted udp-custom >/dev/null 2>&1 || true
    ok "ตั้งค่า service หลักทั้ง 3 ตัวเสร็จ (ยังไม่ restart — restart รวมทีเดียวในขั้นตอน 9)"
else
    ok "(ข้าม — check-only)"
fi

step "8/10 — [FIX-4] รวม systemd hardening + watchdog เหลือชุดเดียว"
if [ "$CHECK_ONLY" -eq 0 ]; then
    ALL_SERVICES="dropbear danted udp-custom"

    for svc in $ALL_SERVICES; do
        systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || continue
        rm -f "/etc/systemd/system/${svc}.service.d/override.conf"
        mkdir -p "/etc/systemd/system/${svc}.service.d"
        PROXY_CPU_DIRECTIVE=""
        [ -n "$PROXY_CPU_RANGE" ] && PROXY_CPU_DIRECTIVE="CPUAffinity=${PROXY_CPU_RANGE}"
        cat > "/etc/systemd/system/${svc}.service.d/99-tuning.conf" << EOF
[Unit]
StartLimitIntervalSec=60
StartLimitBurst=20
[Service]
${PROXY_CPU_DIRECTIVE}
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2
OOMScoreAdjust=-500
LimitNOFILE=1048576
CPUWeight=600
Restart=always
RestartSec=1
ExecStartPost=/bin/bash -c 'sleep 3; sysctl -p /etc/sysctl.d/99-tunnel-final.conf >/dev/null 2>&1; /usr/local/sbin/set-rps.sh >/dev/null 2>&1'
EOF
    done
    systemctl daemon-reload
    ok "systemd hardening (Nice/OOM/CPUAffinity/Restart=always/LimitNOFILE) เหมือนกันทั้ง 3 service"

    if systemctl list-unit-files tunnel-watchdog.timer >/dev/null 2>&1; then
        systemctl disable --now tunnel-watchdog.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/tunnel-watchdog.{service,timer} /usr/local/bin/tunnel-watchdog.sh
        ok "ลบ tunnel-watchdog ตัวเก่าทิ้งแล้ว (รวมเข้า tunnel-selfheal ตัวเดียว)"
    fi

    SELFHEAL_INTERVAL_SEC="${SELFHEAL_INTERVAL_SEC:-10}"
    HEALTHCHECK_FAIL_STREAK_LIMIT="${HEALTHCHECK_FAIL_STREAK_LIMIT:-3}"
    cat > /usr/local/sbin/tunnel-selfheal.sh << 'RUNTIME'
#!/bin/bash
source /etc/tunnel-qos.conf 2>/dev/null || true
STATE_FILE=/run/tunnel-selfheal.state
FAILS=0
[ -f "$STATE_FILE" ] && FAILS=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

CUR_MTU=$(cat /sys/class/net/"${IFACE}"/mtu 2>/dev/null || echo 0)
[ "$CUR_MTU" != "$TUNNEL_MTU" ] && ip link set dev "${IFACE}" mtu "$TUNNEL_MTU" 2>/dev/null || true

QDISC_OK=1
tc qdisc show dev "${IFACE}" 2>/dev/null | grep -q "qdisc htb 1:" || QDISC_OK=0
tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb 1:" || QDISC_OK=0
LINKED_DL=$(tc filter show dev "${IFACE}" 2>/dev/null | grep -c "ht 8:")
LINKED_UL=$(tc filter show dev ifb0 2>/dev/null | grep -c "ht 8:")
[ "$LINKED_DL" -lt "${HASH_DIVISOR:-256}" ] && QDISC_OK=0
[ "$LINKED_UL" -lt "${HASH_DIVISOR:-256}" ] && QDISC_OK=0
if [ "$QDISC_OK" -eq 0 ]; then
    logger -t tunnel-selfheal "HTB per-user hash ไม่ครบ (dl=${LINKED_DL} ul=${LINKED_UL} ต้องการ ${HASH_DIVISOR:-256}) -> rebuild qos-root-init.sh"
    /usr/local/sbin/qos-root-init.sh >/dev/null 2>&1
fi

/usr/local/sbin/set-multiqueue.sh >/dev/null 2>&1
/usr/local/sbin/set-rps.sh >/dev/null 2>&1

PROXY_OK=1
check_port_real() {
    local svc="$1" port="$2"
    systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || return 0
    if ! ss -tuln 2>/dev/null | grep -q ":${port} "; then
        logger -t tunnel-selfheal "${svc} ไม่ฟังพอร์ต ${port} จริง (is-active อาจบอกว่า ok) -> restart"
        systemctl restart "${svc}" >/dev/null 2>&1 || true
        PROXY_OK=0
    fi
}
check_port_real dropbear "${DROPBEAR_PORT:-2345}"
check_port_real danted "${SOCKS5_PORT:-1080}"
check_port_real udp-custom "${UDP_PORT:-36712}"

if [ "$PROXY_OK" -eq 0 ]; then FAILS=$((FAILS+1)); else FAILS=0; fi
echo "$FAILS" > "$STATE_FILE"

if [ "$FAILS" -ge "${HEALTHCHECK_FAIL_STREAK_LIMIT:-3}" ]; then
  systemctl restart tunnel-shaper.service >/dev/null 2>&1 || true
  systemctl restart set-rps.service >/dev/null 2>&1 || true
  echo 0 > "$STATE_FILE"
fi
RUNTIME
    chmod +x /usr/local/sbin/tunnel-selfheal.sh

    cat > /etc/systemd/system/tunnel-selfheal.service << 'EOF'
[Unit]
Description=Detect and repair tunnel network config drift and restart dead proxy services (checks real listening ports)
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
    systemctl enable --now tunnel-selfheal.timer >/dev/null 2>&1
    ok "tunnel-selfheal ตัวเดียวคุมทุก service เช็คพอร์ตฟังจริงทุก ${SELFHEAL_INTERVAL_SEC} วิ (ไม่มี watchdog ตัวที่สองแย่งกันอีกแล้ว)"
else
    ok "(ข้าม — check-only)"
fi

step "9/10 — เขียน /etc/tunnel-qos.conf (single source of truth) + restart ทุก service"
if [ "$CHECK_ONLY" -eq 0 ]; then
    DROPBEAR_PORT=2345
    SOCKS5_PORT=$(cat "$SOCKS5_PORT_FILE" 2>/dev/null); [ -z "$SOCKS5_PORT" ] && SOCKS5_PORT=1080
    UDP_PORT=$(grep -oP '"listen"\s*:\s*"[^"]*:\K[0-9]+' "$UDP_CFG" 2>/dev/null); [ -z "$UDP_PORT" ] && UDP_PORT=36712

    cat > /etc/tunnel-qos.conf << EOF
IFACE=${IFACE}
DOWNLOAD_SHAPE_MBIT=${DOWNLOAD_SHAPE_MBIT}
UPLOAD_SHAPE_MBIT=${UPLOAD_SHAPE_MBIT}
RTT_MS=${RTT_MS}
TUNNEL_MTU=${TUNNEL_MTU}
DNS_V4_A=${DNS_V4_A}
DNS_V4_B=${DNS_V4_B}
NCPU=${NCPU}
APP_CPU=${APP_CPU}
TXQUEUELEN=10000
HEALTHCHECK_FAIL_STREAK_LIMIT=3
HASH_DIVISOR=${HASH_DIVISOR}
PER_USER_GUAR_KBIT=${PER_USER_GUAR_KBIT}
PER_USER_CEIL_MBIT=${PER_USER_CEIL_MBIT}
CAPACITY_PER_VCPU=${CAPACITY_PER_VCPU}
MAX_CAPACITY_USERS=${MAX_CAPACITY_USERS}
DROPBEAR_PORT=${DROPBEAR_PORT}
SOCKS5_PORT=${SOCKS5_PORT}
UDP_PORT=${UDP_PORT}
EOF
    ok "/etc/tunnel-qos.conf เขียนใหม่แล้ว (ไฟล์ config กลางไฟล์เดียวที่ทุกสคริปต์อ่านค่าเดียวกัน)"

    /usr/local/sbin/set-multiqueue.sh >/dev/null 2>&1
    systemctl restart tunnel-shaper.service 2>/dev/null
    /usr/local/sbin/set-rps.sh >/dev/null 2>&1
    systemctl restart set-rps.service 2>/dev/null
    for svc in dropbear danted udp-custom; do
        systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 && systemctl restart "$svc" 2>/dev/null
    done
    sleep 2
    ok "restart ทุก service เรียบร้อย"
else
    ok "(ข้าม — check-only)"
fi

step "10/10 — ตรวจสุขภาพรวมทั้งสแตก + เช็ค conflict (health & conflict dashboard)"
source /etc/tunnel-qos.conf 2>/dev/null || true
DROPBEAR_PORT="${DROPBEAR_PORT:-2345}"; SOCKS5_PORT="${SOCKS5_PORT:-1080}"; UDP_PORT="${UDP_PORT:-36712}"

echo -e "${C}--- ความจุ / สเปค ---${NC}"
echo "  vCPU=${NCPU}  RAM=${TOTAL_RAM_MB}MB  IFACE=${IFACE}"
echo "  ความจุออกแบบ = ${MAX_CAPACITY_USERS} คน (${NCPU} x ${CAPACITY_PER_VCPU}/vCPU) | ผู้ใช้จริงตอนนี้ = ${CURRENT_USERS} คน"
[ "$CURRENT_USERS" -gt "$MAX_CAPACITY_USERS" ] && bad "เกินความจุที่สเปครองรับ! พิจารณาเพิ่ม vCPU" || ok "ยังไม่เกินความจุ"

echo -e "\n${C}--- Conflict checks ---${NC}"
if systemctl is-active ufw >/dev/null 2>&1; then bad "ufw ยัง active คู่กับ nftables (ควรมีแค่ตัวเดียว)"; else ok "ufw: ปิดแล้ว/ไม่มี — nftables เป็นไฟร์วอลล์เดียว"; fi

DUP_SYSCTL=$(ls /etc/sysctl.d/99-tunnel*.conf /etc/sysctl.d/99-smng*.conf 2>/dev/null | wc -l)
[ "$DUP_SYSCTL" -gt 1 ] && bad "เจอไฟล์ sysctl หลายไฟล์ซ้อนกัน ($(ls /etc/sysctl.d/99-tunnel*.conf /etc/sysctl.d/99-smng*.conf 2>/dev/null | tr '\n' ' '))" || ok "sysctl มีไฟล์เดียว (99-tunnel-final.conf)"

if systemctl list-unit-files tunnel-watchdog.timer >/dev/null 2>&1; then bad "ยังเจอ tunnel-watchdog.timer ตัวเก่า (ควรมีแค่ tunnel-selfheal)"; else ok "watchdog เหลือตัวเดียว (tunnel-selfheal)"; fi

echo -e "\n${C}--- Kernel / QoS ---${NC}"
CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
[ "$CUR_CC" = "bbr" ] && ok "BBR: active" || warn "BBR: ยังไม่ active (${CUR_CC:-unknown}) — บาง VPS (OpenVZ) ปรับไม่ได้"

IPV6_DIS=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
[ "$IPV6_DIS" = "1" ] && ok "IPv6: disabled" || warn "IPv6: ยังไม่ disable เต็มที่ (reboot ถ้าเพิ่งแก้ GRUB)"

DL_LINKED=$(tc filter show dev "$IFACE" 2>/dev/null | grep -c "ht 8:")
UL_LINKED=$(tc filter show dev ifb0 2>/dev/null | grep -c "ht 8:")
if tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "qdisc htb 1:" && [ "$DL_LINKED" -ge "$HASH_DIVISOR" ]; then
    ok "HTB per-user shaping (download): active บน ${IFACE} — ${DL_LINKED}/${HASH_DIVISOR} bucket ผูกครบ"
else
    bad "HTB shaping (download): ไม่สมบูรณ์บน ${IFACE} (${DL_LINKED}/${HASH_DIVISOR} bucket) — รัน: sudo /usr/local/sbin/qos-root-init.sh เพื่อดู error สด"
fi
if tc qdisc show dev ifb0 2>/dev/null | grep -q "qdisc htb 1:" && [ "$UL_LINKED" -ge "$HASH_DIVISOR" ]; then
    ok "HTB per-user shaping (upload/ifb0): active — ${UL_LINKED}/${HASH_DIVISOR} bucket ผูกครบ"
else
    warn "HTB shaping (upload/ifb0): ไม่สมบูรณ์ (${UL_LINKED}/${HASH_DIVISOR} bucket) — เช็คว่า modprobe ifb สำเร็จหรือไม่"
fi

echo -e "\n${C}--- Services ---${NC}"
for chk in "dropbear:${DROPBEAR_PORT}" "danted:${SOCKS5_PORT}" "udp-custom:${UDP_PORT}"; do
    svc="${chk%%:*}"; port="${chk##*:}"
    if ! systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
        warn "${svc}: ยังไม่ได้ติดตั้ง"
    elif ss -tuln 2>/dev/null | grep -q ":${port} "; then
        ok "${svc} ฟังพอร์ต ${port} จริง"
    else
        bad "${svc} ไม่ฟังพอร์ต ${port} — เช็ค: journalctl -u ${svc} -n 50"
    fi
done

swapon --show 2>/dev/null | grep -q swapfile && ok "swap: active" || warn "swap: ไม่ได้เปิด (ปกติถ้า RAM เหลือเยอะ)"

echo
echo -e "${G}เสร็จสิ้น — สแตกทั้งหมดรวมเป็นไฟล์เดียว ทำงานร่วมกันแล้ว${NC}"
echo "  • HTB shaping: divisor=256, handle 8: ระบุชัด, hashkey offset แยก src(12)/dst(16), bucket เป็น hex, leaf match แก้ syntax แล้ว"
echo "  • ไฟร์วอลล์เหลือ nftables ตัวเดียว, sysctl เหลือไฟล์เดียว, watchdog เหลือตัวเดียว"
echo "  • ความจุออกแบบไว้: ${MAX_CAPACITY_USERS} คน (ปรับ CAPACITY_PER_VCPU=$CAPACITY_PER_VCPU ในสคริปต์นี้ได้ถ้าต้องการเปลี่ยนสัดส่วน)"
echo -e "${Y}ถ้าเพิ่งแก้ GRUB (ipv6.disable=1) เป็นครั้งแรก ให้ reboot เครื่อง 1 ครั้งเพื่อให้ครบสมบูรณ์${NC}"
echo "  รันซ้ำได้ทุกเมื่ออย่างปลอดภัย (idempotent) หรือรันแบบ --check-only เพื่อดูสถานะโดยไม่แก้อะไร"
