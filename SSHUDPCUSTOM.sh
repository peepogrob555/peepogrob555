#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo "❌ ต้องรันด้วย root: sudo bash $0"
  exit 1
fi

echo -e "${CYAN}======================================================================${NC}"
echo -e "${CYAN}   UDP Custom Full Install + Hardening + Network Optimization${NC}"
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
echo -e "  ${GREEN}[1] Domain${NC}   (ตัวอย่าง: vpn.example.com)"
echo -e "      ต้องมีโดเมนตั้ง A record ชี้มา ${SERVER_IP} ไว้ก่อนแล้ว"
echo -e "      ข้อดี: จำง่าย, ใช้แทน IP ได้ (โหมดนี้ไม่มี TLS แนะนำตั้ง Cloudflare เป็น DNS only เท่านั้น)"
echo -e "      ข้อเสีย: ถ้า DNS ล่มหรือตั้งผิด ต่อไม่ได้จนกว่าจะแก้"
echo ""
echo -e "  ${GREEN}[2] IP ตรง${NC}   (${SERVER_IP})"
echo -e "      ต่อเข้า IP ของ VPS นี้ทันที ไม่ต้องพึ่งโดเมน/DNS ภายนอกเลย"
echo -e "      ข้อดี: เสถียรที่สุด ไม่มี DNS resolution แทรก, ตั้งค่าเสร็จใช้ได้ทันที"
echo -e "      ข้อเสีย: ซ่อน IP จริงไม่ได้ ต่อผ่าน Cloudflare proxy ไม่ได้"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
read -rp "เลือก [1-2]: " CONN_MODE
echo ""

case "$CONN_MODE" in
  1)
    read -rp "กรอกชื่อโดเมน (เช่น vpn.example.com): " USER_DOMAIN
    while [ -z "$USER_DOMAIN" ]; do
      read -rp "โดเมนว่างไม่ได้ กรอกใหม่: " USER_DOMAIN
    done
    CONNECT_ADDRESS="$USER_DOMAIN"
    echo -e "   ${GREEN}✓ เลือกโหมด Domain -> ${CONNECT_ADDRESS}${NC}"
    ;;
  2)
    USER_DOMAIN=""
    CONNECT_ADDRESS="$SERVER_IP"
    echo -e "   ${GREEN}✓ เลือกโหมด IP ตรง -> ${CONNECT_ADDRESS}${NC}"
    ;;
  *)
    echo -e "   ${YELLOW}⚠️ เลือกไม่ถูกต้อง ใช้ค่าเริ่มต้นเป็น IP ตรง${NC}"
    USER_DOMAIN=""
    CONNECT_ADDRESS="$SERVER_IP"
    ;;
esac

echo ""
echo "📦 [1/10] อัปเดตระบบ + ติดตั้งแพ็กเกจพื้นฐาน..."
apt update -y
apt -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt install -y curl wget git ufw fail2ban iptables-persistent netfilter-persistent \
  dnsutils vnstat htop unzip ipset build-essential cmake python3 \
  dropbear squid

echo ""
echo "🌐 [2/10] ล็อก DNS ให้ใช้ Cloudflare (1.1.1.1 / 1.0.0.1) อย่างเดียว..."
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
  echo "   ✓ ล็อกผ่าน systemd-resolved แล้ว"
else
  chattr -i /etc/resolv.conf 2>/dev/null || true
  rm -f /etc/resolv.conf
  printf "nameserver 1.1.1.1\nnameserver 1.0.0.1\n" > /etc/resolv.conf
  chattr +i /etc/resolv.conf
  echo "   ✓ ล็อก /etc/resolv.conf แบบ immutable แล้ว"
fi

echo ""
echo "🛡️  [3/10] ตั้งค่า Firewall..."
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
  echo "   ✓ เพิ่ม rate-limit UDP NEW-connection ต่อ IP ต้นทางแล้ว"
fi

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 2222/tcp
ufw allow 80/tcp
ufw allow 443/tcp
for p in 2052 2053 2082 2083 2086 2087 2095 2096 8080 8443 8880; do
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
echo "⚡ [4/10] ปรับแต่งเครือข่าย (BBR + CAKE + buffer 350Mbps/50ms ต่อ connection)..."
echo "   BDP = 350Mbps x 50ms = 2,187,500 byte (~2.1MB) ต่อ 1 connection"
echo "   ceiling 8MB ต่อ socket / conntrack ขยายรองรับ ~20 users พร้อมกัน"

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
echo "   ✓ ตั้งค่า sysctl แล้ว"

echo "   กำลังตั้ง MSS clamp = 1400 (ไม่มี TLS แล้ว overhead เหลือแค่ SSH framing + WS handshake ครั้งเดียว แต่ยังกัน PMTUD blackhole บนมือถือไทยไว้)..."
iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1400 2>/dev/null || \
  iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1400
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1400 2>/dev/null || \
  iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1400
netfilter-persistent save > /dev/null 2>&1
echo "   ✓ MSS clamp ตั้งแล้ว ไม่ต้องพึ่งค่า MTU ฝั่ง client เลย"

cat > /etc/security/limits.d/99-udpcustom.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

echo ""
echo "🔒 [5/10] เปิดใช้ fail2ban ป้องกัน brute-force SSH (OpenSSH + Dropbear แยก filter)..."
systemctl enable --now fail2ban > /dev/null 2>&1
cat > /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled  = true
filter   = sshd
port     = 22
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
cat > /etc/fail2ban/jail.d/dropbear.local << 'EOF'
[dropbear]
enabled  = true
filter   = dropbear
port     = 2222,2082,2086,2095
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF
systemctl restart fail2ban
echo "   ✓ fail2ban คุม OpenSSH (22) ด้วย filter sshd และ Dropbear (2222,2082,2086,2095) ด้วย filter dropbear แยกกัน"

echo ""
echo "🔑 [6/10] ตั้งค่า Dropbear (SSH ตรง สำหรับ payload/HTTP Custom)..."
cat > /etc/default/dropbear << 'EOF'
NO_START=0
DROPBEAR_PORT=2222
DROPBEAR_EXTRA_ARGS="-p 2082 -p 2086 -p 2095"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
EOF
systemctl enable dropbear > /dev/null 2>&1
systemctl restart dropbear
echo "   ✓ Dropbear ทำงานที่พอต 2222, 2082, 2086, 2095"

echo ""
echo "🔌 [7/10] ตั้งค่า WebSocket Proxy (ไม่มี TLS) ห่อ SSH ไว้ในพอตกลุ่ม HTTP..."
cat > /usr/local/bin/ws-proxy.py << 'PYEOF'
#!/usr/bin/env python3
import socket
import threading

LISTEN_PORTS = [443, 8443, 2053, 2083, 2087, 2096]
TARGET_HOST = "127.0.0.1"
TARGET_PORT = 2222
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

def handle_client(client_sock):
    target_sock = None
    try:
        client_sock.settimeout(10)
        client_sock.recv(BUFFER_SIZE)
        client_sock.settimeout(None)
        client_sock.sendall(HANDSHAKE_RESPONSE)
        target_sock = socket.create_connection((TARGET_HOST, TARGET_PORT))
        t1 = threading.Thread(target=relay, args=(client_sock, target_sock), daemon=True)
        t2 = threading.Thread(target=relay, args=(target_sock, client_sock), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except OSError:
        pass
    finally:
        client_sock.close()
        if target_sock is not None:
            target_sock.close()

def listen_on_port(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", port))
    server.listen(256)
    while True:
        client_sock, _ = server.accept()
        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=handle_client, args=(client_sock,), daemon=True).start()

if __name__ == "__main__":
    threads = []
    for port in LISTEN_PORTS:
        t = threading.Thread(target=listen_on_port, args=(port,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
PYEOF
chmod +x /usr/local/bin/ws-proxy.py

cat > /etc/systemd/system/ws-proxy.service << 'EOF'
[Unit]
Description=SSH WebSocket Proxy (no TLS)
After=network.target dropbear.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ws-proxy > /dev/null 2>&1
echo "   ✓ WebSocket Proxy (ไม่มี TLS) ทำงานที่พอต 443, 8443, 2053, 2083, 2087, 2096 -> forward เข้า dropbear 127.0.0.1:2222"

echo ""
echo "🌍 [8/10] ตั้งค่า Squid (CONNECT proxy จำกัดเฉพาะไปพอต SSH)..."
cat > /etc/squid/squid.conf << EOF
acl SSH_ports port 22 2222 2082 2086 2095
acl CONNECT method CONNECT
http_access allow CONNECT SSH_ports
http_access deny CONNECT !SSH_ports
http_access deny all
http_port 80
http_port 8080
http_port 8880
http_port 2052
visible_hostname ${CONNECT_ADDRESS}
EOF
systemctl enable squid > /dev/null 2>&1
systemctl restart squid
echo "   ✓ Squid ทำงานที่พอต 80, 8080, 8880, 2052 (CONNECT อนุญาตแค่ไปพอต SSH เท่านั้น)"

echo ""
echo "📡 [9/10] ติดตั้ง badvpn-udpgw (UDP gateway สำหรับ UDP Custom app)..."
cd /usr/local/src
if [ ! -d badvpn ]; then
  git clone --depth 1 https://github.com/ambrop72/badvpn.git > /dev/null 2>&1
fi
mkdir -p badvpn-build
cd badvpn-build
cmake ../badvpn -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null
make install > /dev/null

cat > /etc/systemd/system/badvpn-udpgw.service << 'EOF'
[Unit]
Description=BadVPN UDPGW
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 20
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now badvpn-udpgw > /dev/null 2>&1
echo "   ✓ badvpn-udpgw ทำงานที่ 127.0.0.1:7300 (local เท่านั้น ไม่ต้องเปิดไฟร์วอลล์)"

echo ""
echo "🌍 [10/10] คำแนะนำเรื่องโดเมน/IP..."
if [ -n "$USER_DOMAIN" ]; then
  cat << EOF
   ตั้งค่าที่ผู้ให้บริการโดเมน/Cloudflare สำหรับ ${USER_DOMAIN}:
   -> A record: ${USER_DOMAIN} -> ${SERVER_IP}
   -> proxy status เลือก "DNS only" (เมฆสีเทา) เท่านั้น
   -> ⚠️ ไม่มี TLS ที่ต้นทางแล้ว ถ้าเปลี่ยนเป็น Cloudflare proxy (เมฆสีส้ม)
      จะบังคับ SSL mode เป็น "Flexible" เท่านั้น ซึ่งข้อมูลช่วง Cloudflare
      -> เซิร์ฟเวอร์เราจะวิ่งแบบ plaintext ทั้งเส้น (ไม่ปลอดภัยเพิ่มความเสี่ยง
      ถูกดักข้อมูลกลางทาง) แนะนำให้คง "DNS only" ไว้ตลอดสำหรับสถาปัตยกรรมนี้
   -> พอต 22, 2222, 2082, 2086, 2095 (Dropbear ตรง) และ UDP ทั้งหมด ต้องวิ่ง
      ตรงเข้า IP เท่านั้น ต่อผ่าน Cloudflare proxy ไม่ได้อยู่แล้ว
EOF
else
  echo "   โหมด IP ตรง — ไม่ต้องตั้งค่าโดเมนใดๆ ใช้ ${SERVER_IP} เชื่อมต่อได้ทันที"
fi

echo ""
echo -e "${CYAN}======================================================================${NC}"
echo -e "${GREEN}✅ เสร็จสมบูรณ์!  โหมดเชื่อมต่อ: ${CONNECT_ADDRESS}${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo "ตรวจสอบผลลัพธ์:"
echo "   ufw status verbose"
echo "   sysctl net.ipv4.tcp_congestion_control     # ควรได้ bbr"
echo "   sysctl net.core.default_qdisc              # ควรได้ cake"
echo "   cat /etc/resolv.conf                       # ควรเห็นแค่ 1.1.1.1 / 1.0.0.1"
echo "   systemctl status dropbear ws-proxy squid badvpn-udpgw fail2ban"
echo "   fail2ban-client status sshd"
echo "   fail2ban-client status dropbear"
echo "   ss -tulnp | grep -E ':(22|2222|443|8443|2052|2053|2082|2083|2086|2087|2095|2096|80|8080|8880)\\b'"
echo "   iptables -t mangle -L -n -v | grep TCPMSS       # ควรเห็น set-mss 1400"
echo ""
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│  ที่อยู่เชื่อมต่อหลัก : ${CONNECT_ADDRESS}"
echo "│──────────────────────────────────────────────────────────────────│"
echo "│  Dropbear (SSH ตรง)    : ${CONNECT_ADDRESS}:2222, :2082, :2086, :2095"
echo "│  OpenSSH               : ${CONNECT_ADDRESS}:22"
echo "│  WebSocket (ไม่มี TLS) : ${CONNECT_ADDRESS}:443, :8443, :2053, :2083, :2087, :2096"
echo "│  Squid (CONNECT->SSH)  : ${CONNECT_ADDRESS}:80, :8080, :8880, :2052"
echo "│  UDP Custom app UDPGW  : 127.0.0.1:7300 (local)"
echo "│  UDP data plane        : ${CONNECT_ADDRESS} พอต 1-65535"
echo "│  fail2ban              : sshd(22) + dropbear(2222,2082,2086,2095)"
echo "│  TCP MSS clamp         : 1400 (กัน blackhole บนเน็ตมือถือไทย)"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${YELLOW}⚠️  แนะนำ reboot 1 ครั้งให้ BBR/cake/FD-limit apply เต็มที่: reboot${NC}"
echo -e "${CYAN}======================================================================${NC}"
#สำหร้บใช้กับHTTP CUSTOM Enable DNS✅ UDP CUSTOM✅ หลักๆทำมาใช้เองแต่เอาไปใช้ได้เน้นปิงต่ำ เล่นเกมส์ ใช้งานทั่วไป
