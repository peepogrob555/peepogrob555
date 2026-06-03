#!/usr/bin/env bash
# AIS กันรั่ว 128kbps (4G & 5G) — VMESS WS None TLS v4.0 ULTRA LOW LATENCY
# Hardware : 1vCPU @2.69GHz · 2GB RAM · KVM · virtio_net
# Kernel   : 5.15.0-179-generic
# Xray     : 26.6.1 / go1.26.3
# Users    : 2 · RAM per socket ceiling 750MB · Swap 512MB
# RTT      : ~40ms (AIS 4G/5G)
# Bypass   : 325Mbps max (หลังหัก 15% VMESS WS overhead)
# MSS      : 1440 (MTU 1500 - IP 20 - TCP 20 - WS frame 20)
# BDP      : 325Mbps x 40ms / 8 = 1,625,000 bytes
# Goal     : ปิงต่ำสุด jitter ต่ำสุด เสถียรสุด — ไม่สนใจ CPU/RAM overhead
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

STATE_DIR="/var/lib/ais-vmess-setup"
STATE_FILE="${STATE_DIR}/steps.done"
LOG_FILE="${STATE_DIR}/install.log"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

sep()  { echo -e "${DIM}${CYN}────────────────────────────────────────────────────${RST}"; }
hdr()  { echo -e "\n${BLD}${CYN}▶  $1${RST}"; sep; }
ok()   { echo -e "  ${GRN}✔${RST}  $1"; }
warn() { echo -e "  ${YEL}⚠${RST}  $1"; }
info() { echo -e "  ${CYN}ℹ${RST}  $1"; }
die()  { echo -e "\n${RED}${BLD}✘  $1${RST}\n  Log: ${LOG_FILE}\n"; exit 1; }

step_done()  { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done()  { grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"; }
clear_done() { sed -i "/^$1$/d" "$STATE_FILE" 2>/dev/null || true; }

run_step() {
  local name="$1" skip="$2"; shift 2
  if $skip && step_done "$name"; then ok "[SKIP] ${name}"; return 0; fi
  clear_done "$name"
  echo -e "\n${BLD}  → ${name}${RST}"
  if (set -euo pipefail; "$@"); then
    mark_done "$name"; ok "[OK]   ${name}"
  else
    echo -e "\n${RED}${BLD}✘  FAILED: ${name}${RST}"
    echo -e "  ${YEL}Log: ${LOG_FILE}${RST}\n"
    exit 1
  fi
}
run_skip()   { run_step "$1" true  "${@:2}"; }
run_always() { run_step "$1" false "${@:2}"; }

retry() {
  local tries=$1 delay=$2; shift 2; local i=1
  while true; do
    "$@" && return 0
    echo -e "  ${YEL}retry ${i}/${tries} — wait ${delay}s...${RST}"
    [ "$i" -ge "$tries" ] && return 1
    sleep "$delay"; i=$((i+1))
  done
}

wait_active() {
  local svc="$1" timeout="${2:-30}" elapsed=0
  until systemctl is-active "$svc" &>/dev/null; do
    [ "$elapsed" -ge "$timeout" ] && { warn "timeout waiting ${svc}"; return 1; }
    sleep 2; elapsed=$((elapsed+2))
  done
}

[ "$(id -u)" -eq 0 ] || die "must run as root"

# ── Constants ─────────────────────────────────────────────
BASE_MSS=1440
EFFECTIVE_MTU=1500
BDP=1625000
RMEM_MAX=786432000
WMEM_MAX=786432000
RMEM_DEFAULT=1625000
WMEM_DEFAULT=1625000
TCP_MEM_PRESSURE=184320
TCP_MEM_HARD=245760
TCP_MEM_MAX=291840
NOTSENT_LOWAT=4096
LIMIT_OUTPUT=1625000
TC_QUANTUM=1440
TC_BUCKETS=65536
SOMAXCONN=4096
SYN_BACKLOG=4096
NETDEV_BACKLOG=16384
TW_BUCKETS=32768
KA_TIME=15
KA_INTVL=3
KA_PROBES=3
FIN_TIMEOUT=5
BUSY_POLL=100
BUSY_READ=100
XUI_MEM_HIGH=1288490188
XUI_MEM_MAX=1503238553
XUI_MEM_SWAP=104857600
SWAP_SIZE_MB=512
PANEL_PORT="${PANEL_PORT:-2053}"
OPEN_PORTS=(22 80 443 2053 2083 2087 2096 8080 8443 54321)

_detect_nic() {
  local nic
  nic=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -z "$nic" ] && nic=$(ip link show 2>/dev/null \
    | awk -F': ' '/^[0-9]+: / && !/lo:/ {print $2}' \
    | head -1 | cut -d@ -f1)
  echo "${nic:-eth0}"
}
NIC=$(_detect_nic)
MTU_PHYSICAL=$(ip link show "$NIC" 2>/dev/null \
  | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' | head -1)
MTU_PHYSICAL="${MTU_PHYSICAL:-1500}"
VCPU=$(nproc 2>/dev/null || echo 1)

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  AIS กันรั่ว 128kbps — VMESS WS v4.0 ULL            ║${RST}"
echo -e "${BLD}${CYN}║  1vCPU · 2GB RAM · KVM virtio_net · RTT~40ms        ║${RST}"
echo -e "${BLD}${CYN}║  VMESS · WebSocket · port 80 · None TLS              ║${RST}"
echo -e "${BLD}${CYN}║  ปิงต่ำสุด · jitter ต่ำสุด · เก็บทุกรายละเอียด     ║${RST}"
echo -e "${BLD}${CYN}║  NIC: ${NIC}$(printf '%*s' $((47-${#NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""
info "MSS              : ${BASE_MSS} bytes"
info "BDP @325Mbps     : ${BDP} bytes"
info "notsent_lowat    : ${NOTSENT_LOWAT} bytes (4KB — ส่งแทบทุก syscall)"
info "limit_output     : ${LIMIT_OUTPUT} bytes (1xBDP — queue สั้นสุด)"
info "busy_poll/read   : ${BUSY_POLL}us (poll ก่อน IRQ sleep)"
info "fq quantum       : ${TC_QUANTUM} bytes (1xMSS)"
info "keepalive        : ${KA_TIME}s / ${KA_INTVL}s x ${KA_PROBES}"
info "vCPU             : ${VCPU}"
echo ""

hdr "STEP 1 — UPDATE & DEPS"
_step1() {
  systemctl stop    unattended-upgrades 2>/dev/null || true
  systemctl disable unattended-upgrades 2>/dev/null || true
  systemctl kill --kill-who=all unattended-upgrades 2>/dev/null || true
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
              /var/cache/apt/archives/lock &>/dev/null; do
    [ "$waited" -ge 90 ] && {
      fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
               /var/cache/apt/archives/lock 2>/dev/null || true
      sleep 3; break
    }
    sleep 3; waited=$((waited+3))
  done
  dpkg --configure -a
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw ethtool sqlite3 irqbalance iproute2 iputils-ping \
    linux-tools-common linux-tools-generic 2>/dev/null || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw ethtool sqlite3 irqbalance iproute2 iputils-ping
}
run_skip "step1_deps" _step1

hdr "STEP 2 — SWAP 512MB"
_step2() {
  if swapon --show | grep -q '/swapfile'; then
    info "swapfile already active"
    return 0
  fi
  [ -f /swapfile ] && { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }
  fallocate -l "${SWAP_SIZE_MB}M" /swapfile \
    || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE_MB}" status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon --show
  free -h
}
run_skip "step2_swap" _step2

hdr "STEP 3 — FIREWALL"
_step3() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  for port in "${OPEN_PORTS[@]}"; do ufw allow "${port}/tcp"; done
  ufw --force enable
  ufw status
}
run_skip "step3_ufw" _step3

hdr "STEP 4 — INSTALL 3X-UI"
_step4() {
  local installer
  installer=$(mktemp /tmp/3xui-install.XXXXXX.sh)
  retry 3 5 curl -fsSL \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    -o "$installer" || { rm -f "$installer"; return 1; }
  chmod +x "$installer"
  bash "$installer"
  rm -f "$installer"
}
run_skip "step4_3xui" _step4

hdr "STEP 5 — KERNEL / TCP / VM TUNE (ULTRA LOW LATENCY)"
_step5() {
  modprobe tcp_bbr 2>/dev/null || true
  local cc="bbr"
  grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
    || { warn "BBR unavailable — fallback cubic"; cc="cubic"; }

  local qdisc="fq"
  modinfo sch_fq &>/dev/null 2>&1 || { warn "fq unavailable — fallback fq_codel"; qdisc="fq_codel"; }

  local has_notsent=0
  [ -f /proc/sys/net/ipv4/tcp_notsent_lowat ] && has_notsent=1

  cat > /etc/sysctl.d/99-ais-vmess-tune.conf << EOF
net.ipv4.tcp_congestion_control       = ${cc}
net.core.default_qdisc                = ${qdisc}

net.core.rmem_max                     = ${RMEM_MAX}
net.core.wmem_max                     = ${WMEM_MAX}
net.core.rmem_default                 = ${RMEM_DEFAULT}
net.core.wmem_default                 = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem                     = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem                     = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf          = 1
net.ipv4.tcp_adv_win_scale            = 1
net.ipv4.tcp_mem                      = ${TCP_MEM_PRESSURE} ${TCP_MEM_HARD} ${TCP_MEM_MAX}
net.ipv4.tcp_limit_output_bytes       = ${LIMIT_OUTPUT}
net.core.optmem_max                   = 131072

$([ "$has_notsent" = "1" ] && echo "net.ipv4.tcp_notsent_lowat            = ${NOTSENT_LOWAT}")

net.core.busy_poll                    = ${BUSY_POLL}
net.core.busy_read                    = ${BUSY_READ}
net.core.netdev_budget                = 600
net.core.netdev_budget_usecs          = 8000
net.core.netdev_max_backlog           = ${NETDEV_BACKLOG}
net.core.somaxconn                    = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog          = ${SYN_BACKLOG}

net.ipv4.tcp_mtu_probing              = 1
net.ipv4.tcp_base_mss                 = ${BASE_MSS}

net.ipv4.tcp_fastopen                 = 0
net.ipv4.tcp_window_scaling           = 1
net.ipv4.tcp_timestamps               = 1
net.ipv4.tcp_sack                     = 1
net.ipv4.tcp_dsack                    = 1
net.ipv4.tcp_fack                     = 1
net.ipv4.tcp_ecn                      = 0
net.ipv4.tcp_low_latency              = 1
net.ipv4.tcp_autocorking              = 0
net.ipv4.tcp_no_delay_ack             = 1
net.ipv4.tcp_thin_linear_timeouts     = 1
net.ipv4.tcp_thin_dupack              = 1
net.ipv4.tcp_early_retrans            = 3
net.ipv4.tcp_recovery                 = 1
net.ipv4.tcp_reordering               = 3
net.ipv4.tcp_no_metrics_save          = 0
net.ipv4.tcp_syncookies               = 1
net.ipv4.tcp_tw_reuse                 = 1
net.ipv4.tcp_max_tw_buckets           = ${TW_BUCKETS}
net.ipv4.ip_local_port_range          = 1024 65535

net.ipv4.tcp_keepalive_time           = ${KA_TIME}
net.ipv4.tcp_keepalive_intvl          = ${KA_INTVL}
net.ipv4.tcp_keepalive_probes         = ${KA_PROBES}
net.ipv4.tcp_fin_timeout              = ${FIN_TIMEOUT}
net.ipv4.tcp_syn_retries              = 2
net.ipv4.tcp_synack_retries           = 2
net.ipv4.tcp_retries2                 = 5
net.ipv4.tcp_orphan_retries           = 1

vm.swappiness                         = 5
vm.dirty_ratio                        = 5
vm.dirty_background_ratio             = 2
vm.dirty_expire_centisecs             = 200
vm.dirty_writeback_centisecs          = 50
vm.min_free_kbytes                    = 65536
vm.vfs_cache_pressure                 = 50
vm.overcommit_memory                  = 2
vm.overcommit_ratio                   = 90
vm.numa_balancing                     = 0
vm.page_lock_unfairness               = 1

fs.file-max                           = 1048576
fs.nr_open                            = 1048576
fs.pipe-max-size                      = 1048576

kernel.sched_autogroup_enabled        = 0
kernel.sched_min_granularity_ns       = 100000
kernel.sched_wakeup_granularity_ns    = 25000
kernel.sched_latency_ns               = 1000000
kernel.sched_migration_cost_ns        = 25000
kernel.sched_nr_migrate               = 1
kernel.timer_migration                = 0
kernel.pid_max                        = 65536
kernel.threads-max                    = 131072
kernel.panic                          = 10
kernel.panic_on_oops                  = 1

net.ipv4.conf.all.accept_redirects    = 0
net.ipv4.conf.all.send_redirects      = 0
net.ipv4.conf.all.rp_filter           = 1
net.ipv4.icmp_echo_ignore_broadcasts  = 1
net.ipv4.tcp_abort_on_overflow        = 0
EOF

  sysctl -p /etc/sysctl.d/99-ais-vmess-tune.conf

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" \
    target 1ms interval 10ms 2>/dev/null \
  || tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null \
  || warn "tc ${qdisc} failed"
  tc qdisc show dev "$NIC"
}
run_always "step5_sysctl" _step5

hdr "STEP 6 — TRANSPARENT HUGE PAGES off"
_step6() {
  echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
  echo never > /sys/kernel/mm/transparent_hugepage/defrag   || true
  echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
  cat > /etc/systemd/system/thp-disable.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=x-ui.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
ExecStart=/bin/sh -c 'echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thp-disable.service
  cat /sys/kernel/mm/transparent_hugepage/enabled
}
run_always "step6_thp" _step6

hdr "STEP 7 — NIC TUNE (${NIC} — virtio_net)"
_step7() {
  ip link show "$NIC"

  local qdisc="fq"
  grep -q "default_qdisc.*fq_codel" /etc/sysctl.d/99-ais-vmess-tune.conf 2>/dev/null \
    && qdisc="fq_codel"

  ethtool -K "$NIC" gro off lro off tso on gso on 2>/dev/null \
    || warn "ethtool offload: partial (ok on virtio_net)"
  ethtool -K "$NIC" rx-gro-hw off 2>/dev/null || true
  ethtool -A "$NIC" rx off tx off 2>/dev/null || true

  local rx_max tx_max
  rx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/RX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  tx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/TX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  rx_max="${rx_max:-256}"; tx_max="${tx_max:-256}"
  ethtool -G "$NIC" rx "$rx_max" tx "$tx_max" 2>/dev/null \
    && info "ring buffer rx=${rx_max} tx=${tx_max}" || true

  ethtool -C "$NIC" rx-usecs 0 tx-usecs 0 adaptive-rx off adaptive-tx off 2>/dev/null \
    || ethtool -C "$NIC" rx-usecs 0 tx-usecs 0 2>/dev/null || true

  ethtool -K "$NIC" rx-vlan-offload off tx-vlan-offload off 2>/dev/null || true

  ip link set "$NIC" txqueuelen 256
  ip link set "$NIC" mtu "${EFFECTIVE_MTU}" 2>/dev/null || true

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" \
    target 1ms interval 10ms 2>/dev/null \
  || tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null \
  || warn "tc ${qdisc} on ${NIC} failed"

  echo 1 > /sys/class/net/"${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true
  if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
    echo 4096 > /proc/sys/net/core/rps_sock_flow_entries
    echo 4096 > /sys/class/net/"${NIC}"/queues/rx-0/rps_flow_cnt 2>/dev/null || true
    info "RPS/RFS: 4096 entries"
  fi

  mkdir -p /etc/networkd-dispatcher/routable.d
  cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
set -uo pipefail
NIC="${NIC}"
QDISC="${qdisc}"
RX_MAX="${rx_max}"
TX_MAX="${tx_max}"
TC_QUANTUM="${TC_QUANTUM}"
TC_BUCKETS="${TC_BUCKETS}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro off lro off tso on gso on 2>/dev/null || true
ethtool -K "\${NIC}" rx-gro-hw off 2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}" 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 0 tx-usecs 0 adaptive-rx off adaptive-tx off 2>/dev/null || true
ethtool -K "\${NIC}" rx-vlan-offload off tx-vlan-offload off 2>/dev/null || true
ip link set "\${NIC}" mtu "${EFFECTIVE_MTU}" 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 256
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} \
  target 1ms interval 10ms 2>/dev/null \
|| tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} 2>/dev/null || true
echo 1 > /sys/class/net/"\${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true
if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
  echo 4096 > /proc/sys/net/core/rps_sock_flow_entries
  echo 4096 > /sys/class/net/"\${NIC}"/queues/rx-0/rps_flow_cnt 2>/dev/null || true
fi
NEOF
  chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

  cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC Tuning — ${NIC} virtio_net
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/networkd-dispatcher/routable.d/50-nic-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SEOF
  systemctl daemon-reload
  systemctl enable nic-tune.service
  info "nic-tune.service enabled"
}
run_always "step7_nic" _step7

hdr "STEP 8 — I/O SCHEDULER"
_step8() {
  local found=0
  for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/${DEV}" ] || continue
    found=1
    local rot
    rot=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
    if [ "$rot" = "0" ]; then
      echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: SSD/NVMe -> none"
    else
      echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: HDD -> mq-deadline"
    fi
    echo 0  > "/sys/block/${DEV}/queue/add_random"    2>/dev/null || true
    echo 32 > "/sys/block/${DEV}/queue/nr_requests"   2>/dev/null || true
    echo 2  > "/sys/block/${DEV}/queue/nomerges"      2>/dev/null || true
    echo 0  > "/sys/block/${DEV}/queue/read_ahead_kb" 2>/dev/null || true
    echo 0  > "/sys/block/${DEV}/queue/wbt_lat_usec"  2>/dev/null || true
  done
  [ "$found" -eq 1 ] || warn "no block device matched"
  cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]",         ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]",         ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="vd[a-z]",         ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="vd[a-z]",         ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="xvd[a-z]",        ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF
  udevadm control --reload-rules
}
run_always "step8_io" _step8

hdr "STEP 9 — CPU GOVERNOR performance"
_step9() {
  cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=CPU Governor performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c \
  'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; \
  do [ -f "$f" ] && echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cpu-performance.service
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null \
    || info "cpufreq not available (VM passthrough)"
}
run_always "step9_cpu" _step9

hdr "STEP 10 — SYSTEM LIMITS"
_step10() {
  cat > /etc/security/limits.d/99-xui.conf << 'EOF'
*    soft nofile   1048576
*    hard nofile   1048576
*    soft nproc    65536
*    hard nproc    65536
*    soft memlock  unlimited
*    hard memlock  unlimited
*    soft stack    67108864
*    hard stack    67108864
root soft nofile   1048576
root hard nofile   1048576
root soft nproc    65536
root hard nproc    65536
root soft memlock  unlimited
root hard memlock  unlimited
EOF
  for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam" ] || continue
    grep -qxF 'session required pam_limits.so' "$pam" \
      || echo 'session required pam_limits.so' >> "$pam"
  done
  cat /etc/security/limits.d/99-xui.conf
}
run_always "step10_limits" _step10

hdr "STEP 11 — x-ui SYSTEMD OVERRIDE"
_step11() {
  local xui_bin
  xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
  [ -x "$xui_bin" ] || { warn "x-ui binary not found — skipping override"; return 0; }
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=65536
LimitMEMLOCK=infinity
LimitCORE=0
LimitSTACK=67108864
Restart=always
RestartSec=1
RestartPreventExitStatus=0
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=20
Environment=GODEBUG=madvdontneed=1 asyncpreemptoff=0
Environment=GOMEMLIMIT=1200MiB
OOMScoreAdjust=-500
MemoryHigh=${XUI_MEM_HIGH}
MemoryMax=${XUI_MEM_MAX}
MemorySwapMax=${XUI_MEM_SWAP}
CPUSchedulingPolicy=other
CPUSchedulingPriority=0
CPUWeight=100
IOSchedulingClass=best-effort
IOSchedulingPriority=0
IOWeight=100
Nice=-10
TasksMax=4096
EOF
  systemctl daemon-reload
  systemctl restart x-ui
  wait_active x-ui 30 || warn "x-ui not active after override"
  systemctl status x-ui --no-pager
}
run_always "step11_xui_override" _step11

hdr "STEP 12 — IRQBALANCE"
_step12() {
  if command -v irqbalance &>/dev/null; then
    cat > /etc/default/irqbalance << 'EOF'
ENABLED=1
ONESHOT=0
OPTIONS="--powerthresh=0"
EOF
    systemctl enable --now irqbalance 2>/dev/null || true
    systemctl status irqbalance --no-pager
  else
    warn "irqbalance not installed"
  fi
}
run_always "step12_irq" _step12

hdr "STEP 13 — XRAY SOCKOPT PATCH (VMESS WS port 80)"
_step13() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — skipping sockopt patch (run after install)"; return 0; }
  command -v sqlite3 &>/dev/null || { warn "sqlite3 not found"; return 1; }

  local sockopt
  sockopt='{"acceptProxyProtocol":false,"tcpFastOpen":false,"mark":0,"tproxy":"off","tcpMptcp":false,"penetrate":false,"domainStrategy":"AsIs","tcpMaxSeg":1440,"dialerProxy":"","tcpKeepAliveInterval":15,"tcpKeepAliveIdle":15,"tcpUserTimeout":30000,"tcpcongestion":"bbr","V6Only":false,"tcpWindowClamp":0,"interface":"","trustedXForwardedFor":[],"addressPortStrategy":"none","customSockopt":[],"tcpNoDelay":true}'

  local count
  count=$(sqlite3 "$db" "SELECT COUNT(*) FROM inbounds WHERE port=80 AND protocol='vmess';" 2>/dev/null || echo "0")

  if [ "$count" -gt 0 ]; then
    local stream_settings
    stream_settings=$(sqlite3 "$db" "SELECT stream_settings FROM inbounds WHERE port=80 AND protocol='vmess' LIMIT 1;" 2>/dev/null || echo "")

    if [ -n "$stream_settings" ]; then
      local new_stream
      new_stream=$(echo "$stream_settings" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['sockopt'] = json.loads('${sockopt}')
print(json.dumps(d, separators=(',',':')))
" 2>/dev/null || echo "")

      if [ -n "$new_stream" ]; then
        sqlite3 "$db" "UPDATE inbounds SET stream_settings='${new_stream}' WHERE port=80 AND protocol='vmess';"
        info "sockopt patched on existing vmess port 80 inbound"
      else
        warn "python3 parse failed — sockopt not patched"
      fi
    fi
  else
    warn "no vmess port 80 inbound found in DB — create inbound in panel first, then re-run step13"
    warn "sockopt to apply manually:"
    echo "${sockopt}"
  fi

  systemctl restart x-ui 2>/dev/null || true
}
run_always "step13_sockopt" _step13

hdr "STEP 14 — PERSIST VERIFY (reboot-safe)"
_step14() {
  local errors=0
  systemctl is-enabled thp-disable.service     || { warn "thp-disable not enabled";       errors=$((errors+1)); }
  systemctl is-enabled nic-tune.service        || { warn "nic-tune not enabled";           errors=$((errors+1)); }
  systemctl is-enabled cpu-performance.service || { warn "cpu-performance not enabled";    errors=$((errors+1)); }
  systemctl is-enabled x-ui 2>/dev/null        || warn "x-ui not enabled"

  [ -f /etc/sysctl.d/99-ais-vmess-tune.conf ]               || { warn "sysctl conf missing";            errors=$((errors+1)); }
  [ -f /etc/security/limits.d/99-xui.conf ]                 || { warn "limits conf missing";             errors=$((errors+1)); }
  [ -f /etc/udev/rules.d/60-io-scheduler.rules ]            || { warn "io scheduler rules missing";      errors=$((errors+1)); }
  [ -f /etc/networkd-dispatcher/routable.d/50-nic-tune.sh ] || { warn "nic-tune script missing";         errors=$((errors+1)); }
  [ -f /etc/systemd/system/thp-disable.service ]            || { warn "thp-disable service missing";     errors=$((errors+1)); }
  [ -f /etc/systemd/system/nic-tune.service ]               || { warn "nic-tune service missing";        errors=$((errors+1)); }
  [ -f /etc/systemd/system/cpu-performance.service ]        || { warn "cpu-performance service missing"; errors=$((errors+1)); }
  grep -q '/swapfile' /etc/fstab \
    || { warn "swapfile not in fstab"; errors=$((errors+1)); }
  swapon --show | grep -q '/swapfile' \
    || { warn "swapfile not active"; errors=$((errors+1)); }
  [ -f /etc/systemd/system/x-ui.service.d/override.conf ] \
    || warn "x-ui override missing"

  if [ "$errors" -eq 0 ]; then
    ok "all persist checks passed — safe to reboot"
  else
    warn "${errors} issue(s) found — review above before reboot"
    return 1
  fi
}
run_always "step14_verify" _step14

hdr "DONE — FULL SUMMARY"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps completed:${RST}"
while IFS= read -r line; do
  [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  ${line}"
done < "$STATE_FILE"

echo ""
echo -e "  ══════════════════════════════════════════════════════"
echo -e "  ${BLD}Panel URL          :${RST} http://${PUB_IP}:${PANEL_PORT}"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}Protocol           :${RST} VMESS WebSocket port 80 None TLS"
echo -e "  ${BLD}Host header        :${RST} speedtest.net"
echo -e "  ${BLD}NIC                :${RST} ${NIC} virtio_net MTU ${EFFECTIVE_MTU}"
echo -e "  ${BLD}BASE_MSS           :${RST} ${BASE_MSS} bytes"
echo -e "  ${BLD}BDP @325Mbps       :${RST} ${BDP} bytes"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}rmem/wmem def      :${RST} $((RMEM_DEFAULT/1024))KB (1xBDP)"
echo -e "  ${BLD}rmem/wmem max      :${RST} $((RMEM_MAX/1024/1024))MB per socket"
echo -e "  ${BLD}notsent_lowat      :${RST} ${NOTSENT_LOWAT} bytes (4KB)"
echo -e "  ${BLD}limit_output       :${RST} ${LIMIT_OUTPUT} bytes (1xBDP)"
echo -e "  ${BLD}fq quantum         :${RST} ${TC_QUANTUM} bytes (1xMSS)"
echo -e "  ${BLD}fq target          :${RST} 1ms interval 10ms"
echo -e "  ${BLD}txqueuelen         :${RST} 256"
echo -e "  ${BLD}coalescing         :${RST} rx-usecs=0 tx-usecs=0 adaptive=off"
echo -e "  ${BLD}busy_poll/read     :${RST} ${BUSY_POLL}us"
echo -e "  ${BLD}netdev_budget      :${RST} 600 packets / 8000us"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}GOMAXPROCS         :${RST} ${VCPU}"
echo -e "  ${BLD}GOGC               :${RST} 20 (GC บ่อยมาก heap เล็กมาก pause น้อย)"
echo -e "  ${BLD}GOMEMLIMIT         :${RST} 1200MiB"
echo -e "  ${BLD}GODEBUG            :${RST} madvdontneed=1"
echo -e "  ${BLD}Nice x-ui          :${RST} -10"
echo -e "  ${BLD}RestartSec         :${RST} 1s"
echo -e "  ${BLD}OOMScore x-ui      :${RST} -500"
echo -e "  ${BLD}x-ui MemHigh       :${RST} $((XUI_MEM_HIGH/1024/1024))MB"
echo -e "  ${BLD}x-ui MemMax        :${RST} $((XUI_MEM_MAX/1024/1024))MB"
echo -e "  ${BLD}Swap               :${RST} ${SWAP_SIZE_MB}MB (/swapfile)"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}sched latency      :${RST} 1ms granularity=0.1ms wakeup=0.025ms"
echo -e "  ${BLD}sched_nr_migrate   :${RST} 1 (ลด migration jitter)"
echo -e "  ${BLD}timer_migration    :${RST} 0 (timer ไม่ย้าย CPU)"
echo -e "  ${BLD}dirty write        :${RST} ratio=5% bg=2% expire=200cs wb=50cs"
echo -e "  ${BLD}tcp_no_delay_ack   :${RST} 1"
echo -e "  ${BLD}tcp_thin_dupack    :${RST} 1"
echo -e "  ${BLD}tcp_recovery       :${RST} 1"
echo -e "  ${BLD}wbt_lat_usec       :${RST} 0 (ปิด writeback throttle)"
echo -e "  ${BLD}nr_requests        :${RST} 32 (queue disk สั้น)"
echo -e "  ${BLD}BBR                :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Keepalive          :${RST} ${KA_TIME}s / ${KA_INTVL}s x ${KA_PROBES}"
echo -e "  ${BLD}fin_timeout        :${RST} ${FIN_TIMEOUT}s"
echo -e "  ${BLD}tcp_retries2       :${RST} 5"
echo -e "  ${BLD}tcp_orphan_retries :${RST} 1"
echo -e "  ${BLD}Qdisc              :${RST} $(tc qdisc show dev "$NIC" 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP                :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}CPU governor       :${RST} $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui status        :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Log                :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════"
echo ""
echo -e "  ${BLD}${GRN}Panel config (ตั้งใน 3x-ui):${RST}"
echo -e "  Protocol         : VMESS"
echo -e "  Port             : 80"
echo -e "  Transport        : WebSocket"
echo -e "  Path             : /VMESS"
echo -e "  Host             : speedtest.net"
echo -e "  Security         : none"
echo -e "  AlterID          : 0"
echo -e "  Sniffing         : ปิดทั้งหมด"
echo -e "  tcpMaxSeg        : 1440"
echo -e "  tcpNoDelay       : true"
echo -e "  tcpKeepAliveIdle : 15"
echo -e "  tcpUserTimeout   : 30000"
echo -e "  tcpcongestion    : bbr"
echo -e "  tcpWindowClamp   : 0 (ไม่จำกัด)"
echo ""
echo -e "  ${BLD}${YEL}-> reboot แล้ว config VMESS WS ใน panel${RST}"
echo -e "  ${BLD}${YEL}-> step13 sockopt จะ patch อัตโนมัติถ้ามี inbound port 80 อยู่แล้ว${RST}"
echo ""
