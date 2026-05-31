#!/usr/bin/env bash
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

STATE_DIR="/var/lib/vps-setup"
STATE_FILE="${STATE_DIR}/steps.done"
LOG_FILE="${STATE_DIR}/install.log"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

sep()  { echo -e "${DIM}${CYN}────────────────────────────────────────────────${RST}"; }
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
  if $skip && step_done "$name"; then
    ok "[SKIP] ${name}"; return 0
  fi
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
  local tries=$1 delay=$2; shift 2
  local i=1
  while true; do
    "$@" && return 0
    echo -e "  ${YEL}retry ${i}/${tries} — wait ${delay}s...${RST}"
    [ "$i" -ge "$tries" ] && return 1
    sleep "$delay"; i=$((i+1))
  done
}

wait_service_active() {
  local svc="$1" timeout="${2:-30}" elapsed=0
  until systemctl is-active "$svc" &>/dev/null; do
    [ "$elapsed" -ge "$timeout" ] && { echo "  timeout waiting ${svc}"; return 1; }
    sleep 2; elapsed=$((elapsed+2))
  done
}

[ "$(id -u)" -eq 0 ] || die "must run as root"

RMEM_MAX=2147483647
WMEM_MAX=2147483647
RMEM_DEFAULT=1250000
WMEM_DEFAULT=1250000
LIMIT_OUTPUT=2147483647

TC_QUANTUM=65535
TC_BUCKETS=65536

KEEPALIVE_TIME=30
KEEPALIVE_INTVL=5
KEEPALIVE_PROBES=3
FIN_TIMEOUT=5

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

MTU=$(ip link show "$NIC" 2>/dev/null \
  | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}' | head -1)
MTU="${MTU:-1500}"
BASE_MSS=$(( MTU - 40 ))
[ "$BASE_MSS" -lt 512   ] && BASE_MSS=512
[ "$BASE_MSS" -gt 65495 ] && BASE_MSS=65495

VCPU=$(nproc 2>/dev/null || echo 1)

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║   VPS SETUP UNLIMITED v5.1                          ║${RST}"
echo -e "${BLD}${CYN}║   RTT=1ms / 10Gbps / NO LIMITS / NO CAPS            ║${RST}"
echo -e "${BLD}${CYN}║   NIC: ${NIC}$(printf '%*s' $((47-${#NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""
info "NIC      : ${NIC} (MTU ${MTU})"
info "BASE_MSS : ${BASE_MSS} bytes"
info "vCPU     : ${VCPU} → GOMAXPROCS=${VCPU}"
info "rmem/wmem: 2,147,483,647 bytes"
info "BDP ref  : 1,250,000 bytes (10Gbps × 1ms)"
echo ""

hdr "STEP 1 — UPDATE & DEPS"
_step1() {
  systemctl stop    unattended-upgrades 2>/dev/null || true
  systemctl disable unattended-upgrades 2>/dev/null || true
  systemctl kill --kill-who=all unattended-upgrades 2>/dev/null || true
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend \
              /var/lib/dpkg/lock \
              /var/cache/apt/archives/lock &>/dev/null; do
    [ "$waited" -ge 90 ] && {
      fuser -k /var/lib/dpkg/lock-frontend \
               /var/lib/dpkg/lock \
               /var/cache/apt/archives/lock 2>/dev/null || true
      sleep 3; break
    }
    sleep 3; waited=$((waited+3))
  done
  dpkg --configure -a
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw ethtool sqlite3 irqbalance iproute2 iputils-ping
}
run_skip "step1_deps" _step1

hdr "STEP 2 — FIREWALL (UFW)"
_step2() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  for port in "${OPEN_PORTS[@]}"; do
    ufw allow "${port}/tcp"
  done
  ufw --force enable
  ufw status | grep -q "Status: active" || return 1
}
run_skip "step2_ufw" _step2

hdr "STEP 3 — INSTALL 3X-UI"
_step3() {
  local installer
  installer=$(mktemp /tmp/3xui-install.XXXXXX.sh)
  retry 3 5 curl -fsSL \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    -o "$installer" || { rm -f "$installer"; return 1; }
  chmod +x "$installer"
  bash "$installer" || true
  rm -f "$installer"
  local xui_bin
  xui_bin=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
  [ -x "$xui_bin" ] || { echo "x-ui binary not found after install"; return 1; }
  systemctl enable x-ui 2>/dev/null || true
  systemctl start  x-ui 2>/dev/null || true
  wait_service_active x-ui 20 || warn "x-ui may not be ready yet"
}
run_skip "step3_3xui" _step3

hdr "STEP 4 — KERNEL TCP TUNE"
_step4() {
  local cc="bbr"
  modprobe tcp_bbr 2>/dev/null || true
  grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
    || { warn "BBR not supported — fallback cubic"; cc="cubic"; }

  local qdisc="fq"
  if ! modinfo sch_fq &>/dev/null 2>&1; then
    warn "fq not supported — fallback fq_codel"; qdisc="fq_codel"
  fi

  cat > /etc/sysctl.d/99-vps-tune.conf << EOF
net.ipv4.tcp_congestion_control = ${cc}
net.core.default_qdisc          = ${qdisc}
net.core.rmem_max     = ${RMEM_MAX}
net.core.wmem_max     = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = -1
net.ipv4.tcp_limit_output_bytes = ${LIMIT_OUTPUT}
net.core.netdev_max_backlog  = 4194304
net.core.somaxconn           = 4194304
net.ipv4.tcp_max_syn_backlog = 4194304
net.core.optmem_max          = 1073741824
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss    = ${BASE_MSS}
net.ipv4.tcp_fastopen       = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps     = 1
net.ipv4.tcp_sack           = 1
net.ipv4.tcp_dsack          = 1
net.ipv4.tcp_ecn            = 0
net.ipv4.tcp_tw_reuse        = 1
net.ipv4.tcp_max_tw_buckets  = 2000000
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time   = ${KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl  = ${KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${KEEPALIVE_PROBES}
net.ipv4.tcp_fin_timeout      = ${FIN_TIMEOUT}
net.ipv4.tcp_syn_retries      = 3
net.ipv4.tcp_synack_retries   = 3
net.ipv4.tcp_retries2         = 8
vm.swappiness                = 0
vm.dirty_ratio               = 95
vm.dirty_background_ratio    = 80
vm.dirty_expire_centisecs    = 3000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes           = 8192
vm.vfs_cache_pressure        = 50
vm.overcommit_memory         = 1
vm.overcommit_ratio          = 200
fs.file-max      = 9223372036854775807
fs.nr_open       = 2147483584
fs.pipe-max-size = 1073741824
kernel.sched_autogroup_enabled = 0
kernel.pid_max                 = 4194304
kernel.threads-max             = 4194304
net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_abort_on_overflow       = 0
EOF

  sysctl -p /etc/sysctl.d/99-vps-tune.conf || sysctl --system

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" \
    buckets "${TC_BUCKETS}" \
    2>/dev/null || warn "tc ${qdisc} on ${NIC} failed"
}
run_always "step4_sysctl" _step4

hdr "STEP 5 — DISABLE TRANSPARENT HUGE PAGES"
_step5() {
  echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
  echo never > /sys/kernel/mm/transparent_hugepage/defrag   || true
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
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thp-disable.service
  grep -q '' /sys/kernel/mm/transparent_hugepage/enabled \
    || warn "THP may not be disabled"
}
run_always "step5_thp" _step5

hdr "STEP 6 — NIC TUNE (${NIC})"
_step6() {
  ip link show "$NIC" &>/dev/null || { echo "NIC ${NIC} not found"; return 1; }

  local qdisc="fq"
  grep -q "default_qdisc = fq_codel" /etc/sysctl.d/99-vps-tune.conf 2>/dev/null \
    && qdisc="fq_codel"

  ethtool -K "$NIC" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null \
    || warn "ethtool offload partial fail"
  ethtool -A "$NIC" rx off tx off 2>/dev/null || true

  local rx_max tx_max
  rx_max=$(ethtool -g "$NIC" 2>/dev/null | awk '/^Pre-set maximums/,/^Current/ {
    if (/RX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit }
  }')
  tx_max=$(ethtool -g "$NIC" 2>/dev/null | awk '/^Pre-set maximums/,/^Current/ {
    if (/TX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit }
  }')
  rx_max="${rx_max:-4096}"; tx_max="${tx_max:-4096}"
  ethtool -G "$NIC" rx "$rx_max" tx "$tx_max" 2>/dev/null \
    && info "ring buffer: rx=${rx_max} tx=${tx_max}" || true

  ethtool -C "$NIC" rx-usecs 0 tx-usecs 0 2>/dev/null || true
  ip link set "$NIC" txqueuelen 10000

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" \
    buckets "${TC_BUCKETS}" \
    2>/dev/null || warn "tc ${qdisc} failed"

  mkdir -p /etc/networkd-dispatcher/routable.d
  cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
set -uo pipefail
NIC="${NIC}"
QDISC="${qdisc}"
RX_MAX="${rx_max}"
TX_MAX="${tx_max}"
ip link show "${NIC}" &>/dev/null || exit 0
ethtool -K "${NIC}" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null || true
ethtool -A "${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "${NIC}" rx "${RX_MAX}" tx "${TX_MAX}" 2>/dev/null || true
ethtool -C "${NIC}" rx-usecs 0 tx-usecs 0 2>/dev/null || true
ip link set "${NIC}" txqueuelen 10000
tc qdisc del dev "${NIC}" root 2>/dev/null || true
tc qdisc add dev "${NIC}" root handle 1: "${QDISC}" \
  quantum ${TC_QUANTUM} buckets ${TC_BUCKETS} 2>/dev/null || true
NEOF
  chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

  cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC Tuning for ${NIC}
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
run_always "step6_nic" _step6

hdr "STEP 7 — I/O SCHEDULER"
_step7() {
  local found=0
  for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/${DEV}" ] || continue
    found=1
    local rotational
    rotational=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
    if [ "$rotational" = "0" ]; then
      echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: SSD/NVMe → none"
    else
      echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: HDD → mq-deadline"
    fi
    echo 0    > "/sys/block/${DEV}/queue/add_random"  2>/dev/null || true
    echo 4096 > "/sys/block/${DEV}/queue/nr_requests" 2>/dev/null || true
    echo 1    > "/sys/block/${DEV}/queue/nomerges"    2>/dev/null || true
  done
  [ "$found" -eq 1 ] || warn "no block device found"
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
run_always "step7_io_scheduler" _step7

hdr "STEP 8 — CPU GOVERNOR"
_step8() {
  cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
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
}
run_always "step8_cpu_gov" _step8

hdr "STEP 9 — SYSTEM LIMITS"
_step9() {
  cat > /etc/security/limits.d/99-xui.conf << 'EOF'
* soft nofile  unlimited
* hard nofile  unlimited
* soft nproc   unlimited
* hard nproc   unlimited
* soft memlock unlimited
* hard memlock unlimited
* soft stack   unlimited
* hard stack   unlimited
* soft sigpending unlimited
* hard sigpending unlimited
root soft nofile  unlimited
root hard nofile  unlimited
root soft nproc   unlimited
root hard nproc   unlimited
root soft memlock unlimited
root hard memlock unlimited
EOF
  for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam_file" ] || continue
    grep -qxF 'session required pam_limits.so' "$pam_file" \
      || echo 'session required pam_limits.so' >> "$pam_file"
  done
}
run_always "step9_limits" _step9

hdr "STEP 10 — x-ui SYSTEMD OVERRIDE"
_step10() {
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=infinity
LimitNPROC=infinity
LimitMEMLOCK=infinity
LimitCORE=infinity
LimitSTACK=infinity
LimitSIGPENDING=infinity
LimitMSGQUEUE=infinity
LimitRTPRIO=infinity
Restart=always
RestartSec=3
RestartPreventExitStatus=0
Environment=GOMAXPROCS=${VCPU}
OOMScoreAdjust=-1000
EOF
  systemctl daemon-reload
  systemctl restart x-ui
  wait_service_active x-ui 30 || { echo "x-ui failed to start after override"; return 1; }
}
run_always "step10_xui_override" _step10

hdr "DONE — SUMMARY"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps completed:${RST}"
while IFS= read -r line; do
  [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  $line"
done < "$STATE_FILE"
echo ""
echo -e "  ──────────────────────────────────────────────────"
echo -e "  ${BLD}Panel          :${RST} http://${PUB_IP}:${PANEL_PORT}"
echo -e "  ${BLD}NIC            :${RST} ${NIC} (MTU ${MTU})"
echo -e "  ${BLD}BASE_MSS       :${RST} ${BASE_MSS} bytes"
echo -e "  ${BLD}rmem/wmem      :${RST} 2,147,483,647 bytes"
echo -e "  ${BLD}somaxconn      :${RST} 4,194,304"
echo -e "  ${BLD}nofile/nproc   :${RST} unlimited"
echo -e "  ${BLD}GOMAXPROCS     :${RST} ${VCPU}"
echo -e "  ${BLD}OOMScore       :${RST} -1000"
echo -e "  ${BLD}swappiness     :${RST} 0"
echo -e "  ${BLD}BBR            :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Qdisc          :${RST} $(tc qdisc show dev "$NIC" 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP            :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui           :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Log            :${RST} ${LOG_FILE}"
echo -e "  ──────────────────────────────────────────────────"
echo ""
echo -e "  ${BLD}${YEL}→ reboot 1 ครั้ง แล้วใช้งานได้เลย${RST}"
echo ""
