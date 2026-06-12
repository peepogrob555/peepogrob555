#!/usr/bin/env bash
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

STATE_DIR="/var/lib/reality-setup"
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
die()  { echo -e "\n${RED}${BLD}✘  $1${RST}\n"; exit 1; }

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
    echo -e "\n${RED}${BLD}✘  FAILED: ${name}${RST}\n"; exit 1
  fi
}
run_skip()   { run_step "$1" true  "${@:2}"; }
run_always() { run_step "$1" false "${@:2}"; }

retry() {
  local tries=$1 delay=$2; shift 2; local i=1
  while true; do
    "$@" && return 0
    [ "$i" -ge "$tries" ] && return 1
    sleep "$delay"; i=$((i+1))
  done
}

wait_active() {
  local svc="$1" timeout="${2:-30}" elapsed=0
  until systemctl is-active "$svc" &>/dev/null; do
    [ "$elapsed" -ge "$timeout" ] && { warn "timeout: ${svc}"; return 1; }
    sleep 2; elapsed=$((elapsed+2))
  done
}

[ "$(id -u)" -eq 0 ] || die "must run as root"

VCPU=$(nproc 2>/dev/null || echo 1)
RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')

_detect_nic() {
  local nic
  nic=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
  [ -z "$nic" ] && nic=$(ip link show 2>/dev/null \
    | awk -F': ' '/^[0-9]+: / && !/lo:/ {print $2}' \
    | head -1 | cut -d@ -f1)
  echo "${nic:-eth0}"
}
NIC=$(_detect_nic)

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VLESS REALITY · Privacy · Performance  V1.0 BETA             ║${RST}"
echo -e "${BLD}${CYN}║  NIC: ${NIC}$(printf '%*s' $((51-${#NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""
info "RAM: ${RAM_MB}MB  vCPU: ${VCPU}  NIC: ${NIC}"
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
    curl ufw sqlite3 iproute2 ethtool irqbalance \
    fail2ban chrony python3 libcap2-bin \
    linux-tools-common linux-tools-generic 2>/dev/null || \
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw sqlite3 iproute2 ethtool \
    fail2ban chrony python3 libcap2-bin
}
run_skip "step1_deps" _step1

# =============================================================================
hdr "STEP 2 — FIREWALL"
_step2() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit  22/tcp
  ufw allow  443/tcp
  ufw deny   80/tcp
  ufw deny   23/tcp
  ufw deny   25/tcp
  ufw deny   3389/tcp
  ufw --force enable
}
run_skip "step2_ufw" _step2

# =============================================================================
hdr "STEP 3 — INSTALL 3X-UI"
_step3() {
  local installer
  installer=$(mktemp /tmp/3xui.XXXXXX.sh)
  retry 3 5 curl -fsSL \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    -o "$installer" || { rm -f "$installer"; return 1; }
  chmod +x "$installer"
  bash "$installer"
  rm -f "$installer"
}
run_skip "step3_3xui" _step3

# =============================================================================
hdr "STEP 4 — KILL UNUSED SERVICES"
_step4() {
  local svcs=(
    snapd snapd.socket multipathd multipathd.socket apport
    apt-daily.timer apt-daily-upgrade.timer
    man-db.timer motd-news.timer fwupd-refresh.timer
    avahi-daemon cups cups-browsed bluetooth
    ModemManager rsyslog syslog rpcbind
    systemd-networkd-wait-online
  )
  local s
  for s in "${svcs[@]}"; do
    systemctl list-unit-files "$s" 2>/dev/null | grep -q "$s" || continue
    systemctl stop    "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
    systemctl mask    "$s" 2>/dev/null || true
  done
}
run_always "step4_kill_svc" _step4

# =============================================================================
hdr "STEP 5 — ZERO-LOG"
_step5() {
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-nolog.conf << 'EOF'
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=16M
RuntimeMaxUse=16M
RateLimitIntervalSec=0
RateLimitBurst=0
Seal=no
ReadKMsg=no
EOF
  systemctl restart systemd-journald

  grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null \
    || echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,noexec,size=128m 0 0" >> /etc/fstab
  mount -o remount,noexec,nosuid,nodev /tmp     2>/dev/null || true
  mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null || true

  mkdir -p /etc/systemd/coredump.conf.d
  printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' \
    > /etc/systemd/coredump.conf.d/disable.conf
}
run_always "step5_zerolog" _step5

# =============================================================================
hdr "STEP 6 — KERNEL PRIVACY + SECURITY"
_step6() {
  cat > /etc/sysctl.d/99-privacy.conf << 'EOF'
kernel.kptr_restrict                       = 2
kernel.dmesg_restrict                      = 1
kernel.perf_event_paranoid                 = 3
kernel.unprivileged_bpf_disabled           = 1
net.core.bpf_jit_harden                   = 2
kernel.yama.ptrace_scope                   = 2
kernel.randomize_va_space                  = 2
kernel.sysrq                               = 0
fs.suid_dumpable                           = 0
kernel.core_pattern                        = |/bin/false
fs.protected_hardlinks                     = 1
fs.protected_symlinks                      = 1
fs.protected_fifos                         = 2
fs.protected_regular                       = 2
net.ipv4.conf.all.rp_filter                = 1
net.ipv4.conf.default.rp_filter            = 1
net.ipv4.conf.all.accept_redirects         = 0
net.ipv4.conf.default.accept_redirects     = 0
net.ipv6.conf.all.accept_redirects         = 0
net.ipv4.conf.all.send_redirects           = 0
net.ipv4.conf.all.accept_source_route      = 0
net.ipv6.conf.all.accept_source_route      = 0
net.ipv4.conf.all.log_martians             = 1
net.ipv4.icmp_echo_ignore_broadcasts       = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies                    = 1
net.ipv4.conf.all.secure_redirects         = 0
net.ipv6.conf.all.accept_ra                = 0
net.ipv4.tcp_rfc1337                       = 1
EOF
  sysctl -p /etc/sysctl.d/99-privacy.conf
}
run_always "step6_kernel_privacy" _step6

# =============================================================================
hdr "STEP 7 — TCP PERFORMANCE + NIC + CPU"
_step7() {
  modprobe tcp_bbr     2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true

  local cc="bbr"
  grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
    || { warn "BBR unavailable — fallback cubic"; cc="cubic"; }
  local qdisc="fq"
  modinfo sch_fq &>/dev/null || { warn "fq unavailable — fallback fq_codel"; qdisc="fq_codel"; }

  {
    cat << EOF
net.ipv4.tcp_congestion_control        = ${cc}
net.core.default_qdisc                 = ${qdisc}
net.core.rmem_max                      = 2147483647
net.core.wmem_max                      = 2147483647
net.core.rmem_default                  = 4194304
net.core.wmem_default                  = 4194304
net.ipv4.tcp_rmem                      = 4096 4194304 2147483647
net.ipv4.tcp_wmem                      = 4096 4194304 2147483647
net.ipv4.tcp_moderate_rcvbuf           = 1
net.ipv4.tcp_adv_win_scale             = 1
net.core.optmem_max                    = 131072
net.core.busy_poll                     = 50
net.core.busy_read                     = 50
net.core.netdev_budget                 = 1200
net.core.netdev_budget_usecs           = 8000
net.core.netdev_max_backlog            = 65536
net.core.dev_weight                    = 128
net.core.dev_weight_rx_bias            = 8
net.core.somaxconn                     = 4096
net.ipv4.tcp_max_syn_backlog           = 4096
net.ipv4.tcp_mtu_probing               = 1
net.ipv4.tcp_base_mss                  = 1440
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
net.ipv4.tcp_reordering                = 3
net.ipv4.tcp_frto                      = 2
net.ipv4.tcp_no_metrics_save           = 1
net.ipv4.tcp_slow_start_after_idle     = 0
net.ipv4.tcp_syncookies                = 1
net.ipv4.tcp_tw_reuse                  = 1
net.ipv4.tcp_max_tw_buckets            = 262144
net.ipv4.ip_local_port_range           = 1024 65535
net.ipv4.tcp_keepalive_time            = 35
net.ipv4.tcp_keepalive_intvl           = 5
net.ipv4.tcp_keepalive_probes          = 5
net.ipv4.tcp_fin_timeout               = 10
net.ipv4.tcp_syn_retries               = 3
net.ipv4.tcp_synack_retries            = 3
net.ipv4.tcp_retries2                  = 8
net.ipv4.tcp_orphan_retries            = 2
net.ipv4.tcp_max_orphans               = 8192
net.ipv4.tcp_abort_on_overflow         = 0
net.ipv4.ip_no_pmtu_disc               = 0
net.ipv4.ip_forward                    = 1
net.ipv4.conf.all.forwarding           = 1
net.ipv4.conf.default.forwarding       = 1
net.ipv6.conf.all.forwarding           = 1
vm.swappiness                          = 5
vm.dirty_ratio                         = 10
vm.dirty_background_ratio              = 3
vm.dirty_expire_centisecs              = 500
vm.dirty_writeback_centisecs           = 100
vm.min_free_kbytes                     = 65536
vm.vfs_cache_pressure                  = 50
vm.overcommit_memory                   = 1
fs.file-max                            = 1048576
kernel.sched_autogroup_enabled         = 0
kernel.sched_rt_runtime_us             = -1
kernel.timer_migration                 = 0
kernel.threads-max                     = 131072
kernel.panic                           = 10
EOF
    [ -f /proc/sys/net/ipv4/tcp_notsent_lowat ] \
      && echo "net.ipv4.tcp_notsent_lowat         = 131072"
    [ -f /proc/sys/net/ipv4/tcp_fack ]          \
      && echo "net.ipv4.tcp_fack                  = 1"
    [ -f /proc/sys/net/ipv4/tcp_low_latency ]   \
      && echo "net.ipv4.tcp_low_latency           = 1"
    [ -f /proc/sys/vm/numa_balancing ]           \
      && echo "vm.numa_balancing                  = 0"
    [ -f /proc/sys/kernel/sched_min_granularity_ns ]    \
      && echo "kernel.sched_min_granularity_ns    = 500000"
    [ -f /proc/sys/kernel/sched_wakeup_granularity_ns ] \
      && echo "kernel.sched_wakeup_granularity_ns = 50000"
    [ -f /proc/sys/kernel/sched_migration_cost_ns ]     \
      && echo "kernel.sched_migration_cost_ns     = 50000"
    [ -f /proc/sys/kernel/nmi_watchdog ]         \
      && echo "kernel.nmi_watchdog                = 0"
    [ -f /proc/sys/kernel/watchdog ]             \
      && echo "kernel.watchdog                    = 0"
  } > /etc/sysctl.d/99-tcp-perf.conf

  sysctl -p /etc/sysctl.d/99-tcp-perf.conf

  cat > /etc/sysctl.d/99-bbr-persist.conf << EOF
net.ipv4.tcp_congestion_control = ${cc}
net.core.default_qdisc          = ${qdisc}
EOF
  sysctl -p /etc/sysctl.d/99-bbr-persist.conf 2>/dev/null || true

  local ct_max=65536
  echo "$ct_max" > /proc/sys/net/netfilter/nf_conntrack_max                     2>/dev/null || true
  echo 0         > /proc/sys/net/netfilter/nf_conntrack_checksum                2>/dev/null || true
  echo 600       > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
  echo 15        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait   2>/dev/null || true
  echo 10        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait  2>/dev/null || true
  echo 10        > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_fin_wait    2>/dev/null || true
  echo 1         > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal          2>/dev/null || true
  echo $(( ct_max / 4 )) > /sys/module/nf_conntrack/parameters/hashsize        2>/dev/null || true

  ethtool -K "$NIC" gro on lro off tso on gso on            2>/dev/null || true
  ethtool -K "$NIC" rx-gro-hw off                           2>/dev/null || true
  ethtool -K "$NIC" rx-vlan-offload off tx-vlan-offload off 2>/dev/null || true
  ethtool -A "$NIC" rx off tx off                           2>/dev/null || true

  local rx_max tx_max
  rx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/RX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  tx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/TX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  rx_max="${rx_max:-1024}"; tx_max="${tx_max:-1024}"
  ethtool -G "$NIC" rx "$rx_max" tx "$tx_max"               2>/dev/null || true
  ethtool -C "$NIC" rx-usecs 50 tx-usecs 50 \
    adaptive-rx on adaptive-tx on                           2>/dev/null || \
  ethtool -C "$NIC" rx-usecs 50 tx-usecs 50                2>/dev/null || true

  ip link set "$NIC" txqueuelen 10000
  ip link set "$NIC" mtu 1500 2>/dev/null || true

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum 3028 buckets 65536 limit 10000 2>/dev/null \
  || tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum 3028 buckets 65536 2>/dev/null || true

  local cpu_count rps_mask
  cpu_count=$(nproc 2>/dev/null || echo 1)
  rps_mask=$(printf '%x' $(( (1 << cpu_count) - 1 )))
  echo "${rps_mask}" > /sys/class/net/"${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true
  if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
    echo 32768 > /sys/class/net/"${NIC}"/queues/rx-0/rps_flow_cnt 2>/dev/null || true
  fi

  echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo never > /sys/kernel/mm/transparent_hugepage/defrag   2>/dev/null || true

  for DEV in sda sdb vda vdb xvda nvme0n1; do
    [ -b "/dev/${DEV}" ] || continue
    local rot
    rot=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
    [ "$rot" = "0" ] \
      && echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true \
      || echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
    echo 0   > "/sys/block/${DEV}/queue/add_random"    2>/dev/null || true
    echo 256 > "/sys/block/${DEV}/queue/nr_requests"   2>/dev/null || true
    echo 0   > "/sys/block/${DEV}/queue/nomerges"      2>/dev/null || true
    echo 128 > "/sys/block/${DEV}/queue/read_ahead_kb" 2>/dev/null || true
    echo 0   > "/sys/block/${DEV}/queue/wbt_lat_usec"  2>/dev/null || true
  done

  cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]",         ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]",         ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="vd[a-z]",         ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="vd[a-z]",         ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF
  udevadm control --reload-rules 2>/dev/null || true

  mkdir -p /etc/networkd-dispatcher/routable.d
  cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
NIC="${NIC}"; QDISC="${qdisc}"; RX_MAX="${rx_max}"; TX_MAX="${tx_max}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro on lro off tso on gso on 2>/dev/null || true
ethtool -K "\${NIC}" rx-gro-hw off 2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}" 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50 adaptive-rx on adaptive-tx on 2>/dev/null || \
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 10000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum 3028 buckets 65536 limit 10000 2>/dev/null || \
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum 3028 buckets 65536 2>/dev/null || true
CPU_COUNT=\$(nproc 2>/dev/null || echo 1)
RPS_MASK=\$(printf '%x' \$(( (1 << CPU_COUNT) - 1 )))
echo "\${RPS_MASK}" > /sys/class/net/"\${NIC}"/queues/rx-0/rps_cpus 2>/dev/null || true
[ -f /proc/sys/net/core/rps_sock_flow_entries ] \
  && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
NEOF
  chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

  cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC low-latency tune
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/etc/networkd-dispatcher/routable.d/50-nic-tune.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SEOF

  cat > /etc/systemd/system/thp-disable.service << 'EOF'
[Unit]
Description=Disable THP
DefaultDependencies=no
After=sysinit.target local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=CPU Governor performance
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$f" ] && echo performance > "$f" 2>/dev/null || true; done'
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do [ -f "$f" ] && echo 1 > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now nic-tune.service
  systemctl enable --now thp-disable.service
  systemctl enable --now cpu-performance.service

  if command -v irqbalance &>/dev/null; then
    cat > /etc/default/irqbalance << 'EOF'
ENABLED=1
ONESHOT=0
OPTIONS="--powerthresh=0 --deepestcache=1"
EOF
    systemctl enable --now irqbalance 2>/dev/null || true
  fi

  cat > /etc/security/limits.d/99-perf.conf << 'EOF'
*    soft nofile  1048576
*    hard nofile  1048576
*    soft nproc   65536
*    hard nproc   65536
*    soft memlock unlimited
*    hard memlock unlimited
*    soft core    0
*    hard core    0
root soft nofile  1048576
root hard nofile  1048576
root soft core    0
root hard core    0
EOF
  local pam
  for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam" ] || continue
    grep -qxF 'session required pam_limits.so' "$pam" \
      || echo 'session required pam_limits.so' >> "$pam"
  done

  info "BBR=${cc} qdisc=${qdisc} THP=off CPU=performance RPS/RFS=32768"
}
run_always "step7_perf" _step7

# =============================================================================
hdr "STEP 8 — KERNEL MODULE BLACKLIST"
_step8() {
  cat > /etc/modprobe.d/99-blacklist.conf << 'EOF'
install dccp          /bin/false
install sctp          /bin/false
install rds           /bin/false
install tipc          /bin/false
install n-hdlc        /bin/false
install ax25          /bin/false
install netrom        /bin/false
install x25           /bin/false
install rose          /bin/false
install decnet        /bin/false
install af_802154     /bin/false
install ipx           /bin/false
install appletalk     /bin/false
install can           /bin/false
install atm           /bin/false
install usb-storage   /bin/false
install firewire-core /bin/false
EOF
  depmod -a 2>/dev/null || true
}
run_always "step8_blacklist" _step8

# =============================================================================
hdr "STEP 9 — SSH HARDENING"
_step9() {
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-hardened.conf << 'EOF'
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 20
ClientAliveInterval 120
ClientAliveCountMax 3
AllowTcpForwarding no
X11Forwarding no
PermitEmptyPasswords no
Banner none
UsePAM yes
StrictModes yes
IgnoreRhosts yes
HostbasedAuthentication no
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
EOF
  [ -f /etc/ssh/ssh_host_ed25519_key ] \
    || ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" 2>/dev/null || true
  sshd -t 2>/dev/null \
    && { systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true; } \
    || warn "sshd config test failed — not reloading"
}
run_always "step9_ssh" _step9

# =============================================================================
hdr "STEP 10 — FAIL2BAN"
_step10() {
  cat > /etc/fail2ban/jail.d/99-hardened.conf << 'EOF'
[DEFAULT]
bantime  = 604800
findtime = 300
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 604800
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}
run_always "step10_fail2ban" _step10

# =============================================================================
hdr "STEP 11 — CHRONY"
_step11() {
  command -v chronyc &>/dev/null || return 0
  cat > /etc/chrony/chrony.conf << 'EOF'
pool time.cloudflare.com iburst maxsources 4
pool ntp.ubuntu.com iburst maxsources 4
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
maxdistance 1.0
EOF
  systemctl enable --now chrony 2>/dev/null || true
  systemctl restart chrony 2>/dev/null || true
}
run_always "step11_chrony" _step11

# =============================================================================
hdr "STEP 12 — x-ui OVERRIDE"
_step12() {
  local xui_bin
  xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
  [ -x "$xui_bin" ] || { warn "x-ui not found — skipping"; return 0; }

  local ram_avail_mb gomemlimit_val
  ram_avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
  gomemlimit_val=$(( ram_avail_mb - 150 ))
  [ "$gomemlimit_val" -lt 400 ] && gomemlimit_val=400

  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=65536
LimitMEMLOCK=infinity
LimitCORE=0
Restart=always
RestartSec=2
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=150
Environment=GODEBUG=madvdontneed=1
Environment=GOMEMLIMIT=${gomemlimit_val}MiB
OOMScoreAdjust=-1000
Nice=-20
PrivateTmp=yes
ProtectHome=read-only
ProtectSystem=strict
ReadWritePaths=/etc/x-ui /usr/local/x-ui /var/lib/reality-setup /tmp
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
LockPersonality=yes
NoNewPrivileges=no
TasksMax=infinity
CPUWeight=10000
IOWeight=10000
EOF

  setcap 'cap_net_admin,cap_net_bind_service,cap_net_raw,cap_ipc_lock+eip' \
    "$xui_bin" 2>/dev/null || true
  local xray
  xray=$(find /usr/local/x-ui -name "xray" -type f 2>/dev/null | head -1 || true)
  [ -n "$xray" ] && [ -x "$xray" ] && \
    setcap 'cap_net_admin,cap_net_bind_service,cap_net_raw,cap_ipc_lock+eip' \
      "$xray" 2>/dev/null || true

  systemctl daemon-reload
  systemctl restart x-ui
  wait_active x-ui 30 || warn "x-ui not active"
}
run_always "step12_xui" _step12

# =============================================================================
hdr "STEP 13 — XRAY NO-LOG + SQLite WAL"
_step13() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || return 0
  command -v sqlite3 &>/dev/null || return 0

  local template new_template
  template=$(sqlite3 "$db" \
    "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null || true)
  if [ -n "$template" ]; then
    new_template=$(printf '%s' "$template" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['log'] = {'access': 'none', 'error': '', 'loglevel': 'none', 'dnsLog': False}
print(json.dumps(d, separators=(',',':')))
" 2>/dev/null || true)
    if [ -n "$new_template" ]; then
      local esc="${new_template//\'/\'\'}"
      sqlite3 "$db" \
        "UPDATE settings SET value='${esc}' WHERE key='xrayTemplateConfig';" 2>/dev/null || true
    fi
  fi

  sqlite3 "$db" "PRAGMA journal_mode=WAL;"   2>/dev/null || true
  sqlite3 "$db" "PRAGMA synchronous=NORMAL;" 2>/dev/null || true
  sqlite3 "$db" "PRAGMA temp_store=MEMORY;"  2>/dev/null || true
  sqlite3 "$db" "PRAGMA mmap_size=134217728;" 2>/dev/null || true
  sqlite3 "$db" "PRAGMA cache_size=-32768;"  2>/dev/null || true
  sqlite3 "$db" "VACUUM;"                    2>/dev/null || true

  systemctl restart x-ui 2>/dev/null || true
}
run_always "step13_xray_nolog" _step13

# =============================================================================
hdr "DONE"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps completed:${RST}"
while IFS= read -r line; do
  [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  ${line}"
done < "$STATE_FILE"
echo ""
echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}IP           :${RST} ${PUB_IP}"
echo -e "  ${BLD}BBR          :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}THP          :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui         :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}fail2ban     :${RST} $(systemctl is-active fail2ban 2>/dev/null || echo N/A)"
echo -e "  ${BLD}chrony       :${RST} $(systemctl is-active chrony 2>/dev/null || echo N/A)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}VLESS inbound settings:${RST}"
echo -e "    port=443 · network=tcp · security=reality"
echo -e "    flow=xtls-rprx-vision · SNI=speedtest.net"
echo -e "    fingerprint=firefox · SpiderX=/"
echo -e "    sniffing=ปิดทั้งหมด"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""
echo -e "  ${BLD}${RED}⚠  SSH = publickey-only ตรวจ authorized_keys ก่อน reboot${RST}"
echo -e "  ${BLD}${YEL}→  reboot เพื่อ confirm ทุก setting${RST}"
echo ""
