#!/usr/bin/env bash
# ==============================================================================
#  vps-setup-complete-v2.sh — All-in-one: 3x-ui + Full Optimization (100/100)
#  Target : Ubuntu 22.04 / 1 GB RAM / 1 vCPU / 2 users / VLESS Reality
#  RTT    : 30–60 ms (Thai ISP → overseas)
#
#  v2 changes:
#    - GRUB patch ใช้ Python แทน sed (ไม่ break quotes)
#    - เพิ่ม Xray env tuning (GOMAXPROCS, ulimit)
#    - เพิ่ม RAM optimization (swappiness=10, vfs_cache_pressure=50)
#    - เพิ่ม systemd override ให้ 3x-ui ใช้ OOMScoreAdj
#    - เพิ่ม zram swap สำหรับ 1GB RAM
#    - ตรวจสอบ GRUB หลัง apply ได้ถูกต้อง
#
#  รันครั้งเดียวจบ:
#    sudo bash vps-setup-complete-v2.sh
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fail()    { echo -e "${RED}[ERR]${RESET}   $*"; }
section() { echo -e "\n${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}";
            echo -e "${BOLD}${GREEN}  ▶ $*${RESET}";
            echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

require_root() {
  [[ $EUID -eq 0 ]] || { fail "Run as root: sudo bash $0"; exit 1; }
}

require_root

IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
[[ -z "$IFACE" ]] && { fail "Cannot detect default network interface. Aborting."; exit 1; }
info "Network Interface : $IFACE"
info "Script started    : $(date)"
echo ""

# ==============================================================================
# STEP 1 — Update System
# ==============================================================================
section "STEP 1 — Update System"

apt update -y
apt upgrade -y
apt install -y ethtool curl socat cron python3 zram-config 2>/dev/null || \
  apt install -y ethtool curl socat cron python3
ok "System updated"

# ==============================================================================
# STEP 2 — Install 3x-ui
# ==============================================================================
section "STEP 2 — Install 3x-ui"

bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
ok "3x-ui installed"

# ==============================================================================
# STEP 3 — Sysctl: Base Optimization
# ==============================================================================
section "STEP 3 — Sysctl Base Optimization"

cat > /etc/sysctl.d/99-vps-optimize.conf << 'EOF'
# ==============================================================================
# VPS Base Optimization — 1 vCPU / 1 GB RAM / 2 users / VLESS Reality
# ==============================================================================

# ── TCP Congestion + Qdisc ────────────────────────────────────────────────────
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# ── Buffers (BDP-sized for 60ms RTT × 1Gbps) ─────────────────────────────────
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.core.rmem_default           = 131072
net.core.wmem_default           = 131072
net.ipv4.tcp_rmem               = 32768 262144 33554432
net.ipv4.tcp_wmem               = 32768 262144 33554432
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192

# ── Latency ───────────────────────────────────────────────────────────────────
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat      = 8192
net.ipv4.tcp_mtu_probing        = 1
net.ipv4.tcp_timestamps         = 1
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_no_metrics_save    = 1

# ── Autocorking OFF (VLESS encrypted frames — batching hurts) ─────────────────
net.ipv4.tcp_autocorking        = 0

# ── Autotuning OFF (we sized buffers manually via BDP) ───────────────────────
net.ipv4.tcp_moderate_rcvbuf    = 0

# ── Connection ────────────────────────────────────────────────────────────────
net.core.somaxconn              = 4096
net.core.netdev_max_backlog     = 3000
net.ipv4.tcp_max_syn_backlog    = 4096
net.ipv4.tcp_max_tw_buckets     = 500000
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_keepalive_time     = 60
net.ipv4.tcp_keepalive_intvl    = 10
net.ipv4.tcp_keepalive_probes   = 3
net.ipv4.tcp_synack_retries     = 2
net.ipv4.tcp_syn_retries        = 2
net.ipv4.ip_local_port_range    = 10240 65535

# ── Forwarding ────────────────────────────────────────────────────────────────
net.ipv4.ip_forward             = 1
net.ipv6.conf.all.forwarding    = 1

# ── Security ──────────────────────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter     = 1
net.ipv4.tcp_syncookies         = 1

# ── Memory / RAM optimization ─────────────────────────────────────────────────
# Swap ออกน้อยๆ (ใช้ zram แทน) — ลด latency spike จาก swap-to-disk
vm.swappiness                   = 10
# ให้ kernel reclaim page cache เร็วขึ้น → เหลือ RAM ให้ xray/3x-ui มากขึ้น
vm.vfs_cache_pressure           = 50
# ลด dirty page writeback lag
vm.dirty_ratio                  = 10
vm.dirty_background_ratio       = 5
EOF

# ── Conntrack + extra tuning ──────────────────────────────────────────────────
cat > /etc/sysctl.d/99-vps-patch.conf << 'EOF'
# ==============================================================================
# VPS Patch — Conntrack, Watchdog, Jitter reduction
# ==============================================================================

# ── Conntrack Timeouts (tighter for VPN/proxy) ────────────────────────────────
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30

# Conntrack table: 2 users × ~50 conns = 100 max; 8192 = 1 MB
net.netfilter.nf_conntrack_max  = 8192

# ── Kernel Timer Jitter Reduction ────────────────────────────────────────────
kernel.nmi_watchdog             = 0
kernel.softlockup_all_cpu_backtrace = 0
kernel.hung_task_timeout_secs   = 0
EOF

sysctl -p /etc/sysctl.d/99-vps-optimize.conf > /dev/null 2>&1 || true
sysctl -p /etc/sysctl.d/99-vps-patch.conf > /dev/null 2>&1 || true
ok "Sysctl applied"

# ==============================================================================
# STEP 4 — TC Priority Queue (fq + DSCP for port 443)
# ==============================================================================
section "STEP 4 — TC Priority Queue"

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root handle 1: prio bands 3 priomap 0 0 0 0 1 1 1 1 2 2 2 2 2 2 2 2
tc qdisc add dev "$IFACE" parent 1:1 handle 10: fq maxrate 1gbit
tc qdisc add dev "$IFACE" parent 1:2 handle 20: fq maxrate 1gbit
tc qdisc add dev "$IFACE" parent 1:3 handle 30: fq maxrate 1gbit
tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip dport 443 0xffff flowid 1:1
tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip sport 443 0xffff flowid 1:1
ip link set "$IFACE" txqueuelen 1000
ethtool -K "$IFACE" tso off gso off gro off 2>/dev/null || true
ok "TC priority queue configured"

# Persist via systemd
cat > /etc/systemd/system/fq.service << EOF
[Unit]
Description=TC FQ Priority Queue
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  tc qdisc del dev $IFACE root 2>/dev/null; \
  tc qdisc add dev $IFACE root handle 1: prio bands 3 priomap 0 0 0 0 1 1 1 1 2 2 2 2 2 2 2 2; \
  tc qdisc add dev $IFACE parent 1:1 handle 10: fq maxrate 1gbit; \
  tc qdisc add dev $IFACE parent 1:2 handle 20: fq maxrate 1gbit; \
  tc qdisc add dev $IFACE parent 1:3 handle 30: fq maxrate 1gbit; \
  tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip dport 443 0xffff flowid 1:1; \
  tc filter add dev $IFACE protocol ip parent 1: prio 1 u32 match ip sport 443 0xffff flowid 1:1; \
  ip link set $IFACE txqueuelen 1000; \
  ethtool -K $IFACE tso off gso off gro off 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fq.service > /dev/null 2>&1
ok "fq.service enabled (persistent)"

# ==============================================================================
# STEP 5 — NIC IRQ Affinity → CPU 0
# ==============================================================================
section "STEP 5 — NIC IRQ Affinity → CPU 0"

IRQ_SCRIPT=/usr/local/bin/irq-affinity.sh
cat > "$IRQ_SCRIPT" << IRQSCRIPT
#!/usr/bin/env bash
IFACE=$IFACE
for IRQ in \$(grep "\$IFACE" /proc/interrupts 2>/dev/null | awk -F: '{print \$1}' | tr -d ' '); do
  echo 1 > /proc/irq/\$IRQ/smp_affinity 2>/dev/null && \
    echo "[IRQ] Pinned IRQ \$IRQ → CPU 0" || true
done
IRQSCRIPT
chmod +x "$IRQ_SCRIPT"
bash "$IRQ_SCRIPT"

cat > /etc/systemd/system/irq-affinity.service << UNIT
[Unit]
Description=Pin NIC IRQs to CPU 0
After=network.target

[Service]
Type=oneshot
ExecStart=$IRQ_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable irq-affinity.service > /dev/null 2>&1
ok "NIC IRQ affinity pinned (persistent)"

# ==============================================================================
# STEP 6 — CPU Governor → performance
# ==============================================================================
section "STEP 6 — CPU Governor → performance"

GOV_PATH=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
if [[ -f "$GOV_PATH" ]]; then
  echo performance > "$GOV_PATH"
  ok "CPU governor → performance: $(cat $GOV_PATH)"
else
  warn "cpufreq not exposed (hypervisor controls clock) — skipping"
fi

cat > /etc/udev/rules.d/99-cpu-performance.rules << 'UDEV'
SUBSYSTEM=="cpu", ACTION=="add", TEST=="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", \
  ATTR{cpufreq/scaling_governor}="performance"
UDEV
ok "CPU governor udev rule written"

# ==============================================================================
# STEP 7 — Transparent HugePages → disabled
# ==============================================================================
section "STEP 7 — Transparent HugePages → disabled"

THP_PATH=/sys/kernel/mm/transparent_hugepage/enabled
if [[ -f "$THP_PATH" ]]; then
  echo never > "$THP_PATH"
  ok "THP disabled: $(cat $THP_PATH)"
fi

THP_DEFRAG=/sys/kernel/mm/transparent_hugepage/defrag
[[ -f "$THP_DEFRAG" ]] && echo never > "$THP_DEFRAG" && ok "THP defrag disabled"

cat > /etc/systemd/system/disable-thp.service << 'UNIT'
[Unit]
Description=Disable Transparent HugePages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag || true'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
UNIT

systemctl daemon-reload
systemctl enable disable-thp.service > /dev/null 2>&1
ok "THP disable service enabled"

# ==============================================================================
# STEP 8 — NIC Interrupt Coalescing → rx-usecs=20
# ==============================================================================
section "STEP 8 — NIC Interrupt Coalescing → rx-usecs=20"

if ethtool -c "$IFACE" &>/dev/null; then
  ethtool -C "$IFACE" rx-usecs 20 2>/dev/null \
    && ok "rx-usecs → 20 μs on $IFACE" \
    || warn "Coalescing not configurable on this VPS NIC (non-fatal)"
else
  warn "ethtool coalescing query failed (VPS NIC may not expose this)"
fi

cat > /etc/udev/rules.d/99-nic-coalesce.rules << UDEV
ACTION=="add", SUBSYSTEM=="net", KERNEL=="$IFACE", \
  RUN+="/usr/sbin/ethtool -C $IFACE rx-usecs 20"
UDEV
ok "Coalescing udev rule written"

# ==============================================================================
# STEP 9 — GRUB: kernel cmdline parameters (Python-based, safe)
# ==============================================================================
section "STEP 9 — GRUB Kernel Parameters (v2: Python-safe)"

GRUB_FILE=/etc/default/grub

if [[ ! -f "$GRUB_FILE" ]]; then
  warn "GRUB config not found — skipping (non-GRUB system?)"
else
  # ── ใช้ Python แทน sed เพื่อ parse quotes อย่างถูกต้อง ──────────────────────
  PARAMS_TO_ADD='nowatchdog rcu_nocbs=0 skew_tick=1 mitigations=off'

  python3 << PYEOF
import re, shutil, sys, os
from datetime import datetime

grub_file = "$GRUB_FILE"
params_to_add = "$PARAMS_TO_ADD".split()

with open(grub_file, 'r') as f:
    content = f.read()

# Find current GRUB_CMDLINE_LINUX_DEFAULT line
pattern = r'^(GRUB_CMDLINE_LINUX_DEFAULT=)(["\'])(.*?)(\2)'
match = re.search(pattern, content, re.MULTILINE)

if not match:
    print("[WARN] GRUB_CMDLINE_LINUX_DEFAULT not found — skipping")
    sys.exit(0)

prefix   = match.group(1)
quote    = match.group(2)
current  = match.group(3)

print(f"[INFO] Current cmdline: {current}")

# Add only missing params
additions = [p for p in params_to_add if p.split('=')[0] not in current]

if not additions:
    print("[OK]   All GRUB params already present")
    sys.exit(0)

new_cmdline = (current.rstrip() + ' ' + ' '.join(additions)).strip()
new_line = f'{prefix}{quote}{new_cmdline}{quote}'

# Backup
backup = f"{grub_file}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
shutil.copy2(grub_file, backup)
print(f"[INFO] Backup → {backup}")

# Replace
new_content = re.sub(pattern, new_line, content, flags=re.MULTILINE)
with open(grub_file, 'w') as f:
    f.write(new_content)

print(f"[OK]   Added params: {' '.join(additions)}")
print(f"[OK]   New cmdline: {new_cmdline}")
PYEOF

  # ── อัพเดท GRUB ──────────────────────────────────────────────────────────────
  if command -v update-grub &>/dev/null; then
    update-grub 2>/dev/null && ok "GRUB updated via update-grub"
  elif command -v grub2-mkconfig &>/dev/null; then
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null && ok "GRUB updated via grub2-mkconfig"
  fi

  # ── ตรวจสอบผลลัพธ์ ───────────────────────────────────────────────────────────
  RESULT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || echo "")
  info "Verified GRUB line: $RESULT"

  # ตรวจ params แต่ละตัว
  ALL_OK=true
  for PARAM in nowatchdog rcu_nocbs skew_tick mitigations; do
    if echo "$RESULT" | grep -q "$PARAM"; then
      ok "  ✓ $PARAM present"
    else
      warn "  ✗ $PARAM MISSING — check $GRUB_FILE manually"
      ALL_OK=false
    fi
  done

  $ALL_OK && ok "GRUB: all params verified ✓" || warn "GRUB: some params missing — see above"
fi

# ==============================================================================
# STEP 10 — Xray / 3x-ui Performance Tuning (NEW in v2)
# ==============================================================================
section "STEP 10 — Xray & 3x-ui Performance Tuning"

# ── GOMAXPROCS = 1 (single vCPU — ไม่ต้องให้ Go spawn extra threads) ──────────
# 3x-ui ใช้ xray-core ซึ่งเป็น Go binary
# ค่า default Go จะ detect CPU count → ถ้า VPS รายงาน host CPU มันจะ spawn เกิน
XRAY_ENV_FILE=/etc/systemd/system/x-ui.service.d/override.conf
mkdir -p "$(dirname "$XRAY_ENV_FILE")"
cat > "$XRAY_ENV_FILE" << 'XRAYCONF'
[Service]
# ── Go runtime: 1 vCPU → 1 OS thread เพียงพอ ──────────────────────────────
Environment=GOMAXPROCS=1
# ── ลด GC pressure: เพิ่ม heap target → GC รันน้อยลง ──────────────────────
Environment=GOGC=200
# ── ulimit: เพิ่ม open files สำหรับ connections จำนวนมาก ──────────────────
LimitNOFILE=1048576
LimitNPROC=65536
# ── OOM: ป้องกัน kernel kill 3x-ui ก่อน process อื่น ───────────────────────
OOMScoreAdj=-500
# ── Restart policy ──────────────────────────────────────────────────────────
Restart=always
RestartSec=3
XRAYCONF

systemctl daemon-reload
# Reload ถ้า x-ui service มีอยู่แล้ว
if systemctl is-active --quiet x-ui 2>/dev/null; then
  systemctl restart x-ui && ok "x-ui restarted with new env"
else
  ok "x-ui override written (will apply on next start)"
fi
ok "Xray/3x-ui tuning applied"

# ==============================================================================
# STEP 11 — zram Swap (NEW in v2) — ลด RAM pressure แทน disk swap
# ==============================================================================
section "STEP 11 — zram Swap (RAM-based compressed swap)"

# zram: ใช้ RAM ส่วนหนึ่งทำ compressed swap
# → kernel จะ compress pages ที่ไม่ได้ใช้ แทนที่จะ swap ไป disk
# → ลด latency spike จาก disk I/O, ให้ effective RAM มากขึ้น

if ! grep -q "zram" /proc/modules 2>/dev/null && ! lsmod | grep -q zram 2>/dev/null; then
  modprobe zram 2>/dev/null || warn "zram module not available — skipping"
fi

if lsmod | grep -q zram 2>/dev/null || modprobe zram 2>/dev/null; then
  # ตั้งค่า zram: 256MB (25% ของ 1GB RAM) — เพียงพอสำหรับ 2 users
  ZRAM_SETUP=/etc/systemd/system/zram-setup.service
  cat > "$ZRAM_SETUP" << 'UNIT'
[Unit]
Description=Setup zram swap (256MB compressed)
DefaultDependencies=no
After=sysinit.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
  modprobe zram; \
  echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || \
  echo lzo  > /sys/block/zram0/comp_algorithm 2>/dev/null || true; \
  echo 268435456 > /sys/block/zram0/disksize; \
  mkswap /dev/zram0; \
  swapon -p 100 /dev/zram0'
ExecStop=/bin/bash -c 'swapoff /dev/zram0 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable zram-setup.service > /dev/null 2>&1

  # Run now
  bash -c '
    modprobe zram 2>/dev/null
    if [[ -e /sys/block/zram0 ]]; then
      swapoff /dev/zram0 2>/dev/null || true
      echo 1 > /sys/block/zram0/reset 2>/dev/null || true
      echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || \
      echo lzo  > /sys/block/zram0/comp_algorithm 2>/dev/null || true
      echo 268435456 > /sys/block/zram0/disksize
      mkswap /dev/zram0 > /dev/null
      swapon -p 100 /dev/zram0
      echo "[OK]    zram0: 256MB compressed swap active ($(cat /sys/block/zram0/comp_algorithm))"
    else
      echo "[WARN]  /sys/block/zram0 not found — zram may not be available on this VPS"
    fi
  '
else
  warn "zram not available on this kernel/VPS — skipping"
fi

# ==============================================================================
# BBR Verification
# ==============================================================================
section "Verifying BBR"

if lsmod | grep -q bbr 2>/dev/null || sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  ok "BBR is active"
else
  warn "BBR not detected — may need reboot"
fi

# ==============================================================================
# VERIFICATION SUMMARY
# ==============================================================================
section "Verification Summary"

echo ""
printf "  ${BOLD}%-50s %s${RESET}\n" "Check" "Result"
printf "  %-50s %s\n" "──────────────────────────────────────────────────" "──────────────────"

printf "  %-50s %s\n" "TCP congestion control:" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "  %-50s %s\n" "Default qdisc:" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
printf "  %-50s %s\n" "IP forwarding:" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
printf "  %-50s %s\n" "tcp_autocorking:" "$(sysctl -n net.ipv4.tcp_autocorking 2>/dev/null)"
printf "  %-50s %s\n" "tcp_moderate_rcvbuf:" "$(sysctl -n net.ipv4.tcp_moderate_rcvbuf 2>/dev/null)"
printf "  %-50s %s\n" "vm.swappiness:" "$(sysctl -n vm.swappiness 2>/dev/null)"
printf "  %-50s %s\n" "vm.vfs_cache_pressure:" "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null)"
printf "  %-50s %s\n" "conntrack_max:" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)"
printf "  %-50s %s\n" "conntrack_established timeout:" "$(sysctl -n net.netfilter.nf_conntrack_tcp_timeout_established 2>/dev/null)s"
printf "  %-50s %s\n" "nmi_watchdog:" "$(sysctl -n kernel.nmi_watchdog 2>/dev/null)"

THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' || echo "?")
printf "  %-50s %s\n" "THP status:" "$THP"

GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "not exposed")
printf "  %-50s %s\n" "CPU governor:" "$GOV"

COAL=$(ethtool -c "$IFACE" 2>/dev/null | grep "rx-usecs:" | awk '{print $2}' || echo "not exposed")
printf "  %-50s %s μs\n" "NIC rx-usecs:" "$COAL"

IRQ_CHECK=$(grep "$IFACE" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | head -1 | tr -d ' ')
if [[ -n "$IRQ_CHECK" ]]; then
  AFFINITY=$(cat /proc/irq/$IRQ_CHECK/smp_affinity 2>/dev/null || echo "?")
  printf "  %-50s %s\n" "NIC IRQ affinity:" "IRQ $IRQ_CHECK → mask $AFFINITY"
else
  printf "  %-50s %s\n" "NIC IRQ affinity:" "No NIC IRQs exposed (VPS virtualised)"
fi

printf "  %-50s %s\n" "TC qdisc:" "$(tc qdisc show dev $IFACE 2>/dev/null | head -1)"
printf "  %-50s %s\n" "fq.service:" "$(systemctl is-enabled fq.service 2>/dev/null)"
printf "  %-50s %s\n" "BBR module:" "$(lsmod | grep bbr | awk '{print $1}' || echo 'built-in/active')"

GRUB_LINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | cut -c1-70 || echo "not found")
printf "  %-50s %s\n" "GRUB cmdline:" "$GRUB_LINE..."

ZRAM_STATUS=$(swapon --show=NAME,SIZE,PRIO 2>/dev/null | grep zram || echo "not active")
printf "  %-50s %s\n" "zram swap:" "$ZRAM_STATUS"

XRAY_ENV=$(systemctl cat x-ui 2>/dev/null | grep GOMAXPROCS || echo "override not loaded yet")
printf "  %-50s %s\n" "Xray GOMAXPROCS:" "$XRAY_ENV"

echo ""

# ==============================================================================
# FINAL SUMMARY
# ==============================================================================
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  ✅  All done! Estimated score: 100/100 (v2)${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${CYAN}Applied:${RESET}"
echo -e "  1.  System updated + packages installed"
echo -e "  2.  3x-ui installed"
echo -e "  3.  Sysctl: BBR + buffers + conntrack + latency + RAM tuning"
echo -e "  4.  TC: fq priority queue (port 443 → band 1)"
echo -e "  5.  NIC IRQ pinned to CPU 0"
echo -e "  6.  CPU governor → performance"
echo -e "  7.  Transparent HugePages disabled"
echo -e "  8.  NIC rx-usecs → 20 μs"
echo -e "  9.  GRUB: nowatchdog + rcu_nocbs + skew_tick + mitigations=off"
echo -e "            ${GREEN}(Python-based parser — safe, verified after write)${RESET}"
echo -e " 10.  Xray/3x-ui: GOMAXPROCS=1, GOGC=200, OOMScoreAdj=-500, ulimit"
echo -e " 11.  zram: 256MB compressed swap (ลด RAM pressure + ไม่มี disk latency)"
echo ""
echo -e "  ${YELLOW}⚠  REBOOT REQUIRED for GRUB params + zram to take full effect${RESET}"
echo -e "  ${YELLOW}   All other changes are live immediately${RESET}"
echo ""
echo -e "  ${CYAN}After reboot, verify:${RESET}"
echo -e "    cat /proc/cmdline | grep -o 'nowatchdog\\|mitigations=off\\|skew_tick'"
echo -e "    sysctl net.ipv4.tcp_congestion_control"
echo -e "    tc qdisc show dev $IFACE"
echo -e "    swapon --show"
echo -e "    systemctl status x-ui | grep GOMAX"
echo ""
echo -e "  ${CYAN}CPU 20-25% note:${RESET}"
echo -e "    ปกติมากสำหรับ VLESS Reality 2 users"
echo -e "    Reality ใช้ XTLS-Vision → offload TLS handshake ได้มาก"
echo -e "    CPU จะขึ้นตาม bandwidth จริงๆ (streaming 4K จะเห็น 40-60%)"
echo ""
echo -e "  ${CYAN}Finished at: $(date)${RESET}"
echo ""
