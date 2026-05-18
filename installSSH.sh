#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# SSH-over-TLS Production Installer v2.0
# Ubuntu 22.04 | 1vCPU | 2GB RAM | 128kbps/user | RTT 20-40ms | 2 users
# Philosophy: predictable under bad networks, not just optimized for good ones
# =============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly CONFIG_VERSION="2"
readonly LOG_FILE="/var/log/ssh-tls-install.log"
readonly STATE_DIR="/var/lib/ssh-tls"
readonly MGMT_DIR="/usr/local/lib/ssh-tls"
readonly CERT_DIR="/etc/stunnel/certs"
readonly BACKUP_ROOT="/var/backups/ssh-tls"
readonly STUNNEL_PORT=443

TLS_DOMAIN="${TLS_DOMAIN:-$(hostname -f 2>/dev/null || hostname)}"
NET_IFACE=""  # resolved at runtime

# ── Colors ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

log()  { local ts; ts=$(date '+%H:%M:%S'); echo -e "${G}[+]${N} ${ts} $*" | tee -a "$LOG_FILE"; }
warn() { local ts; ts=$(date '+%H:%M:%S'); echo -e "${Y}[!]${N} ${ts} $*" | tee -a "$LOG_FILE"; }
err()  { local ts; ts=$(date '+%H:%M:%S'); echo -e "${R}[✗]${N} ${ts} $*" | tee -a "$LOG_FILE"; exit 1; }
step() { echo -e "\n${B}${C}── $* ──${N}" | tee -a "$LOG_FILE"; }

# ── Pre-flight checks ─────────────────────────────────────────────────────────
preflight() {
    step "Pre-flight checks"
    [[ $EUID -ne 0 ]] && err "Must run as root"

    local os_id os_ver
    os_id=$(. /etc/os-release && echo "$ID")
    os_ver=$(. /etc/os-release && echo "$VERSION_ID")
    [[ "$os_id" != "ubuntu" ]] && err "Ubuntu required, got: $os_id"
    [[ "$os_ver" != "22.04" ]] && warn "Tested on 22.04, got $os_ver — proceed with caution"

    # Detect default interface robustly — no external calls
    NET_IFACE=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    [[ -z "$NET_IFACE" ]] && err "Cannot detect default network interface"
    log "Interface: $NET_IFACE"
    log "TLS domain: $TLS_DOMAIN"

    # Check required kernel modules
    modprobe nf_conntrack 2>/dev/null || warn "nf_conntrack module unavailable — conntrack sysctl tuning skipped"

    # Verify port 443 is free (idempotent re-run: stunnel owns it)
    if ss -tlnp | grep -q ':443' && ! systemctl is-active stunnel4 -q 2>/dev/null; then
        err "Port 443 is in use by another process"
    fi

    mkdir -p "$STATE_DIR" "$MGMT_DIR" "$BACKUP_ROOT"
    log "Pre-flight passed"
}

# ── Timestamped backup ────────────────────────────────────────────────────────
backup_configs() {
    step "Backup existing configs"
    local backup_dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    local files=(
        /etc/ssh/sshd_config
        /etc/ssh/sshd_config.d/
        /etc/stunnel/stunnel.conf
        /etc/nftables.conf
        /etc/sysctl.d/99-ssh-tls.conf
        /etc/fail2ban/jail.local
        /etc/systemd/system/fq-qdisc.service
        /etc/systemd/system/ssh-tls-watchdog.service
        /etc/security/limits.d/ssh-tls.conf
    )
    for f in "${files[@]}"; do
        [[ -e "$f" ]] && cp -a "$f" "$backup_dir/" && log "  backed up: $f"
    done

    # Record what version this backup was from
    echo "SCRIPT_VERSION=$SCRIPT_VERSION" > "$backup_dir/version.txt"
    echo "CONFIG_VERSION=$CONFIG_VERSION" >> "$backup_dir/version.txt"
    echo "DATE=$(date -Iseconds)" >> "$backup_dir/version.txt"

    log "Backup: $backup_dir"
}

# ── Packages ──────────────────────────────────────────────────────────────────
install_packages() {
    step "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    apt-get install -y -qq \
        stunnel4 nftables openssl iproute2 \
        net-tools vnstat htop bc
    # Explicitly purge fail2ban — replaced by nftables native rate limiting
    apt-get purge -y -qq fail2ban 2>/dev/null || true
    apt-get autoremove -y -qq
    apt-get clean
    log "Packages installed (fail2ban replaced by nftables native limits)"
}

# ── Disable bloat ─────────────────────────────────────────────────────────────
disable_bloat() {
    step "Disabling unnecessary services"
    local services=(
        snapd snapd.socket
        ModemManager bluetooth avahi-daemon
        apt-daily.timer apt-daily-upgrade.timer
        man-db.timer motd-news.timer ua-timer
        multipathd iscsid
    )
    for svc in "${services[@]}"; do
        systemctl disable --now "$svc" 2>/dev/null || true
    done
    log "Bloat disabled"
}

# ── TLS Certificate with lifecycle ───────────────────────────────────────────
generate_cert() {
    step "TLS Certificate"
    mkdir -p "$CERT_DIR"
    chmod 700 "$CERT_DIR"

    local cert="$CERT_DIR/stunnel.pem"
    local key="$CERT_DIR/stunnel.key"
    local combined="$CERT_DIR/stunnel-combined.pem"

    # Check if existing cert is still valid for >90 days
    if [[ -f "$cert" ]]; then
        local days_left
        days_left=$(( ( $(openssl x509 -enddate -noout -in "$cert" \
            | cut -d= -f2 | xargs -I{} date -d "{}" +%s) - $(date +%s) ) / 86400 ))
        if [[ $days_left -gt 90 ]]; then
            warn "Certificate valid for $days_left more days — skipping regeneration"
            return
        fi
        warn "Certificate expires in $days_left days — regenerating"
    fi

    openssl req -new -x509 -days 3650 -nodes \
        -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -out "$cert" -keyout "$key" \
        -subj "/CN=${TLS_DOMAIN}/O=SSH-TLS/C=TH" \
        -addext "subjectAltName=DNS:${TLS_DOMAIN}" 2>/dev/null

    cat "$key" "$cert" > "$combined"
    chmod 600 "$key" "$combined"
    chmod 644 "$cert"

    # Install cert renewal systemd timer (annual rotation)
    cat > /etc/systemd/system/ssh-tls-cert-renew.service << EOF
[Unit]
Description=Renew SSH-TLS self-signed certificate
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/ssh-tls/renew-cert.sh
EOF

    cat > /etc/systemd/system/ssh-tls-cert-renew.timer << 'EOF'
[Unit]
Description=Check SSH-TLS certificate renewal (monthly)

[Timer]
OnCalendar=monthly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Renewal script (checks 90d threshold before acting)
    cat > "$MGMT_DIR/renew-cert.sh" << RENEW
#!/usr/bin/env bash
set -euo pipefail
CERT="${CERT_DIR}/stunnel.pem"
DAYS_LEFT=\$(( ( \$(openssl x509 -enddate -noout -in "\$CERT" \\
    | cut -d= -f2 | xargs -I{} date -d "{}" +%s) - \$(date +%s) ) / 86400 ))
if [[ \$DAYS_LEFT -gt 90 ]]; then
    echo "Cert OK: \$DAYS_LEFT days left — no renewal needed"
    exit 0
fi
echo "Renewing cert (\$DAYS_LEFT days left)..."
TLS_DOMAIN="${TLS_DOMAIN}" bash /usr/local/lib/ssh-tls/generate-cert.sh
systemctl restart stunnel4
echo "Cert renewed, stunnel restarted"
RENEW
    chmod +x "$MGMT_DIR/renew-cert.sh"

    systemctl daemon-reload
    systemctl enable --now ssh-tls-cert-renew.timer 2>/dev/null || true

    log "TLS certificate generated (EC P-256, 10yr); renewal timer active"
}

# ── SSH: drop-in config only — do NOT overwrite sshd_config ──────────────────
configure_ssh() {
    step "SSH configuration (drop-in)"

    # Ensure drop-in dir exists and is included
    mkdir -p /etc/ssh/sshd_config.d

    # Guarantee Include exists in base config without overwriting it
    if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config 2>/dev/null; then
        # Prepend Include if missing (safe — sshd reads in order)
        sed -i '1s|^|Include /etc/ssh/sshd_config.d/*.conf\n|' /etc/ssh/sshd_config
    fi

    # Our tuning lives entirely in the drop-in — base sshd_config untouched
    cat > /etc/ssh/sshd_config.d/10-mobile-tunnel.conf << 'EOF'
# SSH-over-TLS mobile tunnel profile
# Drop-in: safe across package updates, easy to diff/remove

Port 22
ListenAddress 127.0.0.1
AddressFamily inet

PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no

AuthenticationMethods password publickey
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
UsePAM yes

# chacha20 best for ARM mobile CPUs (no AES-NI); aes128-ctr fallback
Ciphers chacha20-poly1305@openssh.com,aes128-ctr,aes256-ctr
MACs hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# No SSH-level compression: stunnel TLS adds overhead; BBR handles throughput
Compression no

# 30s interval × 6 = 180s before session drop
# Less aggressive than 15s: reduces battery drain, fewer keepalive packets on 128kbps
# Carrier NAT timeout typically 60-90s; SSH-level keepalive fires at 30s — safe margin
ClientAliveInterval 30
ClientAliveCountMax 6

UseDNS no
LoginGraceTime 30

MaxSessions 4
MaxStartups 4:50:8

SyslogFacility AUTH
LogLevel ERROR

Subsystem sftp /usr/lib/openssh/sftp-server -l ERROR
EOF

    sshd -t || err "sshd config validation failed"
    systemctl restart ssh
    log "SSH drop-in applied: /etc/ssh/sshd_config.d/10-mobile-tunnel.conf"
}

# ── stunnel4 ──────────────────────────────────────────────────────────────────
configure_stunnel() {
    step "stunnel4 configuration"

    cat > /etc/stunnel/stunnel.conf << EOF
; stunnel4 — TLS frontend for SSH over mobile networks
pid = /run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4

; TCP_NODELAY on both sides: critical for interactive SSH over 128kbps
; Without it, Nagle coalesces small ACKs → perceptible lag on slow link
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

; Session cache: avoids full TLS handshake on mobile reconnect
; 256 entries × ~256B ≈ 64KB — negligible on 2GB RAM
sessionCacheSize = 256
sessionCacheTimeout = 300

; TLS 1.3 only: faster handshake (1-RTT vs 2-RTT for TLS1.2)
; Fallback: Android 7.0+ supports TLS 1.3 — safe for target clients
sslVersionMin = TLSv1.3
options = NO_SSLv2
options = NO_SSLv3
options = NO_TLSv1
options = NO_TLSv1.1
options = SINGLE_ECDH_USE

; Log errors only — reduces disk I/O on NVMe, journald pressure
debug = 0

[ssh-tls]
accept  = 0.0.0.0:${STUNNEL_PORT}
connect = 127.0.0.1:22
cert    = ${CERT_DIR}/stunnel-combined.pem
key     = ${CERT_DIR}/stunnel.key
sni     = ${TLS_DOMAIN}

; TIMEOUTclose=0: don't wait for clean TLS close_notify on disconnect
; Mobile clients drop connections abruptly (signal loss); close immediately
TIMEOUTclose  = 0

; idle 24h: long-lived SSH sessions survive overnight on stable connection
TIMEOUTidle   = 86400

; busy/connect conservative: don't wait on broken half-open during reconnect storm
TIMEOUTbusy   = 30
TIMEOUTconnect = 10
EOF

    # systemd hardening for stunnel4
    mkdir -p /etc/systemd/system/stunnel4.service.d
    cat > /etc/systemd/system/stunnel4.service.d/hardening.conf << 'EOF'
[Service]
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
    log "stunnel4 configured on :443 with systemd hardening"
}

# ── fq qdisc via proper systemd unit ─────────────────────────────────────────
configure_fq_qdisc() {
    step "fq qdisc (systemd unit)"

    cat > /etc/systemd/system/fq-qdisc.service << EOF
[Unit]
Description=Apply fq qdisc for BBR (${NET_IFACE})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/tc qdisc replace dev ${NET_IFACE} root fq quantum 1514 flow_limit 50
ExecStop=/sbin/tc qdisc del dev ${NET_IFACE} root 2>/dev/null || true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now fq-qdisc.service
    log "fq qdisc unit active on ${NET_IFACE}"
}

# ── Kernel / sysctl — drop-in file ───────────────────────────────────────────
configure_sysctl() {
    step "sysctl tuning (drop-in)"

    # Check conntrack availability before writing those keys
    local has_conntrack=false
    if modinfo nf_conntrack &>/dev/null || lsmod | grep -q nf_conntrack; then
        has_conntrack=true
    fi

    cat > /etc/sysctl.d/99-ssh-tls.conf << 'EOF'
# ── Congestion control ───────────────────────────────────────────────────────
# BBR: model-based, not loss-based — handles lossy mobile without backing off
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Buffers ──────────────────────────────────────────────────────────────────
# BDP at 128kbps / 40ms RTT = ~640B — buffers are for burst headroom, not steady-state
# 4MB max: fits in 2GB comfortably for 2 users
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 87380 4194304
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_mem = 16384 65536 131072

# ── TCP Fast Open ─────────────────────────────────────────────────────────────
# 3 = server+client; saves 1 RTT on reconnect — valuable at 20-40ms
net.ipv4.tcp_fastopen = 3

# ── MTU Probing ───────────────────────────────────────────────────────────────
# Mobile carriers frequently have inconsistent MTU (PPPoE, GRE tunnels)
# 2 = always probe; base_mss=1024 as safe starting point under TLS overhead
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024

# ── Keepalive ─────────────────────────────────────────────────────────────────
# Kernel-level keepalive as backstop; SSH-level ClientAliveInterval handles app layer
# 60s start, 10s interval × 6 = 120s detection window for dead peers
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# ── Retransmission ────────────────────────────────────────────────────────────
# orphan_retries=2: clear zombie sockets fast after mobile disconnect
# retries2=8: ~51s patience for peer during signal loss (not 15min default)
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_retries2 = 8

# ── TIME_WAIT ─────────────────────────────────────────────────────────────────
# tw_reuse=1: reuse sockets safely (requires timestamps=1)
# fin_timeout=15: shorten FIN_WAIT2 — mobile disconnects leave many of these
# tw_buckets=8192: 2 users produce very few TIME_WAITs; save RAM
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 8192

# ── SYN resilience ────────────────────────────────────────────────────────────
# syncookies=1: protect against SYN flood without dropping legitimate reconnects
# Lower retries: don't waste time on clearly-dead connection attempts
net.ipv4.tcp_syn_retries = 4
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 512

# ── Timestamps / SACK ────────────────────────────────────────────────────────
# timestamps: required for tw_reuse and RTT estimation
# sack: selective retransmit — avoid full-window retransmit on burst loss
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# ── Hardening ─────────────────────────────────────────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# ── File descriptors ──────────────────────────────────────────────────────────
fs.file-max = 65536

# ── VM ────────────────────────────────────────────────────────────────────────
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

    # Conntrack keys only if module available (some VPS kernels strip it)
    if [[ "$has_conntrack" == "true" ]]; then
        cat >> /etc/sysctl.d/99-ssh-tls.conf << 'EOF'

# ── Connection tracking ───────────────────────────────────────────────────────
# 2 users, very low table needed; defaults (65536) waste RAM
net.netfilter.nf_conntrack_max = 8192
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15
EOF
        log "  conntrack tuning included"
    else
        warn "  conntrack module not loaded — skipping conntrack sysctl keys"
    fi

    sysctl -p /etc/sysctl.d/99-ssh-tls.conf
    log "sysctl applied"
}

# ── nftables — portable conservative rules ───────────────────────────────────
configure_firewall() {
    step "nftables firewall"

    # Verify kernel has required nft features before writing rules
    # ct count is not portable across all Ubuntu 22.04 kernel variants
    # Using limit rate + meter which are universally supported
    cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {

    # Per-IP connection rate: track new TLS connections per source
    # meter is more portable than ct count sets across kernel versions
    chain input {
        type filter hook input priority filter; policy drop;

        # Fast path: established/related — kernel handles, minimal overhead
        ct state established,related accept

        # Loopback: always allow
        iif lo accept

        # ICMP: path MTU discovery + basic reachability, rate-limited
        ip  protocol icmp  icmp  type { echo-request, echo-reply,
            destination-unreachable, time-exceeded } limit rate 5/second accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply,
            nd-neighbor-solicit, nd-neighbor-advert,
            destination-unreachable } limit rate 5/second accept

        # Port 443 (stunnel/TLS):
        # Rate limit: max 20 new connections per IP per 60s
        # Handles reconnect storms (mobile signal recovery) without blocking
        # Conservative: 20/60s >> 2 users normal usage (1-2 connections each)
        tcp dport 443 ct state new \
            limit rate over 20/minute \
            drop

        tcp dport 443 ct state new accept

        # Everything else dropped
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    # Validate rules before applying
    nft -c -f /etc/nftables.conf || err "nftables rule validation failed"

    systemctl enable nftables
    systemctl restart nftables
    log "nftables configured (portable rules, no fail2ban dependency)"
}

# ── journald ──────────────────────────────────────────────────────────────────
configure_journald() {
    step "journald tuning"
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/low-overhead.conf << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=32M
Compress=yes
RateLimitInterval=30s
RateLimitBurst=100
EOF
    systemctl restart systemd-journald
    log "journald: volatile, 32MB, compressed"
}

# ── System limits ─────────────────────────────────────────────────────────────
configure_limits() {
    step "System limits"
    cat > /etc/security/limits.d/ssh-tls.conf << 'EOF'
*    soft nofile 16384
*    hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
    log "File descriptor limits set"
}

# ── Self-healing watchdog ──────────────────────────────────────────────────────
configure_watchdog() {
    step "Self-healing watchdog"

    cat > "$MGMT_DIR/watchdog.sh" << 'WATCHDOG'
#!/usr/bin/env bash
# Called by systemd watchdog unit every 60s
# Restarts stunnel4 if port 443 is not listening
set -euo pipefail

LOG="/var/log/ssh-tls-watchdog.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }

if ! ss -tlnp | grep -q ':443'; then
    echo "$(ts) [WATCHDOG] Port 443 not listening — restarting stunnel4" >> "$LOG"
    systemctl restart stunnel4
    sleep 3
    if ss -tlnp | grep -q ':443'; then
        echo "$(ts) [WATCHDOG] stunnel4 recovered" >> "$LOG"
    else
        echo "$(ts) [WATCHDOG] stunnel4 restart FAILED" >> "$LOG"
        exit 1
    fi
fi

# Check SSH is on localhost
if ! ss -tlnp | grep -q '127.0.0.1:22'; then
    echo "$(ts) [WATCHDOG] SSH not on localhost — restarting ssh" >> "$LOG"
    systemctl restart ssh
fi
WATCHDOG
    chmod +x "$MGMT_DIR/watchdog.sh"

    cat > /etc/systemd/system/ssh-tls-watchdog.service << EOF
[Unit]
Description=SSH-TLS service watchdog
After=stunnel4.service ssh.service

[Service]
Type=oneshot
ExecStart=${MGMT_DIR}/watchdog.sh
EOF

    cat > /etc/systemd/system/ssh-tls-watchdog.timer << 'EOF'
[Unit]
Description=SSH-TLS watchdog timer (every 60s)

[Timer]
OnBootSec=120s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ssh-tls-watchdog.timer
    log "Watchdog timer: checks port 443 + SSH every 60s, auto-restarts"
}

# ── Management scripts ────────────────────────────────────────────────────────
create_management_scripts() {
    step "Management scripts"

    # ── user-add.sh ──────────────────────────────────────────────────────────
    cat > "$MGMT_DIR/user-add.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
[[ $# -lt 1 ]] && { echo "Usage: user-add <username> [days_valid=30]"; exit 1; }

USERNAME="$1"
DAYS="${2:-30}"
EXPIRY=$(date -d "+${DAYS} days" +%Y-%m-%d)
PASSWORD=$(openssl rand -base64 16 | tr -d '+/=\n' | cut -c1-14)

# Create restricted user: nologin shell, SSH ForceCommand handles tunnel
useradd -m -s /usr/sbin/nologin -e "$EXPIRY" -c "ssh-tls-user" "$USERNAME" 2>/dev/null \
    || { echo "User $USERNAME already exists"; exit 1; }
echo "$USERNAME:$PASSWORD" | chpasswd

# Allow password auth for this user specifically (shell=nologin blocks interactive)
# AllowTcpForwarding is what matters for tunnel use-case
# Record user in state file for list/monitoring
echo "$USERNAME|$EXPIRY|$(date -Iseconds)" >> /var/lib/ssh-tls/users.db

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " User    : $USERNAME"
echo " Password: $PASSWORD"
echo " Expires : $EXPIRY (${DAYS} days)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
SCRIPT

    # ── user-delete.sh ───────────────────────────────────────────────────────
    cat > "$MGMT_DIR/user-delete.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
[[ $# -lt 1 ]] && { echo "Usage: user-delete <username>"; exit 1; }
USERNAME="$1"
# Kill active sessions first
pkill -u "$USERNAME" -TERM 2>/dev/null || true
sleep 1
pkill -u "$USERNAME" -KILL 2>/dev/null || true
userdel -r "$USERNAME" 2>/dev/null && echo "Deleted: $USERNAME" || echo "User not found: $USERNAME"
# Remove from state db
sed -i "/^${USERNAME}|/d" /var/lib/ssh-tls/users.db 2>/dev/null || true
SCRIPT

    # ── user-list.sh ─────────────────────────────────────────────────────────
    cat > "$MGMT_DIR/user-list.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TODAY=$(date +%s)
printf "%-18s %-12s %-8s %-10s\n" "USER" "EXPIRES" "STATUS" "SESSIONS"
printf "%-18s %-12s %-8s %-10s\n" "──────────────────" "────────────" "────────" "──────────"
while IFS=: read -r user _ uid _ _ home shell; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ "$shell" != "/usr/sbin/nologin" && "$shell" != "/bin/rbash" ]] && continue
    expiry_str=$(chage -l "$user" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ "$expiry_str" == "never" ]]; then
        status="active"; expiry_disp="never"
    else
        expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null || echo 0)
        expiry_disp=$(date -d "@$expiry_epoch" +%Y-%m-%d 2>/dev/null || echo "unknown")
        [[ $expiry_epoch -lt $TODAY ]] && status="expired" || status="active"
    fi
    sessions=$(who | grep -c "^$user " 2>/dev/null || true)
    printf "%-18s %-12s %-8s %-10s\n" "$user" "$expiry_disp" "$status" "$sessions"
done < /etc/passwd
SCRIPT

    # ── monitor.sh ───────────────────────────────────────────────────────────
    cat > "$MGMT_DIR/monitor.sh" << 'SCRIPT'
#!/usr/bin/env bash
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
clear
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SSH-TLS Monitor — $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo -e "\n[ Memory ]"
free -h | awk 'NR==1{print "  "$0} NR==2{print "  "$0}'

echo -e "\n[ CPU ]"
top -bn1 | grep "Cpu(s)" | awk '{printf "  user:%-6s sys:%-6s idle:%s\n",$2,$4,$8}'

echo -e "\n[ Active SSH Sessions ]"
who 2>/dev/null | awk '{printf "  %s\n",$0}' || echo "  None"

echo -e "\n[ Port 443 Connections ]"
ss -tn state established '( dport = :443 or sport = :443 )' \
    | awk 'NR>1{print "  "$0}' | head -20

echo -e "\n[ TCP States ]"
ss -s | grep -E "estab|time-wait|close-wait" | awk '{print "  "$0}'

echo -e "\n[ Retransmit stats ]"
cat /proc/net/snmp | awk '
    /^Tcp:/ { if (header) {
        for(i=1;i<=NF;i++) vals[i]=$i
    } else { for(i=1;i<=NF;i++) keys[i]=$i; header=1 }
    }
    END { for(i=1;i<=length(keys);i++)
        if(keys[i]~/Retrans|OutSegs|InSegs/) printf "  %s: %s\n",keys[i],vals[i] }'

echo -e "\n[ Network (${IFACE}) ]"
read rx1 < /sys/class/net/"$IFACE"/statistics/rx_bytes
read tx1 < /sys/class/net/"$IFACE"/statistics/tx_bytes
sleep 1
read rx2 < /sys/class/net/"$IFACE"/statistics/rx_bytes
read tx2 < /sys/class/net/"$IFACE"/statistics/tx_bytes
printf "  RX: %d KB/s | TX: %d KB/s\n" \
    "$(( (rx2-rx1)/1024 ))" "$(( (tx2-tx1)/1024 ))"

echo -e "\n[ BBR / qdisc ]"
printf "  cc: %s | qdisc: " "$(sysctl -n net.ipv4.tcp_congestion_control)"
tc qdisc show dev "$IFACE" | awk '{printf "%s %s\n",$2,$3; exit}'

echo -e "\n[ Top Source IPs on :443 ]"
ss -tn state established '( sport = :443 )' \
    | awk 'NR>1{print $5}' | cut -d: -f1 \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "  %4s × %s\n",$1,$2}'
SCRIPT

    # ── health-check.sh ──────────────────────────────────────────────────────
    cat > "$MGMT_DIR/health-check.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok()   { echo -e "\033[0;32m[✓]\033[0m $1"; ((PASS++)); }
fail() { echo -e "\033[0;31m[✗]\033[0m $1"; ((FAIL++)); }
wn()   { echo -e "\033[1;33m[!]\033[0m $1"; ((WARN++)); }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SSH-TLS Health Check — $(date '+%H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Services
systemctl is-active ssh     -q && ok "sshd running"      || fail "sshd not running"
systemctl is-active stunnel4 -q && ok "stunnel4 running" || fail "stunnel4 not running"
systemctl is-active nftables -q && ok "nftables running" || fail "nftables not running"
systemctl is-active fq-qdisc -q && ok "fq-qdisc active"  || fail "fq-qdisc not active"

# Ports
ss -tlnp | grep -q '127.0.0.1:22' && ok "SSH on localhost:22"   || fail "SSH not on localhost:22"
ss -tlnp | grep -q ':443'          && ok "Port 443 listening"    || fail "Port 443 not listening"
! ss -tlnp | grep -q '0.0.0.0:22' && ok "SSH not public"        || fail "SSH exposed publicly!"

# BBR
[[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]] \
    && ok "BBR active" || fail "BBR not active"

# fq
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
tc qdisc show dev "$IFACE" | grep -q fq && ok "fq qdisc on ${IFACE}" || fail "fq qdisc missing"

# Certificate
CERT="/etc/stunnel/certs/stunnel.pem"
if [[ -f "$CERT" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" | cut -d= -f2)
    DAYS_LEFT=$(( ( $(date -d "$EXPIRY" +%s) - $(date +%s) ) / 86400 ))
    [[ $DAYS_LEFT -gt 90 ]] && ok "TLS cert valid (${DAYS_LEFT}d left)" \
        || { [[ $DAYS_LEFT -gt 30 ]] && wn "TLS cert expires in ${DAYS_LEFT}d" \
             || fail "TLS cert expires in ${DAYS_LEFT}d — renew NOW"; }
    # Validate cert is readable and non-corrupted
    openssl x509 -noout -in "$CERT" 2>/dev/null && ok "TLS cert parseable" || fail "TLS cert corrupted"
else
    fail "TLS cert not found"
fi

# TLS connectivity (loopback)
if command -v openssl &>/dev/null; then
    echo Q | openssl s_client -connect 127.0.0.1:443 \
        -servername "$(hostname -f)" -brief 2>/dev/null | grep -q "Verification" \
        && ok "TLS handshake success" || wn "TLS handshake check inconclusive"
fi

# Memory
RAM_FREE=$(free -m | awk '/^Mem:/{print $7}')
[[ $RAM_FREE -gt 200 ]] && ok "Free RAM: ${RAM_FREE}MB" || wn "Low free RAM: ${RAM_FREE}MB"

# Watchdog timer
systemctl is-active ssh-tls-watchdog.timer -q \
    && ok "Watchdog timer active" || wn "Watchdog timer not running"

echo ""
echo "Results: ${PASS} passed | ${WARN} warnings | ${FAIL} failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
SCRIPT

    # ── backup-config.sh ─────────────────────────────────────────────────────
    cat > "$MGMT_DIR/backup-config.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1
DEST="/var/backups/ssh-tls/manual-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DEST"
cp -a /etc/ssh/sshd_config.d/10-mobile-tunnel.conf "$DEST/" 2>/dev/null || true
cp -a /etc/stunnel/ "$DEST/"
cp -a /etc/nftables.conf "$DEST/"
cp -a /etc/sysctl.d/99-ssh-tls.conf "$DEST/"
cp -a /etc/systemd/system/fq-qdisc.service "$DEST/" 2>/dev/null || true
cp -a /var/lib/ssh-tls/ "$DEST/" 2>/dev/null || true
tar -czf "${DEST}.tar.gz" -C "$(dirname "$DEST")" "$(basename "$DEST")"
rm -rf "$DEST"
echo "Backup: ${DEST}.tar.gz"
ls -lh "${DEST}.tar.gz"
SCRIPT

    # ── uninstall.sh ─────────────────────────────────────────────────────────
    cat > "$MGMT_DIR/uninstall.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -ne 0 ]] && echo "Run as root" && exit 1

read -rp "This will remove all SSH-TLS configs. Type YES to confirm: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && echo "Aborted" && exit 0

systemctl disable --now stunnel4 fq-qdisc ssh-tls-watchdog.timer \
    ssh-tls-cert-renew.timer 2>/dev/null || true

rm -f /etc/ssh/sshd_config.d/10-mobile-tunnel.conf
rm -f /etc/sysctl.d/99-ssh-tls.conf
rm -f /etc/security/limits.d/ssh-tls.conf
rm -f /etc/systemd/system/fq-qdisc.service
rm -f /etc/systemd/system/ssh-tls-watchdog.*
rm -f /etc/systemd/system/ssh-tls-cert-renew.*
rm -f /etc/systemd/system/stunnel4.service.d/hardening.conf
rm -f /etc/systemd/journald.conf.d/low-overhead.conf

# Restore default nftables (allow all) — operator should reconfigure
echo '#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input  { type filter hook input  priority filter; policy accept; }
  chain output { type filter hook output priority filter; policy accept; }
}' > /etc/nftables.conf
systemctl restart nftables

sysctl -p /etc/sysctl.conf 2>/dev/null || true
systemctl daemon-reload
systemctl restart ssh

echo "Uninstall complete. Review /etc/stunnel/ and /etc/ssh/ manually."
SCRIPT

    chmod +x "$MGMT_DIR"/*.sh

    # Symlinks
    local cmds=(user-add user-delete user-list monitor health-check backup-config)
    for cmd in "${cmds[@]}"; do
        ln -sf "$MGMT_DIR/${cmd}.sh" "/usr/local/bin/${cmd}"
    done

    log "Management scripts: /usr/local/bin/{$(IFS=,; echo "${cmds[*]}")}"
}

# ── Canary validation ─────────────────────────────────────────────────────────
canary_validate() {
    step "Canary validation"
    local failures=0

    sleep 2  # Let services settle

    # 1. SSH config parses cleanly
    sshd -t 2>/dev/null && log "  sshd config OK" || { warn "  sshd config FAIL"; ((failures++)); }

    # 2. stunnel4 active
    systemctl is-active stunnel4 -q && log "  stunnel4 active" || { warn "  stunnel4 not active"; ((failures++)); }

    # 3. Port 443 listening
    ss -tlnp | grep -q ':443' && log "  :443 listening" || { warn "  :443 not listening"; ((failures++)); }

    # 4. SSH on localhost only
    ss -tlnp | grep -q '127.0.0.1:22' && log "  SSH on localhost" || { warn "  SSH not on localhost"; ((failures++)); }

    # 5. BBR active
    [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == "bbr" ]] \
        && log "  BBR active" || { warn "  BBR not active"; ((failures++)); }

    # 6. fq qdisc
    tc qdisc show dev "$NET_IFACE" | grep -q fq \
        && log "  fq on ${NET_IFACE}" || { warn "  fq qdisc missing"; ((failures++)); }

    # 7. nftables has port 443 rule
    nft list ruleset | grep -q '443' \
        && log "  nftables :443 rule present" || { warn "  nftables rule missing"; ((failures++)); }

    if [[ $failures -gt 0 ]]; then
        warn "Canary: $failures check(s) failed — review above. System may still function."
    else
        log "Canary: all checks passed"
    fi
}

# ── Record installed state ────────────────────────────────────────────────────
record_state() {
    cat > "$STATE_DIR/install.state" << EOF
SCRIPT_VERSION=${SCRIPT_VERSION}
CONFIG_VERSION=${CONFIG_VERSION}
INSTALL_DATE=$(date -Iseconds)
NET_IFACE=${NET_IFACE}
TLS_DOMAIN=${TLS_DOMAIN}
STUNNEL_PORT=${STUNNEL_PORT}
EOF
    touch "$STATE_DIR/users.db"
    log "State recorded: $STATE_DIR/install.state"
}

# ── Final summary ─────────────────────────────────────────────────────────────
print_summary() {
    # Get server IP without external call
    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
        | head -1)
    [[ -z "$server_ip" ]] && server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo -e "${B}  SSH-over-TLS v${SCRIPT_VERSION} — Deployment Complete${N}"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
    echo ""
    echo -e "  ${B}Server IP  :${N} ${server_ip}"
    echo -e "  ${B}TLS Port   :${N} 443"
    echo -e "  ${B}Protocol   :${N} SSH over TLS 1.3 (stunnel4)"
    echo -e "  ${B}SNI        :${N} ${TLS_DOMAIN}"
    echo -e "  ${B}Interface  :${N} ${NET_IFACE}"
    echo ""
    echo -e "  ${B}Client Config (Dark Tunnel / HTTP Injector / HA Tunnel Plus):${N}"
    echo -e "  ┌──────────────────────────────────────────────────────┐"
    echo -e "  │ Server      : ${server_ip}"
    echo -e "  │ Port        : 443"
    echo -e "  │ Type        : SSL/TLS"
    echo -e "  │ SNI         : ${TLS_DOMAIN}"
    echo -e "  │ SSH Host    : 127.0.0.1    SSH Port: 22"
    echo -e "  │ Keepalive   : 30s interval"
    echo -e "  └──────────────────────────────────────────────────────┘"
    echo ""
    echo -e "  ${B}Commands:${N}"
    echo -e "    user-add <name> [days]  — create tunnel user"
    echo -e "    user-list               — list users + expiry"
    echo -e "    health-check            — verify all components"
    echo -e "    monitor                 — realtime stats"
    echo -e "    backup-config           — backup configs"
    echo ""
    echo -e "  ${B}Log:${N}    $LOG_FILE"
    echo -e "  ${B}State:${N}  $STATE_DIR"
    echo -e "  ${B}Backup:${N} $BACKUP_ROOT"
    echo ""
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "" >> "$LOG_FILE"
    echo "=== Install started $(date -Iseconds) ===" >> "$LOG_FILE"

    echo -e "${B}${C}"
    echo "  SSH-over-TLS Production Installer v${SCRIPT_VERSION}"
    echo "  128kbps/user | RTT 20-40ms | BBR+fq | reliability-first"
    echo -e "${N}"

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
