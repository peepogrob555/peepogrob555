set -euo pipefail
export LANG=C
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'
STATE_DIR="/var/lib/vps-setup"
STATE_FILE="${STATE_DIR}/steps.done"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
sep()    { echo -e "${DIM}${CYN}────────────────────────────────────────────────${RST}"; }
hdr()    { echo -e "\n${BLD}${CYN}▶  $1${RST}"; sep; }
ok()     { echo -e "  ${GRN}✔${RST}  $1"; }
warn()   { echo -e "  ${YEL}⚠${RST}  $1"; }
die()    {
    echo -e "\n${RED}${BLD}✘  FAILED at: $1${RST}\n"
    exit 1
}
step_done() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { echo "$1" >> "$STATE_FILE"; }
run_step() {
    local name="$1"; shift
    if step_done "$name"; then
        ok "[SKIP] $name — เสร็จแล้ว"
        return 0
    fi
    echo -e "\n${BLD}  → $name${RST}"
    if "$@"; then
        mark_done "$name"
        ok "[OK]   $name"
    else
        die "$name"
    fi
}
[ "$(id -u)" -eq 0 ] || { echo "ต้องรันด้วย root"; exit 1; }
echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║   VPS SETUP — VMESS/WS 500Mbps | Ubuntu 22.04  ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════╝${RST}"
echo -e "  Log: /var/lib/vps-setup/steps.done"
echo ""
hdr "STEP 1 — UPDATE & DEPS"
_step1() {
    apt-get update -y
    apt-get install -y curl ufw ethtool sqlite3
}
run_step "step1_deps" _step1
hdr "STEP 2 — FIREWALL (UFW)"
_step2() {
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    for port in 80 443 2053 2083 2087 2096 8080 8443 54321; do
        ufw allow "${port}"/tcp
    done
    ufw --force enable
}
run_step "step2_ufw" _step2
hdr "STEP 3 — INSTALL 3X-UI"
_step3() {
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    systemctl enable x-ui
}
run_step "step3_3xui" _step3
hdr "STEP 4 — PANEL PORT → 2053"
_step4() {
    x-ui stop
    x-ui setting -port 2053
    x-ui start
    sleep 2
    systemctl is-active x-ui
}
run_step "step4_panel_port" _step4
hdr "STEP 5 — KERNEL TCP TUNE"
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
net.ipv4.tcp_notsent_lowat   = 16384
net.ipv4.tcp_limit_output_bytes = 1048576
net.core.netdev_max_backlog  = 16384
net.core.somaxconn           = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss    = 1440
net.ipv4.tcp_fastopen    = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps  = 1
net.ipv4.tcp_sack        = 1
net.ipv4.tcp_dsack       = 1
net.ipv4.tcp_tw_reuse        = 1
net.ipv4.tcp_max_tw_buckets  = 65536
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout      = 15
net.ipv4.tcp_syn_retries    = 3
net.ipv4.tcp_synack_retries = 3
vm.swappiness              = 5
vm.dirty_ratio             = 15
vm.dirty_background_ratio  = 5
vm.min_free_kbytes         = 65536
vm.vfs_cache_pressure      = 50
net.core.optmem_max        = 65536
kernel.sched_autogroup_enabled = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects   = 0
net.ipv4.conf.all.rp_filter        = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
    sysctl -p /etc/sysctl.d/99-vmess-tune.conf || sysctl --system
}
run_step "step5_sysctl" _step5
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
    systemctl enable thp-disable.service
    systemctl start  thp-disable.service
}
run_step "step6_thp" _step6
hdr "STEP 7 — NIC TUNE (eth0)"
_step7() {
    NIC="eth0"
    ethtool -K "${NIC}" gro off lro off tso on gso on 2>/dev/null || true
    ethtool -C "${NIC}" rx-usecs 50                               2>/dev/null || true
    ip link set "${NIC}" txqueuelen 1000
    mkdir -p /etc/networkd-dispatcher/routable.d
    cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << 'NEOF'
#!/usr/bin/env bash
NIC="eth0"
ethtool -K "${NIC}" gro off lro off tso on gso on 2>/dev/null || true
ethtool -C "${NIC}" rx-usecs 50                               2>/dev/null || true
ip link set "${NIC}" txqueuelen 1000
NEOF
    chmod +x /etc/networkd-dispatcher/routable.d/50-nic-tune.sh
}
run_step "step7_nic" _step7
hdr "STEP 8 — I/O SCHEDULER"
_step8() {
    for DEV in sda vda xvda; do
        [ -b "/dev/${DEV}" ] || continue
        echo mq-deadline > /sys/block/${DEV}/queue/scheduler 2>/dev/null || true
    done
    cat > /etc/udev/rules.d/60-io-scheduler.rules << 'EOF'
ACTION=="add|change", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]", \
  ATTR{queue/rotational}=="0", \
  ATTR{queue/scheduler}="mq-deadline"
EOF
    udevadm control --reload-rules
}
run_step "step8_io_scheduler" _step8
hdr "STEP 9 — CPU GOVERNOR (performance)"
_step9() {
    cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=CPU governor → performance
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c \
  'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; \
   do echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable cpu-performance.service
    systemctl start  cpu-performance.service
}
run_step "step9_cpu_gov" _step9
hdr "STEP 10 — SYSTEM LIMITS"
_step10() {
    cat > /etc/security/limits.d/99-xui.conf << 'EOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    grep -qxF 'session required pam_limits.so' /etc/pam.d/common-session \
        || echo 'session required pam_limits.so' >> /etc/pam.d/common-session
}
run_step "step10_limits" _step10
hdr "STEP 11 — x-ui SYSTEMD OVERRIDE"
_step11() {
    mkdir -p /etc/systemd/system/x-ui.service.d
    cat > /etc/systemd/system/x-ui.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=65535
LimitNPROC=65535
Restart=always
RestartSec=3
Environment=GOMAXPROCS=1
EOF
    systemctl daemon-reload
    systemctl restart x-ui
    sleep 2
    systemctl is-active x-ui
}
run_step "step11_xui_override" _step11
hdr "STEP 12 — POST-REBOOT VERIFY SERVICE"
_step12() {
    cat > /usr/local/bin/vps-verify << 'VEOF'
#!/usr/bin/env bash
export LANG=C
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
PASS=0; FAIL=0; WARN=0
ok()  { echo -e "  ${GRN}✔${RST}  $1"; ((PASS++)); }
bad() { echo -e "  ${RED}✘${RST}  $1"; ((FAIL++)); }
wr()  { echo -e "  ${YEL}⚠${RST}  $1"; ((WARN++)); }
echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║     VPS POST-BOOT VERIFY                ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════╝${RST}"
echo ""
UFW_STATUS=$(ufw status 2>/dev/null)
if echo "$UFW_STATUS" | grep -q "Status: active"; then ok "UFW active"; else bad "UFW ไม่ active"; fi
if echo "$UFW_STATUS" | grep -q "^80/tcp";    then ok "Port 80 open";    else bad "Port 80 ไม่เปิด";    fi
if echo "$UFW_STATUS" | grep -q "^443/tcp";   then ok "Port 443 open";   else bad "Port 443 ไม่เปิด";   fi
if echo "$UFW_STATUS" | grep -q "^2053/tcp";  then ok "Port 2053 open";  else bad "Port 2053 ไม่เปิด";  fi
if echo "$UFW_STATUS" | grep -q "^8080/tcp";  then ok "Port 8080 open";  else bad "Port 8080 ไม่เปิด";  fi
if echo "$UFW_STATUS" | grep -q "^8443/tcp";  then ok "Port 8443 open";  else bad "Port 8443 ไม่เปิด";  fi
if echo "$UFW_STATUS" | grep -q "^54321/tcp"; then ok "Port 54321 open"; else bad "Port 54321 ไม่เปิด"; fi
if systemctl is-active x-ui &>/dev/null;  then ok "x-ui running"; else bad "x-ui ไม่ทำงาน"; fi
if systemctl is-enabled x-ui &>/dev/null; then ok "x-ui enabled"; else bad "x-ui ไม่ enabled"; fi
if [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ]; then ok "BBR active"; else bad "BBR ไม่ active"; fi
if [ "$(sysctl -n net.core.default_qdisc)" = "fq" ]; then ok "FQ qdisc"; else bad "FQ ไม่ active"; fi
if grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled; then ok "THP disabled"; else bad "THP ยังเปิดอยู่"; fi
if [ "$(sysctl -n net.core.rmem_max)" -ge 16777216 ]; then ok "rmem_max OK"; else bad "rmem_max ต่ำเกิน"; fi
if [ "$(sysctl -n net.core.wmem_max)" -ge 16777216 ]; then ok "wmem_max OK"; else bad "wmem_max ต่ำเกิน"; fi
if [ "$(sysctl -n net.ipv4.tcp_notsent_lowat)" -le 32768 ]; then ok "notsent_lowat OK"; else wr "notsent_lowat สูงกว่าที่แนะนำ"; fi
if [ "$(sysctl -n vm.swappiness)" -le 10 ]; then ok "swappiness OK"; else wr "swappiness สูง"; fi
if [ "$(sysctl -n vm.min_free_kbytes)" -ge 65536 ]; then ok "min_free_kbytes OK"; else wr "min_free_kbytes ต่ำ"; fi
NOFILE=$(ulimit -Hn)
if [ "$NOFILE" -ge 65535 ]; then ok "nofile limit OK ($NOFILE)"; else bad "nofile ต่ำ ($NOFILE)"; fi
NIC="eth0"
if ip link show "$NIC" &>/dev/null; then ok "eth0 up"; else bad "eth0 ไม่พบ"; fi
if command -v ethtool &>/dev/null; then
    if ethtool -k "$NIC" 2>/dev/null | grep -q 'generic-receive-offload: off'; then ok "GRO off (proxy OK)"; else wr "GRO ยัง on"; fi
fi
for DEV in sda vda xvda; do
    [ -b "/dev/${DEV}" ] || continue
    SCHED=$(cat /sys/block/${DEV}/queue/scheduler 2>/dev/null)
    if echo "$SCHED" | grep -qE '\[mq-deadline\]|\[none\]'; then ok "I/O Scheduler OK ($DEV)"; else wr "I/O Scheduler ไม่ใช่ mq-deadline ($DEV)"; fi
done
if ss -tlnp | grep -q ':80 '; then ok "Port 80 listening"; else wr "Port 80 ไม่ได้ฟัง (ยังไม่ได้ตั้ง inbound?)"; fi
echo ""
echo -e "  ──────────────────────────────────────"
echo -e "  ${GRN}Pass: ${PASS}${RST}  ${YEL}Warn: ${WARN}${RST}  ${RED}Fail: ${FAIL}${RST}"
[ "$FAIL" -eq 0 ] \
    && echo -e "  ${BLD}${GRN}✔ ทุกอย่างพร้อม 100%${RST}" \
    || echo -e "  ${BLD}${RED}✘ มี ${FAIL} จุดที่ต้องแก้${RST}"
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
run_step "step12_verify_service" _step12
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
echo -e "  ${BLD}BBR    :${RST} $(sysctl -n net.ipv4.tcp_congestion_control)"
echo -e "  ${BLD}Qdisc  :${RST} $(sysctl -n net.core.default_qdisc)"
echo -e "  ${BLD}THP    :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo -e "  ${BLD}x-ui   :${RST} $(systemctl is-active x-ui)"
echo -e "  ──────────────────────────────────────────────"
echo ""
echo -e "  ${BLD}${YEL}→ reboot แล้วรัน:${RST}  vps-verify"
echo ""
