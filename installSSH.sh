#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="4.0.0"
readonly LOG_FILE="/var/log/ssh_tunnel_optimize.log"
readonly BACKUP_DIR="/root/ssh_tunnel_backup_$(date +%Y%m%d_%H%M%S)"

readonly SYSCTL_CONF="/etc/sysctl.d/99-ssh-tunnel.conf"
readonly NFTABLES_CONF="/etc/nftables.conf"
readonly SSHD_CONF="/etc/ssh/sshd_config"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-tunnel.conf"
readonly LIMITS_CONF="/etc/security/limits.d/99-ssh-tunnel.conf"
readonly QDISC_SCRIPT="/usr/local/sbin/setup-qdisc.sh"
readonly QDISC_SERVICE="/etc/systemd/system/setup-qdisc.service"
readonly SWAP_FILE="/swapfile"
readonly SWAP_SIZE_MB=512

readonly SSH_RATE_NEW=8
readonly SSH_RATE_BURST=12
readonly SSH_BAN_TIMEOUT="10m"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >> "$LOG_FILE"; }
info()  { echo -e "  ${GREEN}ℹ${NC}  ${*}";   log "INFO " "$*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  ${*}";  log "WARN " "$*"; }
error() { echo -e "  ${RED}✗${NC}  ${*}" >&2; log "ERROR" "$*"; }
step()  { echo -e "\n${BOLD}${BLUE}▶ ${*}${NC}"; log "STEP " "$*"; }
ok()    { echo -e "  ${GREEN}✓${NC}  ${*}";   log "OK   " "$*"; }

check_root() {
    [[ $EUID -eq 0 ]] || { error "ต้องรันด้วย root"; exit 1; }
}

check_ubuntu() {
    if grep -qi "ubuntu 22" /etc/os-release 2>/dev/null; then
        ok "Ubuntu 22.04 ยืนยันแล้ว"
    else
        warn "ไม่ใช่ Ubuntu 22.04 — ระวังความเข้ากันได้"
    fi
}

detect_iface() {
    IFACE=$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    [[ -n "${IFACE:-}" ]] || { error "ไม่พบ default interface"; exit 1; }
    info "Interface: ${IFACE}"
    export IFACE
}

backup_configs() {
    step "Backup configs → ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
    for f in "${SSHD_CONF}" "${NFTABLES_CONF}" /etc/sysctl.d/ /etc/ssh/sshd_config.d/; do
        [[ -e "$f" ]] && cp -a "$f" "${BACKUP_DIR}/" && ok "backed up: $f"
    done
}

install_packages() {
    step "ติดตั้ง packages"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        iproute2 nftables util-linux openssh-server
    ok "packages พร้อม"
}

disable_services() {
    step "ปิด services ที่ไม่ใช้"
    local svcs=(
        bluetooth avahi-daemon cups cups-browsed ModemManager
        snapd snapd.socket snapd.seeded.service apport whoopsie
        motd-news.timer unattended-upgrades packagekit polkit
    )
    for svc in "${svcs[@]}"; do
        systemctl disable --now "${svc}" 2>/dev/null && ok "ปิด: ${svc}" || true
    done
}

setup_swap() {
    step "Swap (${SWAP_SIZE_MB} MB)"

    if swapon --show | grep -q "${SWAP_FILE}"; then
        ok "Swap ใช้งานอยู่แล้ว — ข้าม"
        return
    fi

    if [[ ! -f "${SWAP_FILE}" ]]; then
        fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}" || \
            dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=none
    fi

    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}" -L tunnel-swap
    swapon "${SWAP_FILE}"
    grep -q "${SWAP_FILE}" /etc/fstab || \
        echo "${SWAP_FILE} none swap sw,pri=-2 0 0" >> /etc/fstab
    ok "Swap พร้อม (${SWAP_SIZE_MB} MB)"
}

verify_modules() {
    step "โหลด kernel modules"

    local loaded_cake=false
    for mod in tcp_bbr sch_fq sch_cake sch_fq_codel nft_limit; do
        if modprobe "$mod" 2>/dev/null; then
            ok "${mod} โหลดแล้ว"
            [[ "$mod" == "sch_cake" ]] && loaded_cake=true
        else
            warn "${mod} ไม่พร้อม"
        fi
    done

    export QDISC_TYPE
    if $loaded_cake; then
        QDISC_TYPE="cake"
    else
        QDISC_TYPE="fq_codel"
        warn "CAKE ไม่พร้อม — fallback เป็น fq_codel"
    fi
    info "qdisc: ${QDISC_TYPE}"
}

apply_sysctl() {
    step "sysctl tuning"

    local qdisc_sysctl="${QDISC_TYPE}"

    cat > "${SYSCTL_CONF}" <<EOF
net.core.default_qdisc = ${qdisc_sysctl}
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max     = 8388608
net.core.wmem_max     = 8388608
net.ipv4.tcp_rmem     = 4096 87380 8388608
net.ipv4.tcp_wmem     = 4096 65536 8388608
net.ipv4.tcp_moderate_rcvbuf = 1

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1

net.ipv4.tcp_syn_retries     = 3
net.ipv4.tcp_synack_retries  = 3
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fin_timeout      = 15

net.ipv4.ip_forward = 1

vm.swappiness              = 10
vm.dirty_ratio             = 15
vm.dirty_background_ratio  = 5

net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies              = 1
EOF

    sysctl --system -q

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    [[ "$cc" == "bbr" ]] && ok "BBR active" || warn "BBR ไม่ active — ได้: ${cc}"

    local qd
    qd=$(sysctl -n net.core.default_qdisc)
    [[ "$qd" == "${qdisc_sysctl}" ]] && ok "default_qdisc=${qd}" || warn "default_qdisc=${qd} (คาดหวัง ${qdisc_sysctl})"
}

setup_qdisc() {
    step "Setup ${QDISC_TYPE} qdisc (no bandwidth cap)"

    if [[ "${QDISC_TYPE}" == "cake" ]]; then
        cat > "${QDISC_SCRIPT}" <<'QDISC'
#!/usr/bin/env bash
set -euo pipefail
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
[[ -n "${IFACE:-}" ]] || exit 1

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root cake \
    besteffort \
    rtt 50ms   \
    mpu 64     \
    nonat
QDISC
    else
        cat > "${QDISC_SCRIPT}" <<'QDISC'
#!/usr/bin/env bash
set -euo pipefail
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
[[ -n "${IFACE:-}" ]] || exit 1

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root fq_codel \
    limit    512  \
    flows    1024 \
    target   5ms  \
    interval 100ms \
    quantum  1514
QDISC
    fi

    chmod +x "${QDISC_SCRIPT}"

    cat > "${QDISC_SERVICE}" <<EOF
[Unit]
Description=Setup ${QDISC_TYPE} qdisc for SSH tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${QDISC_SCRIPT}
RemainAfterExit=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now setup-qdisc.service
    ok "${QDISC_TYPE} qdisc active"
}

setup_limits() {
    step "Resource limits"
    cat > "${LIMITS_CONF}" <<'EOF'
*  hard  nproc   100
*  soft  nproc   80
*  hard  nofile  4096
*  soft  nofile  2048
EOF
    ok "limits.conf พร้อม"
}

configure_sshd() {
    step "sshd config"
    mkdir -p "${SSHD_DROPIN_DIR}"

    grep -q "^Include" "${SSHD_CONF}" 2>/dev/null || \
        echo "Include /etc/ssh/sshd_config.d/*.conf" >> "${SSHD_CONF}"

    # ลบ Subsystem sftp ออกจากทุกที่ก่อน แล้วให้ drop-in ของเราใส่เองเป็นที่เดียว
    sed -i '/^[[:space:]]*Subsystem[[:space:]]\+sftp/d' "${SSHD_CONF}"
    for f in "${SSHD_DROPIN_DIR}"/*.conf; do
        [[ -f "$f" && "$f" != "${SSHD_DROPIN}" ]] && \
            sed -i '/^[[:space:]]*Subsystem[[:space:]]\+sftp/d' "$f" || true
    done

    cat > "${SSHD_DROPIN}" <<'EOF'
Port 443
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
UsePAM yes

UseDNS no
Compression no

MaxSessions 6
MaxStartups 3:50:6
MaxAuthTries 3
LoginGraceTime 20

TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3

AllowTcpForwarding yes
GatewayPorts no
X11Forwarding no

LogLevel VERBOSE
SyslogFacility AUTH

PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    sshd -t || {
        error "sshd config ผิดพลาด — ลบ drop-in"
        rm -f "${SSHD_DROPIN}"
        exit 1
    }

    systemctl restart sshd
    ok "sshd port 443 — key-only, VERBOSE"
}

configure_nftables() {
    step "nftables firewall"

    cat > "${NFTABLES_CONF}" <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {

    set ssh_blocklist {
        type ipv4_addr
        flags dynamic, timeout
        timeout ${SSH_BAN_TIMEOUT}
    }

    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        ip protocol icmp icmp type {
            echo-request, echo-reply,
            destination-unreachable, time-exceeded
        } accept

        tcp dport 443 ct state new ip saddr @ssh_blocklist drop

        tcp dport 443 ct state new \
            limit rate over ${SSH_RATE_NEW}/minute burst ${SSH_RATE_BURST} packets \
            add @ssh_blocklist { ip saddr } drop

        tcp dport 443 ct state new accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
        cat >> "${NFTABLES_CONF}" <<'EOF'

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        masquerade
    }
}
EOF
        ok "NAT masquerade เปิด"
    fi

    systemctl enable nftables
    nft -f "${NFTABLES_CONF}"
    ok "nftables active"
}

health_check() {
    step "Health check"
    local pass=0 fail=0

    chk() {
        if eval "$2" &>/dev/null; then
            ok "$1"; (( pass++ ))
        else
            warn "FAIL: $1"; (( fail++ ))
        fi
    }

    chk "sshd running"              "systemctl is-active --quiet sshd"
    chk "sshd port 443"             "ss -tlnp | grep -q ':443'"
    chk "nftables running"          "systemctl is-active --quiet nftables"
    chk "BBR active"                "[[ \$(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]]"
    chk "ECN enabled"               "[[ \$(sysctl -n net.ipv4.tcp_ecn) == 1 ]]"
    chk "slow_start_after_idle=0"   "[[ \$(sysctl -n net.ipv4.tcp_slow_start_after_idle) == 0 ]]"
    chk "ip_forward=1"              "[[ \$(sysctl -n net.ipv4.ip_forward) == 1 ]]"
    chk "${QDISC_TYPE} on ${IFACE}" "tc qdisc show dev ${IFACE} | grep -q ${QDISC_TYPE}"
    chk "setup-qdisc enabled"       "systemctl is-enabled --quiet setup-qdisc"
    chk "swap active"               "swapon --show | grep -q ${SWAP_FILE}"
    chk "password auth disabled"    "sshd -T | grep -qi 'passwordauthentication no'"
    chk "pubkey auth enabled"       "sshd -T | grep -qi 'pubkeyauthentication yes'"
    chk "MaxAuthTries 3"            "sshd -T | grep -qi 'maxauthtries 3'"
    chk "MaxSessions 6"             "sshd -T | grep -qi 'maxsessions 6'"
    chk "Compression no"            "sshd -T | grep -qi 'compression no'"
    chk "LogLevel VERBOSE"          "sshd -T | grep -qi 'loglevel verbose'"
    chk "resource limits conf"      "[[ -f ${LIMITS_CONF} ]]"
    chk "no bandwidth cap"          "! tc qdisc show dev ${IFACE} | grep -q 'bandwidth'"
    chk "port 80 closed"            "! nft list ruleset | grep -q 'dport 80'"

    echo ""
    echo -e "  ${BOLD}ผล: ${GREEN}${pass} ผ่าน${NC} / ${RED}${fail} ไม่ผ่าน${NC}"
    [[ $fail -eq 0 ]] && ok "ระบบพร้อมใช้งาน" || warn "มีบาง check ไม่ผ่าน"
}

print_observability() {
    cat <<'OBS'

══════════════════════════════════════════════════
  Observability Commands
══════════════════════════════════════════════════

  ss -tnp | grep ':443'
  tc -s qdisc show dev $(ip route show default | awk '/^default/{print $5}')
  ss -tni | grep -A1 bbr
  watch -n1 'ip -s link show $(ip route show default | awk "/^default/{print \$5}")'
  journalctl -fu ssh
  nft list set inet filter ssh_blocklist
  nft list ruleset
  ss -s
  free -h && swapon --show
  sshd -T | grep -E 'port|compression|clientalive|maxsessions|maxstartups|passwordauth|pubkeyauth|maxauthtries|loglevel|gatewayports'
  sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_ecn net.core.default_qdisc net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_moderate_rcvbuf

OBS
}

print_rollback() {
    cat <<EOF

══════════════════════════════════════════════════
  Rollback  (backup: ${BACKUP_DIR})
══════════════════════════════════════════════════

  rm -f ${SSHD_DROPIN}
  cp ${BACKUP_DIR}/sshd_config ${SSHD_CONF}
  sshd -t && systemctl reload sshd

  cp ${BACKUP_DIR}/nftables.conf ${NFTABLES_CONF}
  nft -f ${NFTABLES_CONF}

  rm -f ${SYSCTL_CONF}
  sysctl --system

  tc qdisc del dev \${IFACE} root 2>/dev/null || true
  systemctl disable --now setup-qdisc.service
  rm -f ${QDISC_SERVICE} ${QDISC_SCRIPT}
  systemctl daemon-reload

  swapoff ${SWAP_FILE}
  rm -f ${SWAP_FILE}
  sed -i '\\|${SWAP_FILE}|d' /etc/fstab

  rm -f ${LIMITS_CONF}

EOF
}

main() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    touch "${LOG_FILE}"

    echo -e "\n${BOLD}SSH Tunnel Optimizer v${SCRIPT_VERSION}${NC}"
    echo "Target: Ubuntu 22.04 | 1 vCPU | 2 GB RAM | TCP/443 | no bandwidth cap"
    echo "Log: ${LOG_FILE}"
    echo "────────────────────────────────────────────────────────────"

    check_root
    check_ubuntu
    detect_iface
    backup_configs
    install_packages
    disable_services
    setup_swap
    verify_modules
    apply_sysctl
    setup_qdisc
    setup_limits
    configure_sshd
    configure_nftables
    health_check
    print_observability
    print_rollback

    echo -e "\n${BOLD}${GREEN}✓ เสร็จสิ้น v${SCRIPT_VERSION}${NC}"
    echo ""
    echo "  เชื่อมต่อ SOCKS5:"
    echo "  ssh -p 443 -N -D 1080 -i ~/.ssh/your_key user@<vps-ip>"
    echo ""
    echo "  เชื่อมต่อ port forward:"
    echo "  ssh -p 443 -N -L 8080:target-host:80 -i ~/.ssh/your_key user@<vps-ip>"
}

main "$@"
