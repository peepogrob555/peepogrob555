#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.0.0"
readonly LOG_FILE="/var/log/ssh-tls-install.log"
readonly STATE_DIR="/var/lib/ssh-tls"
readonly MGMT_DIR="/usr/local/lib/ssh-tls"
readonly CERT_DIR="/etc/stunnel/certs"
readonly BACKUP_ROOT="/var/backups/ssh-tls"
readonly STUNNEL_PORT=443

TLS_DOMAIN=""
USE_LETSENCRYPT=false
NET_IFACE=""

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

log()  { local ts; ts=$(date '+%H:%M:%S'); echo -e "${G}[+]${N} ${ts} $*" | tee -a "$LOG_FILE"; }
warn() { local ts; ts=$(date '+%H:%M:%S'); echo -e "${Y}[!]${N} ${ts} $*" | tee -a "$LOG_FILE"; }
err()  { local ts; ts=$(date '+%H:%M:%S'); echo -e "${R}[✗]${N} ${ts} $*" | tee -a "$LOG_FILE"; exit 1; }
step() { echo -e "\n${B}${C}── $* ──${N}" | tee -a "$LOG_FILE"; }

# ── Interactive prompt ────────────────────────────────────────────────────────
prompt_config() {
    echo ""
    echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${B}  SSH-over-TLS Installer v${SCRIPT_VERSION}${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""

    # Non-interactive mode via env vars (CI/automation)
    if [[ -n "${TLS_DOMAIN_OVERRIDE:-}" ]]; then
        TLS_DOMAIN="$TLS_DOMAIN_OVERRIDE"
        USE_LETSENCRYPT="${USE_LE_OVERRIDE:-false}"
        log "Non-interactive: domain=$TLS_DOMAIN le=$USE_LETSENCRYPT"
        return
    fi

    while true; do
        echo -ne "${B}  Domain pointing to this server${N} (e.g. vpn.example.com): "
        read -r TLS_DOMAIN
        TLS_DOMAIN="${TLS_DOMAIN// /}"
        [[ -z "$TLS_DOMAIN" ]] && warn "Domain cannot be empty" && continue
        [[ "$TLS_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?\.([a-zA-Z]{2,})$ ]] && break
        warn "Invalid domain format: $TLS_DOMAIN"
    done

    echo ""
    echo -ne "${B}  Use Let's Encrypt certificate?${N} (recommended) [y/N]: "
    read -r choice
    [[ "${choice,,}" == "y" ]] && USE_LETSENCRYPT=true || USE_LETSENCRYPT=false

    echo ""
    [[ "$USE_LETSENCRYPT" == "true" ]] \
        && log "Let's Encrypt mode | domain: $TLS_DOMAIN" \
        || log "Self-signed mode | domain: $TLS_DOMAIN"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
preflight() {
    step "Pre-flight checks"
    [[ $EUID -ne 0 ]] && err "Must run as root"

    local os_id os_ver
    os_id=$(. /etc/os-release && echo "$ID")
    os_ver=$(. /etc/os-release && echo "$VERSION_ID")
    [[ "$os_id" != "ubuntu" ]] && err "Ubuntu required, got: $os_id"
    [[ "$os_ver" != "22.04" ]] && warn "Tested on 22.04, got $os_ver"

    NET_IFACE=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    [[ -z "$NET_IFACE" ]] && err "Cannot detect default network interface"
    log "Interface: $NET_IFACE | Domain: $TLS_DOMAIN | LE: $USE_LETSENCRYPT"

    modprobe nf_conntrack 2>/dev/null || warn "nf_conntrack unavailable"

    if ss -tlnp | grep -q ':443' && ! systemctl is-active stunnel4 -q 2>/dev/null; then
        err "Port 443 in use by another process"
    fi

    mkdir -p "$STATE_DIR" "$MGMT_DIR" "$BACKUP_ROOT"
    log "Pre-flight passed"
}

# ── Backup ────────────────────────────────────────────────────────────────────
backup_configs() {
    step "Backup"
    local d="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$d"
    for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ \
              /etc/stunnel/ /etc/nftables.conf \
              /etc/sysctl.d/99-ssh-tls.conf; do
        [[ -e "$f" ]] && cp -a "$f" "$d/" && log "  $f"
    done
    echo "SCRIPT_VERSION=$SCRIPT_VERSION DATE=$(date -Iseconds)" > "$d/version.txt"
    log "Backup: $d"
}

# ── Packages ──────────────────────────────────────────────────────────────────
install_packages() {
    step "Packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    local pkgs=(stunnel4 nftables openssl iproute2 net-tools vnstat htop bc)
    [[ "$USE_LETSENCRYPT" == "true" ]] && pkgs+=(certbot)

    apt-get install -y -qq "${pkgs[@]}"
    apt-get purge -y -qq fail2ban 2>/dev/null || true
    apt-get autoremove -y -qq && apt-get clean
    log "Packages installed"
}

# ── Disable bloat ─────────────────────────────────────────────────────────────
disable_bloat() {
    step "Disable unnecessary services"
    local svcs=(snapd snapd.socket ModemManager bluetooth avahi-daemon
                apt-daily.timer apt-daily-upgrade.timer
                man-db.timer motd-news.timer ua-timer multipathd iscsid)
    for s in "${svcs[@]}"; do systemctl disable --now "$s" 2>/dev/null || true; done
    log "Done"
}

# ── TLS Certificate ───────────────────────────────────────────────────────────
generate_cert() {
    step "TLS Certificate"
    mkdir -p "$CERT_DIR" && chmod 700 "$CERT_DIR"
    [[ "$USE_LETSENCRYPT" == "true" ]] && _cert_letsencrypt || _cert_selfsigned
}

_cert_selfsigned() {
    local cert="$CERT_DIR/stunnel.pem"
    local key="$CERT_DIR/stunnel.key"

    if [[ -f "$cert" ]]; then
        local days
        days=$(( ( $(openssl x509 -enddate -noout -in "$cert" \
            | cut -d= -f2 | xargs -I{} date -d "{}" +%s) - $(date +%s) ) / 86400 ))
        if [[ $days -gt 90 ]]; then
            warn "Self-signed cert valid ${days}d — skipping"
            _cert_combine "$key" "$cert"
            return
        fi
        warn "Cert expires in ${days}d — regenerating"
    fi

    openssl req -new -x509 -days 3650 -nodes \
        -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -out "$cert" -keyout "$key" \
        -subj "/CN=${TLS_DOMAIN}/O=SSH-TLS/C=TH" \
        -addext "subjectAltName=DNS:${TLS_DOMAIN}" 2>/dev/null

    _cert_combine "$key" "$cert"
    log "Self-signed cert generated (EC P-256, 10yr)"
    _install_selfsigned_renewal
}

_cert_letsencrypt() {
    # DNS check before attempting
    local server_ip domain_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    domain_ip=$(getent hosts "$TLS_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
    [[ "$domain_ip" != "$server_ip" ]] \
        && warn "DNS mismatch: $TLS_DOMAIN → $domain_ip (this server: $server_ip)"

    # Skip if cert already valid > 30 days
    local le_cert="/etc/letsencrypt/live/${TLS_DOMAIN}/fullchain.pem"
    if [[ -f "$le_cert" ]]; then
        local days
        days=$(( ( $(openssl x509 -enddate -noout -in "$le_cert" \
            | cut -d= -f2 | xargs -I{} date -d "{}" +%s) - $(date +%s) ) / 86400 ))
        if [[ $days -gt 30 ]]; then
            warn "LE cert valid ${days}d — skipping issuance"
            _cert_copy_from_le && return
        fi
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        -d "$TLS_DOMAIN" --http-01-port 80 \
        2>&1 | tee -a "$LOG_FILE" \
        || err "Let's Encrypt failed — verify DNS and that port 80 is free"

    _cert_copy_from_le

    # Deploy hook: runs after every successful certbot renewal
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/stunnel-restart.sh << HOOK
#!/bin/bash
set -e
LE="/etc/letsencrypt/live/${TLS_DOMAIN}"
CD="${CERT_DIR}"
cat "\${LE}/privkey.pem" "\${LE}/fullchain.pem" > "\${CD}/stunnel-combined.pem"
cp "\${LE}/fullchain.pem" "\${CD}/stunnel.pem"
cp "\${LE}/privkey.pem"   "\${CD}/stunnel.key"
chmod 600 "\${CD}/stunnel-combined.pem" "\${CD}/stunnel.key"
chmod 644 "\${CD}/stunnel.pem"
systemctl restart stunnel4
echo "stunnel4 restarted with renewed LE cert"
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/stunnel-restart.sh
    systemctl enable --now certbot.timer 2>/dev/null || true
    log "Let's Encrypt cert obtained | auto-renewal via certbot.timer"
}

_cert_copy_from_le() {
    local le="/etc/letsencrypt/live/${TLS_DOMAIN}"
    cp "${le}/fullchain.pem" "$CERT_DIR/stunnel.pem"
    cp "${le}/privkey.pem"   "$CERT_DIR/stunnel.key"
    _cert_combine "${le}/privkey.pem" "${le}/fullchain.pem"
    log "LE cert copied to $CERT_DIR"
}

_cert_combine() {
    local key="$1" cert="$2"
    cat "$key" "$cert" > "$CERT_DIR/stunnel-combined.pem"
    chmod 600 "$CERT_DIR/stunnel-combined.pem" "$key"
    chmod 644 "$cert"
}

_install_selfsigned_renewal() {
    # generate-cert.sh — reusable standalone
    cat > "$MGMT_DIR/generate-cert.sh" << GENCERT
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="\${1:-${TLS_DOMAIN}}"
CD="${CERT_DIR}"
mkdir -p "\$CD" && chmod 700 "\$CD"
openssl req -new -x509 -days 3650 -nodes \\
    -newkey ec -pkeyopt ec_paramgen_curve:P-256 \\
    -out "\$CD/stunnel.pem" -keyout "\$CD/stunnel.key" \\
    -subj "/CN=\${DOMAIN}/O=SSH-TLS/C=TH" \\
    -addext "subjectAltName=DNS:\${DOMAIN}" 2>/dev/null
cat "\$CD/stunnel.key" "\$CD/stunnel.pem" > "\$CD/stunnel-combined.pem"
chmod 600 "\$CD/stunnel.key" "\$CD/stunnel-combined.pem"
chmod 644 "\$CD/stunnel.pem"
echo "Cert generated for \$DOMAIN"
GENCERT
    chmod +x "$MGMT_DIR/generate-cert.sh"

    # renew-cert.sh — called by systemd timer
    cat > "$MGMT_DIR/renew-cert.sh" << RENEW
#!/usr/bin/env bash
set -euo pipefail
CERT="${CERT_DIR}/stunnel.pem"
DAYS=\$(( ( \$(openssl x509 -enddate -noout -in "\$CERT" \\
    | cut -d= -f2 | xargs -I{} date -d "{}" +%s) - \$(date +%s) ) / 86400 ))
[[ \$DAYS -gt 90 ]] && echo "Cert OK: \${DAYS}d left" && exit 0
echo "Renewing (\${DAYS}d left)..."
bash "${MGMT_DIR}/generate-cert.sh" "${TLS_DOMAIN}"
systemctl restart stunnel4
echo "Renewed and stunnel4 restarted"
RENEW
    chmod +x "$MGMT_DIR/renew-cert.sh"

    cat > /etc/systemd/system/ssh-tls-cert-renew.service << EOF
[Unit]
Description=SSH-TLS self-signed cert renewal
After=network.target
[Service]
Type=oneshot
ExecStart=${MGMT_DIR}/renew-cert.sh
EOF
    cat > /etc/systemd/system/ssh-tls-cert-renew.timer << 'EOF'
[Unit]
Description=SSH-TLS cert renewal (monthly)
[Timer]
OnCalendar=monthly
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now ssh-tls-cert-renew.timer 2>/dev/null || true
    log "Self-signed renewal timer active (monthly)"
}

# ── SSH drop-in ───────────────────────────────────────────────────────────────
configure_ssh() {
    step "SSH (drop-in only)"
    mkdir -p /etc/ssh/sshd_config.d

    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config 2>/dev/null; then
        sed -i '1s|^|Include /etc/ssh/sshd_config.d/*.conf\n|' /etc/ssh/sshd_config
    fi

    cat > /etc/ssh/sshd_config.d/10-mobile-tunnel.conf << 'EOF'
Port 22
ListenAddress 127.0.0.1
AddressFamily inet

PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no

# No AuthenticationMethods = password OR key (any one suffices)
# "AuthenticationMethods password publickey" would require BOTH — breaks injectors
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
UsePAM yes

# chacha20: fastest on ARM/mobile without AES-NI
Ciphers chacha20-poly1305@openssh.com,aes128-ctr,aes256-ctr
MACs hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
Compression no

# 30s × 6 = 180s before drop; carrier NAT typically expires at 60-90s idle
ClientAliveInterval 30
ClientAliveCountMax 6

UseDNS no
LoginGraceTime 30
MaxSessions 4
MaxStartups 4:50:8
SyslogFacility AUTH
LogLevel ERROR
EOF

    sshd -t || err "sshd config invalid — run: sshd -T 2>&1 | grep -i error"
    systemctl restart ssh
    log "SSH drop-in applied (localhost:22 only)"
}

# ── stunnel4 ──────────────────────────────────────────────────────────────────
configure_stunnel() {
    step "stunnel4"

    cat > /etc/stunnel/stunnel.conf << EOF
pid = /run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4

; TCP_NODELAY both sides: eliminates Nagle delay on interactive SSH
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

; TLS session cache: avoids full handshake on mobile reconnect
sessionCacheSize = 256
sessionCacheTimeout = 300

; TLS1.2 min: some Android injectors still negotiate TLS1.2
; AEAD-only ciphers keep security regardless of version
sslVersionMin = TLSv1.2
sslVersionMax = TLSv1.3
options = NO_SSLv2
options = NO_SSLv3
options = NO_TLSv1
options = NO_TLSv1.1
options = SINGLE_ECDH_USE
ciphers = TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256

debug = 0

[ssh-tls]
accept  = 0.0.0.0:${STUNNEL_PORT}
connect = 127.0.0.1:22
cert    = ${CERT_DIR}/stunnel-combined.pem
key     = ${CERT_DIR}/stunnel.key
sni     = ${TLS_DOMAIN}

; TIMEOUTclose=0: mobile drops connections abruptly; don't wait for TLS close_notify
TIMEOUTclose   = 0
TIMEOUTidle    = 86400
TIMEOUTbusy    = 30
TIMEOUTconnect = 10
EOF

    mkdir -p /etc/systemd/system/stunnel4.service.d
    cat > /etc/systemd/system/stunnel4.service.d/hardening.conf << 'EOF'
[Service]
Restart=always
RestartSec=3s
LimitNOFILE=65536
LimitNPROC=512
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryDenyWriteExecute=true
LockPersonality=true
ReadWritePaths=/run/stunnel4 /etc/stunnel/certs
EOF

    systemctl daemon-reload
    systemctl enable stunnel4
    systemctl restart stunnel4
    log "stunnel4 on :443 (TLS1.2+1.3 | Restart=always | hardened)"
}

# ── fq qdisc ─────────────────────────────────────────────────────────────────
configure_fq_qdisc() {
    step "fq qdisc"

    # Dynamic interface at boot — survives rename (eth0/ens3/etc)
    cat > /etc/systemd/system/fq-qdisc.service << 'EOF'
[Unit]
Description=Apply fq qdisc for BBR (dynamic interface)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    IFACE=$(ip route show default | awk "/^default/ {print \$5; exit}"); \
    [ -n "$IFACE" ] \
        && tc qdisc replace dev "$IFACE" root fq quantum 1514 flow_limit 50 \
        || { echo "fq-qdisc: no default interface"; exit 1; }'
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now fq-qdisc.service
    log "fq qdisc active (dynamic interface detection)"
}

# ── sysctl ────────────────────────────────────────────────────────────────────
configure_sysctl() {
    step "sysctl"

    local has_conntrack=false
    { modinfo nf_conntrack &>/dev/null || lsmod | grep -q nf_conntrack; } \
        && has_conntrack=true || true

    cat > /etc/sysctl.d/99-ssh-tls.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 87380 4194304
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.core.netdev_max_backlog = 512
net.ipv4.tcp_mem = 16384 65536 131072

# Server-only TFO: TRUE/DTAC drop client TFO cookies → reconnect failures
net.ipv4.tcp_fastopen = 1

# Limit unsent socket buffer: prevents app-layer bufferbloat on 128kbps
net.ipv4.tcp_notsent_lowat = 16384

net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024

net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_retries2 = 8

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 8192

net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 512

net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

fs.file-max = 65536
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

    if [[ "$has_conntrack" == "true" ]]; then
        cat >> /etc/sysctl.d/99-ssh-tls.conf << 'EOF'
net.netfilter.nf_conntrack_max = 8192
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15
EOF
        log "  conntrack tuning included"
    fi

    sysctl -p /etc/sysctl.d/99-ssh-tls.conf
    log "sysctl applied"
}

# ── nftables ──────────────────────────────────────────────────────────────────
configure_firewall() {
    step "nftables"

    cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {

    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        iif lo accept

        ip  protocol icmp  icmp  type { echo-request, echo-reply,
            destination-unreachable, time-exceeded } limit rate 5/second accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply,
            nd-neighbor-solicit, nd-neighbor-advert,
            destination-unreachable } limit rate 5/second accept

        # Per-IP rate: 20 new conn/min handles reconnect storm without blocking legit users
        tcp dport 443 ct state new limit rate over 20/minute drop

        # Per-IP conn count: max 8 concurrent — prevents single IP hoarding connections
        tcp dport 443 ct state new ct count over 8 drop

        tcp dport 443 ct state new accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    nft -c -f /etc/nftables.conf || err "nftables validation failed"
    systemctl enable nftables
    systemctl restart nftables
    log "nftables: per-IP rate limit + per-IP ct count"
}

# ── journald ──────────────────────────────────────────────────────────────────
configure_journald() {
    step "journald"
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/low-overhead.conf << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=64M
Compress=yes
RateLimitInterval=30s
RateLimitBurst=100
EOF
    systemctl restart systemd-journald
    log "journald: persistent, 64MB"
}

# ── Limits ────────────────────────────────────────────────────────────────────
configure_limits() {
    step "System limits"
    cat > /etc/security/limits.d/ssh-tls.conf << 'EOF'
*    soft nofile 16384
*    hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
    log "nofile 65536 set"
}

# ── Watchdog ──────────────────────────────────────────────────────────────────
configure_watchdog() {
    step "Watchdog"

    cat > "$MGMT_DIR/watchdog.sh" << 'WATCHDOG'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/ssh-tls-watchdog.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Primary: systemd unit state (authoritative)
if ! systemctl is-active stunnel4 -q 2>/dev/null; then
    echo "$(ts) stunnel4 inactive — restarting" >> "$LOG"
    systemctl restart stunnel4
    sleep 3
    systemctl is-active stunnel4 -q \
        && echo "$(ts) stunnel4 recovered" >> "$LOG" \
        || { echo "$(ts) stunnel4 FAILED to restart" >> "$LOG"; exit 1; }
fi

# Secondary: real TLS handshake (unit active != TLS actually working)
if ! echo Q | openssl s_client -connect 127.0.0.1:443 \
        -servername "$(hostname -f)" -brief 2>/dev/null | grep -q "SSL handshake"; then
    echo "$(ts) TLS handshake failed — restarting stunnel4" >> "$LOG"
    systemctl restart stunnel4
fi

# SSH
if ! systemctl is-active ssh -q 2>/dev/null; then
    echo "$(ts) sshd inactive — restarting" >> "$LOG"
    systemctl restart ssh
fi
WATCHDOG
    chmod +x "$MGMT_DIR/watchdog.sh"

    cat > /etc/systemd/system/ssh-tls-watchdog.service << EOF
[Unit]
Description=SSH-TLS watchdog
After=stunnel4.service ssh.service
[Service]
Type=oneshot
ExecStart=${MGMT_DIR}/watchdog.sh
EOF

    cat > /etc/systemd/system/ssh-tls-watchdog.timer << 'EOF'
[Unit]
Description=SSH-TLS watchdog timer (60s)
[Timer]
OnBootSec=120s
OnUnitActiveSec=60s
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ssh-tls-watchdog.timer
    log "Watchdog: systemctl + real TLS handshake every 60s"
}

# ── Management scripts ────────────────────────────────────────────────────────
create_management_scripts() {
    step "Management scripts"

    cat > "$MGMT_DIR/user-add.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
[[ $# -lt 1 ]] && { echo "Usage: user-add <name> [days=30]"; exit 1; }
USERNAME="$1"; DAYS="${2:-30}"
EXPIRY=$(date -d "+${DAYS} days" +%Y-%m-%d)
PASSWORD=$(openssl rand -base64 16 | tr -d '+/=\n' | cut -c1-14)
# /bin/false: cleaner than nologin; both allow AllowTcpForwarding
useradd -m -s /bin/false -e "$EXPIRY" -c "ssh-tls-user" "$USERNAME" 2>/dev/null \
    || { echo "User $USERNAME already exists"; exit 1; }
echo "$USERNAME:$PASSWORD" | chpasswd
echo "$USERNAME|$EXPIRY|$(date -Iseconds)" >> /var/lib/ssh-tls/users.db
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " User    : $USERNAME"
echo " Password: $PASSWORD"
echo " Expires : $EXPIRY (${DAYS}d)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SCRIPT

    cat > "$MGMT_DIR/user-delete.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
[[ $# -lt 1 ]] && { echo "Usage: user-delete <name>"; exit 1; }
pkill -u "$1" -TERM 2>/dev/null || true; sleep 1
pkill -u "$1" -KILL 2>/dev/null || true
userdel -r "$1" 2>/dev/null && echo "Deleted: $1" || echo "Not found: $1"
sed -i "/^${1}|/d" /var/lib/ssh-tls/users.db 2>/dev/null || true
SCRIPT

    cat > "$MGMT_DIR/user-list.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TODAY=$(date +%s)
printf "%-18s %-12s %-8s\n" "USER" "EXPIRES" "STATUS"
printf "%-18s %-12s %-8s\n" "──────────────────" "────────────" "────────"
while IFS=: read -r user _ uid _ _ _ shell; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ "$shell" != "/bin/false" && "$shell" != "/usr/sbin/nologin" ]] && continue
    exp=$(chage -l "$user" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ "$exp" == "never" ]]; then
        printf "%-18s %-12s %-8s\n" "$user" "never" "active"
        continue
    fi
    exp_e=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    exp_d=$(date -d "@$exp_e" +%Y-%m-%d 2>/dev/null || echo "?")
    [[ $exp_e -lt $TODAY ]] && status="expired" || status="active"
    printf "%-18s %-12s %-8s\n" "$user" "$exp_d" "$status"
done < /etc/passwd
SCRIPT

    cat > "$MGMT_DIR/monitor.sh" << 'SCRIPT'
#!/usr/bin/env bash
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SSH-TLS Monitor — $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo -e "\n[ Memory ]"
free -h | awk 'NR<=2{print "  "$0}'

echo -e "\n[ CPU ]"
top -bn1 | grep "Cpu(s)" | awk '{printf "  user:%-6s sys:%-6s idle:%s\n",$2,$4,$8}'

echo -e "\n[ SSH Tunnel Sessions ]"
# ss port 22 — accurate for non-TTY tunnel sessions ('who' misses these)
ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null \
    | awk 'NR>1{print "  "$0}' | head -10 || echo "  None"

echo -e "\n[ TLS Connections :443 ]"
ss -tn state established '( dport = :443 or sport = :443 )' 2>/dev/null \
    | awk 'NR>1{print "  "$0}' | head -20

echo -e "\n[ TCP States ]"
ss -s | grep -E "estab|time-wait|close-wait" | awk '{print "  "$0}'

echo -e "\n[ Network RX/TX (1s sample) ]"
r1=$(cat /sys/class/net/"$IFACE"/statistics/rx_bytes)
t1=$(cat /sys/class/net/"$IFACE"/statistics/tx_bytes)
sleep 1
r2=$(cat /sys/class/net/"$IFACE"/statistics/rx_bytes)
t2=$(cat /sys/class/net/"$IFACE"/statistics/tx_bytes)
printf "  RX: %d KB/s | TX: %d KB/s\n" "$(( (r2-r1)/1024 ))" "$(( (t2-t1)/1024 ))"

echo -e "\n[ BBR / qdisc ]"
printf "  cc=%s | " "$(sysctl -n net.ipv4.tcp_congestion_control)"
tc qdisc show dev "$IFACE" | awk '{printf "qdisc=%s\n",$2; exit}'

echo -e "\n[ Top IPs on :443 ]"
ss -tn state established '( sport = :443 )' 2>/dev/null \
    | awk 'NR>1{print $5}' | cut -d: -f1 \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "  %4s × %s\n",$1,$2}'
SCRIPT

    cat > "$MGMT_DIR/health-check.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { echo -e "\033[0;32m[✓]\033[0m $1"; ((PASS++)); }
fail() { echo -e "\033[0;31m[✗]\033[0m $1"; ((FAIL++)); }
wn()   { echo -e "\033[1;33m[!]\033[0m $1"; ((WARN++)); }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Health Check — $(date '+%H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

systemctl is-active ssh      -q && ok "sshd running"     || fail "sshd down"
systemctl is-active stunnel4 -q && ok "stunnel4 running" || fail "stunnel4 down"
systemctl is-active nftables -q && ok "nftables running" || fail "nftables down"
systemctl is-active fq-qdisc -q && ok "fq-qdisc active"  || fail "fq-qdisc down"

ss -tlnp | grep -q '127.0.0.1:22' && ok "SSH on localhost:22" || fail "SSH not on localhost"
ss -tlnp | grep -q ':443'          && ok "Port 443 listening"  || fail "Port 443 not listening"
! ss -tlnp | grep -q '0.0.0.0:22' && ok "SSH not public"      || fail "SSH exposed publicly!"

[[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]] \
    && ok "BBR active" || fail "BBR not active"

IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
tc qdisc show dev "$IFACE" | grep -q fq && ok "fq on $IFACE" || fail "fq qdisc missing"

CERT="/etc/stunnel/certs/stunnel.pem"
KEY="/etc/stunnel/certs/stunnel.key"
if [[ -f "$CERT" && -f "$KEY" ]]; then
    DAYS=$(( ( $(openssl x509 -enddate -noout -in "$CERT" \
        | cut -d= -f2 | xargs -I{} date -d "{}" +%s) - $(date +%s) ) / 86400 ))
    [[ $DAYS -gt 30 ]] && ok "Cert valid (${DAYS}d)" || fail "Cert expires in ${DAYS}d!"

    # Cert/key pair match — public key fingerprint comparison
    CP=$(openssl x509 -noout -pubkey -in "$CERT" 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -c1-16)
    KP=$(openssl pkey -pubout -in "$KEY" 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -c1-16)
    [[ "$CP" == "$KP" ]] && ok "Cert/key pair match" || fail "Cert/key MISMATCH!"
else
    fail "Cert or key missing"
fi

# Real TLS handshake test
echo Q | openssl s_client -connect 127.0.0.1:443 \
    -servername "$(hostname -f)" -brief 2>/dev/null | grep -q "SSL handshake" \
    && ok "TLS handshake OK" || wn "TLS handshake inconclusive"

RAM=$(free -m | awk '/^Mem:/{print $7}')
[[ $RAM -gt 200 ]] && ok "Free RAM: ${RAM}MB" || wn "Low RAM: ${RAM}MB"

systemctl is-active ssh-tls-watchdog.timer -q && ok "Watchdog active" || wn "Watchdog not running"

echo ""
echo "  ${PASS} passed | ${WARN} warnings | ${FAIL} failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
SCRIPT

    cat > "$MGMT_DIR/backup-config.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
DEST="/var/backups/ssh-tls/manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
for f in /etc/ssh/sshd_config.d/10-mobile-tunnel.conf \
          /etc/stunnel/ /etc/nftables.conf \
          /etc/sysctl.d/99-ssh-tls.conf /var/lib/ssh-tls/; do
    [[ -e "$f" ]] && cp -a "$f" "$DEST/"
done
tar -czf "${DEST}.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
rm -rf "$DEST"
echo "Backup: ${DEST}.tar.gz"
ls -lh "${DEST}.tar.gz"
SCRIPT

    cat > "$MGMT_DIR/uninstall.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
read -rp "Type YES to confirm: " c
[[ "$c" != "YES" ]] && echo "Aborted" && exit 0

systemctl disable --now stunnel4 fq-qdisc \
    ssh-tls-watchdog.timer ssh-tls-cert-renew.timer 2>/dev/null || true

IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
tc qdisc del dev "$IFACE" root 2>/dev/null || true

rm -f /etc/ssh/sshd_config.d/10-mobile-tunnel.conf
rm -f /etc/sysctl.d/99-ssh-tls.conf
rm -f /etc/security/limits.d/ssh-tls.conf
rm -f /etc/systemd/system/fq-qdisc.service
rm -f /etc/systemd/system/ssh-tls-watchdog.*
rm -f /etc/systemd/system/ssh-tls-cert-renew.*
rm -f /etc/systemd/system/stunnel4.service.d/hardening.conf
rm -f /etc/systemd/journald.conf.d/low-overhead.conf

printf '#!/usr/sbin/nft -f\nflush ruleset\ntable inet filter {\n  chain input { type filter hook input priority filter; policy accept; }\n  chain output { type filter hook output priority filter; policy accept; }\n}\n' \
    > /etc/nftables.conf
systemctl restart nftables
sysctl -p /etc/sysctl.conf 2>/dev/null || true
systemctl daemon-reload && systemctl restart ssh
echo "Uninstalled. Review /etc/stunnel/ manually."
SCRIPT

    chmod +x "$MGMT_DIR"/*.sh
    for cmd in user-add user-delete user-list monitor health-check backup-config; do
        ln -sf "$MGMT_DIR/${cmd}.sh" "/usr/local/bin/${cmd}"
    done
    log "Scripts ready: user-add | user-list | monitor | health-check | backup-config"
}

# ── Record state ──────────────────────────────────────────────────────────────
record_state() {
    cat > "$STATE_DIR/install.state" << EOF
SCRIPT_VERSION=${SCRIPT_VERSION}
INSTALL_DATE=$(date -Iseconds)
NET_IFACE=${NET_IFACE}
TLS_DOMAIN=${TLS_DOMAIN}
USE_LETSENCRYPT=${USE_LETSENCRYPT}
STUNNEL_PORT=${STUNNEL_PORT}
EOF
    touch "$STATE_DIR/users.db"
}

# ── Canary validation ─────────────────────────────────────────────────────────
canary_validate() {
    step "Canary validation"
    sleep 2
    local failures=0

    systemctl is-active stunnel4 -q    && log "  stunnel4 active"    || { warn "  stunnel4 not active"; ((failures++)); }
    ss -tlnp | grep -q ':443'          && log "  :443 listening"     || { warn "  :443 not listening"; ((failures++)); }
    ss -tlnp | grep -q '127.0.0.1:22' && log "  SSH on localhost"   || { warn "  SSH not on localhost"; ((failures++)); }
    sshd -t 2>/dev/null                && log "  sshd config valid" || { warn "  sshd config invalid"; ((failures++)); }
    [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]] \
                                       && log "  BBR active"         || { warn "  BBR not active"; ((failures++)); }
    tc qdisc show dev "$NET_IFACE" | grep -q fq \
                                       && log "  fq on $NET_IFACE"  || { warn "  fq qdisc missing"; ((failures++)); }
    nft list ruleset | grep -q '443'   && log "  nftables :443 OK"  || { warn "  nftables rule missing"; ((failures++)); }

    # Cert/key pair match
    local cert="$CERT_DIR/stunnel.pem" key="$CERT_DIR/stunnel.key"
    if [[ -f "$cert" && -f "$key" ]]; then
        local cp kp
        cp=$(openssl x509 -noout -pubkey -in "$cert" 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -c1-16)
        kp=$(openssl pkey -pubout -in "$key" 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -c1-16)
        [[ "$cp" == "$kp" ]] && log "  cert/key match" || { warn "  cert/key MISMATCH!"; ((failures++)); }
    fi

    [[ $failures -eq 0 ]] && log "All canary checks passed" \
        || warn "$failures check(s) failed — run: health-check"
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
    local server_ip cert_mode
    server_ip=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [[ -z "$server_ip" ]] && server_ip=$(hostname -I | awk '{print $1}')
    [[ "$USE_LETSENCRYPT" == "true" ]] && cert_mode="Let's Encrypt" || cert_mode="Self-signed"

    echo ""
    echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${B}  SSH-over-TLS v${SCRIPT_VERSION} — Complete${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "  ${B}Server IP  :${N} ${server_ip}"
    echo -e "  ${B}Domain     :${N} ${TLS_DOMAIN}"
    echo -e "  ${B}Port       :${N} 443 (TLS 1.2/1.3)"
    echo -e "  ${B}Certificate:${N} ${cert_mode}"
    echo ""
    echo -e "  ${B}Client settings:${N}"
    echo -e "  ┌──────────────────────────────────────────────────────┐"
    echo -e "  │ Host  : ${server_ip}  (or ${TLS_DOMAIN})"
    echo -e "  │ Port  : 443  │  Type: SSL/TLS"
    echo -e "  │ SNI   : ${TLS_DOMAIN}"
    echo -e "  │ SSH   : 127.0.0.1:22"
    echo -e "  └──────────────────────────────────────────────────────┘"
    echo ""
    echo -e "  user-add <name> [days]  │  user-list  │  health-check  │  monitor"
    echo ""
    echo -e "  ${B}Log:${N}  $LOG_FILE"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Install started $(date -Iseconds) ===" >> "$LOG_FILE"

    prompt_config
    preflight
    backup_configs
    install_packages
    disable_bloat
    generate_cert
    configure_ssh
    configure_stunnel
    configure_fq_qdisc
    configure_sysctl
    configure_firewall
    configure_journald
    configure_limits
    configure_watchdog
    create_management_scripts
    record_state
    canary_validate
    print_summary

    log "Install complete. Log: $LOG_FILE"
}

main "$@"
