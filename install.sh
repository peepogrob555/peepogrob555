#!/bin/bash
set -e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'

ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1"; exit 1; }
inf() { echo -e "${Y}[INFO]${N} $1"; }
sec() { echo -e "\n${B}${C}╔══════════════════════════════════════════╗${N}"
        echo -e "${B}${C}║  $1${N}"
        echo -e "${B}${C}╚══════════════════════════════════════════╝${N}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
PUBIP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "\n${B}${C}  VPS Setup — VMESS WS | 2-USER | 500Mbps | RTT 25ms | 1vCPU 2GB${N}"
echo -e "  Interface : ${Y}$ETH${N} | IP: ${Y}$PUBIP${N}"
echo -e "  Hardware  : ${Y}1 vCPU (2.69GHz)${N} | ${Y}2GB RAM${N}"
echo -e "  Target    : 500Mbps gross → 425Mbps net after 15% VMESS WS overhead | RTT 25ms | MSS 1360 MTU 1400\n"

sec "STEP 1 — SWAP"

if swapon --show | grep -q /swapfile; then
    ok "Swap already exists"
else
    fallocate -l 512M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap 512MB created"
fi

sec "STEP 2 — OPEN PORTS"

PORTS=(80 443 2053 2083 2087 2096 8080 8443 54321)
if ufw status | grep -q "Status: active"; then
    for p in "${PORTS[@]}"; do
        ufw allow "$p"/tcp comment "3xui" >/dev/null 2>&1
        ok "UFW: $p/tcp"
    done
    ufw reload >/dev/null 2>&1 && ok "UFW reloaded"
else
    ok "UFW inactive — skipped"
fi
for p in "${PORTS[@]}"; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    ok "iptables: $p ACCEPT"
done
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1 && ok "iptables saved"
else
    mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 && ok "iptables saved"
fi

sec "STEP 3 — INSTALL 3x-ui"

if systemctl is-active --quiet x-ui 2>/dev/null; then
    ok "3x-ui already running — skipping install"
else
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    ok "3x-ui installed"
fi

sec "STEP 4 — SYSTEM LIMITS"

cat > /etc/security/limits.d/99-xui.conf << 'EOF'
*    soft nofile 1000000
*    hard nofile 1000000
*    soft nproc  1000000
*    hard nproc  1000000
root soft nofile 1000000
root hard nofile 1000000
root soft nproc  1000000
root hard nproc  1000000
EOF
ok "nofile=1000000 nproc=1000000"

mkdir -p /etc/systemd/system/x-ui.service.d/
cat > /etc/systemd/system/x-ui.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=1000000
LimitNPROC=1000000
EOF
echo 1000000 > /proc/sys/fs/file-max
ok "x-ui service limits set"

sec "STEP 5 — SYSCTL (1vCPU 2GB | BDP=6553600 | RTT=25ms | 500Mbps | MSS=1360)"

modprobe tcp_bbr 2>/dev/null && ok "tcp_bbr loaded" || inf "tcp_bbr built-in"

cat > /etc/sysctl.d/99-ais-vmess.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_default = 262144
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 262144 67108864
net.ipv4.tcp_wmem = 4096 262144 67108864
net.core.optmem_max = 65536
net.ipv4.tcp_mem = 65536 1048576 268435456
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_limit_output_bytes = 655360

net.ipv4.tcp_keepalive_time = 8
net.ipv4.tcp_keepalive_intvl = 2
net.ipv4.tcp_keepalive_probes = 4

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 400
net.core.netdev_budget_usecs = 3000

net.core.busy_poll = 0
net.core.busy_read = 0

net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_recovery = 1
net.ipv4.tcp_retries2 = 5
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_max_orphans = 65535
net.ipv4.tcp_ecn = 1

net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_timestamps = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

kernel.sched_min_granularity_ns = 3000000
kernel.sched_wakeup_granularity_ns = 4000000
kernel.sched_migration_cost_ns = 5000000
kernel.sched_autogroup_enabled = 0
kernel.nmi_watchdog = 0

vm.transparent_hugepage = madvise
fs.file-max = 1000000
fs.nr_open = 1000000
vm.swappiness = 5
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
EOF

sysctl --system 2>&1 | grep -E "bbr|fastopen|keepalive|rmem|wmem|somaxconn|autocorking|slow_start|notsent|mtu_prob|forward|swappiness|output_bytes|sched|hugepage" | \
    while IFS= read -r line; do ok "sysctl: $line"; done
ok "sysctl applied"

echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && \
    ok "hugepage=madvise (live)" || true
echo 0 > /proc/sys/kernel/nmi_watchdog 2>/dev/null && \
    ok "nmi_watchdog=0 (live)" || true

sec "STEP 6 — ETHTOOL OFFLOAD"

if ! command -v ethtool &>/dev/null; then
    apt-get install -y ethtool >/dev/null 2>&1
fi
if command -v ethtool &>/dev/null; then
    ethtool -K "$ETH" gro off 2>/dev/null && ok "gro off" || inf "gro skipped"
    ethtool -K "$ETH" lro off 2>/dev/null && ok "lro off" || inf "lro skipped"
    ethtool -K "$ETH" tso on  2>/dev/null && ok "tso on"  || inf "tso skipped"
    ethtool -K "$ETH" gso on  2>/dev/null && ok "gso on"  || inf "gso skipped"
    ethtool -C "$ETH" rx-usecs 50 rx-frames 32 tx-usecs 50 tx-frames 32 2>/dev/null && \
        ok "coalescing: 50us/32frames" || inf "coalescing skipped"
else
    inf "ethtool not available"
fi

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > /etc/networkd-dispatcher/routable.d/51-ethtool << 'ETEOF'
#!/bin/bash
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
ethtool -K $ETH gro off 2>/dev/null || true
ethtool -K $ETH lro off 2>/dev/null || true
ethtool -K $ETH tso on  2>/dev/null || true
ethtool -K $ETH gso on  2>/dev/null || true
ethtool -C $ETH rx-usecs 50 rx-frames 32 tx-usecs 50 tx-frames 32 2>/dev/null || true
ETEOF
chmod +x /etc/networkd-dispatcher/routable.d/51-ethtool
ok "ethtool persistence written"

sec "STEP 7 — CAKE QDISC (RTT=25ms, 500Mbps) + PERSISTENCE"

ip link set dev "$ETH" txqueuelen 4096 2>/dev/null && ok "txqueuelen=4096" || inf "txqueuelen skipped"
modprobe sch_cake 2>/dev/null && ok "sch_cake loaded" || inf "sch_cake unavailable"
tc qdisc del dev "$ETH" root 2>/dev/null || true
ok "old qdisc cleared"

if lsmod | grep -q sch_cake; then
    tc qdisc add dev "$ETH" root cake bandwidth 500mbit rtt 25ms besteffort split-gso 2>/dev/null && \
        ok "CAKE: 500mbit rtt 25ms besteffort split-gso" || \
    { tc qdisc add dev "$ETH" root cake bandwidth 500mbit rtt 25ms besteffort 2>/dev/null && \
        ok "CAKE: 500mbit rtt 25ms besteffort"; } || \
    { tc qdisc add dev "$ETH" root fq_codel target 1ms interval 25ms 2>/dev/null && \
        ok "fq_codel fallback"; }
else
    tc qdisc add dev "$ETH" root fq_codel target 1ms interval 25ms 2>/dev/null && ok "fq_codel fallback"
fi

tc qdisc show dev "$ETH" | while IFS= read -r line; do inf "qdisc: $line"; done

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > /etc/networkd-dispatcher/routable.d/50-cake << 'BOOTEOF'
#!/bin/bash
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
ip link set dev $ETH txqueuelen 4096 2>/dev/null || true
tc qdisc del dev $ETH root 2>/dev/null || true
modprobe sch_cake 2>/dev/null
if lsmod | grep -q sch_cake; then
    tc qdisc add dev $ETH root cake bandwidth 500mbit rtt 25ms besteffort split-gso 2>/dev/null || \
    tc qdisc add dev $ETH root cake bandwidth 500mbit rtt 25ms besteffort 2>/dev/null || \
    tc qdisc add dev $ETH root fq_codel target 1ms interval 25ms 2>/dev/null
else
    tc qdisc add dev $ETH root fq_codel target 1ms interval 25ms 2>/dev/null
fi
BOOTEOF
chmod +x /etc/networkd-dispatcher/routable.d/50-cake
ok "CAKE networkd-dispatcher persistence written"

RC_LOCAL=/etc/rc.local
if [[ ! -f "$RC_LOCAL" ]]; then
    printf '#!/bin/bash\nexit 0\n' > "$RC_LOCAL"
    chmod +x "$RC_LOCAL"
fi
if ! grep -q "50-cake" "$RC_LOCAL" 2>/dev/null; then
    sed -i '/^exit 0/i bash /etc/networkd-dispatcher/routable.d/50-cake' "$RC_LOCAL"
    ok "rc.local fallback written"
else
    ok "rc.local already has cake entry"
fi

cat > /etc/systemd/system/cake-qdisc.service << 'EOF'
[Unit]
Description=CAKE qdisc 500mbit rtt 25ms for VMESS WS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/networkd-dispatcher/routable.d/50-cake
ExecStartPost=/bin/sh -c 'tc qdisc show dev $(ip -o -4 route show to default | awk "{print $5}" | head -1)'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cake-qdisc.service >/dev/null 2>&1 && ok "cake-qdisc.service enabled"

mkdir -p /etc/network/if-up.d/
cat > /etc/network/if-up.d/cake << 'IFEOF'
#!/bin/bash
[ "$IFACE" = "lo" ] && exit 0
bash /etc/networkd-dispatcher/routable.d/50-cake
IFEOF
chmod +x /etc/network/if-up.d/cake
ok "if-up.d/cake written"

sec "STEP 8 — VMESS WS SOCKOPT PATCHER"

PATCHER=/usr/local/bin/xui-ws-patch.py
cat > "$PATCHER" << 'PYEOF'
import json, sys, os

PATHS = [
    "/usr/local/x-ui/bin/config.json",
    "/etc/x-ui/config.json",
    "/root/x-ui/bin/config.json",
]
SOCKOPT = {
    "tcpNoDelay":           True,
    "tcpKeepAliveIdle":     8,
    "tcpKeepAliveInterval": 2,
    "tcpFastOpen":          True,
    "tcpUserTimeout":       6000,
    "tcpMaxSeg":            1360,
    "mark":                 0,
}

def patch(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"  [{path}] error: {e} — skipping")
        return 0
    inbounds = cfg.get("inbounds") or []
    if not inbounds:
        print(f"  [{path}] no inbounds yet")
        return 0
    changed = 0
    for ib in inbounds:
        if not isinstance(ib, dict):
            continue
        ss = ib.setdefault("streamSettings", {})
        if not isinstance(ss, dict):
            ib["streamSettings"] = {}
            ss = ib["streamSettings"]
        so = ss.setdefault("sockopt", {})
        for k, v in SOCKOPT.items():
            if so.get(k) != v:
                so[k] = v
                changed += 1
    try:
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
    except OSError as e:
        print(f"  [{path}] write error: {e}")
        return 0
    print(f"  [{path}] patched {changed} fields / {len(inbounds)} inbound(s)")
    return changed

for p in PATHS:
    if os.path.exists(p):
        patch(p)
        sys.exit(0)
print("  no xray config found — will patch on next x-ui start")
PYEOF
chmod +x "$PATCHER"
ok "xui-ws-patch.py created"

mkdir -p /etc/systemd/system/x-ui.service.d/
cat > /etc/systemd/system/x-ui.service.d/ws-patch.conf << 'UNITEOF'
[Service]
Environment=GOMAXPROCS=1
ExecStartPost=/bin/bash -c 'for i in $(seq 15); do sleep 2 && python3 /usr/local/bin/xui-ws-patch.py && break; done'
ExecStartPost=/bin/bash -c 'sleep 6 && XP=$(pgrep -x xray | head -1) && [ -n "$XP" ] && taskset -cp 0 $XP && ionice -c 1 -n 0 -p $XP || true'
UNITEOF

ok "GOMAXPROCS=1 | taskset CPU: 0"
inf "running ws-patch now..."
python3 "$PATCHER"

sec "STEP 9 — CPU / IRQ TUNING"

ETH_IRQ=$(grep "$ETH" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1)
if [[ -n "$ETH_IRQ" ]]; then
    echo 1 > /proc/irq/$ETH_IRQ/smp_affinity 2>/dev/null && ok "IRQ $ETH_IRQ → CPU0" || inf "IRQ skipped"
else
    inf "No dedicated NIC IRQ (virtio/KVM — normal)"
fi

if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | head -1 | grep -q governor; then
    echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
    ok "CPU governor: performance"
else
    inf "cpufreq not exposed (host controls — normal)"
fi

sec "STEP 10 — RELOAD & RESTART"

systemctl daemon-reload && ok "daemon reloaded"

if systemctl is-active --quiet x-ui 2>/dev/null; then
    systemctl restart x-ui
    sleep 4
    ok "x-ui restarted"
else
    systemctl start x-ui 2>/dev/null && ok "x-ui started" || err "x-ui failed — journalctl -u x-ui"
fi

sleep 2
XRAY_PID=$(pgrep -x xray 2>/dev/null | head -1)
if [[ -n "$XRAY_PID" ]]; then
    taskset -cp 0 "$XRAY_PID" 2>/dev/null && ok "taskset: xray pid=$XRAY_PID → CPU0" || inf "taskset skipped"
    ionice -c 1 -n 0 -p "$XRAY_PID" 2>/dev/null && ok "ionice: xray realtime" || inf "ionice skipped"
else
    inf "xray pid not found yet"
fi

sec "FINAL — VERIFY"

echo ""
inf "── Hardware Profile ──"
ok "vCPU        = 1 (2.69GHz)"
ok "RAM         = 2GB"
ok "GOMAXPROCS  = 1"
ok "taskset CPU = 0"

inf "── Active Ports ──"
ss -tlnp | grep -E ":(80|443|2053|2083|2087|2096|8080|8443|54321) " | \
    while IFS= read -r line; do ok "$line"; done || \
    inf "no panel ports yet — check x-ui settings"

inf "── Kernel ──"
ok "cc            = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
ok "fastopen      = $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
ok "keepalive     = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)s"
ok "rmem_max      = $(sysctl -n net.core.rmem_max 2>/dev/null)"
ok "wmem_max      = $(sysctl -n net.core.wmem_max 2>/dev/null)"
ok "output_bytes  = $(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)"
ok "somaxconn     = $(sysctl -n net.core.somaxconn 2>/dev/null)"
ok "netdev_budget = $(sysctl -n net.core.netdev_budget 2>/dev/null)"
ok "nofile        = soft:$(ulimit -Sn) hard:$(ulimit -Hn)"
inf "note: nofile มีผลเต็มหลัง reboot"

inf "── qdisc ──"
tc qdisc show dev "$ETH" | while IFS= read -r line; do ok "$line"; done

inf "── cake-qdisc.service ──"
ok "enabled: $(systemctl is-enabled cake-qdisc.service 2>/dev/null)"

inf "── x-ui ──"
ok "status: $(systemctl is-active x-ui 2>/dev/null)"

PANEL_PORT=$(x-ui settings 2>/dev/null | grep -i "port" | grep -oE '[0-9]{2,5}' | head -1)
PANEL_PORT=${PANEL_PORT:-54321}

echo ""
echo -e "${G}${B}╔══════════════════════════════════════════╗${N}"
echo -e "${G}${B}║                      DONE               ║${N}"
echo -e "${G}${B}╚══════════════════════════════════════════╝${N}"
echo ""
echo -e "${Y}  ▸ Hardware      : 1vCPU 2.69GHz | 2GB RAM${N}"
echo -e "${Y}  ▸ GOMAXPROCS    : 1${N}"
echo -e "${Y}  ▸ xray CPU mask : 0${N}"
echo -e "${Y}  ▸ panel         : http://${PUBIP}:${PANEL_PORT}${N}"
echo -e "${Y}  ▸ inbound       : VMESS | WS | port 80 | security: none${N}"
echo -e "${Y}  ▸ MSS/MTU       : 1360${N}"
echo -e "${Y}  ▸ CAKE          : 500mbit rtt 25ms besteffort${N}"
echo -e "${Y}  ▸ BDP           : 6553600 bytes (500Mbps × 25ms / 8 × 4)${N}"
echo -e "${Y}  ▸ output_bytes  : 655360 (500Mbps/8 × 10ms)${N}"
echo -e "${Y}  ▸ hugepage      : madvise${N}"
echo -e "${Y}  ▸ scheduler     : 3ms granularity${N}"
echo -e "${Y}  ▸ CAKE persist  : systemd + networkd-dispatcher + rc.local + if-up.d${N}"
echo -e "${Y}  ▸ Firewall      : เปิดพอร์ตใน ReadyIDC panel ด้วย${N}"
echo -e "${Y}  ▸ reboot        : sudo reboot${N}"
echo -e "${Y}  ▸ nofile        : มีผลเต็มหลัง reboot${N}"
echo ""
