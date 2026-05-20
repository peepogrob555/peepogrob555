#!/usr/bin/env bash
# VPS Fresh Check — เช็คเครื่องเปล่าหลังเช่ามา

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
C='\033[0;36m' B='\033[0;34m' DIM='\033[2m'
BOLD='\033[1m' NC='\033[0m'

_h()  { echo ""; echo -e "${BOLD}${B}── $* ──${NC}"; }
_ok() { echo -e "${G}  ✔  $*${NC}"; }
_no() { echo -e "${R}  ✘  $*${NC}"; }
_wa() { echo -e "${Y}  ⚠  $*${NC}"; }
_in() { echo -e "${C}  ●  $*${NC}"; }
_d()  { echo -e "${DIM}     $*${NC}"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

clear
echo -e "${BOLD}${B}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║  VPS Fresh Check                        ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── OS / Kernel ──────────────────────────────────────────────
_h "OS / Kernel"
_in "OS      : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
_in "Kernel  : $(uname -r)"
_in "Arch    : $(uname -m)"

kver=$(uname -r | cut -d'-' -f1)
major=$(echo "$kver" | cut -d. -f1)
minor=$(echo "$kver" | cut -d. -f2)
(( major > 4 || (major == 4 && minor >= 9) )) \
    && _ok "Kernel ≥ 4.9 — BBR รองรับ" \
    || _no "Kernel < 4.9 — BBR ไม่รองรับ"
(( major > 5 || (major == 5 && minor >= 4) )) \
    && _ok "Kernel ≥ 5.4 — CAKE รองรับ" \
    || _wa "Kernel < 5.4 — CAKE อาจไม่ครบ"

# ── CPU ──────────────────────────────────────────────────────
_h "CPU"
_in "Model   : $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
_in "Cores   : $(nproc)"
virt=$(systemd-detect-virt 2>/dev/null || echo "unknown")
_in "Virt    : ${virt}"
steal=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $17}')
[[ -n "$steal" ]] && {
    (( steal < 5 )) && _ok "CPU steal: ${steal}% (ปกติ)" \
                    || _no "CPU steal: ${steal}% (สูง — shared VPS โหลดหนัก)"
}

# ── RAM ──────────────────────────────────────────────────────
_h "RAM"
total=$(free -m | awk '/^Mem:/{print $2}')
avail=$(free -m | awk '/^Mem:/{print $7}')
swap=$(free -m  | awk '/^Swap:/{print $2}')
_in "Total   : ${total} MB"
_in "Available: ${avail} MB"
_in "Swap    : ${swap} MB"
(( avail > 400 ))  && _ok "RAM available OK" || _wa "RAM เหลือน้อย: ${avail} MB"
(( swap > 0 ))     && _ok "Swap มี: ${swap} MB" \
                    || _wa "ไม่มี Swap — แนะนำสร้าง 512MB"

# ── Disk ─────────────────────────────────────────────────────
_h "Disk"
df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
    | grep -v "^Filesystem\|tmpfs\|udev\|overlay" | sed 's/^/     /'
disk_dev=$(lsblk -nd --output NAME 2>/dev/null | head -1)
[[ -n "$disk_dev" ]] && {
    rota=$(cat /sys/block/"${disk_dev}"/queue/rotational 2>/dev/null)
    [[ "$rota" == "0" ]] && _ok "Disk: SSD/NVMe" || _wa "Disk: HDD"
}
_in "Write speed (dd 256MB):"
dd if=/dev/zero of=/tmp/_dd_test bs=1M count=256 oflag=direct 2>&1 \
    | grep -o "[0-9.]* [MG]B/s" | sed 's/^/     /'
rm -f /tmp/_dd_test

# ── Network ──────────────────────────────────────────────────
_h "Network"
IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
pub_ip=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null || echo "timeout")
priv_ip=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
ipv6=$(ip -6 addr show "$IFACE" 2>/dev/null | awk '/inet6.*global/{print $2}' | head -1)
nic_speed=$(cat /sys/class/net/"${IFACE}"/speed 2>/dev/null || echo "N/A")

_in "Interface : ${IFACE} (${nic_speed} Mbps)"
_in "Public IP : ${pub_ip}"
_in "Private IP: ${priv_ip}"
[[ -n "$ipv6" ]] && _ok "IPv6: ${ipv6}" || _wa "IPv6: ไม่มี"

_in "Latency:"
for host in 1.1.1.1 8.8.8.8 th.speedtest.net; do
    lat=$(ping -c 3 -W 3 "$host" 2>/dev/null \
        | grep "avg" | awk -F'/' '{printf "%.1f ms", $5}')
    [[ -n "$lat" ]] && _d "${host}: ${lat}" || _d "${host}: timeout"
done

_in "Download speed (curl Cloudflare 100MB):"
dl=$(curl -s --max-time 20 -o /dev/null -w "%{speed_download}" \
    "https://speed.cloudflare.com/__down?bytes=104857600" 2>/dev/null \
    | awk '{printf "%.1f Mbps", $1*8/1000000}')
[[ -n "$dl" ]] && _d "${dl}" || _d "timeout"

# ── Kernel / BBR / CAKE ──────────────────────────────────────
_h "Kernel Features"
modprobe tcp_bbr 2>/dev/null  && _ok "tcp_bbr module: loadable" || _no "tcp_bbr: ไม่พบ"
modprobe ifb 2>/dev/null      && _ok "IFB module: loadable"     || _wa "IFB: ไม่พบ — ingress CAKE ใช้ไม่ได้"
modprobe nf_conntrack 2>/dev/null && _ok "nf_conntrack: loadable" || _wa "nf_conntrack: ไม่พบ"

tc qdisc add dev lo root cake 2>/dev/null \
    && { tc qdisc del dev lo root 2>/dev/null; _ok "CAKE: available"; } \
    || _wa "CAKE: ไม่พบ — ใช้ fq_codel แทน"

tc qdisc add dev lo root cake rtt 40ms 2>/dev/null \
    && { tc qdisc del dev lo root 2>/dev/null; _ok "CAKE rtt param: supported"; } \
    || _d "CAKE rtt: ไม่รองรับ"

_in "Current cc: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
_in "ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"

# ── Firewall ─────────────────────────────────────────────────
_h "Firewall"
command -v nft &>/dev/null      && _ok "nftables: $(nft --version 2>/dev/null | head -1)" \
                                 || _wa "nftables: ไม่ติดตั้ง"
command -v iptables &>/dev/null && _in "iptables: $(iptables --version 2>/dev/null)" \
                                 || _wa "iptables: ไม่พบ"
command -v ufw &>/dev/null      && _in "ufw: $(ufw status 2>/dev/null | head -1)" \
                                 || _d  "ufw: ไม่ติดตั้ง"

# ── System Limits ────────────────────────────────────────────
_h "System Limits"
soft=$(ulimit -Sn 2>/dev/null)
hard=$(ulimit -Hn 2>/dev/null)
_in "nofile: soft=${soft} / hard=${hard}"
(( soft >= 65535 )) && _ok "nofile OK" || _wa "nofile ต่ำ — แนะนำ 65535"
dmesg 2>/dev/null | grep -q "Out of memory" \
    && _no "OOM เคย trigger" || _ok "ไม่มี OOM"

# ── Summary ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${B}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}${B}══════════════════════════════════════════════════${NC}"
bbr_mod=$(modprobe tcp_bbr 2>/dev/null && echo "YES" || echo "NO")
cake_mod=$(tc qdisc add dev lo root cake 2>/dev/null \
    && { tc qdisc del dev lo root 2>/dev/null; echo "YES"; } || echo "NO")
ifb_mod=$(modprobe ifb 2>/dev/null && echo "YES" || echo "NO")

printf "  %-28s %s\n" "OS"          "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
printf "  %-28s %s\n" "Kernel"      "$(uname -r)"
printf "  %-28s %s\n" "vCPU"        "$(nproc)"
printf "  %-28s %s MB\n" "RAM total"  "$total"
printf "  %-28s %s MB\n" "RAM avail"  "$avail"
printf "  %-28s %s MB\n" "Swap"       "$swap"
printf "  %-28s %s\n" "Public IP"   "$pub_ip"
printf "  %-28s %s\n" "Interface"   "$IFACE"
printf "  %-28s %s\n" "Virt"        "$virt"
printf "  %-28s %s\n" "BBR module"  "$bbr_mod"
printf "  %-28s %s\n" "CAKE module" "$cake_mod"
printf "  %-28s %s\n" "IFB module"  "$ifb_mod"
printf "  %-28s %s\n" "nofile"      "$soft"
echo ""
