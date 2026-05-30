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

# ============================================================
#  PROFILE — แก้ที่นี่ที่เดียวเมื่อ migrate สเปค
# ============================================================
PROFILE_PROVIDER="ReadyIDC"
PROFILE_VCPU=1
PROFILE_RAM_MB=2048
PROFILE_OS="Ubuntu 22.04"
PROFILE_NIC="eth0"
PROFILE_RTT_MS=40
PROFILE_USERS=2
PROFILE_BW_PER_USER_MBPS=64
PROFILE_PANEL_PORT=2053

PROFILE_RMEM_MAX=16777216
PROFILE_WMEM_MAX=16777216
PROFILE_RMEM_DEFAULT=262144
PROFILE_WMEM_DEFAULT=262144
PROFILE_NOTSENT_LOWAT=16384
PROFILE_LIMIT_OUTPUT=2097152
PROFILE_BASE_MSS=1440
PROFILE_TC_QUANTUM=1514
PROFILE_TC_FLOW_LIMIT=200
PROFILE_TC_BUCKETS=8192
PROFILE_KEEPALIVE_TIME=60
PROFILE_KEEPALIVE_INTVL=10
PROFILE_KEEPALIVE_PROBES=5
PROFILE_FIN_TIMEOUT=10
PROFILE_GOMAXPROCS=1
PROFILE_MIN_FREE_KB=131072
PROFILE_SWAPPINESS=10

OPEN_PORTS=(22 80 443 2053 2083 2087 2096 8080 8443 54321)
# ============================================================

sep()  { echo -e "${DIM}${CYN}────────────────────────────────────────────────${RST}"; }
hdr()  { echo -e "\n${BLD}${CYN}▶  $1${RST}"; sep; }
ok()   { echo -e "  ${GRN}✔${RST}  $1"; }
warn() { echo -e "  ${YEL}⚠${RST}  $1"; }
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

# ============================================================
#  PRE-FLIGHT SPEC CHECK
# ============================================================
_preflight() {
    local fail=0

    local detected_os
    detected_os=$(grep -oP '(?<=^PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null || echo "unknown")
    if ! echo "$detected_os" | grep -q "22.04"; then
        warn "OS: ${detected_os} — expect ${PROFILE_OS}"
        fail=1
    else
        ok "OS: ${detected_os}"
    fi

    local detected_vcpu
    detected_vcpu=$(nproc 2>/dev/null || echo 0)
    if [ "$detected_vcpu" -ne "$PROFILE_VCPU" ]; then
        warn "vCPU: ${detected_vcpu} — expect ${PROFILE_VCPU}"
        fail=1
    else
        ok "vCPU: ${detected_vcpu}"
    fi

    local detected_ram_mb
    detected_ram_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    local ram_min=$(( PROFILE_RAM_MB * 80 / 100 ))
    local ram_max=$(( PROFILE_RAM_MB * 120 / 100 ))
    if [ "$detected_ram_mb" -lt "$ram_min" ] || [ "$detected_ram_mb" -gt "$ram_max" ]; then
        warn "RAM: ${detected_ram_mb} MB — expect ~${PROFILE_RAM_MB} MB"
        fail=1
    else
        ok "RAM: ${detected_ram_mb} MB"
    fi

    if ! ip link show "$PROFILE_NIC" &>/dev/null; then
        warn "NIC: ${PROFILE_NIC} ไม่พบ"
        fail=1
    else
        ok "NIC: ${PROFILE_NIC} found"
    fi

    if [ "$fail" -eq 1 ]; then
        echo ""
        echo -e "  ${YEL}${BLD}สเปคไม่ตรง PROFILE — รัน FORCE=1 bash ... เพื่อข้ามการตรวจ${RST}"
        [ "${FORCE:-0}" = "1" ] && { warn "FORCE=1 — ข้ามการตรวจสเปค"; return 0; }
        die "สเปคไม่ตรง ยกเลิก"
    fi
}

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║   VPS SETUP REMASTER v3.0 — VMESS/WS RTT 40ms  ║${RST}"
echo -e "${BLD}${CYN}║   ${PROFILE_PROVIDER} ${PROFILE_VCPU}vCPU/${PROFILE_RAM_MB}MB | NIC: ${PROFILE_NIC}$(printf '%*s' $((20-${#PROFILE_NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════╝${RST}"
echo ""

hdr "PRE-FLIGHT — SPEC CHECK"
_preflight

hdr "STEP 1 — UPDATE & DEPS"
_step1() {
    systemctl stop    unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    systemctl kill --kill-who=all unattended-upgrades 2>/dev/null || true
    echo "  รอ dpkg lock..."
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend \
                /var/lib/dpkg/lock \
                /var/cache/apt/archives/lock &>/dev/null; do
        if [ "$waited" -ge 90 ]; then
            warn "lock ไม่หลุดใน 90s — force kill"
            fuser -k /var/lib/dpkg/lock-frontend \
                     /var/lib/dpkg/lock \
                     /var/cache/apt/archives/lock 2>/dev/null || true
            sleep 3; break
        fi
        sleep 3; waited=$((waited+3))
    done
    dpkg --configure -a
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl ufw ethtool sqlite3 irqbalance iproute2
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
    [ -x "$xui_bin" ] || { echo "x-ui binary ไม่พบหลัง install"; return 1; }
    systemctl enable x-ui 2>/dev/null || true
    systemctl start  x-ui 2>/dev/null || true
    wait_service_active x-ui 20 || warn "x-ui อาจยังไม่พร้อม — ตรวจ: systemctl status x-ui"
}
run_skip "step3_3xui" _step3

hdr "STEP 4 — KERNEL TCP TUNE"
_step4() {
    cat > /etc/sysctl.d/99-vmess-tune.conf << EOF
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.rmem_max = ${PROFILE_RMEM_MAX}
net.core.wmem_max = ${PROFILE_WMEM_MAX}
net.core.rmem_default = ${PROFILE_RMEM_DEFAULT}
net.core.wmem_default = ${PROFILE_WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${PROFILE_RMEM_DEFAULT} ${PROFILE_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${PROFILE_WMEM_DEFAULT} ${PROFILE_WMEM_MAX}
net.ipv4.tcp_notsent_lowat = ${PROFILE_NOTSENT_LOWAT}
net.ipv4.tcp_limit_output_bytes = ${PROFILE_LIMIT_OUTPUT}
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.optmem_max = 131072
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = ${PROFILE_BASE_MSS}
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = ${PROFILE_KEEPALIVE_TIME}
net.ipv4.tcp_keepalive_intvl = ${PROFILE_KEEPALIVE_INTVL}
net.ipv4.tcp_keepalive_probes = ${PROFILE_KEEPALIVE_PROBES}
net.ipv4.tcp_fin_timeout = ${PROFILE_FIN_TIMEOUT}
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 8
vm.swappiness = ${PROFILE_SWAPPINESS}
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes = ${PROFILE_MIN_FREE_KB}
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1
kernel.sched_autogroup_enabled = 0
kernel.pid_max = 65536
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_abort_on_overflow = 0
EOF
    sysctl -p /etc/sysctl.d/99-vmess-tune.conf || sysctl --system
    tc qdisc del dev "$PROFILE_NIC" root 2>/dev/null || true
    tc qdisc add dev "$PROFILE_NIC" root handle 1: fq \
        quantum "${PROFILE_TC_QUANTUM}" \
        flow_limit "${PROFILE_TC_FLOW_LIMIT}" \
        buckets "${PROFILE_TC_BUCKETS}" || warn "tc fq บน ${PROFILE_NIC} fail"
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
    grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled || \
        warn "THP อาจยังไม่ disabled"
}
run_always "step5_thp" _step5

hdr "STEP 6 — NIC TUNE (${PROFILE_NIC})"
_step6() {
    ip link show "$PROFILE_NIC" &>/dev/null || { echo "NIC ${PROFILE_NIC} ไม่พบ"; return 1; }
    ethtool -K "$PROFILE_NIC" gro off lro off tso on gso on 2>/dev/null || \
        warn "ethtool offload บน ${PROFILE_NIC} บางอย่าง fail"
    ethtool -C "$PROFILE_NIC" rx-usecs 50 2>/dev/null || true
    ip link set "$PROFILE_NIC" txqueuelen 2000
    tc qdisc del dev "$PROFILE_NIC" root 2>/dev/null || true
    tc qdisc add dev "$PROFILE_NIC" root handle 1: fq \
        quantum "${PROFILE_TC_QUANTUM}" \
        flow_limit "${PROFILE_TC_FLOW_LIMIT}" \
        buckets "${PROFILE_TC_BUCKETS}"

    mkdir -p /etc/networkd-dispatcher/routable.d
    cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
set -uo pipefail
NIC="${PROFILE_NIC}"
TC_QUANTUM="${PROFILE_TC_QUANTUM}"
TC_FLOW_LIMIT="${PROFILE_TC_FLOW_LIMIT}"
TC_BUCKETS="${PROFILE_TC_BUCKETS}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro off lro off tso on gso on 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 50 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 2000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: fq \
    quantum "\${TC_QUANTUM}" flow_limit "\${TC_FLOW_LIMIT}" buckets "\${TC_BUCKETS}"
NEOF
    chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh

    cat > /etc/systemd/system/nic-tune.service << SEOF
[Unit]
Description=NIC Tuning for ${PROFILE_NIC}
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
    for DEV in sda vda xvda nvme0n1 nvme1n1; do
        [ -b "/dev/${DEV}" ] || continue
        found=1
        local rotational
        rotational=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
        if [ "$rotational" = "0" ]; then
            echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
        else
            echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
        fi
        echo 0   > "/sys/block/${DEV}/queue/add_random"  2>/dev/null || true
        echo 256 > "/sys/block/${DEV}/queue/nr_requests" 2>/dev/null || true
    done
    [ "$found" -eq 1 ] || warn "ไม่พบ block device — ข้าม I/O scheduler"
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
*    soft nofile 1048576
*    hard nofile 1048576
*    soft nproc  65535
*    hard nproc  65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc  65535
root hard nproc  65535
EOF
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        [ -f "$pam_file" ] || continue
        grep -qxF 'session required pam_limits.so' "$pam_file" \
            || echo 'session required pam_limits.so' >> "$pam_file"
    done
    echo 'fs.file-max = 2097152' > /etc/sysctl.d/98-file-max.conf
    sysctl -p /etc/sysctl.d/98-file-max.conf
}
run_always "step9_limits" _step9

hdr "STEP 10 — x-ui SYSTEMD OVERRIDE"
_step10() {
    mkdir -p /etc/systemd/system/x-ui.service.d
    cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
LimitCORE=infinity
Restart=always
RestartSec=3
RestartPreventExitStatus=0
Environment=GOMAXPROCS=${PROFILE_GOMAXPROCS}
OOMScoreAdjust=-500
EOF
    systemctl daemon-reload
    systemctl restart x-ui
    wait_service_active x-ui 30 || { echo "x-ui ไม่ขึ้นหลัง override"; return 1; }
}
run_always "step10_xui_override" _step10

hdr "STEP 11 — POST-REBOOT VERIFY SERVICE"
_step11() {
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

NIC="${PROFILE_NIC}"
PANEL_PORT="${PROFILE_PANEL_PORT}"
RMEM_MAX="${PROFILE_RMEM_MAX}"
WMEM_MAX="${PROFILE_WMEM_MAX}"
NOTSENT_LOWAT="${PROFILE_NOTSENT_LOWAT}"
LIMIT_OUTPUT="${PROFILE_LIMIT_OUTPUT}"
BASE_MSS="${PROFILE_BASE_MSS}"
TC_QUANTUM="${PROFILE_TC_QUANTUM}"
MIN_FREE_KB="${PROFILE_MIN_FREE_KB}"
SWAPPINESS="${PROFILE_SWAPPINESS}"
OPEN_PORTS=(${OPEN_PORTS[@]})

chk_sysctl() {
    local key="\$1" op="\$2" val="\$3" label="\$4"
    local cur; cur=\$(sysctl -n "\$key" 2>/dev/null || echo "ERR")
    [ "\$cur" = "ERR" ] && { wr "\$label — ไม่พบ key"; return; }
    case "\$op" in
        eq) [ "\$cur" -eq "\$val" ] && ok "\$label (\$cur)"            || bad "\$label (\$cur ≠ \$val)"        ;;
        ge) [ "\$cur" -ge "\$val" ] && ok "\$label (\$cur)"            || bad "\$label (\$cur < \$val)"         ;;
        le) [ "\$cur" -le "\$val" ] && ok "\$label (\$cur)"            || wr  "\$label สูงเกิน (\$cur > \$val)" ;;
    esac
}
chk_service() {
    local svc="\$1"
    systemctl is-active  "\$svc" &>/dev/null && ok "\$svc running"  || bad "\$svc ไม่ทำงาน"
    systemctl is-enabled "\$svc" &>/dev/null && ok "\$svc enabled"  || bad "\$svc ไม่ enabled"
}

echo ""
echo -e "\${BLD}\${CYN}╔══════════════════════════════════════════════╗\${RST}"
echo -e "\${BLD}\${CYN}║   VPS POST-BOOT VERIFY v3.0 — RTT 40ms      ║\${RST}"
echo -e "\${BLD}\${CYN}╚══════════════════════════════════════════════╝\${RST}"
echo ""

echo -e "\${BLD}[ UFW ]\${RST}"
UFW_STATUS=\$(ufw status 2>/dev/null || echo "")
echo "\$UFW_STATUS" | grep -q "Status: active" && ok "UFW active" || bad "UFW ไม่ active"
for p in "\${OPEN_PORTS[@]}"; do
    echo "\$UFW_STATUS" | grep -q "^\${p}/tcp" \
        && ok "Port \${p} open" || bad "Port \${p} ไม่เปิด"
done
echo ""

echo -e "\${BLD}[ x-ui ]\${RST}"
chk_service x-ui
XUI_PID=\$(systemctl show -p MainPID x-ui 2>/dev/null | cut -d= -f2 || echo 0)
if [ "\${XUI_PID:-0}" -gt 0 ] && [ -f "/proc/\${XUI_PID}/status" ]; then
    VMRSS=\$(awk '/VmRSS/{print int(\$2/1024)}' "/proc/\${XUI_PID}/status" 2>/dev/null || echo "?")
    ok "x-ui RAM: \${VMRSS} MB"
fi
if curl -sf --max-time 5 "http://localhost:\${PANEL_PORT}" &>/dev/null || \
   curl -sf --max-time 5 "http://localhost:\${PANEL_PORT}/login" &>/dev/null; then
    ok "Panel HTTP responding (:${PROFILE_PANEL_PORT})"
else
    wr "Panel ไม่ตอบสนอง HTTP"
fi
echo ""

echo -e "\${BLD}[ Services ]\${RST}"
for svc in thp-disable nic-tune cpu-performance; do
    systemctl is-enabled "\$svc" &>/dev/null && ok "\$svc enabled" || wr "\$svc ไม่ enabled"
done
echo ""

echo -e "\${BLD}[ TCP / Kernel ]\${RST}"
BBR=\$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")
[ "\$BBR" = "bbr" ] && ok "BBR active" || bad "BBR ไม่ active (\$BBR)"
QDISC=\$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "none")
[ "\$QDISC" = "fq" ] && ok "default_qdisc = fq" || bad "default_qdisc ≠ fq (\$QDISC)"
tc qdisc show dev "\$NIC" 2>/dev/null | grep -q "quantum \${TC_QUANTUM}" \
    && ok "tc fq quantum \${TC_QUANTUM} OK" || wr "tc fq quantum ไม่ถูก"
chk_sysctl net.core.rmem_max               ge "\$RMEM_MAX"       "rmem_max"
chk_sysctl net.core.wmem_max               ge "\$WMEM_MAX"       "wmem_max"
chk_sysctl net.ipv4.tcp_notsent_lowat      le "\$NOTSENT_LOWAT"  "notsent_lowat"
chk_sysctl net.ipv4.tcp_limit_output_bytes le "\$LIMIT_OUTPUT"   "limit_output_bytes"
chk_sysctl net.ipv4.tcp_base_mss           eq "\$BASE_MSS"       "tcp_base_mss"
chk_sysctl net.ipv4.tcp_ecn                eq 0                  "ECN disabled"
chk_sysctl net.ipv4.tcp_fastopen           eq 0                  "TFO disabled"
chk_sysctl vm.swappiness                   le "\$SWAPPINESS"     "swappiness"
chk_sysctl vm.min_free_kbytes              ge "\$MIN_FREE_KB"    "min_free_kbytes"
chk_sysctl vm.overcommit_memory            eq 1                  "overcommit_memory"
echo ""

echo -e "\${BLD}[ THP / NIC / Disk ]\${RST}"
grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
    && ok "THP disabled" || bad "THP ยังเปิดอยู่"
ip link show "\$NIC" &>/dev/null && ok "NIC \${NIC} up" || bad "\${NIC} ไม่พบ"
TXQLEN=\$(cat "/sys/class/net/\${NIC}/tx_queue_len" 2>/dev/null || echo 0)
[ "\$TXQLEN" -ge 2000 ] && ok "txqueuelen OK (\$TXQLEN)" || wr "txqueuelen ต่ำ (\$TXQLEN)"
if command -v ethtool &>/dev/null; then
    ethtool -k "\$NIC" 2>/dev/null | grep -q 'generic-receive-offload: off' \
        && ok "GRO off" || wr "GRO ยัง on"
fi
for DEV in sda vda xvda nvme0n1 nvme1n1; do
    [ -b "/dev/\${DEV}" ] || continue
    SCHED=\$(cat "/sys/block/\${DEV}/queue/scheduler" 2>/dev/null || echo "unknown")
    echo "\$SCHED" | grep -qE '\[none\]|\[mq-deadline\]' \
        && ok "I/O Scheduler OK (\${DEV})" || wr "Scheduler (\${DEV}: \$SCHED)"
done
echo ""

echo -e "\${BLD}[ Limits ]\${RST}"
NOFILE=\$(ulimit -Hn 2>/dev/null || echo 0)
[ "\$NOFILE" -ge 1048576 ] && ok "nofile hard limit OK (\$NOFILE)" || bad "nofile ต่ำ (\$NOFILE)"
chk_sysctl fs.file-max ge 2097152 "fs.file-max"
echo ""

echo -e "\${BLD}[ Ports & Connections ]\${RST}"
ss -tlnp 2>/dev/null | grep -q ':80 ' \
    && ok "Port 80 listening" || wr "Port 80 ไม่ได้ฟัง — ตั้ง inbound ใน x-ui ก่อน"
ss -tlnp 2>/dev/null | grep -q ":\${PANEL_PORT} " \
    && ok "Port \${PANEL_PORT} listening" || wr "Port \${PANEL_PORT} ไม่ได้ฟัง"
WS_CONN=\$(ss -tnp 2>/dev/null | grep -c ':80' || echo 0)
ok "WS connections on :80 = \${WS_CONN}"
echo ""

echo -e "\${BLD}[ System Resources ]\${RST}"
_read_cpu() {
    awk 'NR==1{total=0; for(i=2;i<=NF;i++) total+=\$i; printf "%d %d\n", total, \$10}' \
        /proc/stat 2>/dev/null || echo "0 0"
}
read -r T1 S1 <<< "\$(_read_cpu)"
sleep 1
read -r T2 S2 <<< "\$(_read_cpu)"
TDIFF=\$(( T2 - T1 )); SDIFF=\$(( S2 - S1 ))
STEAL_PCT=0
[ "\$TDIFF" -gt 0 ] && STEAL_PCT=\$(( SDIFF * 100 / TDIFF ))
[ "\$STEAL_PCT" -le 5 ] \
    && ok "CPU steal OK (\${STEAL_PCT}%)" \
    || bad "CPU steal สูง (\${STEAL_PCT}%) — VPS อาจ oversold"
FREE_MB=\$(( \$(awk '/MemAvailable/{print \$2}' /proc/meminfo 2>/dev/null || echo 0) / 1024 ))
[ "\$FREE_MB" -ge 200 ] \
    && ok "RAM available OK (\${FREE_MB} MB)" \
    || wr "RAM เหลือน้อย (\${FREE_MB} MB)"
echo ""

echo -e "  ──────────────────────────────────────────"
echo -e "  \${GRN}Pass: \${PASS}\${RST}  \${YEL}Warn: \${WARN}\${RST}  \${RED}Fail: \${FAIL}\${RST}"
if [ "\$FAIL" -eq 0 ] && [ "\$WARN" -eq 0 ]; then
    echo -e "  \${BLD}\${GRN}✔ ทุกอย่างพร้อม 100%\${RST}"
elif [ "\$FAIL" -eq 0 ]; then
    echo -e "  \${BLD}\${YEL}✔ ใช้งานได้ แต่มี \${WARN} คำเตือน\${RST}"
else
    echo -e "  \${BLD}\${RED}✘ มี \${FAIL} จุดที่ต้องแก้\${RST}"
fi
PUB_IP=\$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
       || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
       || echo "N/A")
echo ""
echo -e "  Panel : http://\${PUB_IP}:\${PANEL_PORT}"
echo -e "  Log   : /var/lib/vps-setup/install.log"
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

hdr "DONE — SUMMARY"
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null \
      || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps เสร็จแล้ว:${RST}"
while IFS= read -r line; do
    [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  $line"
done < "$STATE_FILE"
echo ""
echo -e "  ──────────────────────────────────────────────"
echo -e "  ${BLD}Panel  :${RST} http://${PUB_IP}:${PROFILE_PANEL_PORT}"
echo -e "  ${BLD}NIC    :${RST} ${PROFILE_NIC}"
echo -e "  ${BLD}Profile:${RST} ${PROFILE_PROVIDER} ${PROFILE_VCPU}vCPU/${PROFILE_RAM_MB}MB RTT${PROFILE_RTT_MS}ms ${PROFILE_USERS}users"
echo -e "  ${BLD}BBR    :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Qdisc  :${RST} $(tc qdisc show dev "$PROFILE_NIC" 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP    :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui   :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Log    :${RST} ${LOG_FILE}"
echo -e "  ──────────────────────────────────────────────"
echo ""
echo -e "  ${BLD}${YEL}→ reboot แล้วรัน:${RST}  vps-verify"
echo ""
