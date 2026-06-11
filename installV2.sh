cat > /mnt/user-data/outputs/install.sh << 'ENDOFSCRIPT'
#!/usr/bin/env bash
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

STATE_DIR="/var/lib/ais-reality-setup"
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
echo -e "${BLD}${CYN}║  Bughost VPN Pole — VLESS REALITY SETUP v10.0            ║${RST}"
echo -e "${BLD}${CYN}║  40 Steps · REALITY port 443 · Max Security              ║${RST}"
echo -e "${BLD}${CYN}║  NIC: ${NIC}$(printf '%*s' $((51-${#NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
info "RAM: ${RAM_MB}MB  vCPU: ${VCPU}  NIC: ${NIC} MTU ${MTU_PHYSICAL}"
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
    linux-tools-common linux-tools-generic nftables libcap2-bin \
    numactl schedtool fail2ban auditd aide rkhunter \
    apparmor apparmor-utils libpam-pwquality \
    unattended-upgrades knockd chrony logwatch \
    python3 attr 2>/dev/null || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw ethtool sqlite3 irqbalance iproute2 iputils-ping \
    nftables libcap2-bin fail2ban auditd python3 chrony
}
run_skip "step1_deps" _step1

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
  swapon --show; free -h
}
run_skip "step2_swap" _step2

hdr "STEP 3 — FIREWALL"
_step3() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny forward
  ufw limit 22/tcp
  ufw allow 443/tcp
  ufw deny "${PANEL_PORT}/tcp"
  ufw deny 23/tcp
  ufw deny 25/tcp
  ufw deny 3389/tcp
  ufw deny 5900/tcp
  ufw --force enable
  ufw status verbose
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
    "rpcbind" "nfs-server"
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

hdr "STEP 6 — KERNEL SECURITY HARDENING"
_step6() {
  cat > /etc/sysctl.d/99-security-harden.conf << 'EOF'
kernel.kptr_restrict                       = 2
kernel.dmesg_restrict                      = 1
kernel.perf_event_paranoid                 = 3
kernel.unprivileged_bpf_disabled           = 1
net.core.bpf_jit_harden                   = 2
fs.suid_dumpable                           = 0
kernel.core_uses_pid                       = 1
kernel.yama.ptrace_scope                   = 2
kernel.randomize_va_space                  = 2
kernel.sysrq                               = 0
fs.protected_hardlinks                     = 1
fs.protected_symlinks                      = 1
fs.protected_fifos                         = 2
fs.protected_regular                       = 2
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv6.conf.all.accept_redirects         = 0
net.ipv6.conf.default.accept_redirects     = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.default.send_redirects       = 0
net.ipv4.conf.all.accept_source_route      = 0
net.ipv4.conf.default.accept_source_route  = 0
net.ipv6.conf.all.accept_source_route      = 0
net.ipv4.conf.all.log_martians             = 1
net.ipv4.conf.default.log_martians         = 1
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                    = 1
net.ipv4.conf.all.secure_redirects         = 0
net.ipv4.conf.default.secure_redirects     = 0
net.ipv6.conf.all.accept_ra                = 0
net.ipv6.conf.default.accept_ra            = 0
net.ipv4.tcp_rfc1337                       = 1
EOF
  sysctl -p /etc/sysctl.d/99-security-harden.conf
  info "kernel security hardening applied"
}
run_always "step6_kernel_security" _step6

hdr "STEP 7 — TRANSPARENT HUGE PAGES off"
_step7() {
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
run_always "step7_thp" _step7

hdr "STEP 8 — TCP / VM / CONNTRACK TUNE"
_step8() {
  modprobe tcp_bbr     2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true
  local cc="bbr"
  grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
    || { warn "BBR unavailable — fallback cubic"; cc="cubic"; }
  local qdisc="fq"
  modinfo sch_fq &>/dev/null || { warn "fq unavailable — fallback fq_codel"; qdisc="fq_codel"; }
  local has_notsent=0
  [ -f /proc/sys/net/ipv4/tcp_notsent_lowat ] && has_notsent=1
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
kernel.threads-max                     = 262144
kernel.panic                           = 10
kernel.panic_on_oops                   = 1
EOF
    [ "$has_notsent" = "1" ] && echo "net.ipv4.tcp_notsent_lowat             = ${NOTSENT_LOWAT}"
    [ -f /proc/sys/net/ipv4/tcp_fack ]                  && echo "net.ipv4.tcp_fack                        = 1"
    [ -f /proc/sys/net/ipv4/tcp_low_latency ]           && echo "net.ipv4.tcp_low_latency                 = 1"
    [ -f /proc/sys/vm/numa_balancing ]                  && echo "vm.numa_balancing                        = 0"
    [ -f /proc/sys/kernel/sched_min_granularity_ns ]    && echo "kernel.sched_min_granularity_ns          = 500000"
    [ -f /proc/sys/kernel/sched_wakeup_granularity_ns ] && echo "kernel.sched_wakeup_granularity_ns       = 50000"
    [ -f /proc/sys/kernel/sched_latency_ns ]            && echo "kernel.sched_latency_ns                  = 4000000"
    [ -f /proc/sys/kernel/sched_migration_cost_ns ]     && echo "kernel.sched_migration_cost_ns           = 50000"
    [ -f /proc/sys/kernel/sched_nr_migrate ]            && echo "kernel.sched_nr_migrate                  = 8"
    [ -f /proc/sys/kernel/nmi_watchdog ]                && echo "kernel.nmi_watchdog                      = 0"
    [ -f /proc/sys/kernel/watchdog ]                    && echo "kernel.watchdog                          = 0"
  } > /etc/sysctl.d/99-ais-reality-tune.conf
  sysctl -p /etc/sysctl.d/99-ais-reality-tune.conf
  local ct_max=131072
  echo "$ct_max" > /proc/sys/net/netfilter/nf_conntrack_max                     2>/dev/null || true
  echo 0         > /proc/sys/net/netfilter/nf_conntrack_checksum                2>/dev/null || true
  echo 600       > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
  echo 20        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait   2>/dev/null || true
  echo 10        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait  2>/dev/null || true
  echo 10        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_fin_wait    2>/dev/null || true
  echo 5         > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_last_ack    2>/dev/null || true
  echo 1         > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal          2>/dev/null || true
  cat >> /etc/sysctl.d/99-ais-reality-tune.conf << EOF
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
run_always "step8_sysctl_conntrack" _step8

hdr "STEP 9 — NIC TUNE"
_step9() {
  ip link show "$NIC"
  local qdisc="fq"
  grep -q "default_qdisc.*fq_codel" /etc/sysctl.d/99-ais-reality-tune.conf 2>/dev/null \
    && qdisc="fq_codel"
  ethtool -K "$NIC" gro on lro off tso on gso on             2>/dev/null || warn "ethtool offload: partial"
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
  ethtool -G "$NIC" rx "$rx_max" tx "$tx_max" 2>/dev/null && info "ring buffer rx=${rx_max} tx=${tx_max}" || true
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
  fi
  mkdir -p /etc/networkd-dispatcher/routable.d
  cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
set -uo pipefail
NIC="${NIC}"; QDISC="${qdisc}"; RX_MAX="${rx_max}"; TX_MAX="${tx_max}"
TC_QUANTUM="${TC_QUANTUM}"; TC_BUCKETS="${TC_BUCKETS}"; EFFECTIVE_MTU="${EFFECTIVE_MTU}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro on lro off tso on gso on 2>/dev/null || true
ethtool -K "\${NIC}" rx-gro-hw off 2>/dev/null || true
ethtool -K "\${NIC}" rx-vlan-offload off tx-vlan-offload off 2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}" 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50 adaptive-rx on adaptive-tx on 2>/dev/null || \
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50 2>/dev/null || true
ip link set "\${NIC}" mtu "\${EFFECTIVE_MTU}" 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 10000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} limit 10000 2>/dev/null || \
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} 2>/dev/null || true
CPU_COUNT=\$(nproc 2>/dev/null || echo 1)
RPS_MASK=\$(printf '%x' \$(( (1 << CPU_COUNT) - 1 )))
echo "\${RPS_MASK}" > /sys/class/net/"\${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true
[ -f /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
[ -f /sys/class/net/"\${NIC}"/queues/rx-0/rps_flow_cnt ] && echo 32768 > /sys/class/net/"\${NIC}"/queues/rx-0/rps_flow_cnt 2>/dev/null || true
NEOF
  chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh
  cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC Tuning — ${NIC}
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
}
run_always "step9_nic" _step9

hdr "STEP 10 — I/O SCHEDULER"
_step10() {
  local found=0 DEV rot
  for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/${DEV}" ] || continue
    found=1
    rot=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
    if [ "$rot" = "0" ]; then
      echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
    else
      echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
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
run_always "step10_io" _step10

hdr "STEP 11 — CPU GOVERNOR"
_step11() {
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
run_always "step11_cpu" _step11

hdr "STEP 12 — SYSTEM LIMITS"
_step12() {
  cat > /etc/security/limits.d/99-xui.conf << 'EOF'
*    soft nofile   2097152
*    hard nofile   2097152
*    soft nproc    131072
*    hard nproc    131072
*    soft memlock  unlimited
*    hard memlock  unlimited
*    soft core     0
*    hard core     0
*    soft stack    134217728
*    hard stack    134217728
root soft nofile   2097152
root hard nofile   2097152
root soft nproc    131072
root hard nproc    131072
root soft memlock  unlimited
root hard memlock  unlimited
root soft core     0
root hard core     0
EOF
  local pam
  for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam" ] || continue
    grep -qxF 'session required pam_limits.so' "$pam" \
      || echo 'session required pam_limits.so' >> "$pam"
  done
}
run_always "step12_limits" _step12

hdr "STEP 13 — IRQBALANCE"
_step13() {
  if command -v irqbalance &>/dev/null; then
    cat > /etc/default/irqbalance << 'EOF'
ENABLED=1
ONESHOT=0
OPTIONS="--powerthresh=0 --deepestcache=1"
EOF
    systemctl enable --now irqbalance 2>/dev/null || true
  fi
}
run_always "step13_irq" _step13

hdr "STEP 14 — JOURNALD + TMPFS"
_step14() {
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
    echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,size=256m 0 0" >> /etc/fstab
    mount -o remount /tmp 2>/dev/null || true
  fi
  if ! grep -q "tmpfs /dev/shm" /etc/fstab 2>/dev/null; then
    echo "tmpfs /dev/shm tmpfs defaults,noatime,nosuid,nodev,noexec,size=128m 0 0" >> /etc/fstab
    mount -o remount /dev/shm 2>/dev/null || true
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
  info "/tmp noexec,nosuid,nodev · /dev/shm noexec"
}
run_always "step14_journald_tmpfs" _step14

hdr "STEP 15 — DNS"
_step15() {
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-fast.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
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
}
run_always "step15_dns" _step15

hdr "STEP 16 — CHRONY TIME SYNC"
_step16() {
  command -v chronyc &>/dev/null || { warn "chrony not installed — skip"; return 0; }
  cat > /etc/chrony/chrony.conf << 'EOF'
pool time.cloudflare.com iburst maxsources 4
pool ntp.ubuntu.com iburst maxsources 4
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logchange 0.5
EOF
  systemctl enable --now chrony 2>/dev/null || true
  systemctl restart chrony 2>/dev/null || true
  sleep 2
  chronyc tracking 2>/dev/null | head -5 || true
  info "chrony time sync active (required for REALITY TLS)"
}
run_always "step16_chrony" _step16

hdr "STEP 17 — SSH HARDENING"
_step17() {
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardened.conf << 'EOF'
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 20
ClientAliveInterval 120
ClientAliveCountMax 3
AllowTcpForwarding no
X11Forwarding no
PermitUserEnvironment no
AllowAgentForwarding no
PermitEmptyPasswords no
Banner none
PrintLastLog yes
UsePAM yes
StrictModes yes
IgnoreRhosts yes
HostbasedAuthentication no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
EOF
  [ -f /etc/ssh/ssh_host_ed25519_key ] \
    || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" 2>/dev/null || true
  if sshd -t 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    info "SSH hardened — publickey-only + strong ciphers"
  else
    warn "sshd config test failed — not reloading"
  fi
}
run_always "step17_ssh_harden" _step17

hdr "STEP 18 — FAIL2BAN"
_step18() {
  mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d
  cat > /etc/fail2ban/filter.d/xui-panel.conf << 'EOF'
[Definition]
failregex = .*login.*fail.*<HOST>
            .*authentication.*fail.*<HOST>
ignoreregex =
EOF
  cat > /etc/fail2ban/jail.d/99-xui.conf << EOF
[DEFAULT]
bantime  = 3600
findtime = 300
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 86400

[xui-panel]
enabled  = true
port     = ${PANEL_PORT}
filter   = xui-panel
logpath  = /var/lib/ais-reality-setup/install.log
maxretry = 5
bantime  = 3600
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  info "fail2ban: SSH 24h ban / panel 1h ban"
}
run_always "step18_fail2ban" _step18

hdr "STEP 19 — CROWDSEC"
_step19() {
  if ! command -v cscli &>/dev/null; then
    curl -fsSL https://packagecloud.io/crowdsec/crowdsec/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/crowdsec-archive-keyring.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/ubuntu $(lsb_release -cs 2>/dev/null || echo jammy) main" \
      > /etc/apt/sources.list.d/crowdsec.list 2>/dev/null || true
    apt-get update -y 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec 2>/dev/null \
      || { warn "crowdsec install failed — skip"; return 0; }
  fi
  cscli collections install crowdsecurity/linux 2>/dev/null || true
  cscli collections install crowdsecurity/sshd  2>/dev/null || true
  systemctl enable --now crowdsec 2>/dev/null || true
  systemctl restart crowdsec 2>/dev/null || true
  info "CrowdSec: crowdsourced IP blocklist active"
}
run_always "step19_crowdsec" _step19

hdr "STEP 20 — AUDITD"
_step20() {
  cat > /etc/audit/rules.d/99-xui-security.rules << 'EOF'
-D
-b 8192
-f 1
-w /usr/local/x-ui/x-ui -p x -k xui_exec
-w /usr/local/x-ui/bin/ -p x -k xray_exec
-w /etc/x-ui/ -p wa -k xui_config
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/sudoers -p wa -k sudoers
-w /etc/passwd -p wa -k passwd_change
-w /etc/shadow -p wa -k shadow_change
-a always,exit -F path=/usr/bin/sudo -F perm=x -k sudo_use
-a always,exit -F path=/usr/bin/su   -F perm=x -k su_use
-a always,exit -F arch=b64 -S sethostname -S setdomainname -k net_config
-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k module_load
-a always,exit -F arch=b64 -S connect -k outbound_connect
EOF
  augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-xui-security.rules 2>/dev/null || true
  systemctl enable --now auditd
  systemctl restart auditd 2>/dev/null || true
}
run_always "step20_auditd" _step20

hdr "STEP 21 — APPARMOR PROFILE"
_step21() {
  command -v aa-status &>/dev/null || { warn "apparmor not available — skip"; return 0; }
  systemctl enable --now apparmor 2>/dev/null || true
  local xui_bin="/usr/local/x-ui/x-ui"
  [ -x "$xui_bin" ] || { warn "x-ui binary not found — skip"; return 0; }
  cat > /etc/apparmor.d/usr.local.x-ui.x-ui << 'EOF'
#include <tunables/global>
/usr/local/x-ui/x-ui {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  capability net_admin,
  capability net_bind_service,
  capability net_raw,
  capability ipc_lock,
  capability sys_resource,
  network inet  stream,
  network inet6 stream,
  network inet  dgram,
  network inet6 dgram,
  network inet  raw,
  network netlink raw,
  /usr/local/x-ui/x-ui       mr,
  /usr/local/x-ui/bin/**     mrx,
  /usr/local/x-ui/**         rw,
  /etc/x-ui/**               rw,
  /var/lib/ais-reality-setup/ rw,
  /var/lib/ais-reality-setup/** rw,
  /tmp/**                    rw,
  /proc/sys/net/**           r,
  /proc/*/net/**             r,
  /proc/*/status             r,
  /sys/kernel/mm/**          r,
  /dev/null                  rw,
  /dev/urandom               r,
  /dev/random                r,
  deny /etc/shadow r,
  deny /root/.ssh/ r,
  deny /home/**/.ssh/ r,
}
EOF
  apparmor_parser -r /etc/apparmor.d/usr.local.x-ui.x-ui 2>/dev/null \
    && info "AppArmor profile loaded" || warn "AppArmor profile load failed (non-fatal)"
}
run_always "step21_apparmor" _step21

hdr "STEP 22 — IMMUTABLE LOGS"
_step22() {
  local f
  for f in /var/lib/ais-reality-setup/install.log \
            /var/log/xui-watchdog.log \
            /var/log/xui-perf.log \
            /var/log/auth.log; do
    touch "$f" 2>/dev/null || true
    chattr +a "$f" 2>/dev/null && info "chattr +a ${f}" || warn "chattr +a ${f} failed (non-fatal)"
  done
}
run_always "step22_immutable_logs" _step22

hdr "STEP 23 — RESTRICT /proc"
_step23() {
  if ! grep -q "hidepid=2" /etc/fstab 2>/dev/null; then
    sed -i 's|^\(proc\s.*defaults\)|\1,hidepid=2,gid=0|' /etc/fstab 2>/dev/null || true
    mount -o remount,hidepid=2,gid=0 /proc 2>/dev/null \
      && info "/proc hidepid=2" \
      || warn "/proc remount failed (applied after reboot)"
  else
    info "/proc hidepid=2 already set"
  fi
}
run_always "step23_proc_restrict" _step23

hdr "STEP 24 — SECURE SHARED MEMORY"
_step24() {
  if ! grep -q "tmpfs /run/shm" /etc/fstab 2>/dev/null && \
     ! grep -q "tmpfs /dev/shm" /etc/fstab 2>/dev/null; then
    echo "tmpfs /dev/shm tmpfs defaults,noatime,nosuid,nodev,noexec,size=128m 0 0" >> /etc/fstab
  fi
  mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null \
    && info "/dev/shm remounted noexec,nosuid,nodev" \
    || warn "/dev/shm remount failed (applied after reboot)"
}
run_always "step24_secure_shm" _step24

hdr "STEP 25 — REMOVE SUID FROM UNUSED BINARIES"
_step25() {
  local suid_list=(
    /usr/bin/at
    /usr/bin/newgrp
    /usr/bin/chage
    /usr/bin/expiry
    /usr/bin/wall
    /usr/bin/write
    /usr/bin/sg
    /sbin/unix_chkpwd
    /usr/lib/openssh/ssh-keysign
  )
  local b
  for b in "${suid_list[@]}"; do
    [ -f "$b" ] || continue
    chmod a-s "$b" 2>/dev/null && info "removed SUID: ${b}" || true
  done
  info "SUID cleanup done"
}
run_always "step25_suid_cleanup" _step25

hdr "STEP 26 — RESTRICT CRON"
_step26() {
  echo root > /etc/cron.allow  2>/dev/null || true
  echo root > /etc/at.allow    2>/dev/null || true
  rm -f /etc/cron.deny /etc/at.deny 2>/dev/null || true
  chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly \
            /etc/cron.monthly /etc/cron.weekly 2>/dev/null || true
  chmod 600 /etc/crontab 2>/dev/null || true
  info "cron/at restricted to root only"
}
run_always "step26_cron_restrict" _step26

hdr "STEP 27 — DISABLE CORE DUMPS"
_step27() {
  echo 'kernel.core_pattern=|/bin/false' > /etc/sysctl.d/99-no-coredump.conf
  sysctl -p /etc/sysctl.d/99-no-coredump.conf 2>/dev/null || true
  echo '* hard core 0' >> /etc/security/limits.d/99-xui.conf
  mkdir -p /etc/systemd/coredump.conf.d
  cat > /etc/systemd/coredump.conf.d/disable.conf << 'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  info "core dumps disabled"
}
run_always "step27_no_coredump" _step27

hdr "STEP 28 — PORT KNOCKING (panel port)"
_step28() {
  command -v knockd &>/dev/null || { warn "knockd not installed — skip"; return 0; }
  local K1 K2 K3
  K1=$(shuf -i 10000-60000 -n 1)
  K2=$(shuf -i 10000-60000 -n 1)
  K3=$(shuf -i 10000-60000 -n 1)
  cat > /etc/knockd.conf << EOF
[options]
    UseSyslog
    Interface = ${NIC}

[openPanel]
    sequence      = ${K1},${K2},${K3}
    seq_timeout   = 10
    command       = /usr/sbin/ufw allow from %IP% to any port ${PANEL_PORT}/tcp
    tcpflags      = syn

[closePanel]
    sequence      = ${K3},${K2},${K1}
    seq_timeout   = 10
    command       = /usr/sbin/ufw delete allow from %IP% to any port ${PANEL_PORT}/tcp
    tcpflags      = syn
EOF
  systemctl enable --now knockd 2>/dev/null || true
  info "Port knocking: ${K1} → ${K2} → ${K3}"
  echo "KNOCK_SEQUENCE=${K1}:${K2}:${K3}" >> "${STATE_DIR}/config.txt"
  chmod 600 "${STATE_DIR}/config.txt"
}
run_always "step28_knockd" _step28

hdr "STEP 29 — AUTO SECURITY UPDATES"
_step29() {
  cat > /etc/apt/apt.conf.d/50unattended-upgrades-security << 'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  systemctl enable --now unattended-upgrades
}
run_always "step29_autoupdate" _step29

hdr "STEP 30 — RKHUNTER"
_step30() {
  command -v rkhunter &>/dev/null || { warn "rkhunter not installed — skip"; return 0; }
  rkhunter --update --nocolors 2>/dev/null || true
  rkhunter --propupd --nocolors 2>/dev/null || true
  cat > /etc/systemd/system/rkhunter-scan.service << 'EOF'
[Unit]
Description=RKHunter rootkit scan
[Service]
Type=oneshot
ExecStart=/usr/bin/rkhunter --check --skip-keypress --nocolors --report-warnings-only
StandardOutput=journal
StandardError=journal
EOF
  cat > /etc/systemd/system/rkhunter-scan.timer << 'EOF'
[Unit]
Description=RKHunter daily scan
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now rkhunter-scan.timer
}
run_always "step30_rkhunter" _step30

hdr "STEP 31 — AIDE FILE INTEGRITY"
_step31() {
  command -v aide &>/dev/null || { warn "aide not installed — skip"; return 0; }
  cat > /etc/aide/aide.conf.d/99-xui.conf << 'EOF'
/usr/local/x-ui/x-ui        f+sha512
/usr/local/x-ui/bin/xray-linux-amd64  f+sha512
/etc/x-ui/x-ui.db           f+sha512+mtime
/etc/ssh/sshd_config        f+sha512
/etc/sudoers                f+sha512
/etc/passwd                 f+sha512
/etc/shadow                 f+sha512
EOF
  aide --init --config /etc/aide/aide.conf 2>/dev/null \
    && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db 2>/dev/null || true
  cat > /etc/systemd/system/aide-check.service << 'EOF'
[Unit]
Description=AIDE file integrity check
[Service]
Type=oneshot
ExecStart=/usr/bin/aide --check --config /etc/aide/aide.conf
StandardOutput=journal
StandardError=journal
EOF
  cat > /etc/systemd/system/aide-check.timer << 'EOF'
[Unit]
Description=AIDE daily integrity check
[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now aide-check.timer
  info "AIDE baseline + daily check enabled"
}
run_always "step31_aide" _step31

hdr "STEP 32 — x-ui SYSTEMD OVERRIDE"
_step32() {
  local xui_bin
  xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
  [ -x "$xui_bin" ] || { warn "x-ui binary not found — skipping"; return 0; }
  local xui_pid rss_mb gogc_val gomemlimit_val ram_avail_mb
  xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  rss_mb=70
  [ -n "$xui_pid" ] && rss_mb=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$xui_pid"/status 2>/dev/null || echo 70)
  ram_avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  gomemlimit_val=$(( ram_avail_mb - rss_mb - 100 ))
  [ "$gomemlimit_val" -lt 400 ] && gomemlimit_val=400
  if [ "$rss_mb" -lt 100 ]; then gogc_val=150
  elif [ "$rss_mb" -lt 200 ]; then gogc_val=100
  else gogc_val=50; fi
  info "GOGC=${gogc_val} GOMEMLIMIT=${gomemlimit_val}MiB"
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=2097152
LimitNPROC=131072
LimitMEMLOCK=infinity
LimitCORE=0
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
NoNewPrivileges=no
PrivateTmp=yes
ProtectHome=read-only
ProtectSystem=strict
ReadWritePaths=/etc/x-ui /usr/local/x-ui /var/lib/ais-reality-setup /tmp
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
LockPersonality=yes
MemoryDenyWriteExecute=no
RestrictNamespaces=yes
SystemCallFilter=@system-service @network-io @process
SystemCallErrorNumber=EPERM
EOF
  systemctl daemon-reload
  systemctl restart x-ui
  wait_active x-ui 30 || warn "x-ui not active after override"
  systemctl status x-ui --no-pager
}
run_always "step32_xui_override" _step32

hdr "STEP 33 — x-ui CAPABILITIES"
_step33() {
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
      && info "xray capabilities set" || true
  fi
}
run_always "step33_capabilities" _step33

hdr "STEP 34 — IONICE + PRIORITY"
_step34() {
  local xui_pid
  xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  if [ -n "$xui_pid" ]; then
    renice -n -20 -p "$xui_pid"      2>/dev/null || true
    ionice  -c 1 -n 0 -p "$xui_pid" 2>/dev/null || true
    chrt    -b -p 1   "$xui_pid"    2>/dev/null || true
    taskset -cp 0     "$xui_pid"    2>/dev/null || true
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
run_always "step34_ionice" _step34

hdr "STEP 35 — SQLite WAL"
_step35() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — skip"; return 0; }
  command -v sqlite3 &>/dev/null || return 1
  sqlite3 "$db" "PRAGMA journal_mode=WAL;"       2>/dev/null || true
  sqlite3 "$db" "PRAGMA synchronous=NORMAL;"      2>/dev/null || true
  sqlite3 "$db" "PRAGMA cache_size=-65536;"       2>/dev/null || true
  sqlite3 "$db" "PRAGMA temp_store=MEMORY;"       2>/dev/null || true
  sqlite3 "$db" "PRAGMA mmap_size=268435456;"     2>/dev/null || true
  sqlite3 "$db" "PRAGMA wal_autocheckpoint=1000;" 2>/dev/null || true
  sqlite3 "$db" "VACUUM;"                         2>/dev/null || true
  sqlite3 "$db" "ANALYZE;"                        2>/dev/null || true
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
}
run_always "step35_sqlite_wal" _step35

hdr "STEP 36 — XRAY LOG DISABLE"
_step36() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — skip"; return 0; }
  local template new_template
  template=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || true)
  [ -n "$template" ] || { warn "xrayTemplateConfig empty — skip"; return 0; }
  new_template=$(printf '%s' "$template" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['log'] = {'access': 'none', 'error': '', 'loglevel': 'none', 'dnsLog': False}
print(json.dumps(d, separators=(',',':')))
" 2>/dev/null || true)
  if [ -n "$new_template" ]; then
    local esc="${new_template//\'/\'\'}"
    sqlite3 "$db" "UPDATE settings SET value='${esc}' WHERE key='xrayTemplateConfig';" 2>/dev/null || true
    info "xray log → none"
  fi
  systemctl restart x-ui 2>/dev/null || true
}
run_always "step36_xray_nolog" _step36

hdr "STEP 37 — SOCKOPT PATCH (VLESS REALITY port 443)"
_step37() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db not found — create inbound first then re-run"; return 0; }
  command -v sqlite3 &>/dev/null || return 1
  local sockopt
  sockopt='{"acceptProxyProtocol":false,"tcpFastOpen":true,"mark":0,"tproxy":"off","tcpMptcp":false,"penetrate":false,"domainStrategy":"AsIs","tcpMaxSeg":1440,"dialerProxy":"","tcpKeepAliveInterval":35,"tcpKeepAliveIdle":35,"tcpUserTimeout":30000,"tcpcongestion":"bbr","V6Only":false,"tcpWindowClamp":0,"interface":"","trustedXForwardedFor":[],"addressPortStrategy":"none","customSockopt":[],"tcpNoDelay":true}'
  local count
  count=$(sqlite3 "$db" "SELECT COUNT(*) FROM inbounds WHERE port=443 AND protocol='vless';" 2>/dev/null || echo "0")
  if [ "$count" -gt 0 ]; then
    local stream_settings new_stream
    stream_settings=$(sqlite3 "$db" "SELECT stream_settings FROM inbounds WHERE port=443 AND protocol='vless' LIMIT 1;" 2>/dev/null || true)
    if [ -n "$stream_settings" ]; then
      new_stream=$(printf '%s' "$stream_settings" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['sockopt'] = json.loads(sys.argv[1])
print(json.dumps(d, separators=(',',':')))
" "$sockopt" 2>/dev/null || true)
      if [ -n "$new_stream" ]; then
        local esc="${new_stream//\'/\'\'}"
        sqlite3 "$db" "UPDATE inbounds SET stream_settings='${esc}' WHERE port=443 AND protocol='vless';"
        info "sockopt patched on vless port 443"
      fi
    fi
  else
    warn "no vless port 443 found — create inbound then re-run"
    echo "${sockopt}"
  fi
  systemctl restart x-ui 2>/dev/null || true
}
run_always "step37_sockopt" _step37

hdr "STEP 38 — WATCHDOG"
_step38() {
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
    sleep "$RESTART_COOL"; continue
  fi
  RSS_MB=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$XUI_PID"/status 2>/dev/null || echo 0)
  if [ "$RSS_MB" -gt "$MAX_RSS_MB" ]; then
    echo "$(ts) [WARN] RSS=${RSS_MB}MB — restarting" >> "$LOG"
    systemctl restart x-ui 2>/dev/null || true
    sleep "$RESTART_COOL"; continue
  fi
  AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
  if [ "$AVAIL_MB" -lt 50 ]; then
    echo "$(ts) [WARN] RAM low — drop caches" >> "$LOG"
    sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  fi
done
WEOF
  chmod +x /usr/local/bin/xui-watchdog.sh
  cat > /etc/systemd/system/xui-watchdog.service << 'EOF'
[Unit]
Description=x-ui Watchdog
After=x-ui.service
Requires=x-ui.service
[Service]
Type=simple
ExecStart=/usr/local/bin/xui-watchdog.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now xui-watchdog.service
}
run_always "step38_watchdog" _step38

hdr "STEP 39 — PERF SNAPSHOT + DB BACKUP"
_step39() {
  cat > /usr/local/bin/xui-perf-snap.sh << 'PEOF'
#!/usr/bin/env bash
set -uo pipefail
LOG="/var/log/xui-perf.log"
MAX_LINES=1000
ts() { date '+%Y-%m-%d %H:%M:%S'; }
[ -f "$LOG" ] && lines=$(wc -l < "$LOG" 2>/dev/null || echo 0) \
  && [ "$lines" -gt "$MAX_LINES" ] \
  && tail -n "$MAX_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
XUI_PID=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
RSS_MB=0; CPU_PCT="0"
if [ -n "$XUI_PID" ]; then
  RSS_MB=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$XUI_PID"/status 2>/dev/null || echo 0)
  CPU_PCT=$(ps -p "$XUI_PID" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0")
fi
AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
CONN=$(ss -s 2>/dev/null | awk '/estab/ {print $4}' | tr -d ',' || echo "?")
echo "$(ts) | PID=${XUI_PID:-none} RSS=${RSS_MB}MB CPU=${CPU_PCT}% RAM=${AVAIL_MB}MB CC=${CC} ESTAB=${CONN}" >> "$LOG"
PEOF
  chmod +x /usr/local/bin/xui-perf-snap.sh
  cat > /etc/systemd/system/xui-perf-snap.service << 'EOF'
[Unit]
Description=x-ui Perf Snapshot
[Service]
Type=oneshot
ExecStart=/usr/local/bin/xui-perf-snap.sh
EOF
  cat > /etc/systemd/system/xui-perf-snap.timer << 'EOF'
[Unit]
Description=x-ui Perf Snapshot every 5min
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF

  local db="/etc/x-ui/x-ui.db"
  local backup_dir="/var/lib/ais-reality-setup/backups"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  cat > /usr/local/bin/xui-db-backup.sh << BEOF
#!/usr/bin/env bash
set -uo pipefail
DB="${db}"
BACKUP_DIR="${backup_dir}"
[ -f "\$DB" ] || exit 0
TS=\$(date '+%Y%m%d_%H%M%S')
sqlite3 "\$DB" ".backup \${BACKUP_DIR}/x-ui_\${TS}.db" 2>/dev/null \
  || cp "\$DB" "\${BACKUP_DIR}/x-ui_\${TS}.db"
chmod 600 "\${BACKUP_DIR}/x-ui_\${TS}.db"
find "\$BACKUP_DIR" -name "x-ui_*.db" -mtime +7 -delete 2>/dev/null || true
BEOF
  chmod +x /usr/local/bin/xui-db-backup.sh
  cat > /etc/systemd/system/xui-db-backup.service << 'EOF'
[Unit]
Description=x-ui DB Backup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/xui-db-backup.sh
EOF
  cat > /etc/systemd/system/xui-db-backup.timer << 'EOF'
[Unit]
Description=x-ui DB daily backup
[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xui-perf-snap.timer
  systemctl enable --now xui-db-backup.timer
  /usr/local/bin/xui-db-backup.sh 2>/dev/null || true
  info "perf snap + DB backup (7-day retention) enabled"
}
run_always "step39_perf_backup" _step39

hdr "STEP 40 — VERIFY"
_step40() {
  local errors=0
  _chk_svc() {
    systemctl is-enabled "$1" &>/dev/null \
      || { warn "$1 not enabled"; errors=$(( errors + 1 )); }
  }
  _chk_val() {
    local label="$1" result="$2" expected="$3"
    if echo "$result" | grep -qF "$expected"; then
      ok "  ${label}: ${result}"
    else
      warn "  ${label}: got='${result}' expected='${expected}'"
      errors=$(( errors + 1 ))
    fi
  }
  _chk_svc thp-disable.service
  _chk_svc nic-tune.service
  _chk_svc cpu-performance.service
  _chk_svc x-ui
  _chk_svc xui-watchdog.service
  _chk_svc xui-perf-snap.timer
  _chk_svc xui-db-wal.timer
  _chk_svc xui-db-backup.timer
  _chk_svc fail2ban
  _chk_svc auditd
  _chk_svc unattended-upgrades
  _chk_svc rkhunter-scan.timer
  _chk_svc aide-check.timer
  [ -f /etc/sysctl.d/99-ais-reality-tune.conf ] || { warn "perf sysctl missing";     errors=$(( errors+1 )); }
  [ -f /etc/sysctl.d/99-security-harden.conf ]  || { warn "security sysctl missing"; errors=$(( errors+1 )); }
  [ -f /etc/security/limits.d/99-xui.conf ]     || { warn "limits conf missing";     errors=$(( errors+1 )); }
  [ -f /etc/ssh/sshd_config.d/99-hardened.conf ]|| { warn "ssh harden missing";      errors=$(( errors+1 )); }
  [ -f /etc/systemd/system/x-ui.service.d/override.conf ] || { warn "xui override missing"; errors=$(( errors+1 )); }
  grep -q '/swapfile' /etc/fstab   || { warn "swapfile not in fstab";  errors=$(( errors+1 )); }
  swapon --show | grep -q '/swapfile' || { warn "swapfile not active"; errors=$(( errors+1 )); }
  _chk_val "BBR"            "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "bbr"
  _chk_val "FQ qdisc"       "$(tc qdisc show dev "$NIC" 2>/dev/null | head -1)"         "fq"
  _chk_val "THP"            "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)" "never"
  _chk_val "x-ui"           "$(systemctl is-active x-ui 2>/dev/null)"                   "active"
  _chk_val "ip_forward"     "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"               "1"
  _chk_val "slow_start"     "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)" "0"
  _chk_val "watchdog"       "$(systemctl is-active xui-watchdog.service 2>/dev/null)"    "active"
  _chk_val "fail2ban"       "$(systemctl is-active fail2ban 2>/dev/null)"                "active"
  _chk_val "auditd"         "$(systemctl is-active auditd 2>/dev/null)"                  "active"
  _chk_val "kptr_restrict"  "$(sysctl -n kernel.kptr_restrict 2>/dev/null)"              "2"
  _chk_val "bpf_jit_harden" "$(sysctl -n net.core.bpf_jit_harden 2>/dev/null)"          "2"
  _chk_val "ptrace_scope"   "$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null)"          "2"
  _chk_val "suid_dumpable"  "$(sysctl -n fs.suid_dumpable 2>/dev/null)"                  "0"
  local xui_pid rss_mb
  xui_pid=$(pgrep -x x-ui 2>/dev/null | head -1 || true)
  rss_mb=0
  [ -n "$xui_pid" ] && rss_mb=$(awk '/^VmRSS/ {print int($2/1024)}' /proc/"$xui_pid"/status 2>/dev/null || echo 0)
  info "x-ui RSS    : ${rss_mb}MB"
  info "RAM avail   : $(free -m | awk '/^Mem:/ {print $7}')MB"
  info "Established : $(ss -s 2>/dev/null | awk '/estab/ {print $4}' | tr -d ',' || echo '?')"
  info "Kernel      : $(uname -r)"
  info "Time sync   : $(chronyc tracking 2>/dev/null | grep 'System time' | head -1 || echo 'n/a')"
  echo ""
  if [ "$errors" -eq 0 ]; then
    ok "ALL checks passed — safe to reboot"
  else
    warn "${errors} issue(s) found"
    return 1
  fi
}
run_always "step40_verify" _step40

hdr "DONE"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

KNOCK=""
[ -f "${STATE_DIR}/config.txt" ] && KNOCK=$(grep KNOCK_SEQUENCE "${STATE_DIR}/config.txt" 2>/dev/null | cut -d= -f2 || true)

echo ""
echo -e "${BLD}${GRN}  Steps completed:${RST}"
while IFS= read -r line; do
  [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  ${line}"
done < "$STATE_FILE"
echo ""
echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Panel        :${RST} https://${PUB_IP}:${PANEL_PORT}/"
[ -n "$KNOCK" ] && echo -e "  ${BLD}${RED}Panel locked — unlock:${RST} knock ${PUB_IP} $(echo "$KNOCK" | tr ':' ' ')"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Protocol     :${RST} VLESS  Port: 443  Network: TCP (raw)"
echo -e "  ${BLD}Security     :${RST} Reality · flow: xtls-rprx-vision"
echo -e "  ${BLD}SNI          :${RST} speedtest.net · fingerprint: chrome"
echo -e "  ${BLD}Sniffing     :${RST} ปิดทั้งหมด"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Security layers active:${RST}"
echo -e "    Kernel hardening · AppArmor · Fail2ban · CrowdSec"
echo -e "    Auditd · AIDE · rkhunter · Port knocking"
echo -e "    SSH publickey-only · SUID cleanup · /proc hidepid=2"
echo -e "    /tmp noexec · /dev/shm noexec · core dumps disabled"
echo -e "    Auto security updates · Time sync (chrony)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}BBR          :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui         :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}fail2ban     :${RST} $(systemctl is-active fail2ban 2>/dev/null || echo N/A)"
echo -e "  ${BLD}CrowdSec     :${RST} $(systemctl is-active crowdsec 2>/dev/null || echo N/A)"
echo -e "  ${BLD}auditd       :${RST} $(systemctl is-active auditd 2>/dev/null || echo N/A)"
echo -e "  ${BLD}AppArmor     :${RST} $(systemctl is-active apparmor 2>/dev/null || echo N/A)"
echo -e "  ${BLD}chrony       :${RST} $(systemctl is-active chrony 2>/dev/null || echo N/A)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}Perf log     :${RST} tail -f /var/log/xui-perf.log"
echo -e "  ${BLD}Audit        :${RST} ausearch -k xui_exec"
echo -e "  ${BLD}Fail2ban     :${RST} fail2ban-client status sshd"
echo -e "  ${BLD}CrowdSec     :${RST} cscli decisions list"
echo -e "  ${BLD}DB backup    :${RST} /var/lib/ais-reality-setup/backups/"
echo -e "  ${BLD}Install log  :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""
echo -e "  ${BLD}${YEL}→ สร้าง VLESS inbound: port=443 network=tcp security=reality${RST}"
echo -e "  ${BLD}${YEL}  flow=xtls-rprx-vision SNI=speedtest.net fingerprint=chrome${RST}"
echo -e "  ${BLD}${YEL}→ รัน script อีกครั้งหลังสร้าง inbound เพื่อ patch sockopt${RST}"
echo -e "  ${BLD}${YEL}→ reboot เพื่อ confirm ทุก setting persistent${RST}"
echo -e "  ${BLD}${RED}⚠ SSH = publickey-only ตรวจ authorized_keys ก่อน reboot${RST}"
echo ""
ENDOFSCRIPT

chmod +x /mnt/user-data/outputs/install.sh
echo "Lines: $(wc -l < /mnt/user-data/outputs/install.sh)"
bash -n /mnt/user-data/outputs/install.sh && echo "SYNTAX OK"
