#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
case "$SCRIPT_PATH" in
    /proc/*|/dev/fd/*|/dev/stdin) SCRIPT_PATH="$(pwd)/vmess-ais-optimized.sh" ;;
esac

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' M='\033[0;35m'
W='\033[1;37m' DIM='\033[2m' NC='\033[0m' BOLD='\033[1m'

XRAY_PORT=10086
PANEL_PORT=2053
WS_PATH="/speedtest"
LOG=/var/log/vmess-setup.log
AIS_RTT="30ms"
GAMING_EMAIL="gaming@ais.th"
DOWNLOAD_EMAIL="download@ais.th"

TOTAL_STEPS=14
CUR_STEP=0
NIC=""
DOMAIN=""
CERT_EMAIL=""
VPS_IP=""
UUID1=""
UUID2=""
FAILED_STEPS=()
WARN_STEPS=()

_log()  { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
_info() { echo -e "${C}  ●  $*${NC}";  _log "INFO: $*"; }
_ok()   { echo -e "${G}  ✔  $*${NC}";  _log "OK: $*"; }
_warn() { echo -e "${Y}  ⚠  $*${NC}";  _log "WARN: $*"; }
_fail() { echo -e "${R}  ✘  $*${NC}";  _log "FAIL: $*"; }
_dim()  { echo -e "${DIM}     $*${NC}"; }

_step() {
    CUR_STEP=$((CUR_STEP + 1))
    local pct=$(( CUR_STEP * 100 / TOTAL_STEPS ))
    local filled=$(( pct * 24 / 100 ))
    local bar="" i
    for ((i=0; i<filled; i++));  do bar+="█"; done
    for ((i=filled; i<24; i++)); do bar+="░"; done
    echo ""
    echo -e "${BOLD}${B}┌─ [${CUR_STEP}/${TOTAL_STEPS}] $1${NC}"
    printf "${B}│${NC} ${G}%s${NC} ${DIM}%d%%${NC}\n" "$bar" "$pct"
    echo -e "${B}└${NC}"
    _log "═══ STEP ${CUR_STEP}/${TOTAL_STEPS}: $1 ═══"
}

_safe_step() {
    local name=$1; shift
    local rc=0; "$@" || rc=$?
    if [[ $rc -ne 0 ]]; then
        FAILED_STEPS+=("Step ${CUR_STEP}: ${name}")
        echo -e "${R}  ✘  Step พัง (exit $rc) — ข้ามต่อ จะสรุปตอนท้าย${NC}"
        _log "STEP FAILED: $name (exit $rc)"; return 1
    fi; return 0
}

_banner() {
    clear
    echo ""
    echo -e "${BOLD}${B}  ╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${B}  ║${NC}${BOLD}${W}    VMESS WS — AIS Mobile (Gaming + Long Download)    ${NC}${BOLD}${B}║${NC}"
    echo -e "${BOLD}${B}  ║${NC}${DIM}    2 Users · BBR + CAKE(AIS RTT) · No rate limit       ${NC}${BOLD}${B}║${NC}"
    echo -e "${BOLD}${B}  ╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}User1 → Gaming   (bufferSize=2K,  connIdle=120s)${NC}"
    echo -e "  ${DIM}User2 → Download (bufferSize=512K, connIdle=600s)${NC}"
    echo -e "  ${DIM}Log: ${LOG}${NC}"
    echo ""
}

do_detect_nic() {
    _step "ตรวจ network interface + public IP"

    NIC=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' \
        | head -1) || true
    if [[ -z "$NIC" ]]; then
        NIC=$(ip link show \
            | awk -F': ' '/^[0-9]+: (eth|ens|enp|eno)/{print $2}' \
            | grep -v lo | head -1) || true
    fi
    [[ -z "$NIC" ]] && { _fail "หา NIC ไม่เจอ"; return 1; }

    VPS_IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null \
          || curl -s --max-time 8 https://ifconfig.me 2>/dev/null \
          || ip addr show "$NIC" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    [[ -z "$VPS_IP" ]] && { _fail "หา public IP ไม่ได้"; return 1; }

    _ok "Interface: ${BOLD}${NIC}${NC}  |  IP: ${BOLD}${VPS_IP}${NC}"
}

do_get_domain() {
    _step "กรอก domain + email สำหรับ TLS"
    echo ""
    echo -e "  ${BOLD}VPS IP: ${C}${VPS_IP}${NC}"
    echo -e "  ${Y}ตรวจ A record ชี้มาที่ IP นี้ก่อนกด Enter${NC}"
    echo ""
    while true; do
        echo -ne "  ${BOLD}กรอก domain (เช่น vpn.example.com): ${NC}"
        read -r DOMAIN; [[ -n "$DOMAIN" ]] && break
        echo -e "  ${R}domain ห้ามว่าง${NC}"
    done
    while true; do
        echo -ne "  ${BOLD}กรอก email สำหรับ Let's Encrypt: ${NC}"
        read -r CERT_EMAIL
        [[ -n "$CERT_EMAIL" && "$CERT_EMAIL" == *"@"* ]] && break
        echo -e "  ${R}กรุณากรอก email จริง${NC}"
    done
    _ok "Domain: ${BOLD}${DOMAIN}${NC}"
}

do_system_update() {
    _step "System update + packages"
    export DEBIAN_FRONTEND=noninteractive

    _info "รอ apt lock..."
    local waited=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock \
                /var/lib/dpkg/lock /var/cache/apt/archives/lock \
                >/dev/null 2>&1; do
        sleep 5; waited=$((waited + 5))
        if [[ $waited -ge 120 ]]; then
            _warn "หยุด unattended-upgrades..."
            systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            sleep 3; break
        fi
    done

    echo ""
    _info "apt-get update..."
    apt-get update -y

    echo ""
    _info "apt-get upgrade..."
    apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    echo ""
    _info "ติดตั้ง packages..."
    apt-get install -y \
        curl wget unzip git socat openssl dnsutils \
        nginx certbot python3-certbot-nginx \
        iproute2 iptables nftables net-tools \
        htop iotop dstat cron logrotate ufw \
        sqlite3 build-essential python3 \
        iputils-ping

    echo ""
    _ok "Packages พร้อม"
}

do_kernel_modules() {
    _step "โหลด kernel modules (BBR + CAKE + IFB)"

    if modprobe tcp_bbr2 2>/dev/null; then
        _ok "BBR2 loaded"
        BBR_MODULE="bbr2"
    else
        modprobe tcp_bbr 2>/dev/null && _ok "BBR loaded" || _warn "BBR module ไม่มี"
        BBR_MODULE="bbr"
    fi

    for m in sch_cake ifb sch_fq nf_conntrack xt_connbytes xt_DSCP; do
        if lsmod | grep -q "^${m}"; then
            _ok "${m} loaded อยู่แล้ว"
        elif modprobe "$m" 2>/dev/null; then
            _ok "${m} loaded"
        else
            _warn "${m} ไม่มี — บาง feature อาจ fallback"
            WARN_STEPS+=("kernel module ${m} ไม่โหลด")
        fi
    done

    cat > /etc/modules-load.d/vmess-modules.conf << EOF
tcp_bbr
sch_cake
ifb
sch_fq
nf_conntrack
xt_connbytes
xt_DSCP
EOF
    _ok "Modules persisted"
}

do_install_xui() {
    _step "ติดตั้ง 3X-UI + Xray-core (official installer)"

    if command -v x-ui &>/dev/null && systemctl list-unit-files x-ui.service &>/dev/null; then
        _ok "3X-UI มีอยู่แล้ว — ข้าม"
        return 0
    fi

    echo ""
    echo -e "${Y}  (installer จะถาม — กด Enter รับ default หรือกรอกเอง)${NC}"
    echo ""

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

    local RC=$?
    echo ""
    if [[ $RC -eq 0 ]] && command -v x-ui &>/dev/null; then
        _ok "3X-UI ติดตั้งสำเร็จ"
    else
        _fail "3X-UI installer ล้มเหลว (exit $RC)"
        return 1
    fi
}

do_panel_port() {
    _step "ตั้ง panel port → ${PANEL_PORT}"
    systemctl start x-ui 2>/dev/null || true; sleep 3
    local XUI_DB="/etc/x-ui/x-ui.db"

    if command -v x-ui &>/dev/null; then
        systemctl stop x-ui 2>/dev/null || true; sleep 1
        echo ""
        x-ui setting -port "$PANEL_PORT"
        x-ui setting -username "admin"
        echo ""
        _ok "Panel port: ${PANEL_PORT}"
    elif [[ -f "$XUI_DB" ]] && command -v sqlite3 &>/dev/null; then
        systemctl stop x-ui 2>/dev/null || true; sleep 1
        sqlite3 "$XUI_DB" \
            "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';"
        _ok "Panel port (SQLite): ${PANEL_PORT}"
    else
        _warn "ตั้ง panel port อัตโนมัติไม่ได้"
        WARN_STEPS+=("Panel port ยังไม่ set — เปลี่ยนเองใน panel")
    fi
}

do_tls_cert() {
    _step "Let's Encrypt TLS สำหรับ ${DOMAIN}"

    _info "ตรวจ DNS: ${DOMAIN}"
    local RESOLVED_IP
    RESOLVED_IP=$(dig +short "$DOMAIN" A 2>/dev/null | tail -1) || RESOLVED_IP=""
    if [[ -z "$RESOLVED_IP" ]]; then
        _warn "DNS resolve ไม่ได้"
    elif [[ "$RESOLVED_IP" != "$VPS_IP" ]]; then
        _warn "DNS → ${RESOLVED_IP}  VPS → ${VPS_IP} ไม่ตรงกัน"
    else
        _ok "DNS OK: ${DOMAIN} → ${RESOLVED_IP}"
    fi

    mkdir -p /var/www/html
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/vmess
    cat > /etc/nginx/sites-available/vmess-acme << TMPEOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/html;
    location /.well-known/acme-challenge/ { allow all; }
    location / { return 444; }
}
TMPEOF
    ln -sf /etc/nginx/sites-available/vmess-acme /etc/nginx/sites-enabled/vmess-acme
    systemctl restart nginx 2>/dev/null || true; sleep 1

    echo ""
    _info "รัน certbot (webroot)..."
    echo ""
    local CERT_OK=false
    certbot certonly --webroot -w /var/www/html \
        --non-interactive --agree-tos --email "$CERT_EMAIL" \
        -d "$DOMAIN" && CERT_OK=true

    rm -f /etc/nginx/sites-enabled/vmess-acme

    local CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    if $CERT_OK && [[ -f "$CERT_PATH" ]]; then
        _ok "TLS cert ออกแล้ว (Let's Encrypt)"
        (crontab -l 2>/dev/null; \
         echo "30 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") \
            | sort -u | crontab -
        _ok "Auto-renewal cron ตั้งแล้ว"
        return 0
    fi

    _warn "certbot ล้มเหลว — สร้าง self-signed cert แทน"
    local SS_DIR="/etc/ssl/vmess"; mkdir -p "$SS_DIR"
    echo ""
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${SS_DIR}/privkey.pem" -out "${SS_DIR}/fullchain.pem" \
        -days 3650 -subj "/CN=${DOMAIN}"
    echo ""

    if [[ -f "${SS_DIR}/fullchain.pem" ]]; then
        mkdir -p "/etc/letsencrypt/live/${DOMAIN}"
        ln -sf "${SS_DIR}/fullchain.pem" "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
        ln -sf "${SS_DIR}/privkey.pem"   "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
        _ok "Self-signed cert พร้อม"
        WARN_STEPS+=("ใช้ self-signed cert — รัน: bash ${SCRIPT_PATH} certbot-renew ${DOMAIN}")
    else
        _fail "self-signed cert ล้มเหลว"; return 1
    fi
}

do_nginx_config() {
    _step "Nginx — WS proxy + TLS config"

    local CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    local KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
    local NGINX_SITE="/etc/nginx/sites-available/vmess"

    rm -f /etc/nginx/sites-enabled/default \
          /etc/nginx/sites-available/vmess-acme \
          /etc/nginx/sites-enabled/vmess-acme

    grep -q "worker_rlimit_nofile" /etc/nginx/nginx.conf || \
        sed -i '/^worker_processes/a worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
    sed -i 's/keepalive_timeout\s\+[0-9]\+/keepalive_timeout 3600/' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i 's/^\s*gzip\s\+on\s*;/\tgzip off;/' /etc/nginx/nginx.conf 2>/dev/null || true
    grep -q "server_tokens" /etc/nginx/nginx.conf || \
        sed -i '/keepalive_timeout/a\\tserver_tokens off;' /etc/nginx/nginx.conf

    cat > "$NGINX_SITE" << NGINXEOF
upstream xray_ws {
    server 127.0.0.1:${XRAY_PORT};
    keepalive 8;
    keepalive_requests 0;
    keepalive_timeout 3600s;
}

server {
    listen 80;
    server_name ${DOMAIN};

    location ${WS_PATH} {
        proxy_pass              http://xray_ws;
        proxy_http_version      1.1;
        proxy_set_header        Upgrade \$http_upgrade;
        proxy_set_header        Connection "upgrade";
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout      86400s;
        proxy_send_timeout      86400s;
        proxy_connect_timeout   10s;
        tcp_nodelay             on;
    }

    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate         ${CERT_PATH};
    ssl_certificate_key     ${KEY_PATH};
    ssl_protocols           TLSv1.2 TLSv1.3;
    ssl_ciphers             TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache       shared:SSL:10m;
    ssl_session_timeout     24h;
    ssl_session_tickets     on;
    ssl_stapling            on;
    ssl_stapling_verify     on;
    resolver                1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout        5s;

    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }

    location ${WS_PATH} {
        proxy_pass              http://xray_ws;
        proxy_http_version      1.1;
        proxy_set_header        Upgrade \$http_upgrade;
        proxy_set_header        Connection "upgrade";
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto https;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout      86400s;
        proxy_send_timeout      86400s;
        proxy_connect_timeout   10s;
        tcp_nodelay             on;
        proxy_socket_keepalive  on;
    }
}
NGINXEOF

    ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/vmess

    echo ""
    _info "ตรวจ nginx config..."
    if nginx -t 2>&1; then
        echo ""
        _ok "Nginx config ผ่าน"
    else
        echo ""
        _fail "Nginx config ผิดพลาด — ดู error ด้านบน"
        return 1
    fi
}

do_xray_config() {
    _step "Xray VMESS WS — dual-policy (gaming + download)"

    local XCONF_DIR="/usr/local/etc/xray"
    local XUI_DB="/etc/x-ui/x-ui.db"
    mkdir -p "$XCONF_DIR" /var/log/xray

    UUID1=$(cat /proc/sys/kernel/random/uuid)
    UUID2=$(cat /proc/sys/kernel/random/uuid)

    _info "เขียน Xray config..."
    echo ""

    cat > "${XCONF_DIR}/config.json.template" << XRAYEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },

  "inbounds": [{
    "tag":      "vmess-ws",
    "port":     ${XRAY_PORT},
    "listen":   "127.0.0.1",
    "protocol": "vmess",

    "settings": {
      "clients": [
        {
          "id":      "${UUID1}",
          "alterId": 0,
          "email":   "${GAMING_EMAIL}",
          "level":   1
        },
        {
          "id":      "${UUID2}",
          "alterId": 0,
          "email":   "${DOWNLOAD_EMAIL}",
          "level":   2
        }
      ],
      "disableInsecureEncryption": true
    },

    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path":    "${WS_PATH}",
        "headers": { "Host": "${DOMAIN}" }
      },
      "sockopt": {
        "tcpKeepAliveInterval": 15,
        "tcpKeepAliveIdle":     30,
        "tcpFastOpen":          true
      }
    },

    "sniffing": {
      "enabled":      true,
      "destOverride": ["http", "tls"],
      "routeOnly":    false
    }
  }],

  "outbounds": [
    {
      "tag":      "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    {
      "tag":      "block",
      "protocol": "blackhole",
      "settings": {}
    }
  ],

  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "outboundTag": "direct" }
    ]
  },

  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  },

  "policy": {
    "levels": {
      "1": {
        "handshakeSec":  4,
        "connIdle":      120,
        "uplinkOnly":    2,
        "downlinkOnly":  10,
        "bufferSize":    2
      },
      "2": {
        "handshakeSec":  4,
        "connIdle":      600,
        "uplinkOnly":    10,
        "downlinkOnly":  60,
        "bufferSize":    512
      }
    },
    "system": {
      "statsInboundUplink":   true,
      "statsInboundDownlink": true
    }
  }
}
XRAYEOF

    cat "${XCONF_DIR}/config.json.template"
    echo ""

    local INJECT_OK=false

    if [[ -f "$XUI_DB" ]] && command -v sqlite3 &>/dev/null; then
        _info "Inject dual-policy inbound เข้า 3X-UI DB..."
        echo ""

        local HAS_ALLOCATE
        HAS_ALLOCATE=$(sqlite3 "$XUI_DB" \
            "SELECT COUNT(*) FROM pragma_table_info('inbounds') WHERE name='allocate';" 2>/dev/null) || HAS_ALLOCATE=0

        local IB; IB="{\"clients\":["
        IB+=" {\"id\":\"${UUID1}\",\"alterId\":0,\"email\":\"${GAMING_EMAIL}\",\"level\":1},"
        IB+=" {\"id\":\"${UUID2}\",\"alterId\":0,\"email\":\"${DOWNLOAD_EMAIL}\",\"level\":2}"
        IB+="],\"disableInsecureEncryption\":true}"

        local SS; SS="{\"network\":\"ws\",\"security\":\"none\","
        SS+="\"wsSettings\":{\"path\":\"${WS_PATH}\",\"headers\":{\"Host\":\"${DOMAIN}\"}},"
        SS+="\"sockopt\":{\"tcpKeepAliveInterval\":15,\"tcpKeepAliveIdle\":30,\"tcpFastOpen\":true}}"

        local SN='{"enabled":true,"destOverride":["http","tls"],"routeOnly":false}'

        cp "$XUI_DB" "${XUI_DB}.bak.$(date +%s)"

        local SQL_RC=0
        if [[ "$HAS_ALLOCATE" -gt 0 ]]; then
            sqlite3 "$XUI_DB" << SQLEOF || SQL_RC=$?
DELETE FROM inbounds WHERE port = ${XRAY_PORT};
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing, allocate)
VALUES (1, 0, 0, 0, 'vmess-ws-ais-dual', 1, 0, '127.0.0.1', ${XRAY_PORT}, 'vmess', '${IB}', '${SS}', 'vmess-ws', '${SN}', '{}');
SQLEOF
        else
            sqlite3 "$XUI_DB" << SQLEOF || SQL_RC=$?
DELETE FROM inbounds WHERE port = ${XRAY_PORT};
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (1, 0, 0, 0, 'vmess-ws-ais-dual', 1, 0, '127.0.0.1', ${XRAY_PORT}, 'vmess', '${IB}', '${SS}', 'vmess-ws', '${SN}');
SQLEOF
        fi

        if [[ $SQL_RC -eq 0 ]]; then
            INJECT_OK=true
            _ok "Inject เข้า 3X-UI DB สำเร็จ"
        else
            _warn "SQLite inject ล้มเหลว (exit ${SQL_RC}) — fallback direct config"
        fi
    else
        _warn "3X-UI DB ยังไม่มี — ใช้ config ตรง"
    fi

    if [[ "$INJECT_OK" == "false" ]]; then
        cp "${XCONF_DIR}/config.json.template" "${XCONF_DIR}/config.json"
        local XUI_BIN="/usr/local/x-ui/bin/config.json"
        [[ -d "/usr/local/x-ui/bin" ]] && cp "${XCONF_DIR}/config.json.template" "$XUI_BIN"
        WARN_STEPS+=("Xray config เขียนตรง — ตรวจใน panel ถ้า inbound หาย")
    fi

    echo ""
    _ok "Xray dual-policy config พร้อม"
    _dim "Gaming  UUID (level 1): ${UUID1}"
    _dim "Download UUID (level 2): ${UUID2}"
}

do_sysctl() {
    _step "sysctl — BBR + AIS mobile tuning (ไม่จำกัด throughput)"

    local BBR_CC="bbr"
    sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr2 && BBR_CC="bbr2"
    _dim "Congestion control: ${BBR_CC}"
    echo ""

    cat > /etc/sysctl.d/99-vmess-ais.conf << SYSCTLEOF
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = ${BBR_CC}

net.ipv4.tcp_notsent_lowat = 16384

net.core.rmem_default = 262144
net.core.rmem_max     = 4194304
net.core.wmem_default = 262144
net.core.wmem_max     = 4194304
net.ipv4.tcp_rmem = 4096  131072  4194304
net.ipv4.tcp_wmem = 4096  32768   4194304

net.ipv4.tcp_keepalive_time   = 30
net.ipv4.tcp_keepalive_intvl  = 5
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_ecn            = 1
net.ipv4.tcp_retries1       = 3
net.ipv4.tcp_retries2       = 8
net.ipv4.tcp_syn_retries    = 4
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_mtu_probing    = 1
net.ipv4.tcp_base_mss       = 1024

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen              = 3
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_fin_timeout           = 20

net.core.busy_poll         = 50
net.core.busy_read         = 50
net.core.netdev_budget     = 600
net.core.somaxconn         = 512
net.ipv4.tcp_max_syn_backlog = 256
net.core.netdev_max_backlog  = 2000

vm.swappiness             = 10
vm.dirty_ratio            = 20
vm.dirty_background_ratio = 5

net.ipv4.ip_forward             = 1
net.ipv4.conf.all.rp_filter     = 1
net.ipv4.conf.default.rp_filter = 1
SYSCTLEOF

    if modprobe nf_conntrack 2>/dev/null; then
        cat >> /etc/sysctl.d/99-vmess-ais.conf << 'CTEOF'
net.netfilter.nf_conntrack_max                     = 16384
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 20
CTEOF
    fi

    echo ""
    _info "Apply sysctl..."
    echo ""
    sysctl --system

    sysctl -w "net.ipv4.tcp_congestion_control=${BBR_CC}" 2>/dev/null || \
        sysctl -w "net.ipv4.tcp_congestion_control=bbr"   2>/dev/null || \
        WARN_STEPS+=("BBR CC apply ล้มเหลว")

    echo ""
    _ok "sysctl applied"
    _dim "cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)  notsent_lowat=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)"
}

do_cake_aqm() {
    _step "CAKE AQM — AIS RTT ${AIS_RTT}, diffserv4, ไม่จำกัด bandwidth"

    local CAKE_SCRIPT="/usr/local/bin/vmess-cake.sh"

    local RTT_SUPPORT=false
    if tc qdisc add dev lo root cake rtt 30ms 2>/dev/null; then
        tc qdisc del dev lo root 2>/dev/null || true
        RTT_SUPPORT=true
    fi

    local EGRESS_OPTS INGRESS_OPTS
    if $RTT_SUPPORT; then
        EGRESS_OPTS="diffserv4 dual-dsthost wash ack-filter rtt ${AIS_RTT}"
        INGRESS_OPTS="diffserv4 dual-srchost wash ingress rtt ${AIS_RTT}"
    else
        EGRESS_OPTS="diffserv4 dual-dsthost wash ack-filter"
        INGRESS_OPTS="diffserv4 dual-srchost wash ingress"
    fi

    _dim "Egress : ${EGRESS_OPTS}"
    _dim "Ingress: ${INGRESS_OPTS}"
    echo ""

    cat > "$CAKE_SCRIPT" << CAKEOF
#!/usr/bin/env bash
set -euo pipefail

log() { logger -t vmess-cake "\$*" 2>/dev/null || true; }

NIC="\$(ip route get 1.1.1.1 2>/dev/null \
    | awk '/dev/{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' | head -1)"
[[ -z "\$NIC" ]] && { log "NIC not found"; exit 1; }

echo "=== CAKE AQM: \$NIC ==="

tc qdisc del dev "\$NIC" root 2>/dev/null || true
if tc qdisc add dev "\$NIC" root cake ${EGRESS_OPTS} 2>/dev/null; then
    log "CAKE egress OK: \$NIC"
    echo "  Egress CAKE: OK"
else
    tc qdisc add dev "\$NIC" root fq_codel 2>/dev/null && \
        { log "fq_codel fallback"; echo "  Egress fq_codel (fallback)"; } || true
fi

if lsmod | grep -q "^ifb"; then
    ip link add ifb0 type ifb 2>/dev/null || true
    ip link set ifb0 up
    tc qdisc del dev "\$NIC" ingress 2>/dev/null || true
    tc qdisc add dev "\$NIC" handle ffff: ingress
    tc filter add dev "\$NIC" parent ffff: protocol all u32 \
        match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || true
    tc qdisc del dev ifb0 root 2>/dev/null || true
    if tc qdisc add dev ifb0 root cake ${INGRESS_OPTS} 2>/dev/null; then
        log "CAKE ingress OK: ifb0"
        echo "  Ingress CAKE: OK (ifb0)"
    else
        tc qdisc add dev ifb0 root fq_codel 2>/dev/null || true
        echo "  Ingress fq_codel (fallback)"
    fi
else
    echo "  Ingress: IFB ไม่มี — egress only"
fi

echo "=== Done ==="
CAKEOF
    chmod +x "$CAKE_SCRIPT"

    cat > /etc/systemd/system/vmess-cake.service << 'SVCEOF'
[Unit]
Description=CAKE AQM — VMESS AIS Mobile
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vmess-cake.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable vmess-cake.service

    echo ""
    _info "Apply CAKE..."
    echo ""
    bash "$CAKE_SCRIPT"
    local CAKE_RC=$?
    echo ""

    sleep 1
    local ACTIVE_QDISC
    ACTIVE_QDISC=$(tc qdisc show dev "$NIC" 2>/dev/null | awk 'NR==1{print $2}')

    if [[ $CAKE_RC -eq 0 ]]; then
        _ok "AQM active: ${ACTIVE_QDISC:-applied} บน ${NIC}"
    else
        _warn "CAKE ล้มเหลว — fallback fq_codel"
        tc qdisc del dev "$NIC" root 2>/dev/null || true
        tc qdisc add dev "$NIC" root fq_codel 2>/dev/null && _ok "fq_codel fallback" || true
        WARN_STEPS+=("CAKE ล้มเหลว — ใช้ fq_codel แทน")
    fi
}

do_dscp_qos() {
    _step "DSCP QoS — gaming AF41 / download CS1"

    local QOS_SCRIPT="/usr/local/bin/vmess-qos.sh"
    cat > "$QOS_SCRIPT" << QOSEOF
#!/usr/bin/env bash
set -euo pipefail
log() { logger -t vmess-qos "\$*" 2>/dev/null || true; }

IPT="iptables"
chain="VMESS_DSCP"

\$IPT -t mangle -F "\$chain" 2>/dev/null || true
\$IPT -t mangle -D OUTPUT -j "\$chain" 2>/dev/null || true
\$IPT -t mangle -X "\$chain" 2>/dev/null || true
\$IPT -t mangle -N "\$chain"
\$IPT -t mangle -A OUTPUT -j "\$chain"

\$IPT -t mangle -A "\$chain" \
    -p tcp --sport ${XRAY_PORT} \
    -m connbytes --connbytes 0:65535 --connbytes-dir both --connbytes-mode bytes \
    -j DSCP --set-dscp-class AF41

\$IPT -t mangle -A "\$chain" \
    -p tcp --sport ${XRAY_PORT} \
    -m connbytes --connbytes 65536: --connbytes-dir both --connbytes-mode bytes \
    -j DSCP --set-dscp-class CS1

\$IPT -t mangle -A "\$chain" \
    -p tcp --dport 443 \
    -m connbytes --connbytes 65536: --connbytes-dir both --connbytes-mode bytes \
    -j DSCP --set-dscp-class CS1

log "DSCP rules installed"
echo "DSCP QoS: OK"
QOSEOF
    chmod +x "$QOS_SCRIPT"

    cat > /etc/systemd/system/vmess-qos.service << 'QSVCEOF'
[Unit]
Description=DSCP QoS — VMESS AIS Gaming/Download
After=network-online.target vmess-cake.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vmess-qos.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
QSVCEOF

    systemctl daemon-reload
    systemctl enable vmess-qos.service

    echo ""
    if modprobe xt_connbytes 2>/dev/null && modprobe xt_DSCP 2>/dev/null; then
        _info "Apply DSCP rules..."
        echo ""
        bash "$QOS_SCRIPT"
        echo ""
        if iptables -t mangle -L VMESS_DSCP -n 2>/dev/null | grep -q DSCP; then
            _ok "DSCP marking active"
            _dim "Flow < 64KB → AF41 (gaming)"
            _dim "Flow > 64KB → CS1  (download bulk)"
        else
            _warn "DSCP apply แล้วแต่ verify ไม่ได้"
        fi
    else
        _warn "xt_connbytes/xt_DSCP ไม่มี — ข้าม DSCP"
        _dim "CAKE ยังทำงานได้ใน best-effort mode"
        WARN_STEPS+=("DSCP kernel modules ไม่มี — ใช้ CAKE best-effort")
    fi
}

do_limits() {
    _step "System limits — file descriptors"

    cat > /etc/security/limits.d/99-vmess.conf << 'LIMEOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
*    soft nproc  4096
*    hard nproc  8192
LIMEOF

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/vmess-limits.conf << 'SDLIMEOF'
[Manager]
DefaultLimitNOFILE=65535
DefaultLimitNPROC=8192
SDLIMEOF

    systemctl daemon-reload
    echo ""
    _ok "Limits: 65535 fd"
}

do_firewall_and_start() {
    _step "Firewall (ufw) + เปิด services"

    _info "ตั้ง UFW..."
    echo ""
    ufw --force reset
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "${PANEL_PORT}/tcp"
    ufw --force enable
    echo ""
    _ok "UFW: 22, 80, 443, ${PANEL_PORT}"

    echo ""
    _info "Apply DSCP QoS..."
    echo ""
    bash /usr/local/bin/vmess-qos.sh 2>/dev/null || true

    echo ""
    _info "Start Nginx..."
    echo ""
    systemctl restart nginx
    if systemctl is-active --quiet nginx; then
        systemctl enable nginx
        _ok "Nginx started"
    else
        _fail "Nginx ไม่ start"
        journalctl -u nginx -n 20 --no-pager
        return 1
    fi

    echo ""
    _info "Start x-ui..."
    echo ""
    systemctl restart x-ui
    sleep 3
    if systemctl is-active --quiet x-ui; then
        systemctl enable x-ui
        _ok "x-ui started"
    else
        _fail "x-ui ไม่ start"
        journalctl -u x-ui -n 20 --no-pager
        return 1
    fi
}

do_summary() {
    echo ""
    echo -e "${BOLD}${G}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${G}║                    HEALTH CHECK                           ║${NC}"
    echo -e "${BOLD}${G}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    sleep 2

    for svc in nginx x-ui; do
        systemctl is-active --quiet "$svc" && \
            echo -e "  ${G}✔ $svc running${NC}" || \
            echo -e "  ${R}✘ $svc ไม่ running  → journalctl -u $svc -n 20${NC}"
    done

    for port in 80 443 "$PANEL_PORT" "$XRAY_PORT"; do
        ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]" && \
            echo -e "  ${G}✔ port $port listening${NC}" || \
            echo -e "  ${Y}⚠ port $port ไม่ listening${NC}"
    done

    if [[ -n "$NIC" ]]; then
        local ACTIVE_QDISC
        ACTIVE_QDISC=$(tc qdisc show dev "$NIC" 2>/dev/null | awk 'NR==1{print $2}')
        [[ -n "$ACTIVE_QDISC" ]] && \
            echo -e "  ${G}✔ AQM: ${ACTIVE_QDISC} บน ${NIC}${NC}" || \
            echo -e "  ${Y}⚠ AQM ไม่ active${NC}"
    fi

    local CC; CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || CC="?"
    [[ "$CC" == "bbr" || "$CC" == "bbr2" ]] && \
        echo -e "  ${G}✔ CC: ${CC}${NC}" || \
        echo -e "  ${Y}⚠ cc=${CC} (BBR preferred)${NC}"

    iptables -t mangle -L VMESS_DSCP -n 2>/dev/null | grep -q DSCP && \
        echo -e "  ${G}✔ DSCP QoS active${NC}" || \
        echo -e "  ${Y}⚠ DSCP rules ไม่ active${NC}"

    local XUI_DB="/etc/x-ui/x-ui.db"
    if [[ -f "$XUI_DB" ]] && command -v sqlite3 &>/dev/null; then
        local IBC
        IBC=$(sqlite3 "$XUI_DB" \
            "SELECT COUNT(*) FROM inbounds WHERE port=${XRAY_PORT};" 2>/dev/null) || IBC=0
        [[ "$IBC" -gt 0 ]] && \
            echo -e "  ${G}✔ 3X-UI inbound OK${NC}" || \
            echo -e "  ${Y}⚠ inbound ไม่พบ → bash ${SCRIPT_PATH} inject-inbound${NC}"
    fi

    [[ ${#FAILED_STEPS[@]} -gt 0 ]] && {
        echo ""; echo -e "  ${R}${BOLD}━━ Failed Steps ━━${NC}"
        for f in "${FAILED_STEPS[@]}"; do echo -e "  ${R}✘ ${f}${NC}"; done
    }
    [[ ${#WARN_STEPS[@]} -gt 0 ]] && {
        echo ""; echo -e "  ${Y}${BOLD}━━ Warnings ━━${NC}"
        for w in "${WARN_STEPS[@]}"; do echo -e "  ${Y}⚠ ${w}${NC}"; done
    }

    echo ""
    echo -e "${BOLD}${G}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${G}║                  CONNECTION INFO                          ║${NC}"
    echo -e "${BOLD}${G}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}3X-UI Panel:${NC}  ${C}http://${VPS_IP}:${PANEL_PORT}${NC}"
    echo -e "  ${Y}  Default login: admin / admin — เปลี่ยนทันที!${NC}"
    echo ""
    echo -e "  ${BOLD}${M}User 1 — GAMING (4G AIS):${NC}"
    echo -e "    Protocol : VMESS"
    echo -e "    Address  : ${C}${DOMAIN}${NC}"
    echo -e "    Port     : 443"
    echo -e "    UUID     : ${C}${UUID1}${NC}"
    echo -e "    AlterID  : 0"
    echo -e "    Security : auto"
    echo -e "    Network  : ws"
    echo -e "    WS Path  : ${WS_PATH}"
    echo -e "    TLS      : tls  |  SNI: ${DOMAIN}"
    echo -e "    ${DIM}bufferSize=2KiB, connIdle=120s${NC}"
    echo ""
    echo -e "  ${BOLD}${C}User 2 — DOWNLOAD (5G AIS):${NC}"
    echo -e "    Protocol : VMESS"
    echo -e "    Address  : ${C}${DOMAIN}${NC}"
    echo -e "    Port     : 443"
    echo -e "    UUID     : ${C}${UUID2}${NC}"
    echo -e "    AlterID  : 0"
    echo -e "    Security : auto"
    echo -e "    Network  : ws"
    echo -e "    WS Path  : ${WS_PATH}"
    echo -e "    TLS      : tls  |  SNI: ${DOMAIN}"
    echo -e "    ${DIM}bufferSize=512KiB, connIdle=600s${NC}"
    echo ""
    echo -e "  ${BOLD}Port 80 fallback (AIS block 443):${NC}  Port=80, TLS=none, UUID เดิม"
    echo ""

    local INFO_FILE="/root/vmess-info.txt"
    {
        echo "VMESS WS AIS — Gaming + Download  [$(date)]"
        echo "========================================================"
        echo "Domain: ${DOMAIN}  |  VPS: ${VPS_IP}"
        echo "Panel : http://${VPS_IP}:${PANEL_PORT}  (admin/admin — เปลี่ยนด้วย!)"
        echo ""
        echo "USER 1 — GAMING (4G)"
        echo "  address=${DOMAIN}  port=443  uuid=${UUID1}"
        echo "  alterId=0  security=auto  network=ws  path=${WS_PATH}  tls=tls  sni=${DOMAIN}"
        echo ""
        echo "USER 2 — DOWNLOAD (5G)"
        echo "  address=${DOMAIN}  port=443  uuid=${UUID2}"
        echo "  alterId=0  security=auto  network=ws  path=${WS_PATH}  tls=tls  sni=${DOMAIN}"
        echo ""
        echo "PORT 80 fallback: port=80, tls=none"
        [[ ${#FAILED_STEPS[@]} -gt 0 ]] && {
            echo ""; echo "FAILED:"; for f in "${FAILED_STEPS[@]}"; do echo "  $f"; done
        }
    } > "$INFO_FILE"

    echo -e "  บันทึก: ${C}${INFO_FILE}${NC}"
    echo ""
    [[ ${#FAILED_STEPS[@]} -eq 0 ]] && \
        echo -e "${BOLD}${G}  ✔ Setup เสร็จสมบูรณ์!${NC}" || \
        echo -e "${BOLD}${Y}  ⚠ เสร็จแต่มี ${#FAILED_STEPS[@]} step พัง — ดูด้านบน${NC}"
    echo ""
    echo -e "  ${DIM}sudo bash ${SCRIPT_PATH} monitor${NC}"
    echo -e "  ${DIM}sudo bash ${SCRIPT_PATH} qos${NC}"
    echo -e "  ${DIM}sudo bash ${SCRIPT_PATH} inject-inbound${NC}"
    echo -e "  ${DIM}sudo bash ${SCRIPT_PATH} rollback${NC}"
    echo ""
}

do_monitor() {
    local NIC_M
    NIC_M=$(ip route get 1.1.1.1 2>/dev/null | \
        awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1) || true

    while true; do
        clear
        echo -e "${BOLD}${B}╔═══════════════════════════════════════════════════════╗${NC}"
        printf "${BOLD}${B}║${NC}${BOLD}  VMESS AIS Monitor   %s  ${BOLD}${B}║${NC}\n" "$(date '+%H:%M:%S')"
        echo -e "${BOLD}${B}╚═══════════════════════════════════════════════════════╝${NC}"
        echo ""

        echo -e "${BOLD}  Services:${NC}"
        for svc in nginx x-ui; do
            systemctl is-active --quiet "$svc" && \
                printf "    ${G}✔ %-10s running${NC}\n" "$svc" || \
                printf "    ${R}✘ %-10s DEAD${NC}\n" "$svc"
        done

        echo ""
        echo -e "${BOLD}  Connections:${NC}"
        local WS_C HTTPS_C ESTAB
        WS_C=$(ss -tnp 2>/dev/null | grep -c ":${XRAY_PORT}[[:space:]]" || echo 0)
        HTTPS_C=$(ss -tnp 2>/dev/null | grep -c ":443[[:space:]]" || echo 0)
        ESTAB=$(ss -tn 2>/dev/null | grep -c ESTAB || echo 0)
        echo -e "    Xray WS (${XRAY_PORT})  : ${C}${WS_C}${NC}"
        echo -e "    HTTPS (443)      : ${C}${HTTPS_C}${NC}"
        echo -e "    TCP ESTABLISHED  : ${C}${ESTAB}${NC}"

        echo ""
        echo -e "${BOLD}  Throughput (1s):${NC}"
        local R1 T1 R2 T2
        R1=$(cat "/sys/class/net/${NIC_M}/statistics/rx_bytes" 2>/dev/null || echo 0)
        T1=$(cat "/sys/class/net/${NIC_M}/statistics/tx_bytes" 2>/dev/null || echo 0)
        sleep 1
        R2=$(cat "/sys/class/net/${NIC_M}/statistics/rx_bytes" 2>/dev/null || echo 0)
        T2=$(cat "/sys/class/net/${NIC_M}/statistics/tx_bytes" 2>/dev/null || echo 0)
        printf "    RX: ${C}%6d kbps${NC}   TX: ${C}%6d kbps${NC}\n" \
            "$(( (R2-R1)*8/1024 ))" "$(( (T2-T1)*8/1024 ))"

        echo ""
        echo -e "${BOLD}  AQM / QoS:${NC}"
        local QDISC_NOW
        QDISC_NOW=$(tc qdisc show dev "$NIC_M" 2>/dev/null | awk 'NR==1{print $2}')
        [[ -n "$QDISC_NOW" ]] && \
            echo -e "    ${G}✔ ${QDISC_NOW} บน ${NIC_M}${NC}" || \
            echo -e "    ${Y}⚠ qdisc ไม่ active${NC}"
        local DSCP_RULES
        DSCP_RULES=$(iptables -t mangle -L VMESS_DSCP --line-numbers 2>/dev/null | grep -c DSCP || echo 0)
        echo -e "    DSCP rules: ${C}${DSCP_RULES}${NC} active"

        echo ""
        echo -e "${BOLD}  TCP:${NC}"
        local CC NL RT
        CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || CC="?"
        NL=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null) || NL="?"
        RT=$(awk '/^Tcp:/{getline; print $13}' /proc/net/snmp 2>/dev/null || echo 0)
        echo -e "    cc=${CC}  notsent_lowat=${NL}  retransmits=${RT}"

        echo ""
        local MF MT
        MF=$(free -m | awk '/^Mem:/{print $4}')
        MT=$(free -m | awk '/^Mem:/{print $2}')
        echo -e "${BOLD}  Memory:${NC}  ${C}${MF}/${MT} MB free${NC}"
        echo ""
        echo -e "  ${DIM}Ctrl+C เพื่อออก${NC}"
        sleep 1
    done
}

do_qos_stats() {
    local NIC_Q
    NIC_Q=$(ip route get 1.1.1.1 2>/dev/null | \
        awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1) || true

    echo ""
    echo -e "${BOLD}QoS Stats — ${NIC_Q}${NC}"
    echo ""
    echo -e "${BOLD}  Egress CAKE (${NIC_Q}):${NC}"
    tc -s qdisc show dev "$NIC_Q" 2>/dev/null | sed 's/^/    /'
    echo ""
    if ip link show ifb0 &>/dev/null; then
        echo -e "${BOLD}  Ingress CAKE (ifb0):${NC}"
        tc -s qdisc show dev ifb0 2>/dev/null | sed 's/^/    /'
        echo ""
    fi
    echo -e "${BOLD}  DSCP rules:${NC}"
    iptables -t mangle -L VMESS_DSCP -v --line-numbers 2>/dev/null | sed 's/^/    /'
    echo ""
    echo -e "${BOLD}  TCP:${NC}"
    sysctl net.ipv4.tcp_congestion_control | sed 's/^/    /'
    sysctl net.ipv4.tcp_notsent_lowat      | sed 's/^/    /'
    sysctl net.core.default_qdisc          | sed 's/^/    /'
}

do_status() {
    echo ""
    echo -e "${BOLD}Quick Status:${NC}"; echo ""
    local NIC_S
    NIC_S=$(ip route get 1.1.1.1 2>/dev/null | \
        awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1) || true

    for svc in nginx x-ui; do
        systemctl is-active --quiet "$svc" && \
            echo -e "  ${G}✔ $svc${NC}" || echo -e "  ${R}✘ $svc${NC}"
    done
    for port in 80 443 "$PANEL_PORT" "$XRAY_PORT"; do
        ss -tlnp 2>/dev/null | grep -q ":${port}[[:space:]]" && \
            echo -e "  ${G}✔ port $port${NC}" || echo -e "  ${Y}⚠ port $port ไม่ listen${NC}"
    done
    [[ -n "$NIC_S" ]] && {
        local QDISC_S; QDISC_S=$(tc qdisc show dev "$NIC_S" 2>/dev/null | awk 'NR==1{print $2}')
        [[ -n "$QDISC_S" ]] && \
            echo -e "  ${G}✔ AQM: ${QDISC_S} บน ${NIC_S}${NC}" || echo -e "  ${Y}⚠ AQM ไม่ active${NC}"
    }
    local CC; CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || CC="?"
    [[ "$CC" == "bbr" || "$CC" == "bbr2" ]] && echo -e "  ${G}✔ ${CC}${NC}" || echo -e "  ${Y}⚠ cc=${CC}${NC}"
    iptables -t mangle -L VMESS_DSCP -n 2>/dev/null | grep -q DSCP && \
        echo -e "  ${G}✔ DSCP QoS active${NC}" || echo -e "  ${Y}⚠ DSCP ไม่ active${NC}"
    local XUI_DB="/etc/x-ui/x-ui.db"
    [[ -f "$XUI_DB" ]] && command -v sqlite3 &>/dev/null && {
        local IBC; IBC=$(sqlite3 "$XUI_DB" \
            "SELECT COUNT(*) FROM inbounds WHERE port=${XRAY_PORT};" 2>/dev/null) || IBC=0
        [[ "$IBC" -gt 0 ]] && echo -e "  ${G}✔ 3X-UI inbound OK (${IBC})${NC}" || \
            echo -e "  ${Y}⚠ inbound ไม่พบ → bash ${SCRIPT_PATH} inject-inbound${NC}"
    }
    echo ""
    [[ -f /root/vmess-info.txt ]] && cat /root/vmess-info.txt
}

do_inject_inbound() {
    local XUI_DB="/etc/x-ui/x-ui.db"
    local XCONF_DIR="/usr/local/etc/xray"
    echo ""; echo -e "${BOLD}Re-inject inbound เข้า 3X-UI database${NC}"; echo ""

    if [[ -z "${UUID1:-}" || -z "${UUID2:-}" ]]; then
        if [[ -f "${XCONF_DIR}/config.json.template" ]]; then
            UUID1=$(grep -oP '"id":\s*"\K[^"]+' "${XCONF_DIR}/config.json.template" | head -1) || true
            UUID2=$(grep -oP '"id":\s*"\K[^"]+' "${XCONF_DIR}/config.json.template" | sed -n '2p') || true
            DOMAIN=$(grep -oP '"Host":\s*"\K[^"]+' "${XCONF_DIR}/config.json.template" | head -1) || true
        fi
    fi
    [[ -z "${UUID1:-}" ]] && { echo -e "${R}ไม่พบ UUID — รัน install ก่อน${NC}"; return 1; }
    [[ -f "$XUI_DB" ]] || { echo -e "${R}3X-UI DB ไม่พบ${NC}"; return 1; }
    command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 >> "$LOG" 2>&1

    cp "$XUI_DB" "${XUI_DB}.bak.$(date +%s)"

    local HAS_ALLOCATE
    HAS_ALLOCATE=$(sqlite3 "$XUI_DB" \
        "SELECT COUNT(*) FROM pragma_table_info('inbounds') WHERE name='allocate';" 2>/dev/null) || HAS_ALLOCATE=0

    local IB; IB="{\"clients\":["
    IB+=" {\"id\":\"${UUID1}\",\"alterId\":0,\"email\":\"${GAMING_EMAIL}\",\"level\":1},"
    IB+=" {\"id\":\"${UUID2}\",\"alterId\":0,\"email\":\"${DOWNLOAD_EMAIL}\",\"level\":2}"
    IB+="],\"disableInsecureEncryption\":true}"

    local SS; SS="{\"network\":\"ws\",\"security\":\"none\","
    SS+="\"wsSettings\":{\"path\":\"${WS_PATH}\",\"headers\":{\"Host\":\"${DOMAIN}\"}},"
    SS+="\"sockopt\":{\"tcpKeepAliveInterval\":15,\"tcpKeepAliveIdle\":30,\"tcpFastOpen\":true}}"

    local SN='{"enabled":true,"destOverride":["http","tls"],"routeOnly":false}'

    echo ""
    if [[ "$HAS_ALLOCATE" -gt 0 ]]; then
        sqlite3 "$XUI_DB" << SQLEOF
DELETE FROM inbounds WHERE port = ${XRAY_PORT};
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing, allocate)
VALUES (1, 0, 0, 0, 'vmess-ws-ais-dual', 1, 0, '127.0.0.1', ${XRAY_PORT}, 'vmess', '${IB}', '${SS}', 'vmess-ws', '${SN}', '{}');
SQLEOF
    else
        sqlite3 "$XUI_DB" << SQLEOF
DELETE FROM inbounds WHERE port = ${XRAY_PORT};
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (1, 0, 0, 0, 'vmess-ws-ais-dual', 1, 0, '127.0.0.1', ${XRAY_PORT}, 'vmess', '${IB}', '${SS}', 'vmess-ws', '${SN}');
SQLEOF
    fi
    echo ""
    echo -e "${G}  ✔ Inject สำเร็จ — restarting x-ui${NC}"
    systemctl restart x-ui
    echo -e "${G}  ✔ x-ui restarted${NC}"
}

do_rollback() {
    echo ""; echo -e "${BOLD}${Y}Rollback — ลบ CAKE + DSCP + sysctl${NC}"; echo ""
    echo -ne "  Continue? [y/N]: "; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }

    local NIC_R
    NIC_R=$(ip route get 1.1.1.1 2>/dev/null | \
        awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1) || true

    echo ""
    iptables -t mangle -F VMESS_DSCP 2>/dev/null && echo -e "  ${G}✔ DSCP flushed${NC}" || true
    iptables -t mangle -D OUTPUT -j VMESS_DSCP 2>/dev/null || true
    iptables -t mangle -X VMESS_DSCP 2>/dev/null || true
    echo -e "  ${G}✔ DSCP rules removed${NC}"

    tc qdisc del dev "$NIC_R" root    2>/dev/null && echo -e "  ${G}✔ egress qdisc removed${NC}"  || true
    tc qdisc del dev "$NIC_R" ingress 2>/dev/null && echo -e "  ${G}✔ ingress removed${NC}" || true
    if ip link show ifb0 &>/dev/null; then
        tc qdisc del dev ifb0 root 2>/dev/null || true
        ip link del ifb0 2>/dev/null && echo -e "  ${G}✔ ifb0 removed${NC}" || true
    fi

    rm -f /etc/sysctl.d/99-vmess-ais.conf
    sysctl --system >> /dev/null 2>&1 || true
    echo -e "  ${G}✔ sysctl reset${NC}"

    systemctl disable vmess-cake.service vmess-qos.service 2>/dev/null && \
        echo -e "  ${G}✔ services disabled${NC}" || true

    echo ""; echo -e "  ${G}Done.${NC}"
}

main_install() {
    [[ $EUID -eq 0 ]] || { echo "รันด้วย root: sudo bash $0"; exit 1; }
    mkdir -p "$(dirname "$LOG")"; touch "$LOG"
    _banner

    _safe_step "ตรวจ NIC"           do_detect_nic
    _safe_step "Domain config"      do_get_domain
    _safe_step "System update"      do_system_update
    _safe_step "Kernel modules"     do_kernel_modules
    _safe_step "ติดตั้ง 3X-UI"     do_install_xui
    _safe_step "Panel port"         do_panel_port
    _safe_step "TLS cert"           do_tls_cert
    _safe_step "Nginx config"       do_nginx_config
    _safe_step "Xray dual-policy"   do_xray_config
    _safe_step "sysctl tuning"      do_sysctl
    _safe_step "CAKE AQM"           do_cake_aqm
    _safe_step "DSCP QoS"           do_dscp_qos
    _safe_step "System limits"      do_limits
    _safe_step "Firewall + Start"   do_firewall_and_start

    do_summary
}

CMD=${1:-install}
case "$CMD" in
    install|"")     main_install ;;
    monitor)        do_monitor ;;
    status)         do_status ;;
    qos)            do_qos_stats ;;
    rollback)       do_rollback ;;
    inject-inbound) do_inject_inbound ;;
    certbot-renew)
        [[ -z "${2:-}" ]] && { echo "Usage: bash $0 certbot-renew <domain> [email]"; exit 1; }
        RENEW_DOMAIN="${2}"; CERT_EMAIL="${3:-admin@${2}}"
        echo -e "${BOLD}Re-issue cert: ${RENEW_DOMAIN}${NC}"
        systemctl stop nginx 2>/dev/null || true
        fuser -k 80/tcp 2>/dev/null || true; sleep 1
        certbot certonly --standalone --preferred-challenges http \
            --non-interactive --agree-tos --email "$CERT_EMAIL" \
            -d "$RENEW_DOMAIN"
        systemctl start nginx && echo -e "${G}  ✔ Cert OK + Nginx restarted${NC}" || \
            echo -e "${R}  ✘ ล้มเหลว — ตรวจ DNS${NC}"
        ;;
    cake)
        NIC_C=$(ip route get 1.1.1.1 | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        echo -e "${BOLD}Egress (${NIC_C}):${NC}"; tc -s qdisc show dev "$NIC_C"
        ip link show ifb0 &>/dev/null && { echo -e "\n${BOLD}Ingress (ifb0):${NC}"; tc -s qdisc show dev ifb0; }
        ;;
    bbr)
        sysctl net.ipv4.tcp_congestion_control
        sysctl net.core.default_qdisc
        sysctl net.ipv4.tcp_notsent_lowat
        sysctl net.ipv4.tcp_slow_start_after_idle
        ss -tni 2>/dev/null | grep -E "bbr|cubic" | head -10
        ;;
    help|--help|-h)
        echo ""
        echo -e "${BOLD}Usage:${NC}  sudo bash $0 [command]"
        echo ""
        echo -e "  ${C}(no args)${NC}                      full install"
        echo -e "  ${C}monitor${NC}                        live dashboard"
        echo -e "  ${C}status${NC}                         quick check"
        echo -e "  ${C}qos${NC}                            CAKE + DSCP stats"
        echo -e "  ${C}cake${NC}                           CAKE qdisc stats"
        echo -e "  ${C}bbr${NC}                            BBR + TCP stats"
        echo -e "  ${C}inject-inbound${NC}                 re-inject inbound → 3X-UI DB"
        echo -e "  ${C}certbot-renew <domain> [email]${NC} ออก cert ใหม่"
        echo -e "  ${C}rollback${NC}                       undo CAKE + DSCP + sysctl"
        echo ""
        ;;
    *) echo "ไม่รู้จัก: $CMD  |  bash $0 help"; exit 1 ;;
esac
