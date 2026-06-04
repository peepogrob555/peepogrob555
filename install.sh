#!/usr/bin/env bash
# =============================================================================
#  Bughost VPN Pole — VMESS WS FULL SETUP v7.1
#  Ubuntu 22.04 · 1vCPU · 2GB RAM · KVM · 10Gbps
#  https://github.com/peepogrob555/peepogrob555
# =============================================================================
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
clear_done() { sed -i "/^${1}$/d" "$STATE_FILE" 2>/dev/null || true; }

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

# ── tunables ──────────────────────────────────────────────────────────────────
BASE_MSS=1440
EFFECTIVE_MTU=1500
RMEM_MAX=2147483647
WMEM_MAX=2147483647
RMEM_DEFAULT=4194304
WMEM_DEFAULT=4194304
TCP_MEM_PRESSURE=786432
TCP_MEM_HARD=1048576
TCP_MEM_MAX=1572864
NOTSENT_LOWAT=131072
LIMIT_OUTPUT=1048576
TC_QUANTUM=3028
TC_BUCKETS=65536
SOMAXCONN=65535
SYN_BACKLOG=65535
NETDEV_BACKLOG=65536
TW_BUCKETS=1440000
KA_TIME=35
KA_INTVL=5
KA_PROBES=5
FIN_TIMEOUT=10
BUSY_POLL=50
BUSY_READ=50
XUI_MEM_HIGH=1503238553
XUI_MEM_MAX=1879048192
XUI_MEM_SWAP=536870912
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
RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  Bughost VPN Pole — VMESS WS FULL SETUP v7.1             ║${RST}"
echo -e "${BLD}${CYN}║  23 Steps · KVM · RTT~35ms · 10Gbps                     ║${RST}"
echo -e "${BLD}${CYN}║  NIC: ${NIC}$(printf '%*s' $((51-${#NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
info "RAM total          : ${RAM_MB}MB"
info "vCPU               : ${VCPU}"
info "NIC                : ${NIC} MTU ${MTU_PHYSICAL}"
info "rmem/wmem max      : 2GB"
info "notsent_lowat      : $((NOTSENT_LOWAT/1024))KB"
info "busy_poll/read     : ${BUSY_POLL}us"
info "fq quantum         : ${TC_QUANTUM} bytes"
info "keepalive          : ${KA_TIME}s/${KA_INTVL}s x ${KA_PROBES}"
echo ""

# =============================================================================
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
    linux-tools-common linux-tools-generic nftables libcap2-bin \
    numactl schedtool 2>/dev/null || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw ethtool sqlite3 irqbalance iproute2 iputils-ping \
    nftables libcap2-bin
}
run_skip "step1_deps" _step1

# =============================================================================
hdr "STEP 2 — SWAP ${SWAP_SIZE_MB}MB"
_step2() {
  if swapon --show | grep -q '/swapfile'; then
    info "swapfile already active"; return 0
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

# =============================================================================
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

# =============================================================================
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

# =============================================================================
hdr "STEP 5 — DISABLE UNUSED SERVICES"
_step5() {
  local services=(
    "snapd" "snapd.socket"
    "snap.amazon-ssm-agent.amazon-ssm-agent"
    "multipathd" "multipathd.socket"
    "apport"
    "apt-daily.timer" "apt-daily-upgrade.timer"
    "man-db.timer" "motd-news.timer"
    "fwupd-refresh.timer"
    "systemd-networkd-wait-online"
    "iscsid" "open-iscsi"
    "mdadm" "lvm2-monitor"
    "bluetooth" "avahi-daemon"
    "cups" "cups-browsed"
    "ModemManager" "packagekit"
    "polkit" "thermald"
    "upower" "udisks2"
    "accounts-daemon"
    "rsyslog" "syslog"
  )
  local svc
  for svc in "${services[@]}"; do
    if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
      systemctl stop    "${svc}" 2>/dev/null || true
      systemctl disable "${svc}" 2>/dev/null || true
      systemctl mask    "${svc}" 2>/dev/null || true
    fi
  done
  info "unnecessary services disabled + masked"
}
run_always "step5_disable_svc" _step5

# =============================================================================
hdr "STEP 6 — TRANSPARENT HUGE PAGES off"
_step6() {
  echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo never > /sys/kernel/mm/transparent_hugepage/defrag   2>/dev/null || true
  echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag               2>/dev/null || true
  echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true
  echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true

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
ExecStart=/bin/sh -c 'echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/scan_sleep_millisecs 2>/dev/null || true'
ExecStart=/bin/sh -c 'echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/alloc_sleep_millisecs 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thp-disable.service
  cat /sys/kernel/mm/transparent_hugepage/enabled
}
run_always "step6_thp" _step6

# =============================================================================
hdr "STEP 7 — KERNEL / TCP / VM / CONNTRACK TUNE"
_step7() {
  modprobe tcp_bbr    2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true

  local cc="bbr"
  grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
    || { warn "BBR unavailable — fallback cubic"; cc="cubic"; }

  local qdisc="fq"
  modinfo sch_fq &>/dev/null || { warn "fq unavailable — fallback fq_codel"; qdisc="fq_codel"; }

  local has_notsent=0
  [ -f /proc/sys/net/ipv4/tcp_notsent_lowat ] && has_notsent=1

  # Only include sysctl keys that actually exist on this kernel
  {
    cat << EOF
net.ipv4.tcp_congestion_control        = ${cc}
net.core.default_qdisc                 = ${qdisc}
net.core.rmem_max                      = ${RMEM_MAX}
net.core.wmem_max                      = ${WMEM_MAX}
net.core.rmem_default                  = ${RMEM_DEFAULT}
net.core.wmem_default                  = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem                      = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem                      = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf           = 1
net.ipv4.tcp_adv_win_scale             = 1
net.ipv4.tcp_mem                       = ${TCP_MEM_PRESSURE} ${TCP_MEM_HARD} ${TCP_MEM_MAX}
net.ipv4.tcp_limit_output_bytes        = ${LIMIT_OUTPUT}
net.core.optmem_max                    = 131072
net.core.busy_poll                     = ${BUSY_POLL}
net.core.busy_read                     = ${BUSY_READ}
net.core.netdev_budget                 = 1200
net.core.netdev_budget_usecs           = 8000
net.core.netdev_max_backlog            = ${NETDEV_BACKLOG}
net.core.dev_weight                    = 128
net.core.dev_weight_rx_bias            = 8
net.core.dev_weight_tx_bias            = 1
net.core.somaxconn                     = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog           = ${SYN_BACKLOG}
net.ipv4.tcp_mtu_probing               = 1
net.ipv4.tcp_base_mss                  = ${BASE_MSS}
net.ipv4.tcp_fastopen                  = 3
net.ipv4.tcp_window_scaling            = 1
net.ipv4.tcp_timestamps                = 1
net.ipv4.tcp_sack                      = 1
net.ipv4.tcp_dsack                     = 1
net.ipv4.tcp_ecn                       = 1
net.ipv4.tcp_autocorking               = 0
net.ipv4.tcp_thin_linear_timeouts      = 1
net.ipv4.tcp_early_retrans             = 3
net.ipv4.tcp_recovery                  = 1
net.ipv4.tcp_reordering                = 6
net.ipv4.tcp_frto                      = 2
net.ipv4.tcp_no_metrics_save           = 1
net.ipv4.tcp_slow_start_after_idle     = 0
net.ipv4.tcp_workaround_signed_windows = 1
net.ipv4.tcp_syncookies                = 1
net.ipv4.tcp_tw_reuse                  = 1
net.ipv4.tcp_max_tw_buckets            = ${TW_BUCKETS}
net.ipv4.ip_local_port_range           = 1024 65535
net.ipv4.tcp_keepalive_time            = ${KA_TIME}
net.ipv4.tcp_keepalive_intvl           = ${KA_INTVL}
net.ipv4.tcp_keepalive_probes          = ${KA_PROBES}
net.ipv4.tcp_fin_timeout               = ${FIN_TIMEOUT}
net.ipv4.tcp_syn_retries               = 3
net.ipv4.tcp_synack_retries            = 3
net.ipv4.tcp_retries2                  = 8
net.ipv4.tcp_orphan_retries            = 2
net.ipv4.tcp_challenge_ack_limit       = 1000
net.ipv4.tcp_max_orphans               = 32768
net.ipv4.tcp_abort_on_overflow         = 0
net.ipv4.route.gc_thresh               = 32768
net.ipv4.ip_no_pmtu_disc               = 0
net.ipv4.ip_forward                    = 1
net.ipv4.conf.all.forwarding           = 1
net.ipv4.conf.default.forwarding       = 1
net.ipv4.conf.all.accept_redirects     = 0
net.ipv4.conf.all.send_redirects       = 0
net.ipv4.conf.all.rp_filter            = 1
net.ipv4.icmp_echo_ignore_broadcasts   = 1
net.ipv6.conf.all.forwarding           = 1
net.ipv6.conf.default.forwarding       = 1
vm.swappiness                          = 10
vm.dirty_ratio                         = 10
vm.dirty_background_ratio              = 3
vm.dirty_expire_centisecs              = 500
vm.dirty_writeback_centisecs           = 100
vm.min_free_kbytes                     = 131072
vm.vfs_cache_pressure                  = 50
vm.overcommit_memory                   = 1
vm.page_lock_unfairness                = 1
vm.stat_interval                       = 10
vm.zone_reclaim_mode                   = 0
vm.watermark_boost_factor              = 0
vm.watermark_scale_factor              = 200
vm.compaction_proactiveness            = 0
fs.file-max                            = 2097152
fs.nr_open                             = 2097152
fs.pipe-max-size                       = 1048576
kernel.sched_autogroup_enabled         = 0
kernel.sched_rt_runtime_us             = -1
kernel.timer_migration                 = 0
kernel.pid_max                         = 131072
kernel.threads-max                     = 262144
kernel.panic                           = 10
kernel.panic_on_oops                   = 1
kernel.perf_event_paranoid             = -1
kernel.kptr_restrict                   = 0
kernel.dmesg_restrict                  = 0
EOF
    # Optional keys — only emit if they exist on this kernel
    [ "$has_notsent" = "1" ] && echo "net.ipv4.tcp_notsent_lowat = ${NOTSENT_LOWAT}"
    [ -f /proc/sys/net/ipv4/tcp_fack ]          && echo "net.ipv4.tcp_fack                        = 1"
    [ -f /proc/sys/net/ipv4/tcp_low_latency ]   && echo "net.ipv4.tcp_low_latency                 = 1"
    [ -f /proc/sys/vm/numa_balancing ]           && echo "vm.numa_balancing                        = 0"
    [ -f /proc/sys/kernel/sched_min_granularity_ns ]   && echo "kernel.sched_min_granularity_ns          = 500000"
    [ -f /proc/sys/kernel/sched_wakeup_granularity_ns ] && echo "kernel.sched_wakeup_granularity_ns       = 50000"
    [ -f /proc/sys/kernel/sched_latency_ns ]    && echo "kernel.sched_latency_ns                  = 4000000"
    [ -f /proc/sys/kernel/sched_migration_cost_ns ] && echo "kernel.sched_migration_cost_ns           = 50000"
    [ -f /proc/sys/kernel/sched_nr_migrate ]    && echo "kernel.sched_nr_migrate                  = 8"
    [ -f /proc/sys/kernel/nmi_watchdog ]        && echo "kernel.nmi_watchdog                      = 0"
    [ -f /proc/sys/kernel/watchdog ]            && echo "kernel.watchdog                          = 0"
  } > /etc/sysctl.d/99-ais-vmess-tune.conf

  sysctl -p /etc/sysctl.d/99-ais-vmess-tune.conf

  local ct_max=131072
  echo "$ct_max" > /proc/sys/net/netfilter/nf_conntrack_max                        2>/dev/null || true
  echo 0         > /proc/sys/net/netfilter/nf_conntrack_checksum                   2>/dev/null || true
  echo 600       > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established    2>/dev/null || true
  echo 20        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait      2>/dev/null || true
  echo 10        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait     2>/dev/null || true
  echo 10        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_fin_wait       2>/dev/null || true
  echo 5         > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_last_ack       2>/dev/null || true
  echo 1         > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal             2>/dev/null || true

  cat >> /etc/sysctl.d/99-ais-vmess-tune.conf << EOF
net.netfilter.nf_conntrack_max                         = ${ct_max}
net.netfilter.nf_conntrack_checksum                    = 0
net.netfilter.nf_conntrack_tcp_timeout_established     = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait       = 20
net.netfilter.nf_conntrack_tcp_timeout_close_wait      = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait        = 10
net.netfilter.nf_conntrack_tcp_timeout_last_ack        = 5
net.netfilter.nf_conntrack_tcp_be_liberal              = 1
EOF

  local bucket_size=$(( ct_max / 4 ))
  echo "$bucket_size" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
  info "conntrack max=${ct_max} hashsize=${bucket_size}"

  cat > /etc/sysctl.d/99-bbr-persistent.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc          = fq
EOF
  sysctl -p /etc/sysctl.d/99-bbr-persistent.conf 2>/dev/null || true

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" limit 10000 2>/dev/null \
  || tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null \
  || warn "tc ${qdisc} failed"
  tc qdisc show dev "$NIC"
}
run_always "step7_sysctl_conntrack" _step7

# =============================================================================
hdr "STEP 8 — NIC TUNE (${NIC} — virtio_net)"
_step8() {
  ip link show "$NIC"

  local qdisc="fq"
  grep -q "default_qdisc.*fq_codel" /etc/sysctl.d/99-ais-vmess-tune.conf 2>/dev/null \
    && qdisc="fq_codel"

  ethtool -K "$NIC" gro on lro off tso on gso on             2>/dev/null || warn "ethtool offload: partial (ok on virtio_net)"
  ethtool -K "$NIC" rx-gro-hw off                            2>/dev/null || true
  ethtool -K "$NIC" rx-checksum on tx-checksum-ip-generic on 2>/dev/null || true
  ethtool -K "$NIC" rx-vlan-offload off tx-vlan-offload off  2>/dev/null || true
  ethtool -A "$NIC" rx off tx off                            2>/dev/null || true

  local rx_max tx_max
  rx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/RX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  tx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/TX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  rx_max="${rx_max:-1024}"; tx_max="${tx_max:-1024}"
  ethtool -G "$NIC" rx "$rx_max" tx "$tx_max" 2>/dev/null \
    && info "ring buffer rx=${rx_max} tx=${tx_max}" || true
  ethtool -C "$NIC" rx-usecs 50 tx-usecs 50 adaptive-rx on adaptive-tx on 2>/dev/null \
    || ethtool -C "$NIC" rx-usecs 50 tx-usecs 50 2>/dev/null || true

  ip link set "$NIC" txqueuelen 10000
  ip link set "$NIC" mtu "${EFFECTIVE_MTU}" 2>/dev/null || true

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" limit 10000 2>/dev/null \
  || tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null \
  || warn "tc ${qdisc} on ${NIC} failed"

  local cpu_count rps_mask
  cpu_count=$(nproc 2>/dev/null || echo 1)
  rps_mask=$(printf '%x' $(( (1 << cpu_count) - 1 )))
  echo "${rps_mask}" > /sys/class/net/"${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true

  if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
    echo 32768 > /sys/class/net/"${NIC}"/queues/rx-0/rps_flow_cnt 2>/dev/null || true
    info "RPS/RFS: 32768 entries"
  fi

  local irq_num
  irq_num=$(grep "${NIC}" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1)
  if [ -n "$irq_num" ] && [ -f "/proc/irq/${irq_num}/smp_affinity_list" ]; then
    echo 0 > "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || true
    info "NIC IRQ ${irq_num} pinned to CPU0"
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
EFFECTIVE_MTU="${EFFECTIVE_MTU}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro on lro off tso on gso on             2>/dev/null || true
ethtool -K "\${NIC}" rx-gro-hw off                            2>/dev/null || true
ethtool -K "\${NIC}" rx-vlan-offload off tx-vlan-offload off  2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off                            2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}"         2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50 adaptive-rx on adaptive-tx on 2>/dev/null || \
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50                  2>/dev/null || true
ip link set "\${NIC}" mtu "\${EFFECTIVE_MTU}"                 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 10000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} limit 10000 2>/dev/null || \
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} 2>/dev/null || true
CPU_COUNT=\$(nproc 2>/dev/null || echo 1)
RPS_MASK=\$(printf '%x' \$(( (1 << CPU_COUNT) - 1 )))
echo "\${RPS_MASK}" > /sys/class/net/"\${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true
if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
  echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
  echo 32768 > /sys/class/net/"\${NIC}"/queues/rx-0/rps_flow_cnt 2>/dev/null || true
fi
IRQ_NUM=\$(grep "${NIC}" /proc/interrupts 2>/dev/null | awk -F: '{print \$1}' | tr -d ' ' | head -1)
[ -n "\$IRQ_NUM" ] && echo 0 > "/proc/irq/\${IRQ_NUM}/smp_affinity_list" 2>/dev/null || true
NEOF
  chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

  cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC Tuning — ${NIC} virtio_net MAX
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
run_always "step8_nic" _step8

# =============================================================================
hdr "STEP 9 — I/O SCHEDULER"
_step9() {
  local found=0 DEV rot
  for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/${DEV}" ] || continue
    found=1
    rot=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
    if [ "$rot" = "0" ]; then
      echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: SSD/NVMe -> none"
    else
      echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: HDD -> mq-deadline"
    fi
    echo 0   > "/sys/block/${DEV}/queue/add_random"    2>/dev/null || true
    echo 256 > "/sys/block/${DEV}/queue/nr_requests"   2>/dev/null || true
    echo 0   > "/sys/block/${DEV}/queue/nomerges"      2>/dev/null || true
    echo 128 > "/sys/block/${DEV}/queue/read_ahead_kb" 2>/dev/null || true
    echo 0   > "/sys/block/${DEV}/queue/wbt_lat_usec"  2>/dev/null || true
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
run_always "step9_io" _step9

# =============================================================================
hdr "STEP 10 — CPU GOVERNOR performance + C-STATE"
_step10() {
  cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=CPU Governor performance + C-state latency
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$f" ] && echo performance > "$f" 2>/dev/null || true; done'
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/power/pm_qos_resume_latency_us; do [ -f "$f" ] && echo 0 > "$f" 2>/dev/null || true; done'
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do [ -f "$f" ] && echo 1 > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cpu-performance.service
  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null \
    || info "cpufreq not available (VM passthrough)"
}
run_always "step10_cpu" _step10

# =============================================================================
hdr "STEP 11 — SYSTEM LIMITS"
_step11() {
  cat > /etc/security/limits.d/99-xui.conf << 'EOF'
*    soft nofile   2097152
*    hard nofile   2097152
*    soft nproc    131072
*    hard nproc    131072
*    soft memlock  unlimited
*    hard memlock  unlimited
*    soft stack    134217728
*    hard stack    134217728
root soft nofile   2097152
root hard nofile   2097152
root soft nproc    131072
root hard nproc    131072
root soft memlock  unlimited
root hard memlock  unlimited
EOF
  local pam
  for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam" ] || continue
    grep -qxF 'session required pam_limits.so' "$pam" \
      || echo 'session required pam_limits.so' >> "$pam"
  done
  cat /etc/security/limits.d/99-xui.conf
}
run_always "step11_limits" _step11

# =============================================================================
hdr "STEP 12 — IRQBALANCE"
_step12() {
  if command -v irqbalance &>/dev/null; then
    cat > /etc/default/irqbalance << 'EOF'
ENABLED=1
ONESHOT=0
OPTIONS="--powerthresh=0 --deepestcache=1"
EOF
    systemctl enable --now irqbalance 2>/dev/null || true
    systemctl status irqbalance --no-pager
  else
    warn "irqbalance not installed"
  fi
}
run_always "step12_irq" _step12

# =============================================================================
hdr "STEP 13 — SYSTEMD JOURNALD + TMPFS"
_step13() {
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-performance.conf << 'EOF'
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=64M
RuntimeMaxUse=64M
RateLimitIntervalSec=0
RateLimitBurst=0
Seal=no
ReadKMsg=no
EOF
  systemctl restart systemd-journald

  if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
    echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=256m 0 0" >> /etc/fstab
    mount -o remount /tmp 2>/dev/null || true
  fi

  cat > /etc/systemd/system/clear-tmp.service << 'EOF'
[Unit]
Description=Clear /tmp on boot
DefaultDependencies=no
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'find /tmp -mindepth 1 -delete 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
  systemctl daemon-reload
  systemctl enable clear-tmp.service
  info "journald volatile + tmpfs /tmp 256MB"
}
run_always "step13_journald_tmpfs" _step13

# =============================================================================
hdr "STEP 14 — DNS RESOLVER OPTIMIZE"
_step14() {
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-fast.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 1.0.0.1 8.8.4.4
FallbackDNS=9.9.9.9 149.112.112.112
DNSSEC=no
DNSOverTLS=no
Cache=yes
CacheFromLocalhost=yes
DNSStubListener=yes
ReadEtcHosts=yes
EOF
  systemctl enable --now systemd-resolved 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || true
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
  info "DNS: 1.1.1.1 + 8.8.8.8 cache+stub active"
}
run_always "step14_dns" _step14

# =============================================================================
hdr "STEP 15 — x-ui SYSTEMD OVERRIDE"
_step15() {
  local xui_bin
  xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
  [ -x "$xui_bin" ] || { warn "x-ui binary not found — skipping override"; return 0; }

  local xui_pid rss_mb gogc_val gomemlimit_val ram_avail_mb
  xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  rss_mb=70
  [ -n "$xui_pid" ] && rss_mb=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$xui_pid"/status 2>/dev/null || echo 70)

  ram_avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  gomemlimit_val=$(( ram_avail_mb - rss_mb - 100 ))
  [ "$gomemlimit_val" -lt 400 ] && gomemlimit_val=400

  if [ "$rss_mb" -lt 100 ]; then
    gogc_val=150
  elif [ "$rss_mb" -lt 200 ]; then
    gogc_val=100
  else
    gogc_val=50
  fi

  info "GOGC=${gogc_val} GOMEMLIMIT=${gomemlimit_val}MiB (RSS=${rss_mb}MB)"

  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=2097152
LimitNPROC=131072
LimitMEMLOCK=infinity
LimitCORE=infinity
LimitSTACK=134217728
Restart=always
RestartSec=1
RestartPreventExitStatus=0
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=${gogc_val}
Environment=GODEBUG=madvdontneed=1 asyncpreemptoff=0 gccheckmark=0
Environment=GOMEMLIMIT=${gomemlimit_val}MiB
Environment=GOGCTRACE=0
OOMScoreAdjust=-1000
MemoryHigh=${XUI_MEM_HIGH}
MemoryMax=${XUI_MEM_MAX}
MemorySwapMax=${XUI_MEM_SWAP}
CPUSchedulingPolicy=other
CPUSchedulingPriority=0
CPUWeight=10000
IOSchedulingClass=best-effort
IOSchedulingPriority=0
IOWeight=10000
Nice=-20
TasksMax=infinity
EOF
  systemctl daemon-reload
  systemctl restart x-ui
  wait_active x-ui 30 || warn "x-ui not active after override"
  systemctl status x-ui --no-pager
}
run_always "step15_xui_override" _step15

# =============================================================================
hdr "STEP 16 — x-ui CAPABILITIES + MEMORY LOCK"
_step16() {
  local xui_bin
  xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
  if [ -x "$xui_bin" ]; then
    setcap 'cap_net_admin,cap_net_bind_service,cap_net_raw,cap_ipc_lock+eip' "$xui_bin" 2>/dev/null \
      && info "x-ui capabilities set" || warn "setcap failed"
  fi
  local xui_xray
  xui_xray=$(find /usr/local/x-ui /root/.x-ui -name "xray" -type f 2>/dev/null | head -1 || true)
  if [ -n "$xui_xray" ] && [ -x "$xui_xray" ]; then
    setcap 'cap_net_admin,cap_net_bind_service,cap_net_raw,cap_ipc_lock+eip' "$xui_xray" 2>/dev/null \
      && info "xray capabilities set: ${xui_xray}" || true
  fi
}
run_always "step16_capabilities" _step16

# =============================================================================
hdr "STEP 17 — IONICE + PROCESS PRIORITY"
_step17() {
  local xui_pid
  xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  if [ -n "$xui_pid" ]; then
    renice -n -20 -p "$xui_pid"     2>/dev/null || true
    ionice  -c 1 -n 0 -p "$xui_pid" 2>/dev/null || true
    chrt    -b -p 1   "$xui_pid"    2>/dev/null || true
    taskset -cp 0     "$xui_pid"    2>/dev/null || true
    info "x-ui pid=${xui_pid}: nice=-20 ionice=realtime:0 chrt=batch taskset=cpu0"
  else
    warn "x-ui not running — skip ionice"
  fi

  cat > /etc/systemd/system/xui-ionice.service << 'EOF'
[Unit]
Description=Set x-ui ionice + sched priority
After=x-ui.service
Requires=x-ui.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'PID=$(pgrep -x x-ui | head -1); [ -n "$PID" ] || exit 0; renice -n -20 -p "$PID" 2>/dev/null || true; ionice -c 1 -n 0 -p "$PID" 2>/dev/null || true; chrt -b -p 1 "$PID" 2>/dev/null || true; taskset -cp 0 "$PID" 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xui-ionice.service 2>/dev/null || true
}
run_always "step17_ionice" _step17

# =============================================================================
hdr "STEP 18 — x-ui DATABASE WAL MODE + OPTIMIZE"
_step18() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — skip"; return 0; }
  command -v sqlite3 &>/dev/null || { warn "sqlite3 not found"; return 1; }

  sqlite3 "$db" "PRAGMA journal_mode=WAL;"       2>/dev/null || true
  sqlite3 "$db" "PRAGMA synchronous=NORMAL;"      2>/dev/null || true
  sqlite3 "$db" "PRAGMA cache_size=-65536;"       2>/dev/null || true
  sqlite3 "$db" "PRAGMA temp_store=MEMORY;"       2>/dev/null || true
  sqlite3 "$db" "PRAGMA mmap_size=268435456;"     2>/dev/null || true
  sqlite3 "$db" "PRAGMA page_size=4096;"          2>/dev/null || true
  sqlite3 "$db" "PRAGMA wal_autocheckpoint=1000;" 2>/dev/null || true
  sqlite3 "$db" "VACUUM;"                         2>/dev/null || true
  sqlite3 "$db" "ANALYZE;"                        2>/dev/null || true

  local journal_mode
  journal_mode=$(sqlite3 "$db" "PRAGMA journal_mode;" 2>/dev/null || echo "unknown")
  info "SQLite journal_mode=${journal_mode}"

  cat > /etc/systemd/system/xui-db-wal.service << EOF
[Unit]
Description=x-ui SQLite WAL checkpoint
After=x-ui.service

[Service]
Type=oneshot
ExecStart=/usr/bin/sqlite3 ${db} "PRAGMA wal_checkpoint(TRUNCATE);"
EOF

  cat > /etc/systemd/system/xui-db-wal.timer << 'EOF'
[Unit]
Description=x-ui SQLite WAL checkpoint every 30min

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xui-db-wal.timer
  info "SQLite WAL + mmap 256MB + cache 64MB applied"
}
run_always "step18_sqlite_wal" _step18

# =============================================================================
hdr "STEP 19 — XRAY LOG DISABLE"
_step19() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — skip"; return 0; }
  command -v sqlite3 &>/dev/null || { warn "sqlite3 not found"; return 1; }

  local template
  template=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || true)
  if [ -n "$template" ]; then
    local new_template
    new_template=$(printf '%s' "$template" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['log'] = {'access': 'none', 'error': '', 'loglevel': 'none', 'dnsLog': False}
print(json.dumps(d, separators=(',',':')))
" 2>/dev/null || true)
    if [ -n "$new_template" ]; then
      local new_escaped="${new_template//\'/\'\'}"
      sqlite3 "$db" "UPDATE settings SET value='${new_escaped}' WHERE key='xrayTemplateConfig';" 2>/dev/null || true
      info "xray log level → none"
    fi
  fi
  systemctl restart x-ui 2>/dev/null || true
}
run_always "step19_xray_nolog" _step19

# =============================================================================
hdr "STEP 20 — XRAY SOCKOPT PATCH (VMESS WS port 80)"
_step20() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — create inbound first then re-run"; return 0; }
  command -v sqlite3 &>/dev/null || { warn "sqlite3 not found"; return 1; }

  local sockopt
  sockopt='{"acceptProxyProtocol":false,"tcpFastOpen":true,"mark":0,"tproxy":"off","tcpMptcp":false,"penetrate":false,"domainStrategy":"AsIs","tcpMaxSeg":1440,"dialerProxy":"","tcpKeepAliveInterval":35,"tcpKeepAliveIdle":35,"tcpUserTimeout":30000,"tcpcongestion":"bbr","V6Only":false,"tcpWindowClamp":0,"interface":"","trustedXForwardedFor":[],"addressPortStrategy":"none","customSockopt":[],"tcpNoDelay":true}'

  local count
  count=$(sqlite3 "$db" "SELECT COUNT(*) FROM inbounds WHERE port=80 AND protocol='vmess';" 2>/dev/null || echo "0")

  if [ "$count" -gt 0 ]; then
    local stream_settings new_stream
    stream_settings=$(sqlite3 "$db" "SELECT stream_settings FROM inbounds WHERE port=80 AND protocol='vmess' LIMIT 1;" 2>/dev/null || true)
    if [ -n "$stream_settings" ]; then
      new_stream=$(printf '%s' "$stream_settings" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['sockopt'] = json.loads(sys.argv[1])
print(json.dumps(d, separators=(',',':')))
" "$sockopt" 2>/dev/null || true)
      if [ -n "$new_stream" ]; then
        local new_stream_escaped="${new_stream//\'/\'\'}"
        sqlite3 "$db" "UPDATE inbounds SET stream_settings='${new_stream_escaped}' WHERE port=80 AND protocol='vmess';"
        info "sockopt patched on vmess port 80"
      else
        warn "python3 parse failed — sockopt not patched"
      fi
    fi
  else
    warn "no vmess port 80 inbound found — create inbound in panel then re-run"
    warn "sockopt JSON to apply manually:"
    echo "${sockopt}"
  fi
  systemctl restart x-ui 2>/dev/null || true
}
run_always "step20_sockopt" _step20

# =============================================================================
hdr "STEP 21 — WATCHDOG + AUTO-RECOVERY"
_step21() {
  cat > /usr/local/bin/xui-watchdog.sh << 'WEOF'
#!/usr/bin/env bash
set -uo pipefail
LOG="/var/log/xui-watchdog.log"
MAX_RSS_MB=1400
RESTART_COOL=60

ts() { date '+%Y-%m-%d %H:%M:%S'; }

while true; do
  sleep 30
  XUI_PID=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  if [ -z "$XUI_PID" ]; then
    echo "$(ts) [WARN] x-ui not running — restarting" >> "$LOG"
    systemctl restart x-ui 2>/dev/null || true
    sleep "$RESTART_COOL"
    continue
  fi
  RSS_MB=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$XUI_PID"/status 2>/dev/null || echo 0)
  if [ "$RSS_MB" -gt "$MAX_RSS_MB" ]; then
    echo "$(ts) [WARN] RSS=${RSS_MB}MB > ${MAX_RSS_MB}MB — restarting x-ui" >> "$LOG"
    systemctl restart x-ui 2>/dev/null || true
    sleep "$RESTART_COOL"
    continue
  fi
  AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
  if [ "$AVAIL_MB" -lt 50 ]; then
    echo "$(ts) [WARN] RAM avail=${AVAIL_MB}MB < 50MB — drop caches" >> "$LOG"
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi
done
WEOF
  chmod +x /usr/local/bin/xui-watchdog.sh

  cat > /etc/systemd/system/xui-watchdog.service << 'EOF'
[Unit]
Description=x-ui Memory Watchdog + Auto-Recovery
After=x-ui.service
Requires=x-ui.service

[Service]
Type=simple
ExecStart=/usr/local/bin/xui-watchdog.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xui-watchdog.service
  info "watchdog: check every 30s restart if RSS>1400MB or crash"
}
run_always "step21_watchdog" _step21

# =============================================================================
hdr "STEP 22 — PERF SNAPSHOT (ทุก 5 นาที)"
_step22() {
  cat > /usr/local/bin/xui-perf-snap.sh << 'PEOF'
#!/usr/bin/env bash
set -uo pipefail
LOG="/var/log/xui-perf.log"
MAX_LINES=1000

ts() { date '+%Y-%m-%d %H:%M:%S'; }
trim_log() {
  [ -f "$LOG" ] || return
  local lines
  lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
  [ "$lines" -gt "$MAX_LINES" ] && tail -n "$MAX_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
}
trim_log
XUI_PID=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
RSS_MB=0; CPU_PCT="0"
if [ -n "$XUI_PID" ]; then
  RSS_MB=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$XUI_PID"/status 2>/dev/null || echo 0)
  CPU_PCT=$(ps -p "$XUI_PID" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0")
fi
AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
CONN=$(ss -s 2>/dev/null | awk '/estab/ {print $4}' | tr -d ',' || echo "?")
echo "$(ts) | PID=${XUI_PID:-none} RSS=${RSS_MB}MB CPU=${CPU_PCT}% RAM_avail=${AVAIL_MB}MB CC=${CC} ESTAB=${CONN}" >> "$LOG"
PEOF
  chmod +x /usr/local/bin/xui-perf-snap.sh

  cat > /etc/systemd/system/xui-perf-snap.service << 'EOF'
[Unit]
Description=x-ui Performance Snapshot

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xui-perf-snap.sh
EOF

  cat > /etc/systemd/system/xui-perf-snap.timer << 'EOF'
[Unit]
Description=x-ui Performance Snapshot every 5min

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xui-perf-snap.timer
  info "perf snapshot: /var/log/xui-perf.log"
}
run_always "step22_perf_snap" _step22

# =============================================================================
hdr "STEP 23 — PERSIST VERIFY (reboot-safe check)"
_step23() {
  local errors=0

  # ── helper: check service is enabled ──────────────────────────────────────
  _chk_svc() {
    systemctl is-enabled "$1" &>/dev/null \
      || { warn "$1 not enabled"; errors=$(( errors + 1 )); }
  }

  _chk_svc thp-disable.service
  _chk_svc nic-tune.service
  _chk_svc cpu-performance.service
  _chk_svc x-ui
  _chk_svc xui-watchdog.service
  _chk_svc xui-perf-snap.timer
  _chk_svc xui-db-wal.timer

  # ── helper: assert expected value ─────────────────────────────────────────
  _chk_val() {
    local label="$1" result="$2" expected="$3"
    if echo "$result" | grep -qF "$expected"; then
      ok "  ${label}: ${result}"
    else
      warn "  ${label}: got='${result}' expected~='${expected}'"
      errors=$(( errors + 1 ))
    fi
  }

  # ── file presence checks ───────────────────────────────────────────────────
  [ -f /etc/sysctl.d/99-ais-vmess-tune.conf ]               || { warn "sysctl conf missing";          errors=$(( errors + 1 )); }
  [ -f /etc/security/limits.d/99-xui.conf ]                 || { warn "limits conf missing";           errors=$(( errors + 1 )); }
  [ -f /etc/udev/rules.d/60-io-scheduler.rules ]            || { warn "io scheduler rules missing";    errors=$(( errors + 1 )); }
  [ -f /etc/networkd-dispatcher/routable.d/50-nic-tune.sh ] || { warn "nic-tune script missing";       errors=$(( errors + 1 )); }
  [ -f /etc/systemd/system/x-ui.service.d/override.conf ]   || { warn "x-ui override missing";         errors=$(( errors + 1 )); }
  grep -q '/swapfile' /etc/fstab                            || { warn "swapfile not in fstab";          errors=$(( errors + 1 )); }
  swapon --show | grep -q '/swapfile'                       || { warn "swapfile not active";            errors=$(( errors + 1 )); }

  # ── live value checks ─────────────────────────────────────────────────────
  _chk_val "BBR CC"                "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"        "bbr"
  _chk_val "FQ qdisc"              "$(tc qdisc show dev "$NIC" 2>/dev/null | head -1)"                "fq"
  _chk_val "THP"                   "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"   "never"
  _chk_val "x-ui active"           "$(systemctl is-active x-ui 2>/dev/null)"                          "active"
  _chk_val "ip_forward"            "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"                     "1"
  _chk_val "slow_start_after_idle" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"      "0"
  _chk_val "watchdog active"       "$(systemctl is-active xui-watchdog.service 2>/dev/null)"          "active"
  _chk_val "perf-snap timer"       "$(systemctl is-active xui-perf-snap.timer 2>/dev/null)"           "active"

  # ── live stats ────────────────────────────────────────────────────────────
  local xui_pid rss_mb
  xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  rss_mb=0
  [ -n "$xui_pid" ] && rss_mb=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$xui_pid"/status 2>/dev/null || echo 0)
  info "x-ui RSS live  : ${rss_mb}MB"
  info "RAM avail      : $(free -m | awk '/^Mem:/ {print $7}')MB"
  info "Established    : $(ss -s 2>/dev/null | awk '/estab/ {print $4}' | tr -d ',' || echo '?') connections"
  info "Kernel         : $(uname -r)"

  echo ""
  if [ "$errors" -eq 0 ]; then
    ok "ALL checks passed — system fully tuned — safe to reboot"
  else
    warn "${errors} issue(s) found — review above"
    return 1
  fi
}
run_always "step23_verify" _step23

# =============================================================================
hdr "DONE — FULL SUMMARY"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps completed:${RST}"
while IFS= read -r line; do
  [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  ${line}"
done < "$STATE_FILE"

echo ""
echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Panel URL       :${RST} https://peepo-team.ddnsking.com:${PANEL_PORT}/"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Protocol        :${RST} VMESS WebSocket port 80 None TLS"
echo -e "  ${BLD}Host header     :${RST} speedtest.net"
echo -e "  ${BLD}Path            :${RST} /VMESS"
echo -e "  ${BLD}AlterID         :${RST} 0"
echo -e "  ${BLD}Sniffing        :${RST} ปิดทั้งหมด"
echo -e "  ${BLD}tcpMaxSeg       :${RST} 1440"
echo -e "  ${BLD}tcpNoDelay      :${RST} true"
echo -e "  ${BLD}tcpFastOpen     :${RST} true"
echo -e "  ${BLD}tcpKeepAliveIdle:${RST} 35"
echo -e "  ${BLD}tcpUserTimeout  :${RST} 30000"
echo -e "  ${BLD}tcpcongestion   :${RST} bbr"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}BBR             :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Qdisc           :${RST} $(tc qdisc show dev "$NIC" 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP             :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}CPU governor    :${RST} $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui status     :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Perf log        :${RST} tail -f /var/log/xui-perf.log"
echo -e "  ${BLD}Watchdog log    :${RST} journalctl -u xui-watchdog -f"
echo -e "  ${BLD}Install log     :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""
echo -e "  ${BLD}${YEL}→ สร้าง VMESS inbound ใน panel แล้วรัน script อีกครั้งเพื่อ patch sockopt${RST}"
echo -e "  ${BLD}${YEL}→ reboot เพื่อ confirm ทุก setting persistent${RST}"
echo ""
