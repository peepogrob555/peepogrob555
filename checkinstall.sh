#!/usr/bin/env bash

set +e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

echo "========================================="
echo " VPS HEALTH CHECK"
echo "========================================="
echo

# 1. x-ui service
if systemctl is-active --quiet x-ui; then
    ok "x-ui service running"
else
    fail "x-ui service stopped"
fi

# 2. xray process
if pgrep -x xray >/dev/null; then
    ok "xray process running"
else
    fail "xray process missing"
fi

# 3. panel port
if ss -tlnp | grep -q ":2053 "; then
    ok "Panel port 2053 listening"
else
    fail "Panel port 2053 not listening"
fi

# 4. sysctl file
if [ -f /etc/sysctl.d/99-tune.conf ]; then
    ok "99-tune.conf exists"
else
    fail "99-tune.conf missing"
fi

# 5. THP
if grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
    ok "THP disabled"
else
    warn "THP not disabled"
fi

# 6. BBR
CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

if [ "$CC" = "bbr" ]; then
    ok "BBR enabled"
else
    fail "BBR not enabled ($CC)"
fi

# 7. qdisc
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

if [ "$QDISC" = "fq" ]; then
    ok "fq qdisc enabled"
else
    warn "fq qdisc not active ($QDISC)"
fi

# 8. THP service
if systemctl is-enabled thp-disable.service >/dev/null 2>&1; then
    ok "THP service enabled"
else
    warn "THP service not enabled"
fi

# 9. cpu-performance
if systemctl is-enabled cpu-performance.service >/dev/null 2>&1; then
    ok "CPU performance service enabled"
else
    warn "CPU performance service missing"
fi

# 10. ulimit
NOFILE=$(ulimit -n)

if [ "$NOFILE" -ge 65535 ]; then
    ok "NOFILE limit = $NOFILE"
else
    warn "NOFILE limit low ($NOFILE)"
fi

# 11. memory
MEM=$(free -m | awk '/Mem:/ {print $7}')

if [ "$MEM" -gt 100 ]; then
    ok "Available RAM ${MEM}MB"
else
    warn "Low RAM ${MEM}MB"
fi

# 12. disk
DISK=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$DISK" -lt 90 ]; then
    ok "Disk usage ${DISK}%"
else
    warn "Disk usage high ${DISK}%"
fi

echo
echo "========================================="
echo " SUMMARY"
echo "========================================="

echo "Server : $(hostname)"
echo "Kernel : $(uname -r)"
echo "IP     : $(curl -4 -s ifconfig.me)"
echo "BBR    : $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "Qdisc  : $(sysctl -n net.core.default_qdisc)"
echo "Uptime : $(uptime -p)"
echo "========================================="
