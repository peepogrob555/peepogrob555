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
echo -e "${CYAN}   UDP Custom All-In-One (OpenSSH-WS / Dropbear-WS / SSL-WS + Hardening)${NC}"
echo -e "${CYAN}   Ubuntu 22.04 / target 350Mbps-50ms ต่อ connection / รองรับ ~20 users${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo ""

echo "🌐 กำลังดึง IP ของ VPS นี้..."
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 icanhazip.com || echo "ไม่พบ")
echo "   IP ที่ตรวจพบ: ${SERVER_IP}"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  เลือกวิธีให้ผู้ใช้เชื่อมต่อเข้าเซิร์ฟเวอร์นี้ (address หลัก / SNI / host header)"
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

echo ""
read -rp "Host WebSocket CDN (Enter = ใช้ ${CONNECT_ADDRESS} เหมือนเดิม, กด - เพื่อไม่ตั้งค่า): " WS_CDN_INPUT
if [ "$WS_CDN_INPUT" = "-" ]; then
  WS_CDN=""
else
  WS_CDN="${WS_CDN_INPUT:-$CONNECT_ADDRESS}"
fi
echo "$WS_CDN" > "${BASE_DIR}/ws-cdn"
echo -e "   ${GREEN}✓ Host WebSocket CDN -> ${WS_CDN:-(ไม่ตั้งค่า)}${NC}"

OPENSSH_PORT=22
DROPBEAR_PORTS=(2222 2082 2086 2095)
OPENSSH_WS_PORTS=(2087 8080)
DROPBEAR_WS_PORTS=(80 8880)
SSL_WS_PORTS=(443 8443 2096)
SQUID_PORTS=(8080 8888 2052)
BADVPN_PORT=7300

SQUID_PORTS=(8888 2052)

echo ""
echo "📦 [1/11] อัปเดตระบบ + ติดตั้งแพ็กเกจพื้นฐาน..."
apt update -y
apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install -y curl wget git ufw fail2ban iptables-persistent netfilter-persistent \
  dnsutils vnstat htop unzip ipset build-essential cmake python3 \
  dropbear openssh-server squid stunnel4

echo ""
echo "🌐 [2/11] ล็อก DNS ให้ใช้ Cloudflare (1.1.1.1 / 1.0.0.1) อย่างเดียว..."
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
echo "🛡️  [3/11] ตั้งค่า Firewall..."
ufw --force reset > /dev/null
sed -i 's/^IPV6=no/IPV6=yes/' /etc/default/ufw

if modprobe xt_hashlimit 2>/dev/null; then
  echo "xt_hashlimit" > /etc/modules-load.d/xt_hashlimit.conf
  if ! grep -q "UDP-RATE-LIMIT" /etc/ufw/before.rules; then
    awk '/^COMMIT$/ && !d {
      print "UDP-RATE-LIMIT";
      print "-A ufw-before-input -p udp -m conntrack --ctstate NEW -m hashlimit --hashlimit-name udpnew --hashlimit-above 200/sec --hashlimit-mode srcip --hashlimit-burst 400 -j DROP";
      d=1
    } { print }' /etc/ufw/before.rules > /tmp/before.rules.tmp
    mv /tmp/before.rules.tmp /etc/ufw/before.rules
  fi
fi

ufw default deny incoming
ufw default allow outgoing

ufw allow ${OPENSSH_PORT}/tcp
for p in "${DROPBEAR_PORTS[@]}" "${OPENSSH_WS_PORTS[@]}" "${DROPBEAR_WS_PORTS[@]}" "${SSL_WS_PORTS[@]}" "${SQUID_PORTS[@]}"; do
  ufw allow ${p}/tcp
done
ufw allow 1:65535/udp

ufw allow out to 1.1.1.1 port 53
ufw allow out to 1.0.0.1 port 53
ufw allow out to 2606:4700:4700::1111 port 53
ufw allow out to 2606:4700:4700::1001 port 53
ufw deny out to any port 53

ufw --force enable
echo "   ✓ Firewall enable แล้ว"

echo ""
echo "⚡ [4/11] ปรับแต่งเครือข่าย (BBR + CAKE + buffer 350Mbps/50ms ต่อ connection)..."
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
echo "🔒 [5/11] เปิดใช้ fail2ban ป้องกัน brute-force (OpenSSH + Dropbear แยก filter)..."
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
echo "🔑 [6/11] ตั้งค่า Dropbear + OpenSSH (SSH ตรง สำหรับ payload/HTTP Custom)..."
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
echo "🔌 [7/11] ตั้งค่า WebSocket Proxy (OpenSSH-WS / Dropbear-WS)..."
cat > "${BIN_DIR}/ws-proxy.py" << 'PYEOF'
#!/usr/bin/env python3
import socket
import threading
import sys

MAPPING_FILE = "/etc/udp-custom/ws-mapping.conf"
TARGET_HOST = "127.0.0.1"
BUFFER_SIZE = 65536
HANDSHAKE_RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n\r\n"
)

def relay(src, dst):
    try:
        while True:
            data = src.recv(BUFFER_SIZE)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

def handle_client(client_sock, target_port):
    target_sock = None
    try:
        client_sock.settimeout(10)
        client_sock.recv(BUFFER_SIZE)
        client_sock.settimeout(None)
        client_sock.sendall(HANDSHAKE_RESPONSE)
        target_sock = socket.create_connection((TARGET_HOST, target_port))
        t1 = threading.Thread(target=relay, args=(client_sock, target_sock), daemon=True)
        t2 = threading.Thread(target=relay, args=(target_sock, client_sock), daemon=True)
        t1.start(); t2.start(); t1.join(); t2.join()
    except OSError:
        pass
    finally:
        client_sock.close()
        if target_sock is not None:
            target_sock.close()

def listen_on_port(listen_port, target_port, label):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", listen_port))
    server.listen(256)
    print(f"[ws-proxy] {label}: listen {listen_port} -> 127.0.0.1:{target_port}", flush=True)
    while True:
        client_sock, _ = server.accept()
        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=handle_client, args=(client_sock, target_port), daemon=True).start()

def load_mapping():
    mapping = []
    with open(MAPPING_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            listen_port, target_port, label = line.split(":", 2)
            mapping.append((int(listen_port), int(target_port), label))
    return mapping

if __name__ == "__main__":
    threads = []
    for listen_port, target_port, label in load_mapping():
        t = threading.Thread(target=listen_on_port, args=(listen_port, target_port, label), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
PYEOF
chmod +x "${BIN_DIR}/ws-proxy.py"

{
  for p in "${OPENSSH_WS_PORTS[@]}"; do echo "${p}:${OPENSSH_PORT}:openssh-ws"; done
  for p in "${DROPBEAR_WS_PORTS[@]}"; do echo "${p}:${DROPBEAR_PORTS[0]}:dropbear-ws"; done
} > "${BASE_DIR}/ws-mapping.conf"

SSL_WS_LOCAL_BASE=12000
i=0
STUNNEL_SERVICES=""
for p in "${SSL_WS_PORTS[@]}"; do
  local_port=$((SSL_WS_LOCAL_BASE + i))
  echo "${local_port}:${DROPBEAR_PORTS[0]}:ssl-ws-local(${p})" >> "${BASE_DIR}/ws-mapping.conf"
  i=$((i + 1))
done

cat > /etc/systemd/system/ws-proxy.service << EOF
[Unit]
Description=UDP Custom WebSocket Proxy (OpenSSH-WS / Dropbear-WS)
After=network.target dropbear.service ssh.service

[Service]
ExecStart=/usr/bin/python3 ${BIN_DIR}/ws-proxy.py
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ws-proxy > /dev/null 2>&1
echo "   ✓ OpenSSH-WS: ${OPENSSH_WS_PORTS[*]} -> :${OPENSSH_PORT} | Dropbear-WS: ${DROPBEAR_WS_PORTS[*]} -> :${DROPBEAR_PORTS[0]}"

echo ""
echo "🔐 [8/11] ตั้งค่า SSL-WS (stunnel TLS termination)..."
mkdir -p /etc/stunnel
if [ ! -f /etc/stunnel/udpcustom.pem ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=${CONNECT_ADDRESS}" \
    -keyout /etc/stunnel/udpcustom.key -out /etc/stunnel/udpcustom.crt > /dev/null 2>&1
  cat /etc/stunnel/udpcustom.key /etc/stunnel/udpcustom.crt > /etc/stunnel/udpcustom.pem
  chmod 600 /etc/stunnel/udpcustom.pem
fi

{
  echo "pid = /var/run/stunnel-udpcustom.pid"
  echo "cert = /etc/stunnel/udpcustom.pem"
  echo "client = no"
  echo ""
  i=0
  for p in "${SSL_WS_PORTS[@]}"; do
    local_port=$((SSL_WS_LOCAL_BASE + i))
    echo "[ssl-ws-${p}]"
    echo "accept = ${p}"
    echo "connect = 127.0.0.1:${local_port}"
    echo ""
    i=$((i + 1))
  done
} > /etc/stunnel/udpcustom.conf

sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || echo "ENABLED=1" >> /etc/default/stunnel4
systemctl enable --now stunnel4 > /dev/null 2>&1
systemctl restart stunnel4
echo "   ✓ SSL-WS (TLS จริง): ${SSL_WS_PORTS[*]} -> stunnel -> ws-proxy(local) -> :${DROPBEAR_PORTS[0]}"
echo "   ⚠️ ใบรับรองเป็น self-signed (CN=${CONNECT_ADDRESS}) เพียงพอสำหรับ client ที่ตั้ง 'ไม่ตรวจสอบ cert'"

echo ""
echo "🌍 [9/11] ตั้งค่า Squid (CONNECT proxy จำกัดเฉพาะไปพอต SSH)..."
SSH_ACL_PORTS="${OPENSSH_PORT} ${DROPBEAR_PORTS[*]}"
cat > /etc/squid/squid.conf << EOF
acl SSH_ports port ${SSH_ACL_PORTS}
acl CONNECT method CONNECT
http_access allow CONNECT SSH_ports
http_access deny CONNECT !SSH_ports
http_access deny all
$(for p in "${SQUID_PORTS[@]}"; do echo "http_port ${p}"; done)
visible_hostname ${CONNECT_ADDRESS}
EOF
systemctl enable squid > /dev/null 2>&1
systemctl restart squid
echo "   ✓ Squid: ${SQUID_PORTS[*]} (CONNECT อนุญาตแค่ไปพอต ${SSH_ACL_PORTS})"

echo ""
echo "📡 [10/11] ติดตั้ง badvpn-udpgw (UDP gateway สำหรับ UDP Custom app)..."
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
echo "👤 [11/11] ติดตั้ง User Manager + Connection Enforcer..."

cat > "${BIN_DIR}/udp-user-manager.sh" << 'UMEOF'
#!/bin/bash
set -e
USERS_DIR="/etc/udp-custom/users"
ADDR_FILE="/etc/udp-custom/address"
WSCDN_FILE="/etc/udp-custom/ws-cdn"
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
  WS_CDN=$(cat "$WSCDN_FILE" 2>/dev/null || echo "")
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
  echo "│ Username         : ${NEW_USER}"
  echo "│ Password         : ${NEW_PASS}"
  echo "│ หมดอายุ          : ${EXPIRE_DATE} (${EXPIRE_DAYS} วัน)"
  echo "│ Max Conn         : ${MAX_CONN}"
  echo "│ SSH ตรง          : ${CONNECT_ADDRESS}:22 / :2222 / :2082 / :2086 / :2095"
  echo "│ Host WebSocket CDN: ${WS_CDN:-(ไม่ตั้งค่า)}"
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
    printf "  %2d) %s / %s\n" "$i" "$uname" "$PASSWORD"
    printf "      SSH ตรง            : %s:22, :2222, :2082, :2086, :2095\n" "$CONNECT_ADDRESS"
    printf "      OpenSSH-WS         : %s:2087, :8080\n" "$CONNECT_ADDRESS"
    printf "      Dropbear-WS        : %s:80, :8880\n" "$CONNECT_ADDRESS"
    printf "      SSL-WS (TLS)       : %s:443, :8443, :2096\n" "$CONNECT_ADDRESS"
    printf "      Host WebSocket CDN : %s\n" "${WS_CDN:-(ไม่ตั้งค่า)}"
    printf "      สร้างเมื่อ         : %s\n" "$created_str"
    printf "      หมดอายุ            : %s (%s วัน)\n" "$EXPIRE_DATE" "$EXPIRE_DAYS"
    printf "      Connect            : ${conn_color}%s/%s${NC}\n" "$active" "$MAX_CONN"
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
echo "│  ที่อยู่เชื่อมต่อหลัก      : ${CONNECT_ADDRESS}"
echo "│  Host WebSocket CDN        : ${WS_CDN:-(ไม่ตั้งค่า)}"
echo "│──────────────────────────────────────────────────────────────────│"
echo "│  OpenSSH (ตรง)             : ${CONNECT_ADDRESS}:${OPENSSH_PORT}"
echo "│  Dropbear (ตรง)            : ${CONNECT_ADDRESS}:${DROPBEAR_PORTS[*]// /, :}"
echo "│  OpenSSH-WS                : ${CONNECT_ADDRESS}:${OPENSSH_WS_PORTS[*]// /, :} -> :${OPENSSH_PORT}"
echo "│  Dropbear-WS               : ${CONNECT_ADDRESS}:${DROPBEAR_WS_PORTS[*]// /, :} -> :${DROPBEAR_PORTS[0]}"
echo "│  SSL-WS (TLS จริง)         : ${CONNECT_ADDRESS}:${SSL_WS_PORTS[*]// /, :} -> :${DROPBEAR_PORTS[0]}"
echo "│  Squid (CONNECT->SSH)      : ${CONNECT_ADDRESS}:${SQUID_PORTS[*]// /, :}"
echo "│  UDP Custom app UDPGW      : 127.0.0.1:${BADVPN_PORT} (local)"
echo "│  UDP data plane            : ${CONNECT_ADDRESS} พอต 1-65535"
echo "│  fail2ban                  : sshd(${OPENSSH_PORT}) + dropbear(${DB_PORT_LIST})"
echo "│  TCP MSS clamp             : 1440"
echo "│  จัดการ user               : udp-user-manager"
echo "│  บังคับ conn limit         : udp-conn-enforcer.timer (ทุก 20 วิ, log /var/log/udp-conn-enforcer.log)"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""
if [ -n "$USER_DOMAIN" ]; then
  echo -e "${YELLOW}⚠️ อย่าลืมตั้ง A record: ${USER_DOMAIN} -> ${SERVER_IP} (Cloudflare proxy = DNS only เท่านั้น${NC}"
  echo -e "${YELLOW}   ยกเว้นพอต SSL-WS (${SSL_WS_PORTS[*]}) ที่มี TLS จริงแล้ว จะลองตั้งเป็น proxied (เมฆส้ม) ผ่าน Cloudflare ได้ แต่ต้องเป็น TLS mode 'Full' ไม่ใช่ 'Flexible'${NC}"
fi
echo -e "${YELLOW}⚠️  แนะนำ reboot 1 ครั้งให้ BBR/cake/FD-limit apply เต็มที่: reboot${NC}"
echo -e "${CYAN}======================================================================${NC}"
