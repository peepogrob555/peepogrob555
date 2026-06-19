#!/usr/bin/env bash
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

RUN_DIR="/run/vmess-cake-setup"
mkdir -p "$RUN_DIR"
LOG_FILE="${RUN_DIR}/install.log"
STATE_FILE="${RUN_DIR}/steps.done"
: > "$STATE_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

sep(){ echo -e "${CYN}────────────────────────────────────────────────────${RST}"; }
hdr(){ echo -e "\n${BLD}${CYN}▶ $1${RST}"; sep; }
ok(){ echo -e "  ${GRN}✔${RST} $1"; }
warn(){ echo -e "  ${YEL}⚠${RST} $1"; }
die(){ echo -e "\n${RED}${BLD}✘ $1${RST}\n"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root"

. /etc/os-release 2>/dev/null || true
if [ "${VERSION_ID:-}" != "24.04" ]; then
  warn "ตรวจพบ ${PRETTY_NAME:-unknown OS} — สคริปต์นี้ทำมาเพื่อ Ubuntu 24.04 โดยเฉพาะ จะรันต่อแต่บางคำสั่งอาจต้องปรับ"
fi

NIC=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
NIC="${NIC:-eth0}"

FLOOR_BUF=2097152
DEFAULT_BUF=4194304
MAX_BUF=8388608

ALLOWED_TCP=(22 80 443 2053 2052 2082 2086 2095 8080 8443)

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  VMESS-WS / CAKE+BBR — Ubuntu 24.04 hardened setup        ║${RST}"
echo -e "${BLD}${CYN}║  Logs: RAM-only (${RUN_DIR})                ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
echo ""

hdr "STEP 1 — UPDATE ทั้งระบบ"
systemctl stop unattended-upgrades 2>/dev/null || true
waited=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock &>/dev/null; do
  [ "$waited" -ge 90 ] && { fuser -k /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null || true; break; }
  sleep 3; waited=$((waited+3))
done
dpkg --configure -a
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" upgrade
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ufw ethtool sqlite3 iproute2 iputils-ping nftables ca-certificates
apt-get autoremove -y
echo "step1_update" >> "$STATE_FILE"
ok "ระบบอัพเดตครบ"

hdr "STEP 2 — FIREWALL: เปิดเฉพาะพอตที่ใช้ / ปิดพอตอันตรายทั้งหมด (TCP+UDP)"
ufw --force reset
ufw default deny incoming
ufw default deny outgoing
ufw default deny forward

for p in "${ALLOWED_TCP[@]}"; do ufw allow "${p}/tcp"; done
ufw allow out 53
ufw allow out 80/tcp
ufw allow out 443/tcp
ufw allow out 123/udp
ufw --force enable

for svc in telnet.socket rpcbind rpcbind.socket nfs-server smbd nmbd avahi-daemon \
           avahi-daemon.socket cups cups-browsed vsftpd proftpd xinetd; do
  systemctl list-unit-files "$svc" 2>/dev/null | grep -q "$svc" && {
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
  }
done

ufw status verbose
echo "step2_firewall" >> "$STATE_FILE"
ok "เปิดเฉพาะ TCP: ${ALLOWED_TCP[*]} — ที่เหลือปิดหมดทั้ง TCP/UDP, บริการเสี่ยงถูก mask"

hdr "STEP 3 — ติดตั้ง 3x-ui"
if command -v x-ui &>/dev/null; then
  ok "3x-ui ติดตั้งอยู่แล้ว — ข้าม"
else
  bash <(curl -fsSL https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
fi
echo "step3_3xui" >> "$STATE_FILE"
ok "3x-ui พร้อมใช้งาน"

hdr "STEP 4 — โหลด kernel module: BBR + CAKE"
modprobe tcp_bbr 2>/dev/null || warn "โหลด tcp_bbr ไม่ได้"
modprobe sch_cake 2>/dev/null || warn "โหลด sch_cake ไม่ได้"
echo "tcp_bbr"  > /etc/modules-load.d/bbr.conf
echo "sch_cake" > /etc/modules-load.d/cake.conf
grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control && ok "bbr พร้อมใช้" || warn "bbr ไม่พร้อม"
lsmod | grep -q sch_cake && ok "cake พร้อมใช้" || warn "cake ไม่พร้อม"
echo "step4_modules" >> "$STATE_FILE"

hdr "STEP 5 — SYSCTL TUNE ขั้นสูง (BBR + CAKE, low-latency, buffer 2-8MiB)"
cat > /etc/sysctl.d/99-vmess-cake.conf << EOF
net.ipv4.tcp_congestion_control     = bbr
net.core.default_qdisc              = cake

net.core.rmem_max                   = ${MAX_BUF}
net.core.wmem_max                   = ${MAX_BUF}
net.core.rmem_default               = ${DEFAULT_BUF}
net.core.wmem_default               = ${DEFAULT_BUF}
net.ipv4.tcp_rmem                   = ${FLOOR_BUF} ${DEFAULT_BUF} ${MAX_BUF}
net.ipv4.tcp_wmem                   = ${FLOOR_BUF} ${DEFAULT_BUF} ${MAX_BUF}
net.ipv4.tcp_moderate_rcvbuf        = 1
net.ipv4.tcp_notsent_lowat          = 131072
net.core.optmem_max                 = 131072

net.ipv4.tcp_low_latency            = 1
net.ipv4.tcp_autocorking            = 0
net.ipv4.tcp_slow_start_after_idle  = 0
net.ipv4.tcp_fastopen               = 3
net.ipv4.tcp_mtu_probing             = 1
net.ipv4.tcp_base_mss               = 1440
net.ipv4.tcp_no_metrics_save        = 1
net.ipv4.tcp_keepalive_time         = 35
net.ipv4.tcp_keepalive_intvl        = 5
net.ipv4.tcp_keepalive_probes       = 5
net.ipv4.tcp_fin_timeout            = 10
net.ipv4.tcp_tw_reuse               = 1
net.ipv4.tcp_syncookies              = 1
net.ipv4.tcp_window_scaling          = 1
net.ipv4.tcp_timestamps              = 1
net.ipv4.tcp_sack                    = 1
net.ipv4.tcp_early_retrans           = 3
net.ipv4.tcp_thin_linear_timeouts    = 1
net.ipv4.tcp_thin_dupack             = 1

net.core.netdev_max_backlog          = 65536
net.core.somaxconn                   = 65535
net.ipv4.tcp_max_syn_backlog         = 65535
net.ipv4.ip_local_port_range         = 1024 65535
net.ipv4.tcp_max_tw_buckets          = 1440000

net.ipv4.ip_forward                  = 1
net.ipv4.conf.all.forwarding         = 1
net.ipv6.conf.all.forwarding         = 1

net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
sysctl -p /etc/sysctl.d/99-vmess-cake.conf
echo "step5_sysctl" >> "$STATE_FILE"
ok "sysctl tuned: bbr+cake, buffer 2/4/8 MiB, mss=1440, low-latency flags ครบ"

hdr "STEP 6 — ผูก CAKE เข้า NIC (${NIC}) — ไม่จำกัด bandwidth, เป็น AQM/fairness ล้วน"
bind_cake() {
  tc qdisc del dev "$1" root 2>/dev/null || true
  tc qdisc add dev "$1" root cake memlimit ${MAX_BUF}b diffserv4 nat dual-srchost ack-filter 2>/dev/null \
    || tc qdisc add dev "$1" root cake 2>/dev/null \
    || return 1
}
bind_cake "$NIC" && ok "cake ผูกกับ ${NIC} แล้ว" || warn "ผูก cake บน ${NIC} ไม่สำเร็จ"
tc qdisc show dev "$NIC"

mkdir -p /etc/networkd-dispatcher/routable.d
cat > /etc/networkd-dispatcher/routable.d/50-cake.sh << EOF
#!/usr/bin/env bash
NIC="${NIC}"
ip link show "\$NIC" &>/dev/null || exit 0
tc qdisc del dev "\$NIC" root 2>/dev/null || true
tc qdisc add dev "\$NIC" root cake memlimit ${MAX_BUF}b diffserv4 nat dual-srchost ack-filter 2>/dev/null \\
  || tc qdisc add dev "\$NIC" root cake 2>/dev/null || true
EOF
chmod +x /etc/networkd-dispatcher/routable.d/50-cake.sh

cat > /etc/systemd/system/cake-qdisc.service << EOF
[Unit]
Description=Bind CAKE qdisc on ${NIC} (no bandwidth cap, AQM only)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/etc/networkd-dispatcher/routable.d/50-cake.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cake-qdisc.service
echo "step6_cake" >> "$STATE_FILE"
ok "cake-qdisc.service enabled — รอด reboot แน่นอน"

hdr "STEP 6.5 — SOCKET-LEVEL TUNE (xray sockopt): TCP_MAXSEG=1440 + buffer ตรงกับ kernel"
patch_xray_sockopt() {
  local db="/etc/x-ui/x-ui.db"
  [ -f "$db" ] || { warn "x-ui.db ยังไม่มี — ยังไม่ได้สร้าง inbound ใน panel ข้ามขั้นนี้ไปก่อน"; return 0; }
  command -v sqlite3 &>/dev/null || { warn "ไม่มี sqlite3"; return 1; }
  command -v python3 &>/dev/null || { warn "ไม่มี python3"; return 1; }

  local sockopt
  sockopt=$(python3 -c "
import json
print(json.dumps({
  'acceptProxyProtocol': False,
  'tcpFastOpen': True,
  'mark': 0,
  'tproxy': 'off',
  'tcpMptcp': False,
  'domainStrategy': 'AsIs',
  'tcpMaxSeg': 1440,
  'dialerProxy': '',
  'tcpKeepAliveInterval': 35,
  'tcpKeepAliveIdle': 35,
  'tcpUserTimeout': 30000,
  'tcpcongestion': 'bbr',
  'V6Only': False,
  'tcpWindowClamp': ${MAX_BUF},
  'interface': '',
  'tcpNoDelay': True,
  'customSockopt': [
    {'system':'', 'network':'tcp', 'level':'sol_socket', 'opt':'SO_RCVBUF', 'value':'${DEFAULT_BUF}', 'type':'int'},
    {'system':'', 'network':'tcp', 'level':'sol_socket', 'opt':'SO_SNDBUF', 'value':'${DEFAULT_BUF}', 'type':'int'}
  ]
}, separators=(',',':')))
")

  local count
  count=$(sqlite3 "$db" "SELECT COUNT(*) FROM inbounds WHERE port=80 AND protocol='vmess';" 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ]; then
    local stream new_stream
    stream=$(sqlite3 "$db" "SELECT stream_settings FROM inbounds WHERE port=80 AND protocol='vmess' LIMIT 1;")
    new_stream=$(echo "$stream" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['sockopt'] = json.loads(sys.argv[1])
print(json.dumps(d, separators=(',',':')))
" "$sockopt" 2>/dev/null || echo "")
    if [ -n "$new_stream" ]; then
      local esc="${new_stream//\'/\'\'}"
      sqlite3 "$db" "UPDATE inbounds SET stream_settings='${esc}' WHERE port=80 AND protocol='vmess';"
      systemctl restart x-ui 2>/dev/null || true
      ok "patch sockopt สำเร็จ: tcpMaxSeg=1440, SO_RCVBUF/SO_SNDBUF=${DEFAULT_BUF}B, tcpWindowClamp=${MAX_BUF}B"
    else
      warn "parse stream_settings ไม่สำเร็จ — ข้าม patch"
    fi
  else
    warn "ยังไม่พบ inbound vmess port 80 — สร้างใน panel ก่อนแล้วรันสคริปต์นี้ซ้ำเพื่อ patch sockopt"
    warn "ค่า sockopt ที่ต้อง apply เองถ้าจำเป็น: ${sockopt}"
  fi
}
patch_xray_sockopt
echo "step6_5_sockopt" >> "$STATE_FILE"

hdr "STEP 7 — LOG ทั้งหมดอยู่บน RAM เท่านั้น (ไม่เหลือร่องรอยบนดิสก์)"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-volatile.conf << 'EOF'
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=64M
RuntimeMaxUse=64M
RateLimitIntervalSec=0
RateLimitBurst=0
Seal=no
ForwardToSyslog=no
EOF
systemctl restart systemd-journald

systemctl disable --now rsyslog 2>/dev/null || true
systemctl mask rsyslog 2>/dev/null || true

[ -d /var/log/journal ] && rm -rf /var/log/journal
if ! grep -q "tmpfs /tmp" /etc/fstab 2>/dev/null; then
  echo "tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=256m 0 0" >> /etc/fstab
fi

echo "step7_ramlogs" >> "$STATE_FILE"
ok "journald=volatile (RAM only), rsyslog ปิด, /tmp เป็น tmpfs, /var/log/journal ลบแล้ว"

hdr "STEP 8 — VERIFY (reboot-safe check)"
errors=0
chk_enabled(){ systemctl is-enabled "$1" &>/dev/null || { warn "$1 ไม่ enable"; errors=$((errors+1)); }; }
chk_val(){
  if echo "$2" | grep -qF "$3"; then ok "  $1: $2"; else warn "  $1: got='$2' expect~'$3'"; errors=$((errors+1)); fi
}

chk_enabled cake-qdisc.service
chk_enabled x-ui
[ -f /etc/sysctl.d/99-vmess-cake.conf ] || { warn "sysctl conf หาย"; errors=$((errors+1)); }
[ -f /etc/modules-load.d/bbr.conf ]     || { warn "bbr modules-load หาย"; errors=$((errors+1)); }
[ -f /etc/modules-load.d/cake.conf ]    || { warn "cake modules-load หาย"; errors=$((errors+1)); }

chk_val "CC"             "$(sysctl -n net.ipv4.tcp_congestion_control)"  "bbr"
chk_val "qdisc default"  "$(sysctl -n net.core.default_qdisc)"          "cake"
chk_val "qdisc on NIC"   "$(tc qdisc show dev "$NIC" | head -1)"        "cake"
chk_val "ip_forward"     "$(sysctl -n net.ipv4.ip_forward)"             "1"
chk_val "x-ui active"    "$(systemctl is-active x-ui 2>/dev/null)"      "active"
chk_val "journald conf"  "$(grep -h Storage /etc/systemd/journald.conf.d/99-volatile.conf)" "volatile"

ufw status | grep -q "Status: active" && ok "  ufw: active" || { warn "  ufw ไม่ active"; errors=$((errors+1)); }

if [ -f /etc/x-ui/x-ui.db ] && command -v sqlite3 &>/dev/null; then
  ss_check=$(sqlite3 /etc/x-ui/x-ui.db "SELECT stream_settings FROM inbounds WHERE port=80 AND protocol='vmess' LIMIT 1;" 2>/dev/null || echo "")
  chk_val "xray tcpMaxSeg" "$ss_check" "\"tcpMaxSeg\":1440"
fi

echo ""
if [ "$errors" -eq 0 ]; then
  ok "ALL CHECKS PASSED — reboot ได้เลย ทุก config persistent"
else
  warn "${errors} จุดที่ต้องดูเพิ่ม (ดู log ด้านบน — log นี้อยู่บน RAM เท่านั้น จะหายเมื่อ reboot/ปิดเครื่อง)"
fi
echo "step8_verify" >> "$STATE_FILE"

PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || echo "N/A")
echo ""
echo -e "${BLD}${GRN}== SUMMARY ==${RST}"
echo "  Panel URL        : http://${PUB_IP}:2053"
echo "  Inbound ที่ต้องสร้างในพาเนล : VMESS / WS / port 80 / Security: none"
echo "  Host/SNI header  : speedtest.net"
echo "  TCP เปิด         : ${ALLOWED_TCP[*]}"
echo "  CC / qdisc       : $(sysctl -n net.ipv4.tcp_congestion_control) / $(tc qdisc show dev "$NIC" | head -1)"
echo "  Buffer rmem/wmem : floor=2MiB default=4MiB max=8MiB (kernel + cake memlimit + xray sockopt ตรงกันหมด)"
echo "  TCP_MAXSEG       : 1440 (kernel tcp_base_mss + xray sockopt.tcpMaxSeg)"
echo "  MTU              : server NIC 1500 / V2Box client MTU 1500 (MSS 1440 เผื่อ WS overhead)"
echo "  Log              : ${LOG_FILE}  (RAM เท่านั้น — หายอัตโนมัติเมื่อ reboot)"
echo ""
echo -e "${YEL}→ แนะนำ reboot 1 ครั้งเพื่อ confirm ทุก setting persistent (จะไม่มีอะไรหาย)${RST}"
echo ""
