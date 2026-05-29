#!/bin/bash
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'

ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1"; }
inf() { echo -e "${Y}[INFO]${N} $1"; }
sec() { echo -e "\n${B}${C}╔══════════════════════════════════════════╗${N}"
        echo -e "${B}${C}║  $1${N}"
        echo -e "${B}${C}╚══════════════════════════════════════════╝${N}"; }

ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)
PUBIP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
NCPU=$(nproc)
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
RAM_GB=$(awk "BEGIN{printf \"%.1f\", $RAM_MB/1024}")

echo -e "\n${B}${C}  VPS Health Check${N}"
echo -e "  Interface : ${Y}$ETH${N} | IP: ${Y}$PUBIP${N}"
echo -e "  Hardware  : ${Y}${NCPU} vCPU${N} | ${Y}${RAM_GB}GB RAM${N}\n"

sec "HARDWARE"
ok "vCPU = $NCPU"
ok "RAM  = ${RAM_GB}GB (${RAM_MB}MB)"
SWAP=$(swapon --show --noheadings 2>/dev/null | awk '{print $3}')
[[ -n "$SWAP" ]] && ok "Swap = $SWAP" || err "Swap = none"

sec "x-ui / XRAY"
systemctl is-active --quiet x-ui && ok "x-ui = active" || err "x-ui = NOT running"
XRAY_PID=$(pgrep -x xray 2>/dev/null | head -1)
[[ -n "$XRAY_PID" ]] && ok "xray pid = $XRAY_PID" || err "xray = NOT running"

if [[ -n "$XRAY_PID" ]]; then
    TASKSET=$(taskset -cp "$XRAY_PID" 2>/dev/null | awk -F': ' '{print $2}')
    ok "taskset CPU = $TASKSET"
    IONICE=$(ionice -p "$XRAY_PID" 2>/dev/null)
    ok "ionice = $IONICE"
    GOMAXPROCS=$(cat /proc/$XRAY_PID/environ 2>/dev/null | tr '\0' '\n' | grep GOMAXPROCS | cut -d= -f2)
    [[ -n "$GOMAXPROCS" ]] && ok "GOMAXPROCS = $GOMAXPROCS" || inf "GOMAXPROCS = (systemd env)"
fi

sec "PORTS"
for p in 80 443 2053 8080 8443 54321; do
    LINE=$(ss -tlnp | grep ":$p ")
    if [[ -n "$LINE" ]]; then
        PROC=$(echo "$LINE" | grep -oP 'users:\(\("\K[^"]+')
        ok "port $p → $PROC"
    else
        inf "port $p → not listening"
    fi
done

sec "KERNEL / SYSCTL"
check_sysctl() {
    local key=$1 expect=$2
    val=$(sysctl -n "$key" 2>/dev/null)
    if [[ "$val" == "$expect" ]]; then
        ok "$key = $val"
    else
        err "$key = $val (expect $expect)"
    fi
}
check_sysctl net.ipv4.tcp_congestion_control bbr
check_sysctl net.core.default_qdisc fq
check_sysctl net.ipv4.tcp_fastopen 3
check_sysctl net.ipv4.tcp_autocorking 0
check_sysctl net.ipv4.tcp_slow_start_after_idle 0
check_sysctl net.ipv4.tcp_notsent_lowat 32768
check_sysctl net.ipv4.tcp_limit_output_bytes 524288
check_sysctl net.ipv4.tcp_mtu_probing 1
check_sysctl net.ipv4.tcp_keepalive_time 10
check_sysctl net.ipv4.tcp_keepalive_intvl 3
check_sysctl net.ipv4.tcp_keepalive_probes 4
check_sysctl net.core.somaxconn 65535
check_sysctl net.ipv4.ip_forward 1
check_sysctl net.ipv4.tcp_tw_reuse 1
check_sysctl net.ipv4.tcp_ecn 1
check_sysctl vm.swappiness 5
check_sysctl kernel.sched_autogroup_enabled 0
check_sysctl kernel.nmi_watchdog 0
ok "rmem_max = $(sysctl -n net.core.rmem_max)"
ok "wmem_max = $(sysctl -n net.core.wmem_max)"

sec "FILE LIMITS"
SOFT=$(ulimit -Sn)
HARD=$(ulimit -Hn)
FMAX=$(cat /proc/sys/fs/file-max)
[[ $SOFT -ge 65535 ]] && ok "nofile soft = $SOFT" || err "nofile soft = $SOFT (too low)"
[[ $HARD -ge 65535 ]] && ok "nofile hard = $HARD" || err "nofile hard = $HARD (too low)"
ok "fs.file-max = $FMAX"

sec "CAKE QDISC"
QDISC=$(tc qdisc show dev "$ETH" 2>/dev/null)
echo "$QDISC" | grep -q "cake" && ok "CAKE active" || err "CAKE not active"
echo "$QDISC" | grep -q "400Mbit" && ok "bandwidth = 400Mbit" || err "bandwidth != 400Mbit"
echo "$QDISC" | grep -q "rtt 35ms" && ok "rtt = 35ms" || err "rtt != 35ms"
echo "$QDISC" | grep -q "besteffort" && ok "mode = besteffort" || err "mode != besteffort"
inf "full: $QDISC"

sec "ETHTOOL"
if command -v ethtool &>/dev/null; then
    ethtool -k "$ETH" 2>/dev/null | grep -E "generic-receive-offload|large-receive-offload|tcp-segmentation-offload|generic-segmentation-offload" | \
        while IFS= read -r line; do inf "$line"; done
else
    inf "ethtool not installed"
fi

sec "HUGEPAGE"
HP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
echo "$HP" | grep -q "\[madvise\]" && ok "hugepage = madvise" || err "hugepage = $HP"

sec "SOCKOPT (xray config)"
CONFIG=""
for p in /usr/local/x-ui/bin/config.json /etc/x-ui/config.json /root/x-ui/bin/config.json; do
    [[ -f "$p" ]] && CONFIG="$p" && break
done

if [[ -n "$CONFIG" ]]; then
    ok "config = $CONFIG"
    python3 << PYEOF
import json
with open("$CONFIG") as f:
    cfg = json.load(f)
inbounds = cfg.get("inbounds", [])
print(f"  inbounds: {len(inbounds)}")
for ib in inbounds:
    tag = ib.get("tag","?")
    port = ib.get("port","?")
    proto = ib.get("protocol","?")
    ss = ib.get("streamSettings", {})
    so = ss.get("sockopt", {})
    net = ss.get("network","?")
    sec = ss.get("security","?")
    print(f"  [{tag}] {proto} {net} port={port} security={sec}")
    checks = {
        "tcpNoDelay": True,
        "tcpFastOpen": True,
        "tcpMaxSeg": 1460,
        "tcpUserTimeout": 8000,
        "tcpKeepAliveIdle": 10,
        "tcpKeepAliveInterval": 3,
    }
    for k,v in checks.items():
        got = so.get(k)
        status = "\033[0;32m[OK]\033[0m" if got == v else "\033[0;31m[ERR]\033[0m"
        print(f"    {status}   {k} = {got} (expect {v})")
PYEOF
else
    err "xray config not found"
fi

sec "CERT"
CERT_DIR="/root/cert"
if [[ -d "$CERT_DIR" ]]; then
    for d in "$CERT_DIR"/*/; do
        DOMAIN=$(basename "$d")
        FULLCHAIN="$d/fullchain.pem"
        PRIVKEY="$d/privkey.pem"
        [[ -f "$FULLCHAIN" ]] && ok "cert = $FULLCHAIN" || err "fullchain missing"
        [[ -f "$PRIVKEY" ]]   && ok "key  = $PRIVKEY"   || err "privkey missing"
        EXP=$(openssl x509 -enddate -noout -in "$FULLCHAIN" 2>/dev/null | cut -d= -f2)
        [[ -n "$EXP" ]] && ok "expires = $EXP" || inf "cannot read expiry"
    done
else
    inf "no cert directory found"
fi

sec "IPTABLES"
for p in 80 443 2053 8080; do
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && \
        ok "iptables port $p ACCEPT" || err "iptables port $p NOT set"
done

sec "SUMMARY"
SCORE=0
TOTAL=0

check() {
    TOTAL=$((TOTAL+1))
    if eval "$1" &>/dev/null; then
        SCORE=$((SCORE+1))
        return 0
    fi
    return 1
}

check "systemctl is-active --quiet x-ui"
check "pgrep -x xray"
check "[[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]"
check "tc qdisc show dev $ETH | grep -q cake"
check "tc qdisc show dev $ETH | grep -q 400Mbit"
check "[[ $(sysctl -n net.ipv4.tcp_fastopen) == 3 ]]"
check "[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]"
check "[[ $(sysctl -n vm.swappiness) == 5 ]]"
check "swapon --show | grep -q swap"
check "[[ -f /usr/local/bin/xui-ws-patch.py ]]"
check "cat /sys/kernel/mm/transparent_hugepage/enabled | grep -q '\[madvise\]'"
check "ss -tlnp | grep -q ':80 '"

PCT=$((SCORE * 100 / TOTAL))
echo ""
if [[ $PCT -ge 90 ]]; then
    echo -e "${G}${B}  ✓ $SCORE/$TOTAL checks passed ($PCT%) — พร้อมใช้งาน${N}"
elif [[ $PCT -ge 70 ]]; then
    echo -e "${Y}${B}  ⚠ $SCORE/$TOTAL checks passed ($PCT%) — บางอย่างผิดปกติ${N}"
else
    echo -e "${R}${B}  ✗ $SCORE/$TOTAL checks passed ($PCT%) — มีปัญหาหลายจุด${N}"
fi
echo ""
