#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  AIS กันรั่ว — VLESS REALITY BYPASS TUNER v9.0                     ║
# ║  Hardware  : 1vCPU @2.69GHz · 2GB RAM (≈1700MB หลัง 3x-ui)        ║
# ║  Users     : 2 คน · RAM คนละ 750MB per socket                      ║
# ║  RTT       : ~40ms (AIS 4G → VPS)                                  ║
# ║  Control   : 128 kbps (ผ่าน VLESS Reality port 443)                ║
# ║  Bypass    : 300 Mbps+ (traffic ที่ bypass ผ่าน VPS ออกอินเตอร์)   ║
# ║  VPN MTU   : 1500 (X2BOX lock) → MSS=1460 (หักแค่ IP+TCP header)  ║
# ║  BDP       : 300Mbps × 40ms = 1,500,000 bytes ≈ 1.5MB              ║
# ║  Goal      : ปิงต่ำ · นิ่ง · ส่งทุก tick · โหลดหนักได้ · 2 users  ║
# ╚══════════════════════════════════════════════════════════════════════╝
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

STATE_DIR="/var/lib/ais-bypass-setup"
STATE_FILE="${STATE_DIR}/steps.done"
LOG_FILE="${STATE_DIR}/install.log"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

sep()  { echo -e "${DIM}${CYN}──────────────────────────────────────────────────────────────${RST}"; }
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
  if $skip && step_done "$name"; then ok "[SKIP] ${name}"; return 0; fi
  clear_done "$name"
  echo -e "\n${BLD}  → ${name}${RST}"
  if (set -euo pipefail; "$@"); then
    mark_done "$name"; ok "[OK]   ${name}"
  else
    echo -e "\n${RED}${BLD}✘  FAILED: ${name}${RST}"
    echo -e "  ${YEL}Log: ${LOG_FILE}${RST}\n"; exit 1
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

# ══════════════════════════════════════════════════════════════════════
#  CONSTANTS
#
#  ── MTU / MSS reasoning ──────────────────────────────────────────────
#  X2BOX ล็อค VPN MTU = 1500 (เปลี่ยนไม่ได้)
#  TCP MSS = MTU − IP header (20) − TCP header (20) = 1460
#  ไม่หักเผื่อ VLESS/TLS overhead เพิ่มเพราะ:
#    - VLESS Reality ใช้ XTLS Vision ซึ่ง passthrough TLS โดยตรง
#    - ไม่มี double-encap เหมือน vmess ws → overhead น้อยมาก
#    - ถ้า path จริงมี PMTU ต่ำกว่า → tcp_mtu_probing=1 จะหด MSS เองอัตโนมัติ
#  ────────────────────────────────────────────────────────────────────
EFFECTIVE_MTU=1500
BASE_MSS=1460

#  ── BDP reasoning ───────────────────────────────────────────────────
#  Control channel  : 128 kbps (ผ่าน VLESS Reality — AIS จำกัด)
#  Bypass traffic   : 300+ Mbps (traffic ที่ผ่าน VPS ออกอินเตอร์เน็ต)
#  Tune ให้ bypass ได้เต็มที่ เพราะนั่นคือ path ที่ใช้งานจริง
#  BDP สำหรับ bypass = 300 Mbps × 40ms / 8 = 1,500,000 bytes ≈ 1.5MB
#  ใช้ 10 Gbps เป็น ceiling ของ socket buffer (ไม่ใช่ actual link speed)
#  เพราะ VPS NIC ไม่มี limit — socket buffer ต้องรองรับ burst ที่ใหญ่ได้
#  BDP_BYPASS ใช้คำนวณ rmem/wmem default (ค่าเริ่มต้นที่ kernel ให้ทุก socket)
#  BDP_CEILING ใช้เป็น max (autotuner ขยายได้ถึงเท่านี้ต่อ socket)
BDP_BYPASS=1500000
BDP_CEILING=50000000

#  ── Per-socket memory ────────────────────────────────────────────────
#  rmem/wmem max = 750MB per socket (สำหรับ 2 users คนละ 750MB)
#  rmem/wmem default = BDP_BYPASS (kernel เริ่มที่ 1.5MB, โตได้ถึง 750MB)
#  เหตุผลที่ default ใช้ BDP_BYPASS ไม่ใช่ BDP_CEILING:
#    ถ้า default = 50MB → kernel จอง 50MB ให้ทุก socket ตั้งแต่เปิด
#    socket idle ก็เสีย RAM ฟรี → บน 2GB ระวัง OOM
#    default = 1.5MB → socket เพิ่งเปิดใช้ RAM น้อย, autotuner โตตาม load
RMEM_MAX=786432000
WMEM_MAX=786432000
RMEM_DEFAULT=1500000
WMEM_DEFAULT=1500000

#  ── tcp_mem: global socket memory budget (pages, 1 page = 4096 bytes) ──
#  Total RAM ≈ 2GB, kernel+system ≈ 300MB, x-ui ≈ 500MB, เหลือ ≈ 1200MB
#  pressure  = 75% of 1200MB = 900MB → 900MB / 4096 ≈ 219,000 pages
#  hard      = 90% of 1200MB = 1080MB → ≈ 264,000 pages
#  max       = 100% of 1200MB = 1200MB → ≈ 293,000 pages
TCP_MEM_PRESSURE=219000
TCP_MEM_HARD=264000
TCP_MEM_MAX=293000

LIMIT_OUTPUT=786432000

#  ── tcp_notsent_lowat ────────────────────────────────────────────────
#  kernel จะ wakeup app และส่ง data ออกเมื่อ unsent bytes < threshold นี้
#  default kernel = 128KB → kernel รอสะสม data ก่อนส่ง (throughput ดี แต่ latency สูง)
#  16384 (16KB) = ใกล้เคียง 1 TLS record → ส่งออกแทบทุก write() call
#  เหมาะกับ VLESS proxy: x-ui forward data เป็นชิ้นเล็กๆ ต้องการส่งทันที
NOTSENT_LOWAT=16384

#  ── fq quantum ──────────────────────────────────────────────────────
#  fq qdisc จัดคิวแบบ per-flow round-robin
#  quantum = จำนวน bytes ที่แต่ละ flow ได้ส่งต่อ 1 รอบ
#  1460 = 1 MSS → แต่ละ flow ส่งได้ 1 segment ต่อรอบ (fairest possible)
#  ผล: user 1 ดาวโหลดหนัก ไม่กิน quota ของ user 2 ที่เล่นเกม
TC_QUANTUM=1460
TC_BUCKETS=65536

#  ── Queues ──────────────────────────────────────────────────────────
#  somaxconn/syn_backlog: 2 users ใช้จริง ≤ 50 connections พร้อมกัน
#  4096 เกิน need มาก แต่ overhead น้อย ไม่เสีย RAM มีแค่ pointer
SOMAXCONN=4096
SYN_BACKLOG=4096
NETDEV_BACKLOG=16384
TW_BUCKETS=32768

#  ── Keepalive ────────────────────────────────────────────────────────
#  AIS 4G ตัด idle connection เร็ว (≈ 30-60 วินาทีไม่มี packet)
#  keepalive 15s → ส่ง probe ก่อนที่ AIS จะตัด → connection ไม่หลุด
#  INTVL 5s × 3 probes = รอ 15s หลัง first probe ก่อน declare dead
KA_TIME=15
KA_INTVL=5
KA_PROBES=3
FIN_TIMEOUT=5

#  ── busy_poll ────────────────────────────────────────────────────────
#  ปกติ: packet มาถึง NIC → IRQ → kernel schedule → process รับ data
#  busy_poll: process รันลูปตรวจสอบ NIC โดยตรง 50μs ก่อน sleep
#  ที่ RTT 40ms: 50μs = 0.125% ของ RTT → overhead น้อยมาก
#  ผล: ลด latency ของ receive path ≈ 0.1-0.3ms ต่อ RTT
BUSY_POLL=50
BUSY_READ=50

#  ── x-ui cgroup memory limits ────────────────────────────────────────
XUI_MEM_HIGH=1572864000
XUI_MEM_MAX=1677721600
XUI_MEM_SWAP=104857600

#  ── Ports ────────────────────────────────────────────────────────────
PANEL_PORT="${PANEL_PORT:-2053}"
OPEN_PORTS=(22 80 443 2053 2083 2087 2096 8080 8443 54321)

#  ── NIC detect ──────────────────────────────────────────────────────
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

# ══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  AIS กันรั่ว — VLESS REALITY BYPASS TUNER v9.0              ║${RST}"
echo -e "${BLD}${CYN}║  1vCPU @2.69GHz · 2GB RAM · 2 users · RTT≈40ms             ║${RST}"
echo -e "${BLD}${CYN}║  Control=128kbps · Bypass=300Mbps+ · MTU=1500 · MSS=1460   ║${RST}"
echo -e "${BLD}${CYN}║  SEND-EVERY-TICK · LATENCY-FIRST · FAIR 2-USER SCHEDULING  ║${RST}"
echo -e "${BLD}${CYN}║  NIC: ${NIC}$(printf '%*s' $((53-${#NIC})) '')║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════════════╝${RST}"
echo ""
info "VPN MTU (X2BOX lock)  : ${EFFECTIVE_MTU} → MSS ${BASE_MSS} (หัก IP+TCP header 40B เท่านั้น)"
info "BDP bypass @300Mbps   : ${BDP_BYPASS} bytes (1.5MB)"
info "BDP socket ceiling    : ${BDP_CEILING} bytes (50MB — @10Gbps burst)"
info "rmem/wmem max         : 750MB per socket"
info "rmem/wmem default     : ${RMEM_DEFAULT} bytes (1.5MB = 1×BDP bypass)"
info "tcp_mem pages         : ${TCP_MEM_PRESSURE} / ${TCP_MEM_HARD} / ${TCP_MEM_MAX}"
info "tcp_notsent_lowat     : ${NOTSENT_LOWAT} bytes (16KB — send-every-tick)"
info "fq quantum            : ${TC_QUANTUM} bytes (1×MSS — fair 2-user scheduling)"
info "busy_poll/read        : ${BUSY_POLL}μs"
info "vCPU                  : ${VCPU} → GOMAXPROCS=${VCPU}"
echo ""

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 1 — UPDATE & DEPS"
# ══════════════════════════════════════════════════════════════════════
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ufw ethtool sqlite3 irqbalance iproute2 iputils-ping
}
run_skip "step1_deps" _step1

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 2 — FIREWALL"
# ══════════════════════════════════════════════════════════════════════
_step2() {
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  for port in "${OPEN_PORTS[@]}"; do
    ufw allow "${port}/tcp"
  done
  ufw allow 443/udp
  ufw --force enable
  ufw status | grep -q "Status: active" || return 1
  info "open ports: ${OPEN_PORTS[*]} + 443/udp"
}
run_skip "step2_ufw" _step2

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 3 — INSTALL 3X-UI"
# ══════════════════════════════════════════════════════════════════════
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
  [ -x "$xui_bin" ] || { echo "x-ui binary not found"; return 1; }
  systemctl enable x-ui 2>/dev/null || true
  systemctl start  x-ui 2>/dev/null || true
  wait_active x-ui 20 || warn "x-ui may not be ready yet"
}
run_skip "step3_3xui" _step3

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 4 — KERNEL / TCP / VM TUNE"
# ══════════════════════════════════════════════════════════════════════
_step4() {
  modprobe tcp_bbr 2>/dev/null || true
  local cc="bbr"
  grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null \
    || { warn "BBR unavailable — fallback cubic"; cc="cubic"; }

  local qdisc="fq"
  modinfo sch_fq &>/dev/null 2>&1 || { warn "fq unavailable — fallback fq_codel"; qdisc="fq_codel"; }

  local has_notsent=0
  [ -f /proc/sys/net/ipv4/tcp_notsent_lowat ] && has_notsent=1

  local has_busypoll=0
  [ -f /proc/sys/net/core/busy_poll ] && has_busypoll=1

  cat > /etc/sysctl.d/99-ais-bypass-tune.conf << EOF
# ════════════════════════════════════════════════════════════════════
#  AIS กันรั่ว — VLESS Reality Bypass Tuner v9.0
#  1vCPU @2.69GHz / 2GB RAM / 2 users / RTT=40ms
#  Control: 128kbps (VLESS Reality port 443 — AIS จำกัด)
#  Bypass:  300Mbps+ (traffic ที่วิ่งผ่าน VPS ออกอินเตอร์เน็ต)
#  VPN MTU: 1500 (X2BOX lock) → MSS=1460
#  Philosophy: ปิงต่ำ · นิ่ง · ส่งทุก tick · fair 2-user
#  Generated: $(date -u '+%Y-%m-%d %H:%M UTC')
# ════════════════════════════════════════════════════════════════════

# ── Congestion Control ─────────────────────────────────────────────
# BBR v1: ไม่ต้องรอ packet loss ถึงลด speed → throughput สม่ำเสมอ
# BBR pacing ทำให้ burst เล็กลง → buffer ที่ AIS ไม่ overflow → ปิงนิ่ง
net.ipv4.tcp_congestion_control = ${cc}

# fq: per-flow fair queuing ใช้คู่กับ BBR เพื่อ pacing
# แต่ละ flow ได้ quantum เท่ากัน → user 1 ไม่กิน BW ของ user 2
net.core.default_qdisc          = ${qdisc}

# ── Socket Buffers ─────────────────────────────────────────────────
# max = 750MB per socket: สำหรับ 2 users คนละ socket
# autotuner จะโตจาก default ขึ้นมาถึง max ตาม BDP จริงที่วัดได้
net.core.rmem_max               = ${RMEM_MAX}
net.core.wmem_max               = ${WMEM_MAX}

# default = 1.5MB = BDP bypass (300Mbps × 40ms)
# socket ใหม่เริ่มที่ 1.5MB → พอสำหรับ normal load โดยไม่เสีย RAM
# ถ้า flow ต้องการมากกว่า autotuner จะขยายเองถึง 750MB
net.core.rmem_default           = ${RMEM_DEFAULT}
net.core.wmem_default           = ${WMEM_DEFAULT}

# tcp_rmem[0]=min: 4KB ป้องกัน kernel deny socket ใหม่ตอน memory pressure
# tcp_rmem[1]=default: เริ่มที่ BDP bypass
# tcp_rmem[2]=max: autotuner ขยายได้ถึง 750MB
net.ipv4.tcp_rmem               = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem               = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}
net.ipv4.tcp_moderate_rcvbuf    = 1

# adv_win_scale=-2: receiver window = rcvbuf × 0.25
# proxy workload: x-ui อ่าน data จาก client แล้ว forward ออก
# ช่วงนี้มี 2 copy ใน kernel buffer พร้อมกัน
# -2 (0.25) ให้ kernel เก็บ buffer margin ไว้มากกว่า -1 (0.5)
# ป้องกัน receive window ล้นตอน forward ช้า
net.ipv4.tcp_adv_win_scale      = -2

# tcp_mem: global memory cap สำหรับทุก TCP socket รวมกัน
# คำนวณจาก RAM ที่เหลือหลัง kernel+system+x-ui ≈ 1200MB
net.ipv4.tcp_mem                = ${TCP_MEM_PRESSURE} ${TCP_MEM_HARD} ${TCP_MEM_MAX}
net.ipv4.tcp_limit_output_bytes = ${LIMIT_OUTPUT}
net.core.optmem_max             = 67108864

# ── SEND-EVERY-TICK: tcp_notsent_lowat ────────────────────────────
# kernel ส่ง data เมื่อ unsent bytes ใน send queue < threshold
# 16KB ≈ 1 TLS record → wakeup app และ flush ออกเกือบทุก write()
# ผล: VLESS payload ถูกส่งออกทันที ไม่รอสะสม → latency ต่ำ
$([ "$has_notsent" = "1" ] && echo "net.ipv4.tcp_notsent_lowat      = ${NOTSENT_LOWAT}" || echo "# tcp_notsent_lowat not available on this kernel")

# ── Queues ─────────────────────────────────────────────────────────
net.core.netdev_max_backlog     = ${NETDEV_BACKLOG}
net.core.somaxconn              = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog    = ${SYN_BACKLOG}

# ── MTU / MSS ──────────────────────────────────────────────────────
# tcp_mtu_probing=1: ถ้า path MTU ต่ำกว่า 1500 (เช่น tunnel hop)
# kernel จะลด MSS อัตโนมัติ → ไม่ต้องเดา overhead ล่วงหน้า
net.ipv4.tcp_mtu_probing        = 1
net.ipv4.tcp_base_mss           = ${BASE_MSS}

# ── Busy Poll: ลด latency ของ receive path ────────────────────────
# process poll NIC โดยตรง 50μs ก่อนที่จะ sleep รอ IRQ
# ที่ RTT 40ms: 50μs = 0.125% ของ RTT — overhead น้อยมาก
# busy_poll + busy_read ทำงานคู่กัน (poll before + read timeout)
$([ "$has_busypoll" = "1" ] && echo "net.core.busy_poll              = ${BUSY_POLL}
net.core.busy_read              = ${BUSY_READ}" || echo "# busy_poll not available on this kernel")

# ── TCP Features ───────────────────────────────────────────────────
# tcp_fastopen=3: ประหยัด 1 RTT (40ms) ตอน reconnect
# AIS 4G reconnect บ่อย → TFO ช่วยได้จริง
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_window_scaling     = 1

# timestamps=0: ไม่ leak server uptime, ประหยัด 12 bytes/segment
# ที่ 128kbps: 12 bytes × ~100 packets/s = ประหยัด ~10kbps (~8% ของ link)
net.ipv4.tcp_timestamps         = 0
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_dsack              = 1
net.ipv4.tcp_fack               = 1

# ECN=1: บอก congestion ด้วย bit flag แทนการ drop packet
# AIS support ECN → ได้ congestion signal เร็วกว่า → BBR adjust ไว
net.ipv4.tcp_ecn                = 1

# tcp_low_latency=1: ACK ได้ priority สูงกว่า data ใน send path
# สำคัญสำหรับ proxy: ACK ช้า = effective RTT สูงขึ้น = throughput ลง
net.ipv4.tcp_low_latency        = 1

# tcp_autocorking=0: ปิด kernel-side Nagle
# default: kernel hold write() เล็กๆ รอ data เพิ่ม (throughput ดีกว่า แต่ latency สูง)
# =0: ทุก write() ส่งออกทันที — ทำงานร่วมกับ tcp_notsent_lowat
net.ipv4.tcp_autocorking        = 0

# thin_linear_timeouts=1: flow ที่มี in-flight segment น้อย (เช่น control traffic)
# ใช้ linear backoff แทน exponential → retransmit เร็วขึ้น
net.ipv4.tcp_thin_linear_timeouts = 1

# early_retrans=3: RFC 5827 — retransmit เมื่อได้ partial ACK
# แทนที่จะรอ full timeout → latency spike จาก loss ลดจาก ~200ms → ~40ms (1 RTT)
net.ipv4.tcp_early_retrans      = 3

# no_metrics_save=0: จำ RTT/CWND ของ peer ไว้ใน route cache
# x-ui connect กลับไป peer เดิมบ่อย → reuse ค่าที่เรียนรู้ → fast start
net.ipv4.tcp_no_metrics_save    = 0
net.ipv4.tcp_syncookies         = 1

# ── TIME_WAIT / Port Reuse ─────────────────────────────────────────
# tw_reuse=1: reuse TIME_WAIT socket สำหรับ new connection
# AIS reconnect บ่อย → port ไม่หมด, connection setup เร็วขึ้น
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_max_tw_buckets     = ${TW_BUCKETS}
net.ipv4.ip_local_port_range    = 1024 65535

# ── Keepalive ──────────────────────────────────────────────────────
# AIS 4G ตัด idle TCP ที่ ~30-60s → ส่ง keepalive ทุก 15s ปลอดภัย
# 15s + (5s × 3 probes) = declare dead ใน 30s หลัง link จริงหาย
net.ipv4.tcp_keepalive_time     = ${KA_TIME}
net.ipv4.tcp_keepalive_intvl    = ${KA_INTVL}
net.ipv4.tcp_keepalive_probes   = ${KA_PROBES}
net.ipv4.tcp_fin_timeout        = ${FIN_TIMEOUT}
net.ipv4.tcp_syn_retries        = 3
net.ipv4.tcp_synack_retries     = 3

# retries2=6: max retransmit time ≈ 127s ที่ RTT 40ms
# ถ้า link หายนานกว่า 127s → close connection แทนที่จะ hang ตลอดไป
net.ipv4.tcp_retries2           = 6

# ── Memory / VM ────────────────────────────────────────────────────
# swappiness=10: ใช้ RAM ก่อน swap — swap บน VPS ช้ามาก (disk I/O)
# x-ui goroutine kicking out to swap = latency spike ทันที
vm.swappiness                   = 10

# dirty_ratio: x-ui ใช้ SQLite ก็ flush ได้เร็ว
vm.dirty_ratio                  = 60
vm.dirty_background_ratio       = 30
vm.dirty_expire_centisecs       = 3000
vm.dirty_writeback_centisecs    = 500

# min_free_kbytes=128MB: kernel safety net สำหรับ GFP_ATOMIC allocation
# IRQ handler, DMA, network stack ต้องการ memory ทันที ถ้าหมดจะ panic
# 2GB RAM: 128MB safety = ≈6% → เหมาะสม
vm.min_free_kbytes              = 131072
vm.vfs_cache_pressure           = 50

# overcommit_memory=2 ratio=95:
# อนุญาต commit ได้ถึง 95% ของ RAM จริง ≈ 1615MB
# ป้องกัน Go runtime overcommit แล้ว OOM ทั้ง server
# mode=2: มีค่า committed memory cap ชัดเจน (ไม่ใช่แค่ฮิวริสติก)
vm.overcommit_memory            = 2
vm.overcommit_ratio             = 95

# numa_balancing=0: single-socket VPS ไม่มี NUMA node
# ปิดเพื่อประหยัด CPU cycles ที่ใช้ scan page
vm.numa_balancing               = 0

# ── File Descriptors ───────────────────────────────────────────────
fs.file-max                     = 1048576
fs.nr_open                      = 1048576

# pipe-max-size=1MB: VLESS data stream ผ่าน Go pipe
# default 64KB → wakeup บ่อย → overhead ไม่จำเป็น
# 1MB → x-ui forward data ใน chunk ใหญ่ขึ้น → efficient
fs.pipe-max-size                = 1048576

# ── Kernel Scheduler ───────────────────────────────────────────────
# autogroup=0: x-ui ได้ CPU timeslice เต็มไม่แบ่งกับ session group
kernel.sched_autogroup_enabled  = 0

# sched_min_granularity_ns=500μs: เวลาน้อยที่สุดที่ task ได้วิ่งก่อน preempt
# 500μs (default desktop 750μs): network IRQ กับ x-ui goroutine สลับเร็วขึ้น
kernel.sched_min_granularity_ns = 500000

# sched_wakeup_granularity_ns=250μs: ป้องกัน task ที่ wake up preempt ทันที
# 250μs: balance ระหว่าง responsiveness กับ cache thrashing
kernel.sched_wakeup_granularity_ns = 250000

kernel.pid_max                  = 65536
kernel.threads-max              = 131072

# panic=10: auto-reboot 10s หลัง kernel panic → VPS ฟื้นเอง
kernel.panic                    = 10
kernel.panic_on_oops            = 1

# ── Security ───────────────────────────────────────────────────────
net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.all.send_redirects     = 0
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_abort_on_overflow       = 0
EOF

  sysctl -p /etc/sysctl.d/99-ais-bypass-tune.conf
  info "sysctl applied"

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null \
    && info "qdisc ${qdisc} quantum=${TC_QUANTUM}B (1×MSS) applied on ${NIC}" \
    || warn "tc ${qdisc} failed — kernel may not support it"

  if [ "$cc" = "bbr" ]; then
    tc qdisc del dev "$NIC" root 2>/dev/null || true
    tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
      quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" \
      maxrate 10gbit 2>/dev/null \
      || tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
         quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null || true
    info "fq maxrate=10gbit (BBR pacing ceiling)"
  fi
}
run_always "step4_sysctl" _step4

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 5 — TRANSPARENT HUGE PAGES → off"
# ══════════════════════════════════════════════════════════════════════
_step5() {
  echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
  echo never > /sys/kernel/mm/transparent_hugepage/defrag   || true
  echo 0     > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null || true
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
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thp-disable.service
  local thp_state
  thp_state=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "unknown")
  info "THP: ${thp_state}"
}
run_always "step5_thp" _step5

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 6 — NIC TUNE (${NIC})"
# ══════════════════════════════════════════════════════════════════════
_step6() {
  ip link show "$NIC" &>/dev/null || { warn "NIC ${NIC} not found"; return 1; }

  local qdisc="fq"
  grep -q "default_qdisc.*fq_codel" /etc/sysctl.d/99-ais-bypass-tune.conf 2>/dev/null \
    && qdisc="fq_codel"

  # GRO/LRO off: ไม่รวม packet บน receive path → latency ต่ำกว่า
  # TSO/GSO on: offload segmentation ไปที่ NIC/kernel → ลด CPU ของ 1vCPU
  # rx-gro-hw off: ปิด hardware GRO ด้วย (consistent กับ GRO off)
  ethtool -K "$NIC" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null \
    || warn "ethtool offload: partial failure (ok on VMs)"

  ethtool -A "$NIC" rx off tx off 2>/dev/null || true

  local rx_max tx_max
  rx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/RX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  tx_max=$(ethtool -g "$NIC" 2>/dev/null \
    | awk '/^Pre-set maximums/,/^Current/ { if(/TX:/) { match($0,/[0-9]+/); print substr($0,RSTART,RLENGTH); exit } }')
  rx_max="${rx_max:-4096}"; tx_max="${tx_max:-4096}"
  ethtool -G "$NIC" rx "$rx_max" tx "$tx_max" 2>/dev/null \
    && info "ring buffer rx=${rx_max} tx=${tx_max}" || true

  # rx-usecs=50: coalescing 50μs ทำงานคู่กับ busy_poll=50μs
  # busy_poll ตรวจก่อน ถ้าพลาด coalescing จะจับ packet ที่เหลือ
  ethtool -C "$NIC" rx-usecs 50 tx-usecs 50 2>/dev/null \
    || ethtool -C "$NIC" rx-usecs 0  tx-usecs 0  2>/dev/null || true

  # MTU=1500: ตรงกับ X2BOX VPN MTU lock → ไม่มี fragmentation
  ip link set "$NIC" mtu "${EFFECTIVE_MTU}" 2>/dev/null \
    && info "MTU → ${EFFECTIVE_MTU}" \
    || warn "MTU set failed — staying at ${MTU_PHYSICAL}"

  # txqueuelen=1000: ไม่ให้ TX queue ยาวเกินไป → bufferbloat ต่ำ
  ip link set "$NIC" txqueuelen 1000

  tc qdisc del dev "$NIC" root 2>/dev/null || true
  tc qdisc add dev "$NIC" root handle 1: "${qdisc}" \
    quantum "${TC_QUANTUM}" buckets "${TC_BUCKETS}" 2>/dev/null \
    || warn "tc ${qdisc} on ${NIC} failed"

  # RPS/RFS: 1vCPU ไม่ได้ distribute จริง แต่ช่วย soft-IRQ budget
  local cpu_mask="1"
  for rps_file in /sys/class/net/"${NIC}"/queues/rx-*/rps_cpus; do
    [ -f "$rps_file" ] && echo "${cpu_mask}" > "$rps_file" 2>/dev/null || true
  done
  if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
    echo 4096 > /proc/sys/net/core/rps_sock_flow_entries
    for rfs_file in /sys/class/net/"${NIC}"/queues/rx-*/rps_flow_cnt; do
      [ -f "$rfs_file" ] && echo 4096 > "$rfs_file" 2>/dev/null || true
    done
    info "RPS/RFS: 4096 entries"
  fi

  mkdir -p /etc/networkd-dispatcher/routable.d
  cat > /etc/networkd-dispatcher/routable.d/50-nic-tune.sh << NEOF
#!/usr/bin/env bash
set -uo pipefail
NIC="${NIC}"
QDISC="${qdisc}"
RX_MAX="${rx_max}"
TX_MAX="${tx_max}"
EFFECTIVE_MTU="${EFFECTIVE_MTU}"
TC_QUANTUM="${TC_QUANTUM}"
TC_BUCKETS="${TC_BUCKETS}"
ip link show "\${NIC}" &>/dev/null || exit 0
ethtool -K "\${NIC}" gro off lro off tso on gso on rx-gro-hw off 2>/dev/null || true
ethtool -A "\${NIC}" rx off tx off 2>/dev/null || true
ethtool -G "\${NIC}" rx "\${RX_MAX}" tx "\${TX_MAX}" 2>/dev/null || true
ethtool -C "\${NIC}" rx-usecs 50 tx-usecs 50 2>/dev/null || true
ip link set "\${NIC}" mtu "\${EFFECTIVE_MTU}" 2>/dev/null || true
ip link set "\${NIC}" txqueuelen 1000
tc qdisc del dev "\${NIC}" root 2>/dev/null || true
tc qdisc add dev "\${NIC}" root handle 1: "\${QDISC}" \
  quantum \${TC_QUANTUM} buckets \${TC_BUCKETS} 2>/dev/null || true
for rps_file in /sys/class/net/"\${NIC}"/queues/rx-*/rps_cpus; do
  [ -f "\$rps_file" ] && echo "1" > "\$rps_file" 2>/dev/null || true
done
if [ -f /proc/sys/net/core/rps_sock_flow_entries ]; then
  echo 4096 > /proc/sys/net/core/rps_sock_flow_entries
  for rfs_file in /sys/class/net/"\${NIC}"/queues/rx-*/rps_flow_cnt; do
    [ -f "\$rfs_file" ] && echo 4096 > "\$rfs_file" 2>/dev/null || true
  done
fi
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
run_always "step6_nic" _step6

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 7 — I/O SCHEDULER"
# ══════════════════════════════════════════════════════════════════════
_step7() {
  local found=0
  for DEV in sda sdb vda vdb xvda nvme0n1 nvme1n1; do
    [ -b "/dev/${DEV}" ] || continue
    found=1
    local rot
    rot=$(cat "/sys/block/${DEV}/queue/rotational" 2>/dev/null || echo "0")
    if [ "$rot" = "0" ]; then
      echo none        > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: SSD/NVMe → none"
    else
      echo mq-deadline > "/sys/block/${DEV}/queue/scheduler" 2>/dev/null || true
      info "${DEV}: HDD → mq-deadline"
    fi
    echo 0    > "/sys/block/${DEV}/queue/add_random"  2>/dev/null || true
    echo 4096 > "/sys/block/${DEV}/queue/nr_requests" 2>/dev/null || true
    echo 1    > "/sys/block/${DEV}/queue/nomerges"    2>/dev/null || true
    echo 128  > "/sys/block/${DEV}/queue/read_ahead_kb" 2>/dev/null || true
  done
  [ "$found" -eq 1 ] || warn "no block device matched — may be unusual path"

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
run_always "step7_io" _step7

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 8 — CPU GOVERNOR → performance"
# ══════════════════════════════════════════════════════════════════════
_step8() {
  cat > /etc/systemd/system/cpu-performance.service << 'EOF'
[Unit]
Description=CPU Governor → performance
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
  local gov
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A (VM may have no cpufreq)")
  info "governor: ${gov}"
}
run_always "step8_cpu" _step8

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 9 — SYSTEM LIMITS"
# ══════════════════════════════════════════════════════════════════════
_step9() {
  cat > /etc/security/limits.d/99-xui.conf << 'EOF'
*    soft nofile   1048576
*    hard nofile   1048576
*    soft nproc    65536
*    hard nproc    65536
*    soft memlock  unlimited
*    hard memlock  unlimited
*    soft stack    67108864
*    hard stack    67108864
root soft nofile   1048576
root hard nofile   1048576
root soft nproc    65536
root hard nproc    65536
root soft memlock  unlimited
root hard memlock  unlimited
EOF
  for pam in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
    [ -f "$pam" ] || continue
    grep -qxF 'session required pam_limits.so' "$pam" \
      || echo 'session required pam_limits.so' >> "$pam"
  done
}
run_always "step9_limits" _step9

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 10 — x-ui SYSTEMD OVERRIDE"
# ══════════════════════════════════════════════════════════════════════
_step10() {
  mkdir -p /etc/systemd/system/x-ui.service.d
  cat > /etc/systemd/system/x-ui.service.d/override.conf << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=65536
LimitMEMLOCK=infinity
LimitCORE=0
LimitSTACK=67108864

Restart=always
RestartSec=2
RestartPreventExitStatus=0

# GOMAXPROCS=${VCPU}: ตรงกับ vCPU จริง ไม่ spawn goroutine thread เกินกว่า CPU ที่มี
# GOGC=80: trigger GC ที่ heap 80% (default 100%) — heap เล็กลง GC pause สั้นลง
# madvdontneed=1: คืน memory ที่ free กลับ OS ทันที ป้องกัน RSS บวม
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=80
Environment=GODEBUG=madvdontneed=1

# OOMScoreAdjust=-500: kernel จะฆ่า process อื่นก่อน x-ui ตอน OOM
OOMScoreAdjust=-500

# MemoryHigh: soft limit — kernel จะ throttle GC ก่อนถึง MemoryMax
# MemoryMax: hard kill — cgroup จะ OOM kill x-ui ถ้าเกิน
# MemorySwapMax: อนุญาต swap เพิ่มอีก 100MB เป็น safety net
MemoryHigh=${XUI_MEM_HIGH}
MemoryMax=${XUI_MEM_MAX}
MemorySwapMax=${XUI_MEM_SWAP}

CPUSchedulingPolicy=other
CPUSchedulingPriority=0
CPUWeight=100
IOSchedulingClass=best-effort
IOSchedulingPriority=0
IOWeight=100

# Nice=0: 1vCPU ไม่มี process อื่นแย่ง CPU จริงๆ ปรับ nice ไม่มีผล
Nice=0

TasksMax=4096
EOF
  systemctl daemon-reload
  systemctl restart x-ui
  wait_active x-ui 30 || { warn "x-ui not active after override — check logs"; return 1; }
  info "x-ui cgroup: MemHigh=$((XUI_MEM_HIGH/1024/1024))MB MemMax=$((XUI_MEM_MAX/1024/1024))MB"
  info "x-ui Go env: GOMAXPROCS=${VCPU} GOGC=80 GODEBUG=madvdontneed=1"
}
run_always "step10_xui_override" _step10

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 11 — IRQBALANCE CONFIG"
# ══════════════════════════════════════════════════════════════════════
_step11() {
  if command -v irqbalance &>/dev/null; then
    cat > /etc/default/irqbalance << 'EOF'
ENABLED=1
ONESHOT=0
OPTIONS="--powerthresh=0"
EOF
    systemctl enable --now irqbalance 2>/dev/null || true
    info "irqbalance: enabled"
  else
    warn "irqbalance not installed — skipping"
  fi
}
run_always "step11_irq" _step11

# ══════════════════════════════════════════════════════════════════════
hdr "STEP 12 — REALITY PANEL CONFIG GUIDE"
# ══════════════════════════════════════════════════════════════════════
_step12() {
  cat << 'GUIDE'

  ┌────────────────────────────────────────────────────────────────┐
  │  AIS กันรั่ว · 3x-ui · VLESS Reality · v9.0                  │
  │  Control: 128kbps (AIS จำกัด) · Bypass: 300Mbps+             │
  ├────────────────────────────────────────────────────────────────┤
  │                                                                │
  │  Protocol     : VLESS                                         │
  │  Port         : 443     ← หลัก (AIS TLS passthrough)         │
  │  Port alt     : 8443    ← สำรอง                              │
  │  Transport    : TCP (raw)                                      │
  │  Security     : Reality                                        │
  │  Flow         : xtls-rprx-vision  ← บังคับสำหรับ Reality     │
  │                                                                │
  │  ── Reality Settings ────────────────────────────────────────  │
  │  Dest (SNI)   : speedtest.net:443                             │
  │  ServerName   : speedtest.net                                 │
  │  Fingerprint  : firefox                                       │
  │  Public Key   : [generate ใน panel → Reality → Gen]          │
  │  Short ID     : [generate ใน panel → 8 hex chars]            │
  │                                                                │
  │  ── TCP Settings ────────────────────────────────────────────  │
  │  TCP Fast Open: enabled (ประหยัด 40ms ต่อ reconnect)         │
  │  Sniffing     : ปิดทั้งหมด (ลด overhead บน 1vCPU)            │
  │                                                                │
  │  ── AIS Port Priority ───────────────────────────────────────  │
  │  ✓  443  — best, TLS passthrough ผ่านสบาย                    │
  │  ✓  8443 — good, alt HTTPS                                    │
  │  ○  2053 — ok, DNS-over-HTTPS port                            │
  │  ✗  80   — avoid, AIS inspect HTTP                            │
  │  ✗  UDP  — avoid, AIS throttle UDP หนักมาก                   │
  │                                                                │
  │  ── v9.0 เปลี่ยนจาก v8.0 ─────────────────────────────────  │
  │  MTU 1500 (ตาม X2BOX lock) · MSS=1460 (หักแค่ IP+TCP 40B)   │
  │  rmem/wmem default: 50MB→1.5MB (= BDP bypass จริง)           │
  │  tcp_mem: ปรับตาม RAM เหลือจริง หลัง x-ui (~1200MB budget)   │
  │  fq quantum: 1460B (= MSS จริง สำหรับ MTU 1500)              │
  │  comments: เพิ่มอธิบายทุก knob เป็นภาษาที่อ่านเข้าใจ        │
  │                                                                │
  │  Max users: 2 คน (per this tune profile)                      │
  └────────────────────────────────────────────────────────────────┘

GUIDE
}
run_always "step12_guide" _step12

# ══════════════════════════════════════════════════════════════════════
hdr "DONE — FULL SUMMARY"
# ══════════════════════════════════════════════════════════════════════
PUB_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
  || curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")

echo ""
echo -e "${BLD}${GRN}  Steps completed:${RST}"
while IFS= read -r line; do
  [ -n "$line" ] && echo -e "    ${GRN}✔${RST}  ${line}"
done < "$STATE_FILE"

echo ""
echo -e "  ══════════════════════════════════════════════════════════════"
echo -e "  ${BLD}Panel URL          :${RST} http://${PUB_IP}:${PANEL_PORT}"
echo -e "  ──────────────────────────────────────────────────────────────"
echo -e "  ${BLD}NIC                :${RST} ${NIC}  MTU ${EFFECTIVE_MTU} (X2BOX lock)"
echo -e "  ${BLD}BASE_MSS           :${RST} ${BASE_MSS} bytes (MTU 1500 − IP 20 − TCP 20)"
echo -e "  ${BLD}BDP bypass         :${RST} ${BDP_BYPASS} bytes (300Mbps × 40ms)"
echo -e "  ${BLD}BDP socket ceiling :${RST} ${BDP_CEILING} bytes (50MB @ 10Gbps burst)"
echo -e "  ──────────────────────────────────────────────────────────────"
echo -e "  ${BLD}rmem/wmem max      :${RST} 750MB per socket"
echo -e "  ${BLD}rmem/wmem default  :${RST} 1.5MB (= 1×BDP bypass, autotuner grows to 750MB)"
echo -e "  ${BLD}tcp_mem pages      :${RST} ${TCP_MEM_PRESSURE} / ${TCP_MEM_HARD} / ${TCP_MEM_MAX}"
echo -e "  ${BLD}                   :${RST} pressure=900MB  hard=1080MB  max=1200MB"
echo -e "  ${BLD}Kernel reserve     :${RST} ~800MB (kernel + system + x-ui)"
echo -e "  ──────────────────────────────────────────────────────────────"
echo -e "  ${BLD}★ notsent_lowat    :${RST} ${NOTSENT_LOWAT} bytes (16KB — send-every-tick)"
echo -e "  ${BLD}★ autocorking      :${RST} 0 (ปิด — ส่งทุก write() ทันที)"
echo -e "  ${BLD}★ fq quantum       :${RST} ${TC_QUANTUM} bytes (1×MSS — fair 2-user)"
echo -e "  ${BLD}★ busy_poll        :${RST} ${BUSY_POLL}μs (ข้าม IRQ latency บน receive path)"
echo -e "  ──────────────────────────────────────────────────────────────"
echo -e "  ${BLD}somaxconn          :${RST} ${SOMAXCONN}"
echo -e "  ${BLD}nofile             :${RST} 1,048,576"
echo -e "  ${BLD}nproc              :${RST} 65,536"
echo -e "  ${BLD}GOMAXPROCS         :${RST} ${VCPU}"
echo -e "  ${BLD}GOGC               :${RST} 80 (GC เร็วกว่า default 100)"
echo -e "  ${BLD}GODEBUG            :${RST} madvdontneed=1 (คืน free memory OS ทันที)"
echo -e "  ${BLD}OOMScore x-ui      :${RST} -500 (protected)"
echo -e "  ${BLD}x-ui MemHigh       :${RST} 1500MB"
echo -e "  ${BLD}x-ui MemMax        :${RST} 1600MB"
echo -e "  ${BLD}x-ui SwapMax       :${RST} 100MB"
echo -e "  ──────────────────────────────────────────────────────────────"
echo -e "  ${BLD}swappiness         :${RST} 10"
echo -e "  ${BLD}overcommit         :${RST} mode=2  ratio=95% (≈1615MB ceiling)"
echo -e "  ${BLD}min_free_kbytes    :${RST} 131072 (128MB kernel safety net)"
echo -e "  ${BLD}numa_balancing     :${RST} 0"
echo -e "  ──────────────────────────────────────────────────────────────"
echo -e "  ${BLD}BBR                :${RST} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
echo -e "  ${BLD}FastOpen           :${RST} $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo N/A) (3=client+server)"
echo -e "  ${BLD}ECN                :${RST} $(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Timestamps         :${RST} $(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo N/A) (0=privacy+ประหยัด BW)"
echo -e "  ${BLD}Keepalive          :${RST} ${KA_TIME}s / ${KA_INTVL}s × ${KA_PROBES} (AIS กัน idle drop)"
echo -e "  ${BLD}Qdisc              :${RST} $(tc qdisc show dev "$NIC" 2>/dev/null | head -1 || echo N/A)"
echo -e "  ${BLD}THP                :${RST} $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo N/A)"
echo -e "  ${BLD}CPU governor       :${RST} $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo N/A)"
echo -e "  ${BLD}x-ui status        :${RST} $(systemctl is-active x-ui 2>/dev/null || echo N/A)"
echo -e "  ${BLD}Log                :${RST} ${LOG_FILE}"
echo -e "  ══════════════════════════════════════════════════════════════"
echo ""
echo -e "  ${BLD}${YEL}→ reboot แล้ว config Reality ใน panel ตาม guide ด้านบน${RST}"
echo ""
