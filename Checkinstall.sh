#!/usr/bin/env bash
set -euo pipefail

OUT="/root/vps_full_specs_$(date +%Y%m%d_%H%M%S).txt"

exec > >(tee -a "$OUT") 2>&1

section() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "▶ $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

echo "VPS FULL INSPECTION REPORT"
echo "Generated: $(date)"
echo "Hostname : $(hostname)"
echo "Output   : $OUT"

section "OS / KERNEL"

uname -a || true
cat /etc/os-release || true
hostnamectl || true

section "CPU"

lscpu || true
nproc || true
cat /proc/cpuinfo | head -100 || true

section "MEMORY"

free -mh || true
vmstat -s || true
swapon --show || true

section "DISK"

lsblk || true
df -hT || true
mount | head -100 || true

section "IO BENCH"

which fio >/dev/null 2>&1 && \
fio --name=randread --rw=randread --bs=4k --size=128M --numjobs=1 --iodepth=16 --runtime=15 --time_based || true

section "VIRTUALIZATION"

systemd-detect-virt || true
virt-what || true

section "NETWORK INTERFACES"

ip addr || true
ip route || true
ip -s link || true

section "NIC DETAILS"

for i in $(ls /sys/class/net | grep -v lo); do
  echo "### $i ###"
  ethtool $i || true
  ethtool -k $i || true
  ethtool -S $i || true
done

section "IRQ / SOFTIRQ"

cat /proc/interrupts | head -100 || true
cat /proc/softirqs || true

section "TCP STACK"

sysctl net.ipv4.tcp_congestion_control || true
sysctl net.core.default_qdisc || true

sysctl -a 2>/dev/null | grep -E \
'tcp|udp|rmem|wmem|somaxconn|fq|cake|bbr|busy_poll|netdev|conntrack' || true

section "QDISC"

tc qdisc show || true
tc -s qdisc show || true

section "NFTABLES"

nft list ruleset || true

section "IPTABLES"

iptables-save || true
ip6tables-save || true

section "CONNTRACK"

sysctl net.netfilter.nf_conntrack_max || true
conntrack -S || true

section "SOCKETS"

ss -s || true
ss -tulpn || true

section "SYSTEMD SERVICES"

systemctl list-units --type=service --state=running || true

section "TOP PROCESSES"

ps aux --sort=-%mem | head -30 || true
ps aux --sort=-%cpu | head -30 || true

section "XRAY / 3X-UI"

systemctl status x-ui --no-pager || true
x-ui settings || true

find /usr/local/x-ui/ -type f 2>/dev/null | head -50 || true

section "XRAY CONFIG"

find / -name "*.json" 2>/dev/null | grep xray || true

section "OPEN PORTS"

ss -lntup || true

section "DNS"

resolvectl status || true
cat /etc/resolv.conf || true

section "MODULES"

lsmod | sort || true

section "KERNEL FEATURES"

modprobe tcp_bbr || true
modprobe sch_cake || true
modprobe ifb || true

lsmod | grep -E 'bbr|cake|ifb' || true

section "LIMITS"

ulimit -a || true
cat /etc/security/limits.conf || true

section "SYSCTL FILES"

find /etc/sysctl* -type f -maxdepth 2 -exec echo "### {} ###" \; -exec cat {} \; || true

section "JOURNAL ERRORS"

journalctl -p 3 -xb --no-pager | tail -100 || true

section "DMESG"

dmesg | tail -200 || true

section "PING TEST"

ping -c 20 1.1.1.1 || true
ping -c 20 8.8.8.8 || true

section "TRACE"

tracepath 1.1.1.1 || true

section "SPEED"

curl -4 ifconfig.me || true
echo

section "FINAL"

echo "Inspection complete."
echo "Saved to: $OUT"
