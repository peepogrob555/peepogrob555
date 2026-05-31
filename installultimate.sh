#!/usr/bin/env bash
# =============================================================
#  VPS SETUP UNLIMITED v5.1
#  RTT=1ms / BW=10Gbps / NO LIMITS / NO CAPS
#  NIC: auto-detect จาก default route
# =============================================================
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
clear_done() { sed -i "/^$1\$/d" "$STATE_FILE" 2>/dev/null || true; }

run_step() {
    local name="$1" skip="$2"; shift 2
    if $skip && step_done "$name"; then
        ok "[SKIP] ${name} — เสร็จแล้ว"; return 0
    fi
    clear_done "$name"
    echo -e "\n${BLD}  → ${name}${RST}"
    if (set -euo pipefail; "$@"); then
        mark_done "$name"; ok "[OK]   ${name}"
    else
        echo -e "\n${RED}${BLD}✘  FAILED: ${name}${RST}"
        echo -e "  ${YEL}แก้ปัญหาแล้วรันใหม่ได้เลย — Log: ${LOG_FILE}${RST}\n"
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
        echo -e "  ${YEL}retry ${i}/${tries} — รอ ${delay}s...${RST}"
        [ "$i" -ge "$tries" ] && return 1
        sleep "$delay"; i=$((i+1))
    done
}

wait_service_active() {
    local svc="$1" timeout="${2:-30}" elapsed=0
    until systemctl is-active "$svc" &>/dev/null; do
        [ "$elapsed" -ge "$timeout" ] && { echo "  timeout รอ ${svc}"; return 1; }
        sleep 2; elapsed=$((elapsed+2))
    done
}

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root"

# =============================================================
#  CONSTANTS
#  BDP = 10Gbps × 1ms = 1,250,000 bytes
#  INT_MAX (signed 32-bit) = 2,147,483,647
# =============================================================

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

# NIC auto-detect
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
info "rmem/wmem: INT_MAX = 2,147,483,647 bytes"
info "BDP ref  : 1,250,000 bytes (10Gbps × 1ms)"
echo ""

# =============================================================
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

# =============================================================
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

# =============================================================
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
    [ -x "$xui_bin" ] || { echo "x-ui binary ไม่พบหลัง install"; return 1; }
    systemctl enable x-ui 2>/dev/null || true
    systemctl start  x-ui 2>/dev/null || true
    wait_service_active x-ui 20 || warn "x-ui อาจยังไม่พร้อม"
}
run_skip "step3_3xui" _step3

# =============================================================
hdr "STEP 4 — KERNEL TCP TUNE (UNLIMITED)"
_step4() {
    local cc="bbr"
    modprobe tcp_bbr 2>/dev/null || true
    grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        || { warn "BBR ไม่รองรับ — fallback cubic"; cc="cubic"; }

    local qdisc="fq"
    if ! modinfo sch_fq &>/dev/null 2>&1; then
        warn "fq ไม่รองรับ — fallback fq_codel"; qdisc="fq_codel"
    fi

    cat > /etc/sysctl.d/99-vps-tune.conf << EOF
# VPS SETUP UNLIMITED v5.1
# RTT=1ms BW=10Gbps BDP=1,250,000 bytes
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Congestion / Qdisc ──────────────────────────────────────
net.ipv4.tcp_congestion_control = ${cc}
net.core.default_qdisc          = ${qdisc}

# ── Socket Buffers — INT_MAX ─────────────────────────────────
net.core.rmem_max     = ${RMEM_MAX}
net.core.wmem_max     = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}

# ── tcp_moderate_rcvbuf = 1 ──────────────────────────────────
# เปิดให้ BBR/kernel auto-tune buffer ขึ้นถึง rmem_max ได้เต็มที่
# ถ้าปิด (=0) buffer จะติดที่ rmem_default ตลอด — BBR ลาก window ไม่ได้
net.ipv4.tcp_moderate_rcvbuf = 1

# tcp_adv_win_scale = -1
# application recv window = 87.5% ของ socket buffer (สูงสุดก่อน -2 = 75%)
net.ipv4.tcp_adv_win_scale = -1

# ── Anti-bufferbloat — ปิดทั้งหมด ───────────────────────────
# tcp_notsent_lowat: ไม่ตั้ง = kernel default (INT_MAX = off)
net.ipv4.tcp_limit_output_bytes = ${LIMIT_OUTPUT}

# ── Backlog — สูงสุดที่ kernel รับได้ ───────────────────────
net.core.netdev_max_backlog  = 4194304
net.core.somaxconn           = 4194304
net.ipv4.tcp_max_syn_backlog = 4194304
net.core.optmem_max          = 1073741824

# ── MTU / MSS (from NIC MTU=${MTU}) ──────────────────────────
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss    = ${BASE_MSS}

# ── TCP Features ─────────────────────────────────────────────
net.ipv4.tcp_fastopen       = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps     = 1
net.ipv4.tcp_sack           = 1
net.ipv4.tcp_dsack          = 1
net.ipv4.tcp_ecn            = 0

# ── TIME_WAIT — ไม่มี limit ──────────────────────────────────
net.ipv4.tcp_tw_reuse        = 1
net.ipv4.tcp_max_tw_buckets  = 2000000
net.ipv4.ip_local_port_range = 1024 65535

# ── Keepalive — aggressive (RTT=1ms) ─────────────────────────
net.ipv4.tcp_keepalive_time   = ${KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl  = ${KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${KEEPALIVE_PROBES}
net.ipv4.tcp_fin_timeout      = ${FIN_TIMEOUT}
net.ipv4.tcp_syn_retries      = 3
net.ipv4.tcp_synack_retries   = 3
net.ipv4.tcp_retries2         = 8

# ── Memory — ปล่อยทุกหยดให้ใช้ได้ ──────────────────────────
vm.swappiness                = 0
vm.dirty_ratio               = 95
vm.dirty_background_ratio    = 80
vm.dirty_expire_centisecs    = 3000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes           = 8192
vm.vfs_cache_pressure        = 50
vm.overcommit_memory         = 1
vm.overcommit_ratio          = 200

# ── File system — near INT64_MAX ─────────────────────────────
fs.file-max      = 9223372036854775807
fs.nr_open       = 2147483584
fs.pipe-max-size = 1073741824

# ── Kernel ───────────────────────────────────────────────────
kernel.sched_autogroup_enabled = 0
kernel.pid_max                 = 4194304
kernel.threads-max             = 4194304

# ── Security minimal ─────────────────────────────────────────
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
        2>/dev/null || warn "tc ${qdisc} บน ${NIC} fail"
}
run_always "step4_sysctl" _step4

# =============================================================
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
    grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled \
        || warn "THP อาจยังไม่ disabled"
}
run_always "step5_thp" _step5

# =============================================================
hdr "STEP 6 — NIC TUNE (${NIC})"
_step6() {
    ip link show "$NIC" &>/dev/null || { echo "NIC ${NIC} ไม่พบ"; return 1; }

    local qdisc="fq"
    grep -q "default_qdisc = fq_codel" /etc/sysctl.d/99-vps-tune.conf 2>/dev/null \
        && qdisc="fq_codel"

    # offload
    ethtool -K "$NIC" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null \
        || warn "ethtool offload บางอย่าง fail"

    # pause frame off — ป้องกัน head-of-line blocking
    ethtool -A "$NIC" rx off tx off 2>/dev/null || true

    # ring buffer — ดึง max จาก NIC จริงก่อน ไม่ hardcode
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

    # interrupt coalescing — ปิดทั้ง rx และ tx = latency ต่ำสุด
    ethtool -C "$NIC" rx-usecs 0 tx-usecs 0 2>/dev/null || true

    # TX queue
    ip link set "$NIC" txqueuelen 10000

    # tc fq — ไม่มี flow_limit
    tc qdisc del dev "$NIC" root 2>/dev/null || true
    tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
        quantum "${TC_QUANTUM}" \
        buckets "${TC_BUCKETS}" \
        2>/dev/null || warn "tc ${qdisc} fail"

    # persist
    mkdir -p /etc/networkd-dispatcher/routable.d
    cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
set -uo pipefail
NIC="${NIC}"
QDISC="${qdisc}"
RX_MAX="${rx_max}"
TX_MAX="${tx_max}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}" 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 0 tx-usecs 0 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 10000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
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

# =============================================================
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
    [ "$found" -eq 1 ] || warn "ไม่พบ block device"
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

# =============================================================
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

# =============================================================
hdr "STEP 9 — SYSTEM LIMITS (UNLIMITED)"
_step9() {
    cat > /etc/security/limits.d/99-xui.conf << 'EOF'
# VPS SETUP UNLIMITED v5.1
*    soft nofile  unlimited
*    hard nofile  unlimited
*    soft nproc   unlimited
*    hard nproc   unlimited
*    soft memlock unlimited
*    hard memlock unlimited
*    soft stack   unlimited
*    hard stack   unlimited
*    soft sigpending unlimited
*    hard sigpending unlimited
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

# =============================================================
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
    wait_service_active x-ui 30 || { echo "x-ui ไม่ขึ้นหลัง override"; return 1; }
}
run_always "step10_xui_override" _step10

# =============================================================
hdr "STEP 11 — POST-REBOOT VERIFY SERVICE"
_step11() {
    local _NIC="$NIC" _PANEL_PORT="$PANEL_PORT"
    local _RMEM_MAX="$RMEM_MAX" _BASE_MSS="$BASE_MSS"
    local _TC_QUANTUM="$TC_QUANTUM" _OPEN_PORTS="${OPEN_PORTS[*]}"

    cat > /usr/local/bin/vps-verify << VEOF
#!/usr/bin/env bash
set -uo pipefail
export LANG=C
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
PASS=0; FAIL=0; WARN=0
ok()  { echo -e "  \${GRN}✔\${RST}  \$1"; ((PASS++))  || true; }
bad() { echo -e "  \${RED}✘\${RST}  \$1"; ((FAIL++))  || true; }
wr()  { echo -e "  \${YEL}⚠\${RST}  \$1"; ((WARN++))  || true; }
info(){ echo -e "  \${CYN}ℹ\${RST}  \$1"; }

NIC="${_NIC}"
PANEL_PORT="${_PANEL_PORT}"
RMEM_MAX="${_RMEM_MAX}"
BASE_MSS="${_BASE_MSS}"
TC_QUANTUM="${_TC_QUANTUM}"
OPEN_PORTS=(${_OPEN_PORTS})

chk_sysctl() {
    local key="\$1" op="\$2" val="\$3" label="\$4"
    local cur; cur=\$(sysctl -n "\$key" 2>/dev/null || echo "ERR")
    [ "\$cur" = "ERR" ] && { wr "\$label — ไม่พบ key"; return; }
    case "\$op" in
        eq) [ "\$cur" -eq "\$val" ] 2>/dev/null && ok "\$label (\$cur)" || bad "\$label (\$cur ≠ \$val)" ;;
        ge) [ "\$cur" -ge "\$val" ] 2>/dev/null && ok "\$label (\$cur)" || bad "\$label (\$cur < \$val)" ;;
    esac
}
chk_service() {
    systemctl is-active  "\$1" &>/dev/null && ok "\$1 running" || bad "\$1 ไม่ทำงาน"
    systemctl is-enabled "\$1" &>/dev/null && ok "\$1 enabled" || bad "\$1 ไม่ enabled"
}

echo ""
echo -e "\${BLD}\${CYN}╔══════════════════════════════════════════════════╗\${RST}"
echo -e "\${BLD}\${CYN}║   VPS VERIFY v5.1 — UNLIMITED                   ║\${RST}"
echo -e "\${BLD}\${CYN}╚══════════════════════════════════════════════════╝\${RST}"
echo ""

echo -e "\${BLD}[ UFW ]\${RST}"
UFW_STATUS=\$(ufw status 2>/dev/null || echo "")
echo "\$UFW_STATUS" | grep -q "Status: active" && ok "UFW active" || bad "UFW ไม่ active"
for p in "\${OPEN_PORTS[@]}"; do
    echo "\$UFW_STATUS" | grep -q "^\${p}/tcp" && ok "Port \${p}" || bad "Port \${p} ไม่เปิด"
done
echo ""

echo -e "\${BLD}[ x-ui ]\${RST}"
chk_service x-ui
XUI_PID=\$(systemctl show -p MainPID x-ui 2>/dev/null | cut -d= -f2 || echo 0)
if [ "\${XUI_PID:-0}" -gt 0 ] && [ -f "/proc/\${XUI_PID}/status" ]; then
    VMRSS=\$(awk '/VmRSS/{print int(\$2/1024)}' "/proc/\${XUI_PID}/status" 2>/dev/null || echo "?")
    ok "x-ui RAM: \${VMRSS} MB"
    NOFILE_LIMIT=\$(awk '/open files/{print \$4}' "/proc/\${XUI_PID}/limits" 2>/dev/null || echo "?")
    ok "x-ui nofile limit: \${NOFILE_LIMIT}"
    OOM_ADJ=\$(cat "/proc/\${XUI_PID}/oom_score_adj" 2>/dev/null || echo "?")
    ok "x-ui OOM adj: \${OOM_ADJ} (expect -1000)"
fi
curl -sf --max-time 5 "http://localhost:\${PANEL_PORT}/login" &>/dev/null \
    && ok "Panel HTTP (:\${PANEL_PORT})" || wr "Panel ไม่ตอบ — ตั้ง inbound ก่อน"
echo ""

echo -e "\${BLD}[ Services ]\${RST}"
for svc in thp-disable nic-tune cpu-performance; do
    systemctl is-enabled "\$svc" &>/dev/null && ok "\$svc enabled" || wr "\$svc ไม่ enabled"
done
echo ""

echo -e "\${BLD}[ TCP / Kernel ]\${RST}"
BBR=\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
[ "\$BBR" = "bbr" ] && ok "BBR active" || wr "congestion: \$BBR"
QDISC=\$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
echo "\$QDISC" | grep -qE "^(fq|fq_codel)$" && ok "qdisc = \$QDISC" || bad "qdisc = \$QDISC"
tc qdisc show dev "\$NIC" 2>/dev/null | grep -q "quantum \${TC_QUANTUM}" \
    && ok "tc quantum \${TC_QUANTUM}" || wr "tc quantum ไม่ถูก"
chk_sysctl net.core.rmem_max             ge "\$RMEM_MAX"   "rmem_max (INT_MAX)"
chk_sysctl net.core.wmem_max             ge "\$RMEM_MAX"   "wmem_max (INT_MAX)"
chk_sysctl net.ipv4.tcp_moderate_rcvbuf  eq 1              "moderate_rcvbuf = 1 (BBR auto-tune)"
chk_sysctl net.ipv4.tcp_adv_win_scale    eq -1             "adv_win_scale = -1 (87.5% window)"
chk_sysctl net.ipv4.tcp_base_mss         eq "\$BASE_MSS"   "tcp_base_mss"
chk_sysctl net.core.somaxconn            ge 4194304        "somaxconn"
chk_sysctl net.ipv4.tcp_max_syn_backlog  ge 4194304        "syn_backlog"
chk_sysctl net.core.netdev_max_backlog   ge 4194304        "netdev_backlog"
chk_sysctl net.ipv4.tcp_max_tw_buckets  ge 2000000         "max_tw_buckets"
chk_sysctl vm.swappiness                 eq 0              "swappiness = 0"
chk_sysctl vm.overcommit_memory          eq 1              "overcommit = 1"
chk_sysctl vm.overcommit_ratio           ge 200            "overcommit_ratio = 200"
chk_sysctl vm.min_free_kbytes            eq 8192           "min_free_kbytes = 8192"
chk_sysctl fs.file-max                   ge 9000000000     "fs.file-max (near INT64_MAX)"
echo ""

echo -e "\${BLD}[ THP / NIC / Disk ]\${RST}"
grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
    && ok "THP disabled" || bad "THP ยังเปิดอยู่"
ip link show "\$NIC" &>/dev/null && ok "NIC \${NIC} up" || bad "\${NIC} ไม่พบ"
TXQLEN=\$(cat "/sys/class/net/\${NIC}/tx_queue_len" 2>/dev/null || echo 0)
[ "\$TXQLEN" -ge 10000 ] && ok "txqueuelen \${TXQLEN}" || wr "txqueuelen ต่ำ (\${TXQLEN})"
ethtool -k "\$NIC" 2>/dev/null | grep -q 'generic-receive-offload: off' \
    && ok "GRO off" || wr "GRO ยัง on"
if command -v ethtool &>/dev/null; then
    PAUSE=\$(ethtool -a "\$NIC" 2>/dev/null | grep -c 'off' || echo 0)
    [ "\$PAUSE" -ge 2 ] && ok "Pause frames off (rx+tx)" || wr "Pause frames ยังเปิด"
fi
for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/\${DEV}" ] || continue
    SCHED=\$(cat "/sys/block/\${DEV}/queue/scheduler" 2>/dev/null || echo "?")
    echo "\$SCHED" | grep -qE '\[none\]|\[mq-deadline\]' \
        && ok "I/O scheduler OK (\${DEV})" || wr "scheduler (\${DEV}: \$SCHED)"
done
echo ""

echo -e "\${BLD}[ Limits ]\${RST}"
NOFILE=\$(ulimit -Hn 2>/dev/null || echo 0)
[ "\$NOFILE" = "unlimited" ] && ok "nofile: unlimited" || wr "nofile: \${NOFILE} (ไม่ unlimited)"
echo ""

echo -e "\${BLD}[ Ports & Connections ]\${RST}"
ss -tlnp 2>/dev/null | grep -q ':80 ' \
    && ok "Port 80 listening" || wr "Port 80 ไม่ได้ฟัง"
ss -tlnp 2>/dev/null | grep -q ":\${PANEL_PORT} " \
    && ok "Port \${PANEL_PORT} listening" || wr "Port \${PANEL_PORT} ไม่ได้ฟัง"
WS_CONN=\$(ss -tnp 2>/dev/null | grep -c ':80' || echo 0)
info "WS connections on :80 = \${WS_CONN}"
echo ""

echo -e "\${BLD}[ System Resources ]\${RST}"
_read_cpu() {
    awk 'NR==1{t=0; for(i=2;i<=NF;i++) t+=\$i; printf "%d %d\n", t, \$10}' /proc/stat
}
read -r T1 S1 <<< "\$(_read_cpu)"
sleep 1
read -r T2 S2 <<< "\$(_read_cpu)"
TDIFF=\$(( T2-T1 )); SDIFF=\$(( S2-S1 ))
STEAL=0; [ "\$TDIFF" -gt 0 ] && STEAL=\$(( SDIFF*100/TDIFF ))
[ "\$STEAL" -le 5 ] && ok "CPU steal \${STEAL}%" || bad "CPU steal สูง \${STEAL}% — oversold"
FREE_MB=\$(( \$(awk '/MemAvailable/{print \$2}' /proc/meminfo) / 1024 ))
TOTAL_MB=\$(( \$(awk '/MemTotal/{print \$2}' /proc/meminfo) / 1024 ))
info "RAM: \${FREE_MB} MB free / \${TOTAL_MB} MB total"
GW=\$(ip route show default 2>/dev/null | awk '/^default/{print \$3; exit}')
if [ -n "\${GW:-}" ]; then
    RTT=\$(ping -c 3 -q "\$GW" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{printf "%.2f", \$5}')
    info "RTT to gateway: \${RTT:-?} ms"
fi
echo ""

echo -e "  ────────────────────────────────────────────────"
echo -e "  \${GRN}Pass: \${PASS}\${RST}  \${YEL}Warn: \${WARN}\${RST}  \${RED}Fail: \${FAIL}\${RST}"
[ "\$FAIL" -eq 0 ] && [ "\$WARN" -eq 0 ] \
    && echo -e "  \${BLD}\${GRN}✔ ทุกอย่างพร้อม 100%\${RST}" \
    || { [ "\$FAIL" -eq 0 ] \
        && echo -e "  \${BLD}\${YEL}✔ ใช้งานได้ มี \${WARN} warning\${RST}" \
        || echo -e "  \${BLD}\${RED}✘ มี \${FAIL} จุดที่ต้องแก้\${RST}"; }
PUB_IP=\$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")
echo ""
echo -e "  Panel: http://\${PUB_IP}:\${PANEL_PORT}"
echo -e "  Log  : /var/lib/vps-setup/install.log"
echo ""
VEOF
    chmod +x /usr/local/bin/vps-verify

    cat > /etc/systemd/system/vps-verify.service << 'EOF'
[Unit]
Description=VPS Post-boot Verify
After=network-online.target x-ui.service nic-tune.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-verify
StandardOutput=journal
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vps-verify.service
}
run_always "step11_verify_service" _step11

# =============================================================
hdr "DONE — SUMMARY"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps เสร็จแล้ว:${RST}"
while IFS= read -r line; do
    [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  $line"
done < "$STATE_FILE"
echo ""
echo -e "  ──────────────────────────────────────────────────"
echo -e "  ${BLD}Panel          :${RST} http://${PUB_IP}:${PANEL_PORT}"
echo -e "  ${BLD}NIC            :${RST} ${NIC} (MTU ${MTU})"
echo -e "  ${BLD}BASE_MSS       :${RST} ${BASE_MSS} bytes"
echo -e "  ${BLD}rmem/wmem      :${RST} INT_MAX = 2,147,483,647 bytes"
echo -e "  ${BLD}moderate_rcvbuf:${RST} 1 (BBR auto-tune เต็ม INT_MAX)"
echo -e "  ${BLD}adv_win_scale  :${RST} -1 (app window 87.5%)"
echo -e "  ${BLD}somaxconn      :${RST} 4,194,304"
echo -e "  ${BLD}nofile/nproc   :${RST} unlimited"
echo -e "  ${BLD}sigpending/msg :${RST} unlimited"
echo -e "  ${BLD}GOMAXPROCS     :${RST} ${VCPU}"
echo -e "  ${BLD}OOMScore       :${RST} -1000 (never killed)"
echo -e "  ${BLD}swappiness     :${RST} 0"
echo -e "  ${BLD}min_free_kb    :${RST} 8192 (ปล่อย RAM สูงสุด)"
echo -e "  ${BLD}overcommit     :${RST} 1 / ratio 200"
echo -e "  ${BLD}dirty          :${RST} 95% / 80% bg"
echo -e "  ${BLD}pause frames   :${RST} off (rx+tx)"
echo -e "  ${BLD}BBR            :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Qdisc          :${RST} $(tc qdisc show dev "$NIC" 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP            :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui           :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Log            :${RST} ${LOG_FILE}"
echo -e "  ──────────────────────────────────────────────────"
echo ""
echo -e "  ${BLD}${YEL}→ reboot แล้วรัน:${RST}  vps-verify"
echo ""
SCRIPT
echo "done"
