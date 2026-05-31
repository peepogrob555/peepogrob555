#!/usr/bin/env bash
# =============================================================
#  VPS SETUP UNLIMITED v6.0  ██████████████████████████████
#  RTT=0.5ms / BW=500Gbps / ABSOLUTELY NO LIMITS / NO CAPS
#  BDP = 500Gbps × 0.5ms = 31,250,000 bytes
#  tcp_base_mss = 1440 (HARDCODED / NO AUTO)
#  NIC: auto-detect จาก default route
#  MODE: MAXIMUM CHAOS — ทุกอย่างเปิดหมด ไม่มีขีดจำกัด
# =============================================================
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; MGN='\033[0;35m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

STATE_DIR="/var/lib/vps-setup"
STATE_FILE="${STATE_DIR}/steps.done"
LOG_FILE="${STATE_DIR}/install.log"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

sep()  { echo -e "${DIM}${CYN}────────────────────────────────────────────────────────${RST}"; }
hdr()  { echo -e "\n${BLD}${MGN}▶  $1${RST}"; sep; }
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
#  CONSTANTS — MAXIMUM CHAOS EDITION
#
#  RTT  = 0.5ms  = 0.0005s
#  BW   = 500Gbps = 62,500,000,000 bytes/s
#  BDP  = 62,500,000,000 × 0.0005 = 31,250,000 bytes
#
#  INT_MAX   (signed 32-bit)  = 2,147,483,647
#  INT64_MAX (signed 64-bit)  = 9,223,372,036,854,775,807
#
#  tcp_base_mss = 1440 — HARDCODED, ไม่มีการคำนวณจาก MTU
# =============================================================

# ── Socket buffers ─────────────────────────────────────────────
# ตั้งค่าเป็น INT_MAX (2^31-1) สูงสุดที่ kernel signed-int รับได้
RMEM_MAX=2147483647
WMEM_MAX=2147483647

# ── Default buffer = BDP ──────────────────────────────────────
# 500Gbps × 0.5ms = 31,250,000 bytes — kernel จะ grow จากนี้ถึง INT_MAX
RMEM_DEFAULT=31250000
WMEM_DEFAULT=31250000

# ── tcp_limit_output_bytes = INT_MAX (ปิด anti-bufferbloat) ───
LIMIT_OUTPUT=2147483647

# ── tcp_base_mss — LOCKED 1440 ──────────────────────────────
BASE_MSS=1440

# ── TC (Traffic Control) ─────────────────────────────────────
# quantum = jumbo segment = 65535 (max TCP payload unsigned)
# buckets = 2^17 = 131072 — flow hash table ใหญ่มาก
TC_QUANTUM=65535
TC_BUCKETS=131072

# ── Keepalive — aggressive สำหรับ RTT 0.5ms ─────────────────
KEEPALIVE_TIME=10       # probe หลังจาก idle 10s (เดิม 30s)
KEEPALIVE_INTVL=2       # ส่ง probe ทุก 2s (เดิม 5s)
KEEPALIVE_PROBES=3      # ตัดหลัง 3 probe ไม่ตอบ

# ── FIN / SYN ────────────────────────────────────────────────
FIN_TIMEOUT=3           # รอ FIN แค่ 3s (RTT 0.5ms ปิดได้เร็ว)
SYN_RETRIES=2
SYNACK_RETRIES=2
RETRIES2=5              # data retransmit สูงสุด 5 ครั้งก่อนตัด

# ── Backlog — สูงสุด kernel ───────────────────────────────────
BACKLOG=4194304

# ── Ports ────────────────────────────────────────────────────
PANEL_PORT="${PANEL_PORT:-2053}"
OPEN_PORTS=(22 80 443 2053 2083 2087 2096 8080 8443 54321)

# ── NIC auto-detect ──────────────────────────────────────────
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

VCPU=$(nproc 2>/dev/null || echo 1)

echo ""
echo -e "${BLD}${MGN}╔══════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${MGN}║   VPS SETUP UNLIMITED v6.0  ████████████████████████████   ║${RST}"
echo -e "${BLD}${MGN}║   RTT=0.5ms / 500Gbps / ABSOLUTELY NO LIMITS / NO CAPS    ║${RST}"
echo -e "${BLD}${MGN}║   MODE: MAXIMUM CHAOS — ไม่มีขีดจำกัดใดๆ ทั้งสิ้น          ║${RST}"
echo -e "${BLD}${MGN}║   NIC: ${NIC}$(printf '%*s' $((55-${#NIC})) '')║${RST}"
echo -e "${BLD}${MGN}╚══════════════════════════════════════════════════════════════╝${RST}"
echo ""
info "NIC           : ${NIC} (MTU ${MTU})"
info "BASE_MSS      : ${BASE_MSS} bytes ← HARDCODED, ไม่คำนวณจาก MTU"
info "vCPU          : ${VCPU} → GOMAXPROCS=${VCPU}"
info "rmem/wmem MAX : INT_MAX = 2,147,483,647 bytes"
info "rmem/wmem DEF : BDP = 31,250,000 bytes (500Gbps × 0.5ms)"
info "TC quantum    : ${TC_QUANTUM} / buckets: ${TC_BUCKETS}"
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
hdr "STEP 4 — KERNEL TCP TUNE (MAXIMUM CHAOS / NO LIMITS)"
_step4() {
    # ── Congestion Control ────────────────────────────────────
    local cc="bbr"
    modprobe tcp_bbr 2>/dev/null || true
    # ลอง load bbr2 ก่อน (kernel ≥ 5.19)
    modprobe tcp_bbr2 2>/dev/null && cc="bbr2" || true
    grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
        || { warn "BBR ไม่รองรับ — fallback cubic"; cc="cubic"; }

    # ── Qdisc ────────────────────────────────────────────────
    local qdisc="fq"
    if ! modinfo sch_fq &>/dev/null 2>&1; then
        warn "fq ไม่รองรับ — fallback fq_codel"; qdisc="fq_codel"
    fi

    cat > /etc/sysctl.d/99-vps-tune.conf << EOF
# ╔══════════════════════════════════════════════════════════════╗
# ║  VPS SETUP UNLIMITED v6.0 — MAXIMUM CHAOS EDITION           ║
# ║  RTT=0.5ms  BW=500Gbps  BDP=31,250,000 bytes                ║
# ║  tcp_base_mss=1440 (HARDCODED)                               ║
# ║  Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ╚══════════════════════════════════════════════════════════════╝

# ══════════════════════════════════════════════════════════════
#  CONGESTION / QDISC
# ══════════════════════════════════════════════════════════════
net.ipv4.tcp_congestion_control = ${cc}
net.core.default_qdisc          = ${qdisc}

# ══════════════════════════════════════════════════════════════
#  SOCKET BUFFERS — INT_MAX (2,147,483,647 bytes)
#  Default = BDP = 500Gbps × 0.5ms = 31,250,000 bytes
#  kernel จะ auto-grow จาก default → INT_MAX ตาม load จริง
# ══════════════════════════════════════════════════════════════
net.core.rmem_max     = ${RMEM_MAX}
net.core.wmem_max     = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}

# ══════════════════════════════════════════════════════════════
#  TCP BUFFER TUNING
# ══════════════════════════════════════════════════════════════
# moderate_rcvbuf=1: BBR/kernel auto-tune buffer ขึ้นถึง rmem_max
net.ipv4.tcp_moderate_rcvbuf = 1

# adv_win_scale=-2: app recv window = 75% ของ socket buffer
# (ใหญ่กว่า -1=87.5% ใน absolute แต่ conservative ต่อ overhead)
# เปลี่ยนเป็น -2 เพื่อ reserve น้อยลง → app ได้ buffer มากกว่า
net.ipv4.tcp_adv_win_scale = -2

# notsent_lowat: ไม่ตั้ง = kernel default
# limit_output_bytes = INT_MAX = ปิด pacing throttle ทั้งหมด
net.ipv4.tcp_limit_output_bytes = ${LIMIT_OUTPUT}

# ══════════════════════════════════════════════════════════════
#  BACKLOG — ไม่มีขีดจำกัด
# ══════════════════════════════════════════════════════════════
net.core.netdev_max_backlog  = ${BACKLOG}
net.core.somaxconn           = ${BACKLOG}
net.ipv4.tcp_max_syn_backlog = ${BACKLOG}
net.core.optmem_max          = 1073741824

# ══════════════════════════════════════════════════════════════
#  MTU / MSS — HARDCODED 1440 (ไม่คำนวณ ไม่ auto detect)
# ══════════════════════════════════════════════════════════════
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_base_mss    = ${BASE_MSS}

# ══════════════════════════════════════════════════════════════
#  TCP FEATURES
# ══════════════════════════════════════════════════════════════
net.ipv4.tcp_fastopen       = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps     = 1
net.ipv4.tcp_sack           = 1
net.ipv4.tcp_dsack          = 1
net.ipv4.tcp_ecn            = 0
net.ipv4.tcp_low_latency    = 1

# ══════════════════════════════════════════════════════════════
#  TIME_WAIT — ไม่มี limit ใดๆ
# ══════════════════════════════════════════════════════════════
net.ipv4.tcp_tw_reuse        = 1
net.ipv4.tcp_max_tw_buckets  = 2000000
net.ipv4.ip_local_port_range = 1024 65535

# ══════════════════════════════════════════════════════════════
#  KEEPALIVE — aggressive สำหรับ RTT 0.5ms
# ══════════════════════════════════════════════════════════════
net.ipv4.tcp_keepalive_time   = ${KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl  = ${KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${KEEPALIVE_PROBES}
net.ipv4.tcp_fin_timeout      = ${FIN_TIMEOUT}
net.ipv4.tcp_syn_retries      = ${SYN_RETRIES}
net.ipv4.tcp_synack_retries   = ${SYNACK_RETRIES}
net.ipv4.tcp_retries2         = ${RETRIES2}

# ══════════════════════════════════════════════════════════════
#  MEMORY — ปล่อยทุกหยดให้ใช้ได้ / ไม่ swap
# ══════════════════════════════════════════════════════════════
vm.swappiness                = 0
vm.dirty_ratio               = 95
vm.dirty_background_ratio    = 80
vm.dirty_expire_centisecs    = 3000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes           = 4096
vm.vfs_cache_pressure        = 50
vm.overcommit_memory         = 1
vm.overcommit_ratio          = 200
vm.page-cluster              = 0

# ══════════════════════════════════════════════════════════════
#  FILESYSTEM — near INT64_MAX
# ══════════════════════════════════════════════════════════════
fs.file-max      = 9223372036854775807
fs.nr_open       = 2147483584
fs.pipe-max-size = 1073741824
fs.aio-max-nr    = 1048576

# ══════════════════════════════════════════════════════════════
#  KERNEL — พิเรนขั้นสุด
# ══════════════════════════════════════════════════════════════
kernel.sched_autogroup_enabled  = 0
kernel.pid_max                  = 4194304
kernel.threads-max              = 4194304
kernel.sched_migration_cost_ns  = 5000000
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.perf_event_paranoid      = -1
kernel.dmesg_restrict           = 0
kernel.kptr_restrict            = 0

# ══════════════════════════════════════════════════════════════
#  NETWORK PERFORMANCE
# ══════════════════════════════════════════════════════════════
net.core.busy_poll              = 50
net.core.busy_read              = 50
net.core.dev_weight             = 64
net.core.netdev_budget          = 600
net.core.netdev_budget_usecs    = 8000

# ══════════════════════════════════════════════════════════════
#  SECURITY MINIMAL — ปิดแค่ที่อันตรายจริง
# ══════════════════════════════════════════════════════════════
net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_abort_on_overflow       = 0
EOF

    sysctl -p /etc/sysctl.d/99-vps-tune.conf || sysctl --system

    # ── TC fq on NIC ─────────────────────────────────────────
    tc qdisc del dev "$NIC" root 2>/dev/null || true
    tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
        quantum "${TC_QUANTUM}" \
        buckets "${TC_BUCKETS}" \
        2>/dev/null || warn "tc ${qdisc} บน ${NIC} fail"

    # ── Verify MSS locked ────────────────────────────────────
    local actual_mss
    actual_mss=$(sysctl -n net.ipv4.tcp_base_mss 2>/dev/null || echo "?")
    [ "$actual_mss" = "$BASE_MSS" ] \
        && ok "tcp_base_mss LOCKED = ${BASE_MSS}" \
        || warn "tcp_base_mss = ${actual_mss} (คาดว่า ${BASE_MSS})"
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
hdr "STEP 6 — NIC TUNE (${NIC}) — MAXIMUM CHAOS"
_step6() {
    ip link show "$NIC" &>/dev/null || { echo "NIC ${NIC} ไม่พบ"; return 1; }

    local qdisc="fq"
    grep -q "default_qdisc = fq_codel" /etc/sysctl.d/99-vps-tune.conf 2>/dev/null \
        && qdisc="fq_codel"

    # ── Offload: ปิด GRO/LRO (latency), เปิด TSO/GSO (throughput) ─
    ethtool -K "$NIC" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null \
        || warn "ethtool offload บางอย่าง fail"

    # ── Pause frame: ปิดทั้งหมด ─────────────────────────────
    ethtool -A "$NIC" rx off tx off 2>/dev/null || true

    # ── Ring buffer: ดึง max จาก NIC จริง ───────────────────
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

    # ── Interrupt coalescing: ปิด = latency ต่ำสุด ──────────
    ethtool -C "$NIC" rx-usecs 0 tx-usecs 0 2>/dev/null || true

    # ── TX queue ─────────────────────────────────────────────
    ip link set "$NIC" txqueuelen 10000

    # ── TC fq — ไม่มี flow_limit ────────────────────────────
    tc qdisc del dev "$NIC" root 2>/dev/null || true
    tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
        quantum "${TC_QUANTUM}" \
        buckets "${TC_BUCKETS}" \
        2>/dev/null || warn "tc ${qdisc} fail"

    # verify quantum
    tc qdisc show dev "$NIC" | grep -q "quantum ${TC_QUANTUM}" \
        && ok "tc quantum ${TC_QUANTUM} confirmed" \
        || warn "tc quantum อาจไม่ match"

    # ── Persist via networkd-dispatcher ──────────────────────
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
ethtool -K "\${NIC}" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}" 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 0 tx-usecs 0 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 10000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
    quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} 2>/dev/null || true
NEOF
    chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

    cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC Tuning for ${NIC} — UNLIMITED v6
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
        echo 2    > "/sys/block/${DEV}/queue/rq_affinity" 2>/dev/null || true
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
hdr "STEP 8 — CPU GOVERNOR + IRQ AFFINITY"
_step8() {
    # ── CPU performance governor ─────────────────────────────
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

    # ── IRQ balance ──────────────────────────────────────────
    systemctl enable --now irqbalance 2>/dev/null || true

    # ── CPU energy perf hint ─────────────────────────────────
    for f in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
        [ -f "$f" ] && echo 0 > "$f" 2>/dev/null || true   # 0 = performance
    done
}
run_always "step8_cpu_gov" _step8

# =============================================================
hdr "STEP 9 — SYSTEM LIMITS (ABSOLUTELY UNLIMITED)"
_step9() {
    cat > /etc/security/limits.d/99-xui.conf << 'EOF'
# VPS SETUP UNLIMITED v6.0 — ไม่มีขีดจำกัดใดๆ
*    soft nofile      unlimited
*    hard nofile      unlimited
*    soft nproc       unlimited
*    hard nproc       unlimited
*    soft memlock     unlimited
*    hard memlock     unlimited
*    soft stack       unlimited
*    hard stack       unlimited
*    soft sigpending  unlimited
*    hard sigpending  unlimited
*    soft msgqueue    unlimited
*    hard msgqueue    unlimited
*    soft rtprio      unlimited
*    hard rtprio      unlimited
*    soft nice        -20
*    hard nice        -20
root soft nofile      unlimited
root hard nofile      unlimited
root soft nproc       unlimited
root hard nproc       unlimited
root soft memlock     unlimited
root hard memlock     unlimited
root soft rtprio      unlimited
root hard rtprio      unlimited
EOF

    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        [ -f "$pam_file" ] || continue
        grep -qxF 'session required pam_limits.so' "$pam_file" \
            || echo 'session required pam_limits.so' >> "$pam_file"
    done

    # ── Systemd global limits ─────────────────────────────────
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-unlimited.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=infinity
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
DefaultLimitCORE=infinity
DefaultLimitSTACK=infinity
DefaultLimitSIGPENDING=infinity
DefaultLimitMSGQUEUE=infinity
DefaultLimitRTPRIO=infinity
EOF
    systemctl daemon-reexec || true
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
RestartSec=1
RestartPreventExitStatus=0
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=off
Environment=GOMEMLIMIT=0
OOMScoreAdjust=-1000
CPUSchedulingPolicy=other
Nice=-15
EOF
    systemctl daemon-reload
    systemctl restart x-ui
    wait_service_active x-ui 30 || { echo "x-ui ไม่ขึ้นหลัง override"; return 1; }
}
run_always "step10_xui_override" _step10

# =============================================================
hdr "STEP 11 — LOCK tcp_base_mss=1440 (ANTI-REVERT SERVICE)"
_step11() {
    # service นี้คอย enforce tcp_base_mss=1440 ทุก 60s
    # ป้องกัน kernel หรือ service อื่น reset ค่า
    cat > /etc/systemd/system/tcp-mss-lock.service << 'EOF'
[Unit]
Description=Lock tcp_base_mss=1440 forever
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c '\
    while true; do \
        sysctl -w net.ipv4.tcp_base_mss=1440 >/dev/null 2>&1; \
        sysctl -w net.ipv4.tcp_mtu_probing=0 >/dev/null 2>&1; \
        sleep 60; \
    done'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tcp-mss-lock.service
    ok "tcp_base_mss=1440 LOCKED — ทุก 60s"
}
run_always "step11_mss_lock" _step11

# =============================================================
hdr "STEP 12 — POST-REBOOT VERIFY SERVICE"
_step12() {
    local _NIC="$NIC" _PANEL_PORT="$PANEL_PORT"
    local _RMEM_MAX="$RMEM_MAX" _RMEM_DEFAULT="$RMEM_DEFAULT"
    local _BASE_MSS="$BASE_MSS"
    local _TC_QUANTUM="$TC_QUANTUM" _TC_BUCKETS="$TC_BUCKETS"
    local _OPEN_PORTS="${OPEN_PORTS[*]}"
    local _BACKLOG="$BACKLOG"

    cat > /usr/local/bin/vps-verify << VEOF
#!/usr/bin/env bash
set -uo pipefail
export LANG=C
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; MGN='\033[0;35m'; BLD='\033[1m'; RST='\033[0m'
PASS=0; FAIL=0; WARN=0
ok()  { echo -e "  \${GRN}✔\${RST}  \$1"; ((PASS++))  || true; }
bad() { echo -e "  \${RED}✘\${RST}  \$1"; ((FAIL++))  || true; }
wr()  { echo -e "  \${YEL}⚠\${RST}  \$1"; ((WARN++))  || true; }
info(){ echo -e "  \${CYN}ℹ\${RST}  \$1"; }

NIC="${_NIC}"
PANEL_PORT="${_PANEL_PORT}"
RMEM_MAX="${_RMEM_MAX}"
RMEM_DEFAULT="${_RMEM_DEFAULT}"
BASE_MSS="${_BASE_MSS}"
TC_QUANTUM="${_TC_QUANTUM}"
TC_BUCKETS="${_TC_BUCKETS}"
BACKLOG="${_BACKLOG}"
OPEN_PORTS=(${_OPEN_PORTS})

chk_sysctl() {
    local key="\$1" op="\$2" val="\$3" label="\$4"
    local cur; cur=\$(sysctl -n "\$key" 2>/dev/null || echo "ERR")
    [ "\$cur" = "ERR" ] && { wr "\$label — ไม่พบ key"; return; }
    case "\$op" in
        eq) [ "\$cur" -eq "\$val" ] 2>/dev/null && ok "\$label (\$cur)" || bad "\$label (\$cur ≠ \$val)" ;;
        ge) [ "\$cur" -ge "\$val" ] 2>/dev/null && ok "\$label (\$cur)" || bad "\$label (\$cur < \$val)" ;;
        str) [ "\$cur" = "\$val" ] && ok "\$label (\$cur)" || bad "\$label (\$cur ≠ \$val)" ;;
    esac
}
chk_service() {
    systemctl is-active  "\$1" &>/dev/null && ok "\$1 running" || bad "\$1 ไม่ทำงาน"
    systemctl is-enabled "\$1" &>/dev/null && ok "\$1 enabled" || bad "\$1 ไม่ enabled"
}

echo ""
echo -e "\${BLD}\${MGN}╔══════════════════════════════════════════════════════╗\${RST}"
echo -e "\${BLD}\${MGN}║   VPS VERIFY v6.0 — MAXIMUM CHAOS / NO LIMITS       ║\${RST}"
echo -e "\${BLD}\${MGN}║   RTT=0.5ms / 500Gbps / BDP=31,250,000 bytes         ║\${RST}"
echo -e "\${BLD}\${MGN}╚══════════════════════════════════════════════════════╝\${RST}"
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
    info "x-ui RAM: \${VMRSS} MB"
    NOFILE_LIMIT=\$(awk '/open files/{print \$4}' "/proc/\${XUI_PID}/limits" 2>/dev/null || echo "?")
    [ "\${NOFILE_LIMIT}" = "unlimited" ] && ok "x-ui nofile: unlimited" || wr "x-ui nofile: \${NOFILE_LIMIT}"
    OOM_ADJ=\$(cat "/proc/\${XUI_PID}/oom_score_adj" 2>/dev/null || echo "?")
    [ "\${OOM_ADJ}" = "-1000" ] && ok "x-ui OOM adj: -1000 (never killed)" || bad "x-ui OOM adj: \${OOM_ADJ}"
    NICE=\$(cat "/proc/\${XUI_PID}/stat" 2>/dev/null | awk '{print \$19}' || echo "?")
    info "x-ui nice: \${NICE}"
fi
curl -sf --max-time 5 "http://localhost:\${PANEL_PORT}/login" &>/dev/null \
    && ok "Panel HTTP (:\${PANEL_PORT})" || wr "Panel ไม่ตอบ — ตั้ง inbound ก่อน"
echo ""

echo -e "\${BLD}[ Services ]\${RST}"
for svc in thp-disable nic-tune cpu-performance tcp-mss-lock; do
    systemctl is-enabled "\$svc" &>/dev/null && ok "\$svc enabled" \
        || wr "\$svc ไม่ enabled"
    systemctl is-active "\$svc" &>/dev/null && ok "\$svc active" \
        || wr "\$svc ไม่ active"
done
echo ""

echo -e "\${BLD}[ TCP / Kernel — UNLIMITED v6 ]\${RST}"
CC=\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
echo "\$CC" | grep -qE "^(bbr|bbr2)$" && ok "Congestion: \$CC" || wr "Congestion: \$CC (คาด bbr/bbr2)"
QDISC=\$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "?")
echo "\$QDISC" | grep -qE "^(fq|fq_codel)$" && ok "qdisc = \$QDISC" || bad "qdisc = \$QDISC"
TC_OUT=\$(tc qdisc show dev "\$NIC" 2>/dev/null || echo "")
echo "\$TC_OUT" | grep -q "quantum \${TC_QUANTUM}" \
    && ok "tc quantum \${TC_QUANTUM}" || bad "tc quantum ไม่ถูก (คาด \${TC_QUANTUM})"
echo "\$TC_OUT" | grep -q "buckets \${TC_BUCKETS}" \
    && ok "tc buckets \${TC_BUCKETS}" || wr "tc buckets ไม่ถูก (คาด \${TC_BUCKETS})"

chk_sysctl net.core.rmem_max             ge "\$RMEM_MAX"      "rmem_max (INT_MAX)"
chk_sysctl net.core.wmem_max             ge "\$RMEM_MAX"      "wmem_max (INT_MAX)"
chk_sysctl net.core.rmem_default         ge "\$RMEM_DEFAULT"  "rmem_default (BDP=31.25MB)"
chk_sysctl net.core.wmem_default         ge "\$RMEM_DEFAULT"  "wmem_default (BDP=31.25MB)"
chk_sysctl net.ipv4.tcp_moderate_rcvbuf  eq 1                 "moderate_rcvbuf = 1 (BBR auto-tune)"
chk_sysctl net.ipv4.tcp_adv_win_scale    eq -2                "adv_win_scale = -2"
chk_sysctl net.ipv4.tcp_base_mss         eq "\$BASE_MSS"      "tcp_base_mss = 1440 (LOCKED)"
chk_sysctl net.ipv4.tcp_mtu_probing      eq 0                 "tcp_mtu_probing = 0 (off)"
chk_sysctl net.core.somaxconn            ge "\$BACKLOG"        "somaxconn ≥ 4M"
chk_sysctl net.ipv4.tcp_max_syn_backlog  ge "\$BACKLOG"        "syn_backlog ≥ 4M"
chk_sysctl net.core.netdev_max_backlog   ge "\$BACKLOG"        "netdev_backlog ≥ 4M"
chk_sysctl net.ipv4.tcp_max_tw_buckets  ge 2000000            "max_tw_buckets ≥ 2M"
chk_sysctl net.ipv4.tcp_fastopen         eq 3                  "tcp_fastopen = 3 (client+server)"
chk_sysctl net.ipv4.tcp_fin_timeout      eq 3                  "fin_timeout = 3s"
chk_sysctl net.ipv4.tcp_keepalive_time   eq 10                 "keepalive_time = 10s"
chk_sysctl net.ipv4.tcp_keepalive_intvl  eq 2                  "keepalive_intvl = 2s"
chk_sysctl vm.swappiness                 eq 0                  "swappiness = 0"
chk_sysctl vm.overcommit_memory          eq 1                  "overcommit = 1"
chk_sysctl vm.overcommit_ratio           ge 200                "overcommit_ratio = 200"
chk_sysctl vm.min_free_kbytes            eq 4096               "min_free_kbytes = 4096"
chk_sysctl fs.file-max                   ge 9000000000         "fs.file-max (near INT64_MAX)"
chk_sysctl fs.aio-max-nr                 ge 1048576            "aio-max-nr ≥ 1M"
echo ""

echo -e "\${BLD}[ THP / NIC / Disk ]\${RST}"
grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
    && ok "THP disabled" || bad "THP ยังเปิดอยู่"
ip link show "\$NIC" &>/dev/null && ok "NIC \${NIC} up" || bad "\${NIC} ไม่พบ"
TXQLEN=\$(cat "/sys/class/net/\${NIC}/tx_queue_len" 2>/dev/null || echo 0)
[ "\$TXQLEN" -ge 10000 ] && ok "txqueuelen \${TXQLEN}" || wr "txqueuelen ต่ำ (\${TXQLEN})"
ethtool -k "\$NIC" 2>/dev/null | grep -q 'generic-receive-offload: off' \
    && ok "GRO off" || wr "GRO ยัง on"
# ── Pause frames check (fixed) ────────────────────────────────
PAUSE_OUT=\$(ethtool -a "\$NIC" 2>/dev/null || true)
PAUSE=\$(echo "\$PAUSE_OUT" | awk '/RX:/{r=\$NF} /TX:/{t=\$NF} END{print (r=="off" && t=="off") ? "ok" : "on"}')
[ "\${PAUSE}" = "ok" ] && ok "Pause frames off (rx+tx)" || wr "Pause frames: \${PAUSE}"
for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/\${DEV}" ] || continue
    SCHED=\$(cat "/sys/block/\${DEV}/queue/scheduler" 2>/dev/null || echo "?")
    echo "\$SCHED" | grep -qE '\[none\]|\[mq-deadline\]' \
        && ok "I/O scheduler OK (\${DEV})" || wr "scheduler (\${DEV}: \$SCHED)"
done
echo ""

echo -e "\${BLD}[ Limits — MUST BE unlimited ]\${RST}"
NOFILE=\$(ulimit -Hn 2>/dev/null || echo 0)
[ "\$NOFILE" = "unlimited" ] && ok "nofile: unlimited" || bad "nofile: \${NOFILE} (ต้อง unlimited)"
NPROC=\$(ulimit -Hu 2>/dev/null || echo 0)
[ "\$NPROC" = "unlimited" ] && ok "nproc: unlimited"  || wr "nproc: \${NPROC}"
MEMLOCK=\$(ulimit -Hl 2>/dev/null || echo 0)
[ "\$MEMLOCK" = "unlimited" ] && ok "memlock: unlimited" || wr "memlock: \${MEMLOCK}"
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
    RTT=\$(ping -c 3 -q "\$GW" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/{printf "%.3f", \$5}')
    info "RTT to gateway: \${RTT:-?} ms  (target ≤ 0.5ms)"
fi
echo ""

echo -e "  ────────────────────────────────────────────────────"
echo -e "  \${GRN}Pass: \${PASS}\${RST}  \${YEL}Warn: \${WARN}\${RST}  \${RED}Fail: \${FAIL}\${RST}"
[ "\$FAIL" -eq 0 ] && [ "\$WARN" -eq 0 ] \
    && echo -e "  \${BLD}\${GRN}✔ ทุกอย่างพร้อม 100% — MAXIMUM CHAOS UNLOCKED\${RST}" \
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
Description=VPS Post-boot Verify v6.0
After=network-online.target x-ui.service nic-tune.service tcp-mss-lock.service
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
run_always "step12_verify_service" _step12

# =============================================================
hdr "DONE — SUMMARY"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

CC_NOW=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
QDISC_NOW=$(tc qdisc show dev "$NIC" 2>/dev/null | head -1 || echo "N/A")
THP_NOW=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "N/A")
XUI_NOW=$(systemctl is-active x-ui 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps เสร็จแล้ว:${RST}"
while IFS= read -r line; do
    [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  $line"
done < "$STATE_FILE"
echo ""
echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}${MGN}VPS SETUP UNLIMITED v6.0 — MAXIMUM CHAOS SUMMARY${RST}"
echo -e "  ══════════════════════════════════════════════════════════"
echo -e "  ${BLD}Panel          :${RST} http://${PUB_IP}:${PANEL_PORT}"
echo -e "  ${BLD}NIC            :${RST} ${NIC} (MTU ${MTU})"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}RTT target     :${RST} 0.5ms"
echo -e "  ${BLD}BW target      :${RST} 500Gbps"
echo -e "  ${BLD}BDP            :${RST} 31,250,000 bytes (500Gbps × 0.5ms)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}tcp_base_mss   :${RST} ${BASE_MSS} bytes ← LOCKED (ไม่มีการคำนวณ)"
echo -e "  ${BLD}tcp_mtu_probing:${RST} 0 (off — MSS ไม่เปลี่ยน)"
echo -e "  ${BLD}rmem/wmem MAX  :${RST} INT_MAX = 2,147,483,647 bytes"
echo -e "  ${BLD}rmem/wmem DEF  :${RST} BDP = 31,250,000 bytes"
echo -e "  ${BLD}adv_win_scale  :${RST} -2 (app window 75% of buffer)"
echo -e "  ${BLD}moderate_rcvbuf:${RST} 1 (BBR auto-grow ถึง INT_MAX)"
echo -e "  ${BLD}somaxconn      :${RST} 4,194,304"
echo -e "  ${BLD}tc quantum     :${RST} ${TC_QUANTUM} / buckets ${TC_BUCKETS}"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}nofile/nproc   :${RST} unlimited"
echo -e "  ${BLD}memlock/stack  :${RST} unlimited"
echo -e "  ${BLD}sigpending/msg :${RST} unlimited"
echo -e "  ${BLD}rtprio/nice    :${RST} unlimited / -20"
echo -e "  ${BLD}GOMAXPROCS     :${RST} ${VCPU}"
echo -e "  ${BLD}GOGC           :${RST} off (no GC pressure)"
echo -e "  ${BLD}OOMScore       :${RST} -1000 (never killed)"
echo -e "  ${BLD}RestartSec     :${RST} 1s (fast recovery)"
echo -e "  ──────────────────────────────────────────────────────────"
echo -e "  ${BLD}keepalive_time :${RST} ${KEEPALIVE_TIME}s"
echo -e "  ${BLD}keepalive_intvl:${RST} ${KEEPALIVE_INTVL}s"
echo -e "  ${BLD}fin_timeout    :${RST} ${FIN_TIMEOUT}s"
echo -e "  ${BLD}tcp_fastopen   :${RST} 3 (client+server)"
echo -e "  ${BLD}swappiness     :${RST} 0"
echo -e "  ${BLD}min_free_kb    :${RST} 4096 (ปล่อย RAM สูงสุด)"
echo -e "  ${BLD}overcommit     :${RST} 1 / ratio 200"
echo -e "  ${BLD}dirty          :${RST} 95% / 80% bg"
echo -e "  ${BLD}pause frames   :${RST} off (rx+tx)"
echo -e "  ${BLD}busy_poll      :${RST} 50µs"
echo -e "  ${BLD}BBR            :${RST} ${CC_NOW}"
echo -e "  ${BLD}Qdisc          :${RST} ${QDISC_NOW}"
echo -e "  ${BLD}THP            :${RST} ${THP_NOW}"
echo -e "  ${BLD}x-ui           :${RST} ${XUI_NOW}"
echo -e "  ${BLD}Log            :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════════"
echo ""
echo -e "  ${BLD}${YEL}→ reboot แล้วรัน:${RST}  vps-verify"
echo -e "  ${BLD}${MGN}→ MAXIMUM CHAOS MODE ACTIVE — ไม่มีขีดจำกัดใดๆ${RST}"
echo ""
