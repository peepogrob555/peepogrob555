#!/bin/bash
set -e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1"; }
sec() { echo -e "\n${B}${C}══════ $1 ══════${N}"; }
run() { echo -e "${C}  >>> $1${N}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

# ══════ PORTS ══════
sec "OPEN PORTS"

PORTS=(80 443 2053 2083 2087 2096 8080 8443 54321)

run "Checking UFW..."
if ufw status | grep -q "Status: active"; then
    for p in "${PORTS[@]}"; do
        run "ufw allow $p/tcp"
        ufw allow "$p"/tcp comment "3xui-vmess"
        ok "UFW: $p/tcp open"
    done
    run "ufw reload"
    ufw reload
    ok "UFW reloaded"
else
    ok "UFW inactive — skipped"
fi

run "Checking nftables..."
if nft list ruleset 2>/dev/null | grep -q "chain input"; then
    for p in "${PORTS[@]}"; do
        run "nft add rule inet filter input tcp dport $p accept"
        if ! nft list ruleset | grep -q "tcp dport $p accept"; then
            nft add rule inet filter input tcp dport "$p" accept 2>/dev/null || true
            ok "nftables: $p accepted"
        else
            ok "nftables: $p already open"
        fi
    done
else
    ok "nftables: no input chain — skipped"
fi

run "Applying iptables rules..."
for p in "${PORTS[@]}"; do
    run "iptables -I INPUT -p tcp --dport $p -j ACCEPT"
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    ok "iptables: $p ACCEPT"
done

run "Saving iptables..."
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    ok "iptables saved via netfilter-persistent"
elif command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ok "iptables saved to /etc/iptables/rules.v4"
fi

# ══════ INSTALL 3x-ui ══════
sec "INSTALL 3x-ui"
if systemctl is-active --quiet x-ui 2>/dev/null; then
    ok "3x-ui already running — skipping install"
else
    run "Downloading 3x-ui installer..."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    ok "3x-ui installed"
fi

# ══════ SYSTEM LIMITS ══════
sec "SYSTEM LIMITS"

run "Writing /etc/security/limits.d/99-xui-lte.conf"
cat > /etc/security/limits.d/99-xui-lte.conf << 'EOF'
*         soft    nofile    65535
*         hard    nofile    65535
root      soft    nofile    65535
root      hard    nofile    65535
EOF
ok "nofile: 65535"

run "Writing systemd override for x-ui..."
mkdir -p /etc/systemd/system/x-ui.service.d/
cat > /etc/systemd/system/x-ui.service.d/limits.conf << 'EOF'
[Service]
LimitNOFILE=65535
EOF
run "systemctl daemon-reload"
systemctl daemon-reload
ok "x-ui LimitNOFILE=65535"

run "Writing /proc/sys/fs/file-max"
echo 1000000 > /proc/sys/fs/file-max
ok "fs.file-max = 1000000 (live)"

# ══════ SYSCTL / KERNEL TUNING ══════
sec "SYSCTL KERNEL TUNING"

run "Writing /etc/sysctl.d/99-lte-vmess.conf"
cat > /etc/sysctl.d/99-lte-vmess.conf << 'EOF'
# ── Congestion control ──────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── TCP Memory / Buffer ─────────────────────────────────────
# BDP = 400Mbps * 0.040s RTT / 8 = 2MB → max 8MB (4x BDP)
net.core.rmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_default = 262144
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 262144 8388608
net.ipv4.tcp_wmem = 4096 262144 8388608
# optmem_max: ancillary buffer (WS, cmsg headers)
net.core.optmem_max = 65536
# tcp_mem: min/pressure/max in pages (4KB each)
# min=64MB  pressure=256MB  max=512MB — ใช้ RAM 2GB ได้คุ้มขึ้น
net.ipv4.tcp_mem = 16384 65536 131072
# tcp_adv_win_scale=2 → app ได้ 75% ของ rmem แทน 50%
net.ipv4.tcp_adv_win_scale = 2
# moderate_rcvbuf: auto-tune recv buffer ตาม RTT/bandwidth จริง
net.ipv4.tcp_moderate_rcvbuf = 1
# window_scaling: รองรับ window > 64KB (จำเป็นที่ 400Mbps)
net.ipv4.tcp_window_scaling = 1

# ── Latency & Interactive (VMESS WS) ───────────────────────
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
# autocorking=0: ไม่รวม packet ไว้ก่อนส่ง → latency ต่ำกว่า (สำคัญ WS)
net.ipv4.tcp_autocorking = 0
# slow_start_after_idle=0: ไม่ reset cwnd หลัง idle → reconnect เร็ว
net.ipv4.tcp_slow_start_after_idle = 0
# notsent_lowat: epoll EPOLLOUT fire เมื่อ send buffer < 16KB
# ทำให้ xray write path ไม่ block รอ → jitter ลด
net.ipv4.tcp_notsent_lowat = 16384
# mtu_probing=1: probe MTU อัตโนมัติ รับมือ LTE path MTU ที่ไม่แน่นอน
net.ipv4.tcp_mtu_probing = 1

# ── ACK ────────────────────────────────────────────────────
net.ipv4.tcp_delack_min = 0

# ── Keepalive — LTE NAT ────────────────────────────────────
net.ipv4.tcp_keepalive_time = 20
net.ipv4.tcp_keepalive_intvl = 5
net.ipv4.tcp_keepalive_probes = 6

# ── RTT Estimation ─────────────────────────────────────────
# tcp_min_rtt_wlen: window ที่ kernel ใช้วัด min RTT → ค่า 300 เหมาะกับ
# connection ที่มีอายุยาว (VMESS WS persistent)
net.ipv4.tcp_min_rtt_wlen = 300

# ── Connection queue ───────────────────────────────────────
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
# netdev_budget: packets per NAPI poll — เพิ่มเพื่อรองรับ burst
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000

# ── LTE Packet Loss Recovery ───────────────────────────────
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_recovery = 1
net.ipv4.tcp_retries2 = 6
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_max_orphans = 8192

# ── Port Range ─────────────────────────────────────────────
# ขยาย ephemeral ports สำหรับ outbound connections ของ xray
net.ipv4.ip_local_port_range = 1024 65535

# ── Scheduling Jitter ──────────────────────────────────────
net.core.busy_poll = 50
net.core.busy_read = 50
net.ipv4.tcp_timestamps = 1

# ── Routing ────────────────────────────────────────────────
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# ── File Descriptors ───────────────────────────────────────
fs.file-max = 1000000
fs.nr_open = 1000000

# ── VM / Swap ──────────────────────────────────────────────
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

run "sysctl --system (applying all sysctl.d)"
sysctl --system 2>&1 | grep -E "(bbr|fastopen|keepalive|rmem|wmem|somaxconn|busy|rp_filter|forward|swappiness|autocorking|slow_start|notsent|mtu_prob|adv_win|budget|port_range|orphan|tcp_mem)" | while IFS= read -r line; do
    ok "sysctl: $line"
done

# ══════ CAKE QDISC — RTT=40ms ══════
sec "CAKE QDISC  [RTT=40ms, 400mbit]"

ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
echo -e "${C}  interface: $ETH${N}"

# txqueuelen — เพิ่ม queue depth สำหรับ 400Mbps link
# default=1000 → ที่ 400Mbps burst ทำให้ drop, เพิ่มเป็น 10000
run "ip link set dev $ETH txqueuelen 10000"
ip link set dev "$ETH" txqueuelen 10000 2>/dev/null && ok "txqueuelen → 10000" || ok "txqueuelen skipped (KVM may ignore)"

run "modprobe sch_cake"
if modprobe sch_cake 2>/dev/null; then
    ok "sch_cake loaded"
else
    err "sch_cake unavailable — falling back to fq_codel"
fi

run "tc qdisc del dev $ETH root (clean slate)"
tc qdisc del dev "$ETH" root 2>/dev/null || true
ok "old qdisc removed"

# CAKE flags สำหรับ 2 users, server-side:
# besteffort     → ไม่แบ่ง tin (ลด overhead, ดีพอสำหรับ 2 users)
# no-triple-isolate → ปิด per-host isolation (ไม่จำเป็น มี 2 users เท่านั้น)
# split-gso      → แบ่ง GSO segments ก่อน queue → jitter ลด (default ON แต่ระบุชัดเจน)
# nat            → ถ้าทำ NAT ให้ CAKE มองเห็น internal IP ได้ถูกต้อง
# wash           → ล้าง DSCP markings จาก upstream ก่อน queue
CAKE_OPTS="bandwidth 400mbit rtt 40ms besteffort no-triple-isolate split-gso nat wash"

if lsmod | grep -q sch_cake; then
    run "tc qdisc add dev $ETH root cake $CAKE_OPTS"
    if tc qdisc add dev "$ETH" root cake $CAKE_OPTS 2>/dev/null; then
        ok "CAKE set: $CAKE_OPTS"
    else
        # ลอง minimal flags ถ้า flag บางตัวไม่รองรับ (kernel เก่า)
        run "CAKE minimal fallback: bandwidth 400mbit rtt 40ms besteffort"
        tc qdisc add dev "$ETH" root cake bandwidth 400mbit rtt 40ms besteffort 2>/dev/null && \
            ok "CAKE minimal set" || {
            err "CAKE failed entirely"
            run "tc qdisc add dev $ETH root fq_codel target 5ms interval 40ms"
            tc qdisc add dev "$ETH" root fq_codel target 5ms interval 40ms && ok "fq_codel applied" || err "fq_codel failed"
        }
    fi
else
    run "tc qdisc add dev $ETH root fq_codel target 5ms interval 40ms"
    tc qdisc add dev "$ETH" root fq_codel target 5ms interval 40ms && ok "fq_codel applied" || err "fq_codel failed"
fi

run "tc qdisc show dev $ETH"
tc qdisc show dev "$ETH"

run "Writing boot persistence: /etc/networkd-dispatcher/routable.d/50-cake"
mkdir -p /etc/networkd-dispatcher/routable.d/
cat > /etc/networkd-dispatcher/routable.d/50-cake << BOOTEOF
#!/bin/bash
ETH=\$(ip -o -4 route show to default | awk '{print \$5}' | head -1)
ip link set dev \$ETH txqueuelen 10000 2>/dev/null || true
tc qdisc del dev \$ETH root 2>/dev/null || true
modprobe sch_cake 2>/dev/null
if lsmod | grep -q sch_cake; then
    tc qdisc add dev \$ETH root cake bandwidth 400mbit rtt 40ms besteffort no-triple-isolate split-gso nat wash 2>/dev/null || \
    tc qdisc add dev \$ETH root cake bandwidth 400mbit rtt 40ms besteffort 2>/dev/null
else
    tc qdisc add dev \$ETH root fq_codel target 5ms interval 40ms 2>/dev/null
fi
BOOTEOF
chmod +x /etc/networkd-dispatcher/routable.d/50-cake
ok "Boot persistence written"

# ══════ IRQ AFFINITY / CPU TUNING ══════
sec "CPU / IRQ TUNING  [1 vCPU]"

run "Checking network IRQ affinity..."
ETH_IRQ=$(grep "$ETH" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1)
if [[ -n "$ETH_IRQ" ]]; then
    run "echo 1 > /proc/irq/$ETH_IRQ/smp_affinity"
    echo 1 > /proc/irq/$ETH_IRQ/smp_affinity 2>/dev/null && ok "IRQ $ETH_IRQ pinned to CPU0" || ok "IRQ affinity skipped (KVM may handle)"
else
    ok "No dedicated NIC IRQ (virtio/KVM — normal)"
fi

run "Setting CPU scaling governor to performance..."
if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | head -1 | grep -q governor; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$f" 2>/dev/null && ok "Governor: performance ($f)"
    done
else
    ok "cpufreq not exposed (KVM — normal, host controls)"
fi

# ══════ XRAY / 3x-ui SOCKOPT ══════
sec "XRAY SOCKOPT PATCH"

XRAY_CONFIG=""
for p in /usr/local/x-ui/bin/config.json /etc/x-ui/config.json /root/x-ui/bin/config.json; do
    [[ -f "$p" ]] && XRAY_CONFIG="$p" && break
done

if [[ -n "$XRAY_CONFIG" ]]; then
    run "Found xray config: $XRAY_CONFIG"
    run "Backing up to ${XRAY_CONFIG}.bak"
    cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    ok "Backup done"
    if command -v python3 &>/dev/null; then
        run "Patching inbounds with sockopt tcpNoDelay=true, keepAlive=true..."
        python3 << PYEOF
import json, sys

with open("$XRAY_CONFIG") as f:
    cfg = json.load(f)

inbounds = cfg.get("inbounds") or []
if not inbounds:
    print("  no inbounds yet (fresh install) — sockopt will be patched after first inbound is added")
    sys.exit(0)

changed = 0
for ib in inbounds:
    if not isinstance(ib, dict):
        continue
    ss = ib.setdefault("streamSettings", {})
    if not isinstance(ss, dict):
        ib["streamSettings"] = {}
        ss = ib["streamSettings"]
    so = ss.setdefault("sockopt", {})
    updates = {
        "tcpNoDelay": True,
        "tcpKeepAliveIdle": 20,
        "tcpKeepAliveInterval": 5,
        "mark": 0
    }
    for k, v in updates.items():
        if so.get(k) != v:
            so[k] = v
            changed += 1

with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print(f"  patched {changed} fields across {len(inbounds)} inbounds")
PYEOF
        ok "sockopt patch done"
    else
        err "python3 not found"
    fi

    # ── install re-patcher service: รัน patch ทุกครั้งที่ x-ui restart ──
    run "Installing sockopt auto-patcher (runs on every x-ui restart)..."
    PATCHER=/usr/local/bin/xui-sockopt-patch.py
    cat > "$PATCHER" << 'PYFILE'
#!/usr/bin/env python3
import json, sys, os, time

PATHS = [
    "/usr/local/x-ui/bin/config.json",
    "/etc/x-ui/config.json",
    "/root/x-ui/bin/config.json",
]
SOCKOPT = {
    "tcpNoDelay": True,
    "tcpKeepAliveIdle": 20,
    "tcpKeepAliveInterval": 5,
    "mark": 0,
}

def patch(path):
    with open(path) as f:
        cfg = json.load(f)
    inbounds = cfg.get("inbounds") or []
    if not inbounds:
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
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    return changed

for p in PATHS:
    if os.path.exists(p):
        n = patch(p)
        print(f"patched {n} fields in {p}")
        sys.exit(0)

print("no xray config found")
PYFILE
    chmod +x "$PATCHER"

    # systemd ExecStartPost hook บน x-ui
    mkdir -p /etc/systemd/system/x-ui.service.d/
    # append ไปใน override เดิม
    cat > /etc/systemd/system/x-ui.service.d/sockopt.conf << 'UNITEOF'
[Service]
ExecStartPost=/bin/bash -c 'sleep 3 && python3 /usr/local/bin/xui-sockopt-patch.py'
UNITEOF
    systemctl daemon-reload
    ok "auto-patcher installed → จะรันทุกครั้งหลัง x-ui start"
else
    ok "xray config not found yet (จะ patch อัตโนมัติเมื่อ 3x-ui สร้าง config แล้ว)"
    echo -e "${Y}  ▸ sockopt ที่ต้องเพิ่มใน inbound ทุก entry ใน 3x-ui JSON editor:${N}"
    echo '  "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 20, "tcpKeepAliveInterval": 5 }'
fi

# ══════ RESTART x-ui ══════
sec "RESTART x-ui"

run "systemctl restart x-ui"
if systemctl is-active --quiet x-ui 2>/dev/null; then
    systemctl restart x-ui
    sleep 2
    STATUS=$(systemctl is-active x-ui)
    ok "x-ui status: $STATUS"
    run "journalctl -u x-ui --no-pager -n 5"
    journalctl -u x-ui --no-pager -n 5 2>/dev/null || true
else
    run "systemctl start x-ui"
    systemctl start x-ui 2>/dev/null && ok "x-ui started" || err "x-ui start failed — check: journalctl -u x-ui"
fi

# ══════ FINAL VERIFY ══════
sec "FINAL VERIFY"

run "Active ports (ss -tlnp):"
ss -tlnp | grep -E ":(80|443|2053|2083|2087|2096|8080|8443|54321) " | while IFS= read -r line; do
    ok "$line"
done

run "Congestion control:"
ok "cc = $(sysctl -n net.ipv4.tcp_congestion_control)"

run "qdisc:"
tc qdisc show dev "$ETH" | while IFS= read -r line; do ok "$line"; done

run "keepalive time:"
ok "tcp_keepalive_time = $(sysctl -n net.ipv4.tcp_keepalive_time)s"

run "nofile (current shell):"
ok "soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

echo -e "\n${G}${B}══════ DONE ══════${N}"
echo -e "${Y}  ▸ เปิด port ใน ReadyIDC Panel → Firewall Rules ด้วย${N}"
echo -e "${Y}  ▸ reboot เพื่อให้ limits.conf มีผลกับทุก process${N}"
