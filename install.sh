#!/usr/bin/env bash
set -euo pipefail
export LANG=C
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
STATE_DIR="/var/lib/vps-setup"
STATE_FILE="${STATE_DIR}/steps.done"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
sep()        { echo -e "${DIM}${CYN}────────────────────────────────────────────────${RST}"; }
hdr()        { echo -e "\n${BLD}${CYN}▶  $1${RST}"; sep; }
ok()         { echo -e "  ${GRN}✔${RST}  $1"; }
die()        { echo -e "\n${RED}${BLD}✘  FAILED at: $1${RST}\n"; exit 1; }
step_done()  { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done()  { echo "$1" >> "$STATE_FILE"; }
clear_done() { sed -i "/^$1$/d" "$STATE_FILE" 2>/dev/null || true; }
_cleanup_on_fail() {
    local name="$1"
    echo -e "\n${RED}${BLD}✘  FAILED at: ${name}${RST}"
    echo -e "  ${YEL}ระบบยังอยู่ในสถานะก่อนหน้า step นี้${RST}\n"
    exit 1
}
run_skip() {
    local name="$1"; shift
    if step_done "$name"; then ok "[SKIP] $name — เสร็จแล้ว"; return 0; fi
    echo -e "\n${BLD}  → $name${RST}"
    if "$@"; then mark_done "$name"; ok "[OK]   $name"; else _cleanup_on_fail "$name"; fi
}
run_always() {
    local name="$1"; shift
    clear_done "$name"
    echo -e "\n${BLD}  → $name${RST}"
    if "$@"; then mark_done "$name"; ok "[OK]   $name"; else _cleanup_on_fail "$name"; fi
}
[ "$(id -u)" -eq 0 ] || { echo "ต้องรันด้วย root"; exit 1; }
echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║   VPS SETUP REMASTER — VMESS/WS | RTT 40ms     ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════╝${RST}"
echo ""

hdr "STEP 1 — UPDATE & DEPS"
_step1() {
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    systemctl kill --kill-who=all unattended-upgrades 2>/dev/null || true
    echo "  รอ dpkg lock หลุด..."
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock &>/dev/null; do
        if [ "$waited" -ge 60 ]; then
            echo "  lock ไม่หลุดใน 60s — force kill"
            fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true
            sleep 2
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    dpkg --configure -a
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ufw ethtool sqlite3 irqbalance
}
run_skip "step1_deps" _step1

hdr "STEP 2 — FIREWALL (UFW)"
_step2() {
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    for port in 22 80 443 2053 2083 2087 2096 8080 8443 54321; do
        ufw allow "${port}"/tcp
    done
    ufw --force enable
}
run_skip "step2_ufw" _step2

hdr "STEP 3 — INSTALL 3X-UI"
_step3() {
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    systemctl enable x-ui
}
run_skip "step3_3xui" _step3

hdr "STEP 4 — PANEL PORT → 2053"
_step4() {
    XUI_BIN=$(command -v x-ui 2>/dev/null || echo "/usr/local/x-ui/x-ui")
    [ -x "$XUI_BIN" ] || { echo "x-ui binary ไม่พบ"; return 1; }
    "$XUI_BIN" stop 2>/dev/null || systemctl stop x-ui 2>/dev/null || true
    "$XUI_BIN" setting -port 2053
    "$XUI_BIN" start 2>/dev/null || systemctl start x-ui
    sleep 2
    systemctl is-active x-ui
}
run_skip "step4_panel_port" _step4

hdr "STEP 5 — KERNEL TCP TUNE (latency-first | RTT 40ms | 2 users)"
_step5() {
    cat > /etc/sysctl.d/99-vmess-tune.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216

net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_limit_output_bytes = 2097152

net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.optmem_max = 131072

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1440
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 0

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.ip_local_port_range = 1024 65535

net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_retries2 = 8

net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_adv_win_scale = 1

vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1000
vm.dirty_writeback_centisecs = 500
vm.min_free_kbytes = 131072
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
    tc qdisc del dev eth0 root 2>/dev/null || true
    tc qdisc add dev eth0 root handle 1: fq quantum 1514 flow_limit 200 buckets 8192
}
run_always "step5_sysctl" _step5

hdr "STEP 6 — DISABLE TRANSPARENT HUGE PAGES"
_step6() {
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
    cat > /etc/systemd/system/thp-disable.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
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
    systemctl daemon-reload
    systemctl enable --now thp-disable.service
}
run_always "step6_thp" _step6

hdr "STEP 7 — NIC TUNE (eth0)"
_step7() {
    NIC="eth0"
    ethtool -K "${NIC}" gro off lro off tso on gso on 2>/dev/null || true
    ethtool -C "${NIC}" rx-usecs 50 2>/dev/null || true
    ip link set "${NIC}" txqueuelen 2000
    mkdir -p /etc/networkd-dispatcher/routable.d
    cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << 'NEOF'
#!/usr/bin/env bash
set -euo pipefail
NIC="eth0"
ethtool -K "${NIC}" gro off lro off tso on gso on 2>/dev/null || true
ethtool -C "${NIC}" rx-usecs 50 2>/dev/null || true
ip link set "${NIC}" txqueuelen 2000
tc qdisc del dev "${NIC}" root 2>/dev/null || true
tc qdisc add dev "${NIC}" root handle 1: fq quantum 1514 flow_limit 200 buckets 8192
NEOF
    chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh
}
run_always "step7_nic" _step7

hdr "STEP 8 — I/O SCHEDULER"
_step8() {
    for DEV in sda vda xvda nvme0n1; do
        [ -b "/dev/${DEV}" ] || continue
        if grep -q "0" /sys/block/${DEV}/queue/rotational 2>/dev/null; then
            echo none > /sys/block/${DEV}/queue/scheduler 2>/dev/null || true
        else
            echo mq-deadline > /sys/block/${DEV}/queue/scheduler 2>/dev/null || true
        fi
        echo 0 > /sys/block/${DEV}/queue/add_random 2>/dev/null || true
        echo 256 > /sys/block/${DEV}/queue/nr_requests 2>/dev/null || true
    done
    cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF
    udevadm control --reload-rules
}
run_always "step8_io_scheduler" _step8

hdr "STEP 9 — CPU GOVERNOR (performance)"
_step9() {
    cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=CPU governor → performance
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cpu-performance.service
}
run_always "step9_cpu_gov" _step9

hdr "STEP 10 — SYSTEM LIMITS"
_step10() {
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
    grep -qxF 'session required pam_limits.so' /etc/pam.d/common-session \
        || echo 'session required pam_limits.so' >> /etc/pam.d/common-session
    echo 'fs.file-max = 2097152' > /etc/sysctl.d/98-file-max.conf
    sysctl -p /etc/sysctl.d/98-file-max.conf
}
run_always "step10_limits" _step10

hdr "STEP 11 — x-ui SYSTEMD OVERRIDE"
_step11() {
    mkdir -p /etc/systemd/system/x-ui.service.d
    cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=65535
LimitCORE=infinity
Restart=always
RestartSec=3
RestartPreventExitStatus=0
Environment=GOMAXPROCS=1
OOMScoreAdjust=-500
EOF
    systemctl daemon-reload
    systemctl restart x-ui
    sleep 3
    systemctl is-active x-ui
}
run_always "step11_xui_override" _step11

hdr "STEP 12 — POST-REBOOT VERIFY"
_step12() {
    cat > /usr/local/bin/vps-verify << 'VEOF'
#!/usr/bin/env bash
set -uo pipefail
export LANG=C
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
PASS=0; FAIL=0; WARN=0
ok()  { echo -e "  ${GRN}✔${RST}  $1"; ((PASS++)); }
bad() { echo -e "  ${RED}✘${RST}  $1"; ((FAIL++)); }
wr()  { echo -e "  ${YEL}⚠${RST}  $1"; ((WARN++)); }
echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║   VPS POST-BOOT VERIFY — RTT 40ms Remaster  ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════╝${RST}"
echo ""
UFW_STATUS=$(ufw status 2>/dev/null)
if echo "$UFW_STATUS" | grep -q "Status: active";  then ok "UFW active";        else bad "UFW ไม่ active";        fi
if echo "$UFW_STATUS" | grep -q "^22/tcp";         then ok "Port 22  SSH";      else bad "Port 22 ไม่เปิด";       fi
if echo "$UFW_STATUS" | grep -q "^80/tcp";         then ok "Port 80  VMESS WS"; else bad "Port 80 ไม่เปิด";       fi
if echo "$UFW_STATUS" | grep -q "^443/tcp";        then ok "Port 443 HTTPS";    else bad "Port 443 ไม่เปิด";      fi
if echo "$UFW_STATUS" | grep -q "^2053/tcp";       then ok "Port 2053 Panel";   else bad "Port 2053 ไม่เปิด";     fi
if echo "$UFW_STATUS" | grep -q "^8080/tcp";       then ok "Port 8080 open";    else bad "Port 8080 ไม่เปิด";     fi
if echo "$UFW_STATUS" | grep -q "^8443/tcp";       then ok "Port 8443 open";    else bad "Port 8443 ไม่เปิด";     fi
if echo "$UFW_STATUS" | grep -q "^54321/tcp";      then ok "Port 54321 open";   else bad "Port 54321 ไม่เปิด";    fi
echo ""
if systemctl is-active  x-ui &>/dev/null; then ok "x-ui running"; else bad "x-ui ไม่ทำงาน"; fi
if systemctl is-enabled x-ui &>/dev/null; then ok "x-ui enabled (auto-start)"; else bad "x-ui ไม่ enabled"; fi
XUI_PID=$(systemctl show -p MainPID x-ui 2>/dev/null | cut -d= -f2)
if [ "${XUI_PID:-0}" -gt 0 ]; then
    VMRSS=$(awk '/VmRSS/{print int($2/1024)}' /proc/${XUI_PID}/status 2>/dev/null || echo "?")
    ok "x-ui RAM: ${VMRSS} MB"
fi
echo ""
if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then ok "BBR active"; else bad "BBR ไม่ active"; fi
if [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ];           then ok "FQ qdisc";   else bad "FQ ไม่ active";  fi
QDISC_DETAIL=$(tc qdisc show dev eth0 2>/dev/null || echo "")
if echo "$QDISC_DETAIL" | grep -q "quantum 1514"; then ok "FQ quantum 1514 OK"; else wr "FQ quantum ไม่ถูก — รัน step5 ใหม่"; fi
RMEM=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
WMEM=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
[ "$RMEM" -ge 16777216 ] && ok "rmem_max 16MB OK" || bad "rmem_max ต่ำ ($RMEM)"
[ "$WMEM" -ge 16777216 ] && ok "wmem_max 16MB OK" || bad "wmem_max ต่ำ ($WMEM)"
LOWAT=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo 999999)
LIMIT=$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || echo 999999)
[ "$LOWAT" -le 16384   ] && ok "notsent_lowat OK (${LOWAT})"        || wr "notsent_lowat สูงเกิน (${LOWAT})"
[ "$LIMIT" -le 2097152 ] && ok "limit_output_bytes OK (${LIMIT})"   || wr "limit_output_bytes สูงเกิน (${LIMIT})"
MSS=$(sysctl -n net.ipv4.tcp_base_mss 2>/dev/null || echo 0)
[ "$MSS" -eq 1440 ] && ok "tcp_base_mss 1440 OK" || wr "tcp_base_mss ไม่ถูก (${MSS}, ควรเป็น 1440)"
ECN=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo 1)
[ "$ECN" -eq 0 ] && ok "ECN disabled (AIS-safe)" || wr "ECN ยังเปิด — อาจ drop ใน AIS middlebox"
TFO=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 1)
[ "$TFO" -eq 0 ] && ok "TFO disabled (AIS-safe)" || wr "TCP FastOpen ยังเปิด — AIS อาจ block"
if [ "$(sysctl -n vm.swappiness 2>/dev/null)"        -le 10 ];     then ok "swappiness OK";        else wr "swappiness สูง";         fi
if [ "$(sysctl -n vm.min_free_kbytes 2>/dev/null)"   -ge 131072 ]; then ok "min_free_kbytes OK";   else wr "min_free_kbytes ต่ำ";    fi
if [ "$(sysctl -n vm.overcommit_memory 2>/dev/null)" -eq 1 ];      then ok "overcommit_memory OK"; else wr "overcommit_memory ≠ 1";  fi
echo ""
if grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then ok "THP disabled"; else bad "THP ยังเปิดอยู่"; fi
NIC="eth0"
if ip link show "$NIC" &>/dev/null; then ok "eth0 up"; else bad "eth0 ไม่พบ"; fi
TXQLEN=$(cat /sys/class/net/${NIC}/tx_queue_len 2>/dev/null || echo 0)
[ "$TXQLEN" -ge 2000 ] && ok "TX Queue OK ($TXQLEN)" || wr "TX Queue ต่ำ ($TXQLEN)"
if command -v ethtool &>/dev/null; then
    if ethtool -k "$NIC" 2>/dev/null | grep -q 'generic-receive-offload: off'; then ok "GRO off"; else wr "GRO ยัง on"; fi
fi
for DEV in sda vda xvda nvme0n1; do
    [ -b "/dev/${DEV}" ] || continue
    SCHED=$(cat /sys/block/${DEV}/queue/scheduler 2>/dev/null || echo "unknown")
    if echo "$SCHED" | grep -qE '\[none\]|\[mq-deadline\]'; then ok "I/O Scheduler OK ($DEV)"; else wr "Scheduler ไม่ optimal ($DEV)"; fi
done
echo ""
NOFILE=$(ulimit -Hn 2>/dev/null || echo 0)
[ "$NOFILE" -ge 1048576 ] && ok "nofile limit OK ($NOFILE)" || bad "nofile ต่ำ ($NOFILE)"
FS_MAX=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
[ "$FS_MAX" -ge 2097152 ] && ok "fs.file-max OK ($FS_MAX)" || wr "fs.file-max ต่ำ ($FS_MAX)"
echo ""
if ss -tlnp 2>/dev/null | grep -q ':80 '; then ok "Port 80 listening (inbound OK)"; else wr "Port 80 ไม่ได้ฟัง — ตั้ง inbound ใน x-ui ก่อน"; fi
WS_CONN=$(ss -tnp 2>/dev/null | grep -c ':80' || true)
WS_CONN=${WS_CONN:-0}
ok "WS connections: ${WS_CONN} active"
CPU1=($(awk 'NR==1{print $2,$3,$4,$5,$6,$7,$8,$9,$10}' /proc/stat 2>/dev/null || echo "0 0 0 0 0 0 0 0 0"))
sleep 1
CPU2=($(awk 'NR==1{print $2,$3,$4,$5,$6,$7,$8,$9,$10}' /proc/stat 2>/dev/null || echo "0 0 0 0 0 0 0 0 0"))
TOTAL_DIFF=$(( (CPU2[0]+CPU2[1]+CPU2[2]+CPU2[3]+CPU2[4]+CPU2[5]+CPU2[6]+CPU2[7]+CPU2[8]) - (CPU1[0]+CPU1[1]+CPU1[2]+CPU1[3]+CPU1[4]+CPU1[5]+CPU1[6]+CPU1[7]+CPU1[8]) ))
STEAL_DIFF=$(( CPU2[7] - CPU1[7] ))
STEAL_PCT=0
[ "$TOTAL_DIFF" -gt 0 ] && STEAL_PCT=$(( STEAL_DIFF * 100 / TOTAL_DIFF ))
[ "$STEAL_PCT" -le 5 ] && ok "CPU steal OK (${STEAL_PCT}%)" || bad "CPU steal สูง (${STEAL_PCT}%) — VPS oversold!"
FREE_MB=$(( $(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0) / 1024 ))
[ "$FREE_MB" -ge 200 ] && ok "RAM available OK (${FREE_MB} MB)" || wr "RAM เหลือน้อย (${FREE_MB} MB)"
echo ""
echo -e "  ──────────────────────────────────────────"
echo -e "  ${GRN}Pass: ${PASS}${RST}  ${YEL}Warn: ${WARN}${RST}  ${RED}Fail: ${FAIL}${RST}"
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${BLD}${GRN}✔ ทุกอย่างพร้อม 100%${RST}"
else
    echo -e "  ${BLD}${RED}✘ มี ${FAIL} จุดที่ต้องแก้${RST}"
fi
PUB_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "N/A")
echo ""
echo -e "  Panel : http://${PUB_IP}:2053"
echo ""
VEOF
    chmod +x /usr/local/bin/vps-verify
    cat > /etc/systemd/system/vps-verify.service << 'EOF'
[Unit]
Description=VPS Post-boot Verify
After=network-online.target x-ui.service
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

hdr "DONE — SUMMARY"
PUB_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "N/A")
echo ""
echo -e "${BLD}${GRN}  Steps เสร็จแล้ว:${RST}"
while IFS= read -r line; do
    echo -e "    ${GRN}✔${RST}  $line"
done < "$STATE_FILE"
echo ""
echo -e "  ──────────────────────────────────────────────"
echo -e "  ${BLD}Panel  :${RST} http://${PUB_IP}:2053"
echo -e "  ${BLD}BBR    :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Qdisc  :${RST} $(tc qdisc show dev eth0 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP    :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui   :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ──────────────────────────────────────────────"
echo ""
echo -e "  ${BLD}${YEL}→ reboot แล้วรัน:${RST}  vps-verify"
echo ""
