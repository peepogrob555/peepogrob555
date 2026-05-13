#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║              VPS SETUP SCRIPT — File 1/2                        ║
# ║  Ubuntu 22.04 | Xver Cloud TH | VLESS Reality | 3x-ui           ║
# ║  Author: AI-Generated for AIS 128kbps Low-Latency Profile       ║
# ╚══════════════════════════════════════════════════════════════════╝
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR/REPO/main/setup.sh)
#
# หลังรันไฟล์นี้เสร็จ → รัน tune.sh เพื่อ optimize kernel/CAKE/BBR

set -euo pipefail

# ─────────────────────────────────────────
#  COLORS & HELPERS
# ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/var/log/vps-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ${NC}"; }
pause()   {
  echo -e "\n${YELLOW}▶ กด [Enter] เพื่อดำเนินการต่อ ...${NC}"
  read -r < /dev/tty
}

# ─────────────────────────────────────────
#  ROOT CHECK
# ─────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && err "ต้องรันด้วย root: sudo bash setup.sh"

# ─────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────
clear
echo -e "${BOLD}${GREEN}"
cat << 'BANNER'
 ██╗   ██╗██████╗ ███████╗    ███████╗███████╗████████╗██╗   ██╗██████╗ 
 ██║   ██║██╔══██╗██╔════╝    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
 ██║   ██║██████╔╝███████╗    ███████╗█████╗     ██║   ██║   ██║██████╔╝
 ╚██╗ ██╔╝██╔═══╝ ╚════██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝ 
  ╚████╔╝ ██║     ███████║    ███████║███████╗   ██║   ╚██████╔╝██║     
   ╚═══╝  ╚═╝     ╚══════╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝     
BANNER
echo -e "${NC}"
echo -e "${CYAN}  VPS Setup Script — Xver Cloud TH | VLESS Reality | Ubuntu 22.04${NC}"
echo -e "${CYAN}  Log: $LOG_FILE${NC}"
echo -e "  $(date)"
echo ""

# ─────────────────────────────────────────
#  STEP 0 — SYSTEM INFO SNAPSHOT
# ─────────────────────────────────────────
step "STEP 0 — System Snapshot"
info "OS      : $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY | cut -d= -f2)"
info "Kernel  : $(uname -r)"
info "CPU     : $(nproc) core(s)"
info "RAM     : $(free -h | awk '/^Mem:/{print $2}')"
info "Disk    : $(df -h / | awk 'NR==2{print $4}') free"
info "IP      : $(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
info "Interface: $(ip route | grep default | awk '{print $5}' | head -1)"
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$IFACE" ] && err "ไม่พบ default interface — ตรวจสอบ network"
ok "Interface: $IFACE"

# ─────────────────────────────────────────
#  STEP 1 — APT UPDATE & UPGRADE
# ─────────────────────────────────────────
step "STEP 1 — APT Update & Upgrade"
info "กำลัง update apt package list..."
pause

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && ok "apt update สำเร็จ"

info "กำลัง upgrade packages (อาจใช้เวลา 1-3 นาที)..."
apt-get upgrade -y -qq \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  && ok "apt upgrade สำเร็จ"

apt-get autoremove -y -qq && apt-get autoclean -qq
ok "Cleanup เสร็จ"

# ─────────────────────────────────────────
#  STEP 2 — INSTALL REQUIRED PACKAGES
# ─────────────────────────────────────────
step "STEP 2 — Install Required Packages"
info "ติดตั้ง packages ที่จำเป็น..."
pause

PKGS=(
  curl wget git unzip tar
  ca-certificates gnupg lsb-release
  ufw fail2ban
  iproute2 iputils-ping
  net-tools tcpdump
  htop iotop iftop
  cron logrotate
  # CAKE/Traffic shaping
  iproute2            # tc command
  linux-modules-extra-$(uname -r) # CAKE, ifb modules
  # Utilities
  jq bc
)

for pkg in "${PKGS[@]}"; do
  if ! dpkg -l "$pkg" &>/dev/null 2>&1; then
    apt-get install -y -qq "$pkg" && ok "ติดตั้ง $pkg" || warn "ไม่สามารถติดตั้ง $pkg (ข้ามไป)"
  else
    info "$pkg — มีอยู่แล้ว"
  fi
done

# ตรวจ CAKE module
info "ตรวจสอบ CAKE module..."
if modprobe sch_cake 2>/dev/null; then
  ok "CAKE module พร้อมใช้งาน"
else
  warn "CAKE module ไม่พบ — จะลองติดตั้ง kernel extras..."
  apt-get install -y -qq "linux-modules-extra-$(uname -r)" 2>/dev/null || \
    warn "ติดตั้ง kernel extras ไม่ได้ — CAKE อาจต้องการ kernel upgrade"
fi

# ตรวจ ifb module
if modprobe ifb numifbs=1 2>/dev/null; then
  ok "IFB module พร้อมใช้งาน"
  ip link add ifb0 type ifb 2>/dev/null || true
  ip link set ifb0 up 2>/dev/null || true
else
  warn "IFB module ไม่พบ — Ingress CAKE จะถูกข้ามใน tune.sh"
fi

# ─────────────────────────────────────────
#  STEP 3 — SWAP (ถ้า RAM ≤ 1GB)
# ─────────────────────────────────────────
step "STEP 3 — Swap Setup"
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_CURRENT=$(swapon --show | wc -l)

if [ "$SWAP_CURRENT" -le 1 ] && [ "$TOTAL_RAM_MB" -le 1024 ]; then
  info "RAM ${TOTAL_RAM_MB}MB และไม่มี Swap — กำลังสร้าง 512MB Swap..."
  pause
  fallocate -l 512M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile -q
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo "vm.swappiness=10" >> /etc/sysctl.d/99-swap.conf
  ok "Swap 512MB สร้างเสร็จ (swappiness=10)"
else
  info "Swap มีอยู่แล้ว หรือ RAM เพียงพอ — ข้ามขั้นตอนนี้"
fi

# ─────────────────────────────────────────
#  STEP 4 — UFW FIREWALL
# ─────────────────────────────────────────
step "STEP 4 — UFW Firewall"
info "จะตั้งค่า UFW เปิด port: 22 (SSH), 80 (HTTP/ACME), 443 (VLESS), 2053 (3x-ui)"
info "⚠️  UFW จะ enable หลังจากตั้งค่า — SSH port 22 จะเปิดไว้เสมอ"
pause

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — สำคัญมาก อย่าลืม
ufw allow 22/tcp comment "SSH"

# HTTP (ACME cert / Xray fallback)
ufw allow 80/tcp comment "HTTP-ACME"

# VLESS Reality
ufw allow 443/tcp comment "VLESS-Reality"
ufw allow 443/udp comment "VLESS-Reality-UDP"

# 3x-ui Panel
ufw allow 2053/tcp comment "3x-ui-Panel"

# Enable
ufw --force enable
ok "UFW เปิดใช้งาน"
ufw status numbered

# ─────────────────────────────────────────
#  STEP 5 — FAIL2BAN (SSH protection)
# ─────────────────────────────────────────
step "STEP 5 — Fail2Ban"
info "ตั้งค่า fail2ban ป้องกัน SSH brute force..."

cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(syslog_backend)s
F2B

systemctl enable fail2ban --quiet
systemctl restart fail2ban
ok "Fail2Ban เปิดใช้งาน"

# ─────────────────────────────────────────
#  STEP 6 — 3x-ui INSTALL
# ─────────────────────────────────────────
step "STEP 6 — 3x-ui Installation"
echo ""
echo -e "${YELLOW}┌──────────────────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}│  จะติดตั้ง 3x-ui (MHSanaei) — Official Latest        │${NC}"
echo -e "${YELLOW}│  Source: github.com/MHSanaei/3x-ui                   │${NC}"
echo -e "${YELLOW}│  Panel จะอยู่ที่: http://YOUR-IP:2053                 │${NC}"
echo -e "${YELLOW}│  ระบบจะถามตั้ง username/password ระหว่างติดตั้ง       │${NC}"
echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}ติดตั้ง 3x-ui ไหม?${NC}"
echo -e "  [Enter]  = ใช่ ติดตั้งเลย"
echo -e "  [Ctrl+C] = ออกจาก script"
echo ""
read -rp "▶ กด Enter เพื่อติดตั้ง 3x-ui: " < /dev/tty

info "กำลังดาวน์โหลดและติดตั้ง 3x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || \
  err "ติดตั้ง 3x-ui ไม่สำเร็จ — ตรวจสอบ internet connection"

ok "3x-ui ติดตั้งสำเร็จ"

# รอให้ service start
sleep 3
if systemctl is-active --quiet x-ui; then
  ok "x-ui service กำลังทำงาน"
else
  warn "x-ui service ยังไม่ start — ลอง: systemctl start x-ui"
fi

# ─────────────────────────────────────────
#  STEP 7 — LOGROTATE
# ─────────────────────────────────────────
step "STEP 7 — Log Rotation"
cat > /etc/logrotate.d/vps-setup << 'LR'
/var/log/vps-setup.log
/var/log/vps-tune.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
LR
ok "Logrotate ตั้งค่าเสร็จ"

# ─────────────────────────────────────────
#  STEP 8 — PRE-CHECK สำหรับ tune.sh
# ─────────────────────────────────────────
step "STEP 8 — Pre-check ก่อนรัน tune.sh"

echo ""
echo -e "${BOLD}ตรวจสอบ modules ที่ tune.sh ต้องการ:${NC}"

check_module() {
  local mod="$1"
  if modprobe "$mod" 2>/dev/null; then
    echo -e "  ${GREEN}✅ $mod${NC}"
  else
    echo -e "  ${RED}❌ $mod — ไม่พบ (tune.sh จะ handle เอง)${NC}"
  fi
}

check_module tcp_bbr
check_module sch_cake
check_module ifb

echo ""
CC_AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "unknown")
echo -e "  CC Available: ${CYAN}$CC_AVAIL${NC}"

# ─────────────────────────────────────────
#  COMPLETE SUMMARY
# ─────────────────────────────────────────
VPS_IP=$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            ✅  SETUP COMPLETE — File 1/2                ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  3x-ui Panel  : http://%-33s║\n" "${VPS_IP}:2053"
echo "║  Log file     : /var/log/vps-setup.log                  ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  ขั้นตอนถัดไป:                                            ║"
echo "║  รัน tune.sh เพื่อ Optimize BBR + CAKE + Kernel          ║"
echo "║                                                          ║"
echo "║  bash <(curl -fsSL https://YOUR_REPO/tune.sh)           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "[$(date)] Setup complete" >> "$LOG_FILE"
