#!/bin/bash
set -e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'

ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1"; }
inf() { echo -e "${Y}[INFO]${N} $1"; }
sec() { echo -e "\n${B}${C}╔══════════════════════════════════════════╗${N}"
        echo -e "${B}${C}║  $1${N}"
        echo -e "${B}${C}╚══════════════════════════════════════════╝${N}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
PUBIP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo -e "\n${B}${C}  VPS Setup — VMESS WS | MULTI-USER | 1Gbps/conn | LOW PING + LOW JITTER${N}"
echo -e "  Interface: ${Y}$ETH${N} | IP: ${Y}$PUBIP${N}\n"
echo -e "  Target: 1Gbps max/conn | RTT 20ms | MTU VPN 1500 | ping low | jitter low\n"

sec "STEP 1 — SWAP 512MB"

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
    ufw reload >/dev/null 2>&1
    ok "UFW reloaded"
else
    ok "UFW inactive — skipped"
fi

for p in "${PORTS[@]}"; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    ok "iptables: $p ACCEPT"
done

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save >/dev/null 2>&1
    ok "iptables saved via netfilter-persistent"
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "iptables saved to /etc/iptables/rules.v4"
fi

sec "STEP 3 — INSTALL 3x-ui (Official)"

if systemctl is-active --quiet x-ui 2>/dev/null; then
    ok "3x-ui already running — skipping install"
else
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    ok "3x-ui installed"
fi

sec "STEP 4 — SYSTEM LIMITS (multi-user)"

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
ok "limits.d: nofile=1000000"

mkdir -p /etc/systemd/system/x-ui.service.d/
cat > /etc/systemd/system/x-ui.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=1000000
LimitNPROC=1000000
EOF
ok "x-ui service limits set"

echo 1000000 > /proc/sys/fs/file-max
ok "fs.file-max=1000000 (live)"

sec "STEP 5 — SYSCTL (1Gbps/conn × multi-user | RTT 20ms | low ping | low jitter)"

modprobe tcp_bbr 2>/dev/null && ok "tcp_bbr loaded" || inf "tcp_bbr built-in"

cat > /etc/sysctl.d/99-ais-vmess.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = 131072
net.core.rmem_max = 67108864
net.core.wmem_default = 131072
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 131072 67108864
net.core.optmem_max = 65536
net.ipv4.tcp_mem = 65536 1048576 536870912
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_limit_output_bytes = 131072

net.ipv4.tcp_keepalive_time = 10
net.ipv4.tcp_keepalive_intvl = 3
net.ipv4.tcp_keepalive_probes = 4

net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 32768
net.core.netdev_budget = 300
net.core.netdev_budget_usecs = 4000

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

fs.file-max = 1000000
fs.nr_open = 1000000

vm.swappiness = 5
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
EOF

sysctl --system 2>&1 | grep -E "bbr|fastopen|keepalive|rmem|wmem|somaxconn|autocorking|slow_start|notsent|mtu_prob|forward|swappiness|output_bytes" | \
    while IFS= read -r line; do ok "sysctl: $line"; done
ok "sysctl applied"

sec "STEP 6 — ETHTOOL OFFLOAD"

if ! command -v ethtool &>/dev/null; then
    apt-get install -y ethtool >/dev/null 2>&1
fi

if command -v ethtool &>/dev/null; then
    ethtool -K "$ETH" gro off 2>/dev/null && ok "ethtool: gro off" || inf "ethtool: gro skipped"
    ethtool -K "$ETH" lro off 2>/dev/null && ok "ethtool: lro off" || inf "ethtool: lro skipped"
    ethtool -K "$ETH" tso on  2>/dev/null && ok "ethtool: tso on"  || inf "ethtool: tso skipped"
    ethtool -K "$ETH" gso on  2>/dev/null && ok "ethtool: gso on"  || inf "ethtool: gso skipped"
    ethtool -K "$ETH" tx-checksum-ip-generic on 2>/dev/null && ok "ethtool: tx-checksum on" || true
else
    inf "ethtool not available -- skipped"
fi

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > /etc/networkd-dispatcher/routable.d/51-ethtool << 'ETEOF'
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
ethtool -K $ETH gro off 2>/dev/null || true
ethtool -K $ETH lro off 2>/dev/null || true
ethtool -K $ETH tso on  2>/dev/null || true
ethtool -K $ETH gso on  2>/dev/null || true
ETEOF
chmod +x /etc/networkd-dispatcher/routable.d/51-ethtool
ok "ethtool persistence written"

sec "STEP 7 — CAKE QDISC (RTT=25ms, 1Gbps, fair per-flow)"

ip link set dev "$ETH" txqueuelen 4096 2>/dev/null && \
    ok "txqueuelen -> 4096" || inf "txqueuelen skipped"

modprobe sch_cake 2>/dev/null && ok "sch_cake loaded" || inf "sch_cake unavailable"

tc qdisc del dev "$ETH" root 2>/dev/null || true
ok "old qdisc cleared"

if lsmod | grep -q sch_cake; then
    tc qdisc add dev "$ETH" root cake bandwidth 1gbit rtt 25ms besteffort split-gso 2>/dev/null && \
        ok "CAKE applied: 1gbit rtt 25ms besteffort split-gso" || {
        tc qdisc add dev "$ETH" root cake bandwidth 1gbit rtt 25ms besteffort 2>/dev/null && \
            ok "CAKE applied: 1gbit rtt 25ms besteffort" || {
            tc qdisc add dev "$ETH" root fq_codel target 2ms interval 25ms 2>/dev/null && \
                ok "fq_codel fallback applied" || err "qdisc failed"
        }
    }
else
    tc qdisc add dev "$ETH" root fq_codel target 2ms interval 25ms 2>/dev/null && \
        ok "fq_codel applied" || err "qdisc failed"
fi

tc qdisc show dev "$ETH" | while IFS= read -r line; do inf "qdisc: $line"; done

mkdir -p /etc/networkd-dispatcher/routable.d/
cat > /etc/networkd-dispatcher/routable.d/50-cake << 'BOOTEOF'
ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
ip link set dev $ETH txqueuelen 4096 2>/dev/null || true
tc qdisc del dev $ETH root 2>/dev/null || true
modprobe sch_cake 2>/dev/null
if lsmod | grep -q sch_cake; then
    tc qdisc add dev $ETH root cake bandwidth 1gbit rtt 25ms besteffort split-gso 2>/dev/null || \
    tc qdisc add dev $ETH root cake bandwidth 1gbit rtt 25ms besteffort 2>/dev/null || \
    tc qdisc add dev $ETH root fq_codel target 2ms interval 25ms 2>/dev/null
else
    tc qdisc add dev $ETH root fq_codel target 2ms interval 25ms 2>/dev/null
fi
BOOTEOF
chmod +x /etc/networkd-dispatcher/routable.d/50-cake
ok "CAKE boot persistence written"

sec "STEP 8 — VMESS WS SOCKOPT PATCHER (MTU 1500 | None-TLS)"

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
    "tcpKeepAliveIdle":     10,
    "tcpKeepAliveInterval": 3,
    "tcpFastOpen":          True,
    "tcpUserTimeout":       5000,
    "tcpMaxSeg":            1460,
    "mark":                 0,
}

def patch(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except json.JSONDecodeError as e:
        print(f"  [{path}] JSON parse error: {e} — skipping")
        return 0
    except OSError as e:
        print(f"  [{path}] read error: {e} — skipping")
        return 0
    inbounds = cfg.get("inbounds") or []
    if not inbounds:
        print(f"  [{path}] no inbounds yet — will patch after inbound is added")
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
    print(f"  [{path}] patched {changed} fields across {len(inbounds)} inbound(s)")
    return changed

patched = 0
for p in PATHS:
    if os.path.exists(p):
        patched = patch(p)
        sys.exit(0 if patched >= 0 else 1)

print("  no xray config found — patcher will run automatically on every x-ui start")
sys.exit(0)
PYEOF
chmod +x "$PATCHER"
ok "xui-ws-patch.py created"

mkdir -p /etc/systemd/system/x-ui.service.d/
cat > /etc/systemd/system/x-ui.service.d/ws-patch.conf << 'UNITEOF'
[Service]
ExecStartPost=/bin/bash -c 'for i in $(seq 15); do sleep 2 && python3 /usr/local/bin/xui-ws-patch.py && break; done'
UNITEOF
ok "sockopt auto-patcher hooked to x-ui (runs on every start)"

inf "running ws-patch now..."
python3 "$PATCHER"

sec "STEP 9 — CPU / IRQ TUNING"

ETH_IRQ=$(grep "$ETH" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1)
if [[ -n "$ETH_IRQ" ]]; then
    echo 1 > /proc/irq/$ETH_IRQ/smp_affinity 2>/dev/null && \
        ok "IRQ $ETH_IRQ pinned to CPU0" || inf "IRQ affinity skipped"
else
    inf "No dedicated NIC IRQ (virtio/KVM — normal)"
fi

if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | head -1 | grep -q governor; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$f" 2>/dev/null
    done
    ok "CPU governor: performance"
else
    inf "cpufreq not exposed (host controls — normal for KVM)"
fi

sec "STEP 10 — RELOAD & RESTART"

systemctl daemon-reload
ok "systemd daemon reloaded"

if systemctl is-active --quiet x-ui 2>/dev/null; then
    systemctl restart x-ui
    sleep 3
    ok "x-ui restarted"
else
    systemctl start x-ui 2>/dev/null && ok "x-ui started" || err "x-ui start failed — check: journalctl -u x-ui"
fi

sec "FINAL — VERIFY"

echo ""
inf "── Active Ports ──"
ss -tlnp | grep -E ":(80|443|2053|2083|2087|2096|8080|8443|54321) " | \
    while IFS= read -r line; do ok "$line"; done || \
    inf "no panel ports up yet (normal if installer changed port — check x-ui settings)"

inf "── Kernel ──"
ok "cc             = $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
ok "fastopen       = $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
ok "keepalive_time = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)s"
ok "rmem_max       = $(sysctl -n net.core.rmem_max 2>/dev/null)"
ok "wmem_max       = $(sysctl -n net.core.wmem_max 2>/dev/null)"
ok "notsent_lowat  = $(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
ok "output_bytes   = $(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null)"
ok "somaxconn      = $(sysctl -n net.core.somaxconn 2>/dev/null)"
ok "mtu_probing    = $(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
ok "ecn            = $(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)"
ok "nofile         = soft:$(ulimit -Sn) hard:$(ulimit -Hn)"
inf "note: nofile 1000000 มีผลหลัง reboot"

inf "── qdisc ──"
tc qdisc show dev "$ETH" | while IFS= read -r line; do ok "$line"; done

inf "── x-ui ──"
ok "status: $(systemctl is-active x-ui 2>/dev/null)"

PANEL_PORT=$(x-ui settings 2>/dev/null | grep -i "port" | grep -oE '[0-9]{2,5}' | head -1)
PANEL_PORT=${PANEL_PORT:-54321}

echo ""
echo -e "${G}${B}╔══════════════════════════════════════════╗${N}"
echo -e "${G}${B}║  DONE — Multi-User Setup complete!       ║${N}"
echo -e "${G}${B}╚══════════════════════════════════════════╝${N}"
echo ""
echo -e "${Y}  ▸ 3x-ui panel    : https://YOUR_DOMAIN:${PANEL_PORT}/YOUR_PATH${N}"
echo -e "${Y}                     http://${PUBIP}:${PANEL_PORT}  (fallback)${N}"
echo -e "${Y}  ▸ inbound         : VMESS | WS | port 80 | security: none${N}"
echo -e "${Y}  ▸ TCP Max Seg     : 1460 (None-TLS optimized — MTU VPN 1500)${N}"
echo -e "${Y}  ▸ MTU VPN V2BOX   : 1500 (locked — tcpMaxSeg 1460 compensates)${N}"
echo -e "${Y}  ▸ max speed/conn  : 1Gbps${N}"
echo -e "${Y}  ▸ CAKE            : 1gbit fair queue ทุก flow${N}"
echo -e "${Y}  ▸ RAM kernel buf  : default 128KB/conn, max 64MB/conn${N}"
echo -e "${Y}  ▸ output_bytes    : 131072 (4×MSS burst สำหรับ 1460 MSS)${N}"
echo -e "${Y}  ▸ sockopt patcher : runs auto on every x-ui start${N}"
echo -e "${Y}  ▸ Firewall Rules  : เปิดพอร์ตใน ReadyIDC panel ด้วย${N}"
echo -e "${Y}  ▸ reboot          : sudo reboot${N}"
echo -e "${Y}  ▸ nofile 1000000  : มีผลหลัง reboot${N}"
echo ""
