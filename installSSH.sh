#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  ssh_tunnel_optimize v4.0.0                                             ║
# ║  Ubuntu 22.04 | 1 vCPU | 2 GB RAM | TCP/443 | mobile gaming tunnel     ║
# ╚══════════════════════════════════════════════════════════════════════════╝

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
readonly SWAP_SIZE_MB=512   # safety net สำหรับ 2GB RAM

# SSH rate-limit
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

# ─── preflight ────────────────────────────────────────────────────────────────
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

# ─── backup ──────────────────────────────────────────────────────────────────
backup_configs() {
    step "Backup configs → ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
    for f in "${SSHD_CONF}" "${NFTABLES_CONF}" /etc/sysctl.d/ /etc/ssh/sshd_config.d/; do
        [[ -e "$f" ]] && cp -a "$f" "${BACKUP_DIR}/" && ok "backed up: $f"
    done
}

# ─── packages ────────────────────────────────────────────────────────────────
install_packages() {
    step "ติดตั้ง packages"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        iproute2 nftables util-linux openssh-server
    ok "packages พร้อม"
}

# ─── disable unnecessary services ────────────────────────────────────────────
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

# ─── swap ────────────────────────────────────────────────────────────────────
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

# ─── kernel modules ──────────────────────────────────────────────────────────
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

    # export ค่า QDISC_TYPE เพื่อใช้ใน setup_qdisc และ apply_sysctl
    export QDISC_TYPE
    if $loaded_cake; then
        QDISC_TYPE="cake"
    else
        QDISC_TYPE="fq_codel"
        warn "CAKE ไม่พร้อม — fallback เป็น fq_codel"
    fi
    info "qdisc: ${QDISC_TYPE}"
}

# ─── sysctl ──────────────────────────────────────────────────────────────────
apply_sysctl() {
    step "sysctl tuning"

    # sync default_qdisc กับ module ที่โหลดได้จริง
    local qdisc_sysctl="${QDISC_TYPE}"

    cat > "${SYSCTL_CONF}" <<EOF
# ── Congestion control ───────────────────────────────────────────────────────
# BBR: rate-based CC ที่ไม่พึ่ง buffer bloat signal เหมาะกับ mobile loss
net.core.default_qdisc = ${qdisc_sysctl}
net.ipv4.tcp_congestion_control = bbr

# ── Socket buffers (2 GB RAM) ─────────────────────────────────────────────────
# ไม่ oversized — เน้น latency ไม่ใช่ throughput
# tcp_moderate_rcvbuf: kernel ปรับ rcvbuf อัตโนมัติตาม RTT และ BDP จริง
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max     = 8388608
net.core.wmem_max     = 8388608
net.ipv4.tcp_rmem     = 4096 87380 8388608
net.ipv4.tcp_wmem     = 4096 65536 8388608
net.ipv4.tcp_moderate_rcvbuf = 1

# ── Mobile-specific ──────────────────────────────────────────────────────────
# slow_start_after_idle=0: ไม่ reset cwnd หลัง idle — สำคัญมากสำหรับ gaming
net.ipv4.tcp_slow_start_after_idle = 0
# mtu_probing=1: รับมือ PMTUD blackhole บน mobile carrier
net.ipv4.tcp_mtu_probing = 1
# ECN: บอก congestion โดยไม่ต้อง drop packet — ช่วยบน LTE/5G
net.ipv4.tcp_ecn = 1

# ── Fast failure / keepalive ─────────────────────────────────────────────────
# retry ต่ำ = fail fast แทนที่จะค้างนาน
net.ipv4.tcp_syn_retries     = 3
net.ipv4.tcp_synack_retries  = 3
# detect dead connection ภายใน 90 วินาที (60 + 10×3)
net.ipv4.tcp_keepalive_time   = 60
net.ipv4.tcp_keepalive_intvl  = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fin_timeout      = 15

# ── Forwarding (tunnel) ───────────────────────────────────────────────────────
net.ipv4.ip_forward = 1

# ── Memory (2 GB RAM) ─────────────────────────────────────────────────────────
# swappiness=10: ใช้ swap เป็น safety net ไม่ใช่ default path
vm.swappiness              = 10
vm.dirty_ratio             = 15
vm.dirty_background_ratio  = 5

# ── Hardening ────────────────────────────────────────────────────────────────
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

# ─── qdisc ───────────────────────────────────────────────────────────────────
# NOTE: CAKE/fq_codel ควบคุม egress ออกจาก VPS เท่านั้น
# ingress ของ VPS (= upload จาก client) ไม่สามารถ shape ได้จากฝั่ง server
# ประโยชน์: ป้องกัน burst queue บน egress + AQM ลด self-induced latency
# ไม่ใส่ bandwidth cap เพราะ throughput ขึ้นกับ network จริง
setup_qdisc() {
    step "Setup ${QDISC_TYPE} qdisc (no bandwidth cap)"

    if [[ "${QDISC_TYPE}" == "cake" ]]; then
        cat > "${QDISC_SCRIPT}" <<'QDISC'
#!/usr/bin/env bash
set -euo pipefail
IFACE=$(ip route show default | awk '/^default/ {print $5; exit}')
[[ -n "${IFACE:-}" ]] || exit 1

tc qdisc del dev "$IFACE" root 2>/dev/null || true

# CAKE — no bandwidth cap (throughput จาก network จริง)
# besteffort: single tier ไม่ใช้ diffserv (ไม่มี QoS marking จาก tunnel)
# rtt 50ms: domestic mobile (เปลี่ยนเป็น 100ms ถ้า cross-region)
# mpu 64: minimum packet unit สำหรับ mobile header
# nonat: masquerade อยู่ใน nftables แล้ว ไม่ต้อง NAT-aware
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

# fq_codel — fallback เมื่อ CAKE ไม่พร้อม
# target 5ms: latency target ก่อน mark/drop
# interval 100ms: window สำหรับ codel algorithm
# limit 512: queue depth ต่ำ — fail fast แทน buffer bloat
# quantum 1514: MTU-sized quantum
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

# ─── resource limits ──────────────────────────────────────────────────────────
# ป้องกัน SSH user fork bomb / fd exhaustion บน 1 vCPU
setup_limits() {
    step "Resource limits"
    cat > "${LIMITS_CONF}" <<'EOF'
# ป้องกัน resource abuse จาก SSH tunnel users
*  hard  nproc   100
*  soft  nproc   80
*  hard  nofile  4096
*  soft  nofile  2048
EOF
    ok "limits.conf พร้อม"
}

# ─── sshd ────────────────────────────────────────────────────────────────────
configure_sshd() {
    step "sshd config"
    mkdir -p "${SSHD_DROPIN_DIR}"

    grep -q "^Include" "${SSHD_CONF}" 2>/dev/null || \
        echo "Include /etc/ssh/sshd_config.d/*.conf" >> "${SSHD_CONF}"

    cat > "${SSHD_DROPIN}" <<'EOF'
# ── Port / Auth ──────────────────────────────────────────────────────────────
Port 443
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
UsePAM yes

# ── Performance / Compatibility ───────────────────────────────────────────────
UseDNS no
# Compression no: CPU cost สูงกว่าประโยชน์บน 1vCPU + gaming traffic ไม่ compressible
Compression no

# ── Session limits (2 users, 2GB RAM) ────────────────────────────────────────
MaxSessions 6
# MaxStartups 3:50:6: อนุญาต 3 unauthenticated พร้อมกัน
# drop 50% หลัง 3, hard limit 6
MaxStartups 3:50:6
MaxAuthTries 3
LoginGraceTime 20

# ── Keepalive (สำคัญสำหรับ mobile — NAT timeout ~60-90s) ─────────────────────
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3

# ── Forwarding ────────────────────────────────────────────────────────────────
AllowTcpForwarding yes
# GatewayPorts no: ป้องกัน tunnel bind 0.0.0.0 โดยไม่ตั้งใจ
# เปลี่ยนเป็น clientspecified ถ้าต้องการ reverse tunnel
GatewayPorts no
X11Forwarding no

# ── Logging (VERBOSE: debug mobile drop, key fingerprint, tunnel events) ─────
LogLevel VERBOSE
SyslogFacility AUTH

# ── Misc ──────────────────────────────────────────────────────────────────────
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    sshd -t || {
        error "sshd config ผิดพลาด — ลบ drop-in"
        rm -f "${SSHD_DROPIN}"
        exit 1
    }

    systemctl reload sshd
    ok "sshd port 443 — key-only, VERBOSE"
}

# ─── nftables ────────────────────────────────────────────────────────────────
configure_nftables() {
    step "nftables firewall"

    cat > "${NFTABLES_CONF}" <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {

    # dynamic blocklist: IP brute-force ถูก ban ${SSH_BAN_TIMEOUT}
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

        # ICMP เฉพาะที่จำเป็น
        ip protocol icmp icmp type {
            echo-request, echo-reply,
            destination-unreachable, time-exceeded
        } accept

        # ตรวจ blocklist ก่อน
        tcp dport 443 ct state new ip saddr @ssh_blocklist drop

        # rate-limit: เกิน ${SSH_RATE_NEW}/min → ban
        tcp dport 443 ct state new \
            limit rate over ${SSH_RATE_NEW}/minute burst ${SSH_RATE_BURST} packets \
            add @ssh_blocklist { ip saddr } drop

        tcp dport 443 ct state new accept

        # port 80 ปิด: ไม่มี web server
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    # NAT masquerade สำหรับ tunnel traffic
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

# ─── health check ─────────────────────────────────────────────────────────────
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

# ─── observability ───────────────────────────────────────────────────────────
print_observability() {
    cat <<'OBS'

══════════════════════════════════════════════════
  Observability Commands
══════════════════════════════════════════════════

  # active connections บน port 443
  ss -tnp | grep ':443'

  # qdisc stats (drops, ECN marks, backlog)
  tc -s qdisc show dev $(ip route show default | awk '/^default/{print $5}')

  # BBR cwnd + RTT per connection
  ss -tni | grep -A1 bbr

  # realtime traffic
  watch -n1 'ip -s link show $(ip route show default | awk "/^default/{print \$5}")'

  # sshd log (VERBOSE — key fingerprint, tunnel open/close)
  journalctl -fu ssh

  # IP ที่ถูก ban
  nft list set inet filter ssh_blocklist

  # nftables ruleset
  nft list ruleset

  # connection summary
  ss -s

  # memory + swap
  free -h && swapon --show

  # sshd runtime config
  sshd -T | grep -E 'port|compression|clientalive|maxsessions|maxstartups|passwordauth|pubkeyauth|maxauthtries|loglevel|gatewayports'

  # ยืนยัน kernel tuning
  sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_ecn net.core.default_qdisc net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_moderate_rcvbuf

OBS
}

# ─── rollback ────────────────────────────────────────────────────────────────
print_rollback() {
    cat <<EOF

══════════════════════════════════════════════════
  Rollback  (backup: ${BACKUP_DIR})
══════════════════════════════════════════════════

  # sshd
  rm -f ${SSHD_DROPIN}
  cp ${BACKUP_DIR}/sshd_config ${SSHD_CONF}
  sshd -t && systemctl reload sshd

  # nftables
  cp ${BACKUP_DIR}/nftables.conf ${NFTABLES_CONF}
  nft -f ${NFTABLES_CONF}

  # sysctl
  rm -f ${SYSCTL_CONF}
  sysctl --system

  # qdisc
  tc qdisc del dev \${IFACE} root 2>/dev/null || true
  systemctl disable --now setup-qdisc.service
  rm -f ${QDISC_SERVICE} ${QDISC_SCRIPT}
  systemctl daemon-reload

  # swap
  swapoff ${SWAP_FILE}
  rm -f ${SWAP_FILE}
  sed -i '\\|${SWAP_FILE}|d' /etc/fstab

  # resource limits
  rm -f ${LIMITS_CONF}

EOF
}

# ─── main ────────────────────────────────────────────────────────────────────
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
    verify_modules      # ต้องก่อน apply_sysctl และ setup_qdisc (export QDISC_TYPE)
    apply_sysctl        # ใช้ QDISC_TYPE จาก verify_modules
    setup_qdisc         # ใช้ QDISC_TYPE จาก verify_modules
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
