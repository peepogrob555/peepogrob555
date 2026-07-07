#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

BASE_DIR="/etc/udp-custom"
USERS_DIR="${BASE_DIR}/users"
BIN_DIR="/usr/local/bin"

if [ "$EUID" -ne 0 ]; then
  echo "❌ ต้องรันด้วย root: sudo bash $0"
  exit 1
fi

mkdir -p "$BASE_DIR" "$USERS_DIR"
chmod 700 "$USERS_DIR"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UDP Custom Installer (Dropbear/OpenSSH ตรง + UDP Custom)${NC}"
echo -e "${CYAN}   Ubuntu 22.04 / target 350Mbps-50ms ต่อ connection / รองรับ ~20 users${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

echo "🌐 กำลังดึง IP ของ VPS นี้..."
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 icanhazip.com || echo "ไม่พบ")
echo "   IP ที่ตรวจพบ: ${SERVER_IP}"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  เลือกวิธีให้ผู้ใช้เชื่อมต่อเข้าเซิร์ฟเวอร์นี้"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}[1] Domain${NC}   ต้องมี A record ชี้มา ${SERVER_IP} ไว้ก่อนแล้ว"
echo -e "  ${GREEN}[2] IP ตรง${NC}   (${SERVER_IP})"
read -rp "เลือก [1-2]: " CONN_MODE
case "$CONN_MODE" in
  1)
    read -rp "กรอกชื่อโดเมน (เช่น vpn.example.com): " USER_DOMAIN
    while [ -z "$USER_DOMAIN" ]; do read -rp "โดเมนว่างไม่ได้ กรอกใหม่: " USER_DOMAIN; done
    CONNECT_ADDRESS="$USER_DOMAIN"
    ;;
  *)
    USER_DOMAIN=""
    CONNECT_ADDRESS="$SERVER_IP"
    ;;
esac
echo -e "   ${GREEN}✓ ที่อยู่เชื่อมต่อหลัก -> ${CONNECT_ADDRESS}${NC}"
echo "$CONNECT_ADDRESS" > "${BASE_DIR}/address"

OPENSSH_PORT=22
DROPBEAR_PORTS=(2222 2082 2086 2095)
BADVPN_PORT=7300

echo ""
echo "📦 [1/8] อัปเดตระบบ + ติดตั้งแพ็กเกจพื้นฐาน..."
apt update -y
apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install -y curl wget git ufw fail2ban iptables-persistent netfilter-persistent \
  dnsutils vnstat htop unzip ipset build-essential cmake python3 \
  dropbear openssh-server

echo ""
echo "🌐 [2/8] ล็อก DNS ให้ใช้ Cloudflare (1.1.1.1 / 1.0.0.1) อย่างเดียว..."
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/cloudflare-dns.conf << 'EOF'
[Resolve]
DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
FallbackDNS=
DNSStubListener=no
EOF
  systemctl restart systemd-resolved
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
else
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf
  chattr +i /etc/resolv.conf
fi
echo "   ✓ ล็อก DNS แล้ว"

echo ""
echo "🛡️  [3/8] ตั้งค่า Firewall (stealth: เปิดพอตที่ใช้จริงเท่านั้น, ที่เหลือ DROP เงียบ ตอบเฉพาะ ESTABLISHED/RELATED)..."
ufw --force reset > /dev/null
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw

if modprobe xt_hashlimit 2>/dev/null; then
  echo "xt_hashlimit" > /etc/modules-load.d/xt_hashlimit.conf
  if ! grep -q "UDP-RATE-LIMIT" /etc/ufw/before.rules; then
    # FIX: marker ต้องมี "# " นำหน้า ไม่งั้น iptables-restore จะเจอ
    # error "Bad argument `UDP-RATE-LIMIT'" เพราะมันกลายเป็นบรรทัดคำสั่งจริง
    # (grep -q ด้านบนยังหาเจอ "UDP-RATE-LIMIT" ปกติ เพราะเป็น substring match)
    awk '/^COMMIT$/ && !d {
      print "# UDP-RATE-LIMIT";
      print "-A ufw-before-input -p udp -m conntrack --ctstate NEW -m hashlimit --hashlimit-name udpnew --hashlimit-above 200/sec --hashlimit-mode srcip --hashlimit-burst 400 -j DROP";
      d=1
    } { print }' /etc/ufw/before.rules > /tmp/before.rules.tmp
    mv /tmp/before.rules.tmp /etc/ufw/before.rules
  fi
fi

ufw default deny incoming
ufw default allow outgoing

ufw allow ${OPENSSH_PORT}/tcp
for p in "${DROPBEAR_PORTS[@]}"; do
  ufw allow ${p}/tcp
done

ufw allow out to 1.1.1.1 port 53
ufw allow out to 1.0.0.1 port 53
ufw allow out to 2606:4700:4700::1111 port 53
ufw allow out to 2606:4700:4700::1001 port 53
ufw deny out to any port 53

ufw --force enable
echo "   ✓ Firewall enable แล้ว (เปิดเฉพาะ ${OPENSSH_PORT}, ${DROPBEAR_PORTS[*]} — พอตอื่นทั้งหมด DROP เงียบ ไม่ REJECT)"

echo ""
echo "⚡ [4/8] ปรับแต่งเครือข่าย (BBR + CAKE + buffer 350Mbps/50ms ต่อ connection)..."
modprobe tcp_bbr 2>/dev/null || true
modprobe sch_cake 2>/dev/null || true
echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
echo "sch_cake" > /etc/modules-load.d/sch_cake.conf

cat > /etc/modprobe.d/nf_conntrack.conf << 'EOF'
options nf_conntrack hashsize=524288
EOF

cat > /etc/sysctl.d/99-udpcustom-optimize.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 8388608
net.ipv4.tcp_wmem = 4096 1048576 8388608
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 8192
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
fs.file-max = 2097152
EOF
sysctl --system > /dev/null 2>&1 || echo "   ⚠️ บาง sysctl key ยังไม่พร้อม จะครบหลัง reboot"

iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440 2>/dev/null || \
  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1440
netfilter-persistent save > /dev/null 2>&1

cat > /etc/security/limits.d/99-udpcustom.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
echo "   ✓ ตั้งค่า sysctl / MSS clamp / FD limit แล้ว"

echo ""
echo "🔒 [5/8] เปิดใช้ fail2ban ป้องกัน brute-force (OpenSSH + Dropbear แยก filter)..."
systemctl enable --now fail2ban > /dev/null 2>&1
cat > /etc/fail2ban/jail.d/sshd.local << EOF
[sshd]
enabled  = true
filter   = sshd
port     = ${OPENSSH_PORT}
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
DB_PORT_LIST=$(IFS=,; echo "${DROPBEAR_PORTS[*]}")
cat > /etc/fail2ban/jail.d/dropbear.local << EOF
[dropbear]
enabled  = true
filter   = dropbear
port     = ${DB_PORT_LIST}
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
systemctl restart fail2ban
echo "   ✓ fail2ban คุม OpenSSH(${OPENSSH_PORT}) และ Dropbear(${DB_PORT_LIST})"

echo ""
echo "🔑 [6/8] ตั้งค่า Dropbear + OpenSSH (SSH ตรง)..."
DB_EXTRA=""
for p in "${DROPBEAR_PORTS[@]:1}"; do DB_EXTRA="${DB_EXTRA} -p ${p}"; done
cat > /etc/default/dropbear << EOF
NO_START=0
DROPBEAR_PORT=${DROPBEAR_PORTS[0]}
DROPBEAR_EXTRA_ARGS="${DB_EXTRA}"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
systemctl enable dropbear > /dev/null 2>&1
systemctl restart dropbear
systemctl enable --now ssh > /dev/null 2>&1
echo "   ✓ Dropbear: ${DROPBEAR_PORTS[*]} | OpenSSH: ${OPENSSH_PORT}"

echo ""
echo "📡 [7/8] ติดตั้ง badvpn-udpgw (UDP Custom)..."
cd /usr/local/src
if [ ! -d badvpn ]; then
  git clone --depth 1 https://github.com/ambrop72/badvpn.git > /dev/null 2>&1
fi
mkdir -p badvpn-build
cd badvpn-build
cmake ../badvpn -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null
make install > /dev/null

cat > /etc/systemd/system/badvpn-udpgw.service << EOF
[Unit]
Description=BadVPN UDPGW
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${BADVPN_PORT} --max-clients 1000 --max-connections-for-client 20
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now badvpn-udpgw > /dev/null 2>&1
echo "   ✓ badvpn-udpgw ทำงานที่ 127.0.0.1:${BADVPN_PORT}"

echo ""
echo "👤 [8/8] ติดตั้ง User Manager + Connection Enforcer..."

cat > "${BIN_DIR}/udp-user-manager.sh" << 'UMEOF'
#!/bin/bash
set -e
USERS_DIR="/etc/udp-custom/users"
ADDR_FILE="/etc/udp-custom/address"
DROPBEAR_PORTS=(22 2222 2082 2086 2095)

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo "❌ ต้องรันด้วย root: sudo bash $0"; exit 1; fi
mkdir -p "$USERS_DIR"; chmod 700 "$USERS_DIR"

ensure_address() {
  CONNECT_ADDRESS=$(cat "$ADDR_FILE" 2>/dev/null || echo "")
  if [ -z "$CONNECT_ADDRESS" ]; then
    DETECTED_IP=$(curl -s --max-time 5 ifconfig.me || echo "")
    read -rp "กรอก Domain หรือ IP ที่ต้องการใช้แสดง (Enter = ${DETECTED_IP}): " INPUT_ADDR
    CONNECT_ADDRESS="${INPUT_ADDR:-$DETECTED_IP}"
    echo "$CONNECT_ADDRESS" > "$ADDR_FILE"
  fi
}

count_connections() {
  local user="$1"; local count=0; local pids
  for port in "${DROPBEAR_PORTS[@]}"; do
    pids=$(ss -H -tnp state established "( sport = :${port} )" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u)
    for pid in $pids; do
      owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$owner" = "$user" ] && count=$((count + 1))
    done
  done
  echo "$count"
}

human_ago() {
  local created_at="$1"; local now; now=$(date +%s)
  local diff=$((now - created_at)); local days=$((diff / 86400)); local hours=$(((diff % 86400) / 3600))
  if [ "$days" -gt 0 ]; then echo "${days} วัน ${hours} ชม.ที่แล้ว"
  else
    local mins=$(((diff % 3600) / 60))
    if [ "$hours" -gt 0 ]; then echo "${hours} ชม. ${mins} นาทีที่แล้ว"; else echo "${mins} นาทีที่แล้ว"; fi
  fi
}

create_user() {
  echo -e "${CYAN}== สร้าง User ใหม่ ==${NC}"
  read -rp "Username: " NEW_USER
  [ -z "$NEW_USER" ] && { echo -e "${RED}❌ ต้องกรอก username${NC}"; return; }
  id "$NEW_USER" &>/dev/null && { echo -e "${RED}❌ user นี้มีอยู่แล้ว${NC}"; return; }
  read -rsp "Password: " NEW_PASS; echo ""
  [ -z "$NEW_PASS" ] && { echo -e "${RED}❌ ต้องกรอก password${NC}"; return; }
  read -rp "จำกัดอายุกี่วัน (เช่น 30): " EXPIRE_DAYS; EXPIRE_DAYS=${EXPIRE_DAYS:-30}
  case "$EXPIRE_DAYS" in ''|*[!0-9]*) echo -e "${RED}❌ ต้องเป็นตัวเลข${NC}"; return ;; esac
  read -rp "จำกัดจำนวน connection พร้อมกัน (เช่น 2): " MAX_CONN; MAX_CONN=${MAX_CONN:-1}
  case "$MAX_CONN" in ''|*[!0-9]*) echo -e "${RED}❌ ต้องเป็นตัวเลข${NC}"; return ;; esac
  EXPIRE_DATE=$(date -d "+${EXPIRE_DAYS} days" +%Y-%m-%d)
  useradd -M -N -s /usr/sbin/nologin -e "$EXPIRE_DATE" "$NEW_USER"
  echo "${NEW_USER}:${NEW_PASS}" | chpasswd
  ensure_address
  cat > "${USERS_DIR}/${NEW_USER}.conf" << EOF
USERNAME=${NEW_USER}
PASSWORD=${NEW_PASS}
CREATED_AT=$(date +%s)
EXPIRE_DAYS=${EXPIRE_DAYS}
EXPIRE_DATE=${EXPIRE_DATE}
MAX_CONN=${MAX_CONN}
EOF
  chmod 600 "${USERS_DIR}/${NEW_USER}.conf"
  echo ""
  echo -e "${GREEN}✅ สร้าง user สำเร็จ${NC}"
  echo "┌──────────────────────────────────────────────┐"
  echo "│ Username     : ${NEW_USER}"
  echo "│ Password     : ${NEW_PASS}"
  echo "│ หมดอายุ      : ${EXPIRE_DATE} (${EXPIRE_DAYS} วัน)"
  echo "│ Max Conn     : ${MAX_CONN}"
  echo "│ Connect      : ${CONNECT_ADDRESS}:2222@${NEW_USER}:${NEW_PASS}"
  echo "│ พอตอื่น      : 22, 2082, 2086, 2095 (ใช้ user/pass เดียวกัน)"
  echo "│ UDP Custom   : ผ่าน badvpn-udpgw 127.0.0.1:7300 (local เท่านั้น)"
  echo "└──────────────────────────────────────────────┘"
}

remove_user() {
  echo -e "${CYAN}== ลบ User ==${NC}"
  mapfile -t META_FILES < <(for f in "${USERS_DIR}"/*.conf; do [ -e "$f" ] || continue; source "$f"; echo "${CREATED_AT}|${USERNAME}"; done | sort -n)
  [ "${#META_FILES[@]}" -eq 0 ] && { echo -e "${YELLOW}ยังไม่มี user ในระบบ${NC}"; return; }
  echo "รายชื่อ user (เรียงจากสร้างนานสุด -> ล่าสุด):"; echo ""
  local i=1; declare -A INDEX_MAP
  for entry in "${META_FILES[@]}"; do
    created_at="${entry%%|*}"; uname="${entry##*|}"
    created_str=$(date -d "@${created_at}" "+%Y/%m/%d %H:%M"); ago=$(human_ago "$created_at")
    printf "  %2d) %-15s สร้างเมื่อ %s (%s)\n" "$i" "$uname" "$ago" "$created_str"
    INDEX_MAP[$i]="$uname"; i=$((i + 1))
  done
  echo ""; read -rp "เลือกหมายเลขที่จะลบ (0 = ยกเลิก): " SEL
  [ "$SEL" = "0" ] || [ -z "$SEL" ] && { echo "ยกเลิกแล้ว"; return; }
  TARGET_USER="${INDEX_MAP[$SEL]}"
  [ -z "$TARGET_USER" ] && { echo -e "${RED}❌ เลือกไม่ถูกต้อง${NC}"; return; }
  read -rp "ยืนยันลบ user '${TARGET_USER}' ? พิมพ์ yes เพื่อยืนยัน: " CONFIRM
  [ "$CONFIRM" != "yes" ] && { echo "ยกเลิกแล้ว"; return; }
  pkill -u "$TARGET_USER" 2>/dev/null || true
  userdel -f "$TARGET_USER" 2>/dev/null || true
  rm -f "${USERS_DIR}/${TARGET_USER}.conf"
  echo -e "${GREEN}✅ ลบ user '${TARGET_USER}' เรียบร้อย${NC}"
}

user_detail() {
  echo -e "${CYAN}== User Detail ==${NC}"
  ensure_address
  mapfile -t META_FILES < <(for f in "${USERS_DIR}"/*.conf; do [ -e "$f" ] || continue; source "$f"; echo "${CREATED_AT}|${USERNAME}"; done | sort -n)
  [ "${#META_FILES[@]}" -eq 0 ] && { echo -e "${YELLOW}ยังไม่มี user ในระบบ${NC}"; return; }
  local i=1
  for entry in "${META_FILES[@]}"; do
    created_at="${entry%%|*}"; uname="${entry##*|}"
    source "${USERS_DIR}/${uname}.conf"
    created_str=$(date -d "@${CREATED_AT}" "+%Y/%m/%d %H:%M")
    active=$(count_connections "$uname")
    if [ "$active" -ge "$MAX_CONN" ]; then conn_color="${RED}"; else conn_color="${GREEN}"; fi
    echo ""
    printf "  %2d) %s:2222@%s:%s\n" "$i" "$CONNECT_ADDRESS" "$uname" "$PASSWORD"
    printf "      พอตอื่น    : 22, 2082, 2086, 2095\n"
    printf "      สร้างเมื่อ : %s\n" "$created_str"
    printf "      หมดอายุ   : %s (%s วัน)\n" "$EXPIRE_DATE" "$EXPIRE_DAYS"
    printf "      Connect   : ${conn_color}%s/%s${NC}\n" "$active" "$MAX_CONN"
    i=$((i + 1))
  done
  echo ""
}

while true; do
  echo ""
  echo -e "${CYAN}══════════════ UDP Custom User Manager ══════════════${NC}"
  echo "  1) Create new user"
  echo "  2) Remove user"
  echo "  3) User detail"
  echo "  0) Exit"
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
  read -rp "เลือกเมนู: " CHOICE
  case "$CHOICE" in
    1) create_user ;;
    2) remove_user ;;
    3) user_detail ;;
    0) echo "บาย 👋"; exit 0 ;;
    *) echo -e "${RED}เลือกไม่ถูกต้อง${NC}" ;;
  esac
done
UMEOF
chmod +x "${BIN_DIR}/udp-user-manager.sh"
ln -sf "${BIN_DIR}/udp-user-manager.sh" "${BIN_DIR}/udp-user-manager"

cat > "${BIN_DIR}/udp-conn-enforcer.sh" << 'CEEOF'
#!/bin/bash
USERS_DIR="/etc/udp-custom/users"
DROPBEAR_PORTS=(22 2222 2082 2086 2095)
LOG_FILE="/var/log/udp-conn-enforcer.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

get_user_pids() {
  local user="$1"; local pids=(); local pid owner
  for port in "${DROPBEAR_PORTS[@]}"; do
    for pid in $(ss -H -tnp state established "( sport = :${port} )" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u); do
      owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$owner" = "$user" ] && pids+=("$pid")
    done
  done
  echo "${pids[@]}"
}

for conf in "${USERS_DIR}"/*.conf; do
  [ -e "$conf" ] || continue
  source "$conf"
  today=$(date +%Y-%m-%d)
  if [[ "$today" > "$EXPIRE_DATE" ]]; then
    pids=($(get_user_pids "$USERNAME"))
    if [ "${#pids[@]}" -gt 0 ]; then
      kill -9 "${pids[@]}" 2>/dev/null
      log "user ${USERNAME} หมดอายุแล้ว (${EXPIRE_DATE}) -> ตัดการเชื่อมต่อ ${#pids[@]} session"
    fi
    continue
  fi
  read -ra PIDS <<< "$(get_user_pids "$USERNAME")"
  count="${#PIDS[@]}"
  if [ "$count" -gt "$MAX_CONN" ]; then
    excess=$((count - MAX_CONN))
    sorted_pids=$(for p in "${PIDS[@]}"; do
      etimes=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
      echo "${etimes:-0} ${p}"
    done | sort -n | awk '{print $2}')
    to_kill=$(echo "$sorted_pids" | tail -n "$excess")
    for p in $to_kill; do kill -9 "$p" 2>/dev/null; done
    log "user ${USERNAME} เกิน limit (${count}/${MAX_CONN}) -> ตัด ${excess} session ที่ใหม่สุด"
  fi
done
CEEOF
chmod +x "${BIN_DIR}/udp-conn-enforcer.sh"

cat > /etc/systemd/system/udp-conn-enforcer.service << 'EOF'
[Unit]
Description=UDP Custom per-user connection limit enforcer

[Service]
Type=oneshot
ExecStart=/usr/local/bin/udp-conn-enforcer.sh
EOF

cat > /etc/systemd/system/udp-conn-enforcer.timer << 'EOF'
[Unit]
Description=Run udp-conn-enforcer every 20 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=20s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now udp-conn-enforcer.timer > /dev/null 2>&1
echo -e "   ${GREEN}✓ ติดตั้ง udp-user-manager (พิมพ์ 'udp-user-manager' เพื่อเปิดเมนู) + udp-conn-enforcer.timer (ทุก 20 วิ)${NC}"

echo ""
echo -e "${CYAN}======================================================================${NC}"
echo -e "${GREEN}✅ เสร็จสมบูรณ์!${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│  ที่อยู่เชื่อมต่อหลัก : ${CONNECT_ADDRESS}"
echo "│──────────────────────────────────────────────────────────────────│"
echo "│  OpenSSH (ตรง)        : ${CONNECT_ADDRESS}:${OPENSSH_PORT}"
echo "│  Dropbear (ตรง)       : ${CONNECT_ADDRESS}:${DROPBEAR_PORTS[*]// /, :}"
echo "│  UDP Custom app UDPGW : 127.0.0.1:${BADVPN_PORT} (local)"
echo "│  พอตอื่นทั้งหมด        : DROP เงียบ (ไม่ REJECT) ยกเว้น ESTABLISHED/RELATED"
echo "│  fail2ban             : sshd(${OPENSSH_PORT}) + dropbear(${DB_PORT_LIST})"
echo "│  TCP MSS clamp        : 1440"
echo "│  จัดการ user          : udp-user-manager"
echo "│  บังคับ conn limit    : udp-conn-enforcer.timer (ทุก 20 วิ, log /var/log/udp-conn-enforcer.log)"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""
if [ -n "$USER_DOMAIN" ]; then
  echo -e "${YELLOW}⚠️ อย่าลืมตั้ง A record: ${USER_DOMAIN} -> ${SERVER_IP} (Cloudflare proxy = DNS only เท่านั้น เพราะไม่มี TLS ที่ต้นทาง)${NC}"
fi
echo -e "${YELLOW}⚠️  แนะนำ reboot 1 ครั้งให้ BBR/cake/FD-limit apply เต็มที่: reboot${NC}"
echo -e "${CYAN}======================================================================${NC}"
