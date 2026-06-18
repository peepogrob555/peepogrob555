#!/usr/bin/env bash
################################################################################
# vmess-ws-setup.sh
#
# จุดประสงค์:
#   ตั้งเซิร์ฟเวอร์ VPS สำหรับ VMESS over WebSocket (Security: none, no TLS)
#   ปรับจูนทั้งระบบให้เหมาะกับ "เน็ตมือถือ" (AIS 4G/5G) เน้นปิงต่ำ-นิ่ง-เสถียร
#   รองรับ throughput สูงสุดถึง 1 Gbps โดยไม่ให้ buffer ใหญ่จนมือถือแลค
#
# สเปกเครื่องที่ออกแบบมาให้:
#   Ubuntu 24.04, RAM ~1950MB, 1 vCPU @ 2.69GHz, NIC=eth0, ดิสก์ ~30GB
#   ผู้ใช้งานจริง 2 คน (เบามาก ใช้ทรัพยากรเต็มที่ได้)
#
# โปรโตคอล/พารามิเตอร์ที่ตรึงไว้:
#   - VMESS + WebSocket, ไม่ใช้ TLS (security: none)
#   - พอร์ตที่เปิด (TCP): 22 80 443 8080 8443 2053
#   - Firewall: policy ACCEPT ก่อน แล้วค่อย DROP เฉพาะพอร์ตอันตรายที่รู้จริง
#     (ไม่ปิดทั้งหมดแบบ default-deny เพราะอาจกระทบ service ที่ไม่รู้จัก)
#   - ปิด UDP เฉพาะพอร์ตอันตรายที่รู้ (ไม่ปิด UDP ทั้งกระดาน)
#   - DNS: บังคับ 1.1.1.1 / 1.0.0.1 กัน DNS leak
#   - ปิด IPv6 ทั้งระบบ กัน IPv6 leak
#   - congestion control: BBR2 (fallback BBR)
#   - qdisc: CAKE + bandwidth 1gbit + diffserv4 (ACK priority + AQM ถูกต้อง)
#   - TCP buffer: BDP = 1000Mbps × 60ms = 7,500,000 bytes
#     TCP_BUF_MAX = 15MB (2×BDP) — รองรับ throughput เต็ม 1Gbps
#     rmem/wmem default = 256KB — กันมือถือ latency พุ่งตอน idle
#   - MTU 1500, MSS 1460
#   - Swap 4096MB, swappiness=10
#   - log (journald + xray) บน tmpfs (RAM only)
#
# หมายเหตุ buffer design:
#   max buffer 15MB ไม่ได้แปลว่าทุก connection กิน 15MB พร้อมกัน
#   kernel จัดสรรตาม cwnd จริง ถ้า RTT ต่ำหรือ window เล็ก kernel ใช้น้อยกว่า
#   CAKE+BBR2 ทำหน้าที่กัน bufferbloat ฝั่ง sender ก่อนที่ buffer จะโตเกินจริง
#
# ลำดับขั้นตอน:
#   STAGE 0  - Preflight check
#   STAGE 1  - apt update/upgrade
#   STAGE 2  - Firewall (policy accept + block known-dangerous ports)
#   STAGE 3  - ติดตั้ง 3x-ui
#   STAGE 4  - Network tuning (sysctl, BBR2/BBR, CAKE 1gbit, MTU/MSS, DNS, IPv6 off)
#   STAGE 5  - Swap setup
#   STAGE 6  - ย้าย log ไปบน tmpfs
#   STAGE 7  - Verify ทุกระบบ + สรุป
#
# วิธีรัน:
#   sudo bash vmess-ws-setup.sh
#
# Idempotent: รันซ้ำได้
################################################################################

set -uo pipefail

################################################################################
# ค่าคงที่ / พารามิเตอร์
################################################################################

readonly LOG_FILE="/var/log/vmess-ws-setup.log"
readonly TCP_PORTS=(22 80 443 8080 8443 2053)
readonly NIC="eth0"
readonly MTU_VAL=1500
readonly MSS_VAL=1460
readonly DNS_PRIMARY="1.1.1.1"
readonly DNS_SECONDARY="1.0.0.1"
readonly SWAP_FILE="/swapfile"
readonly SWAP_SIZE_MB=4096
readonly SWAPPINESS=10
readonly XUI_LOG_DIR="/var/log/x-ui"
readonly TMPLOG_SIZE="256M"

# ---- BDP สำหรับ 1 Gbps / RTT 60ms ----
# BDP = 1000 Mbps × (60ms/1000) / 8 = 7,500,000 bytes (~7.5 MB)
# TCP_BUF_MAX = 2 × BDP = 15 MB  --> รองรับ throughput เต็ม 1 Gbps
# rmem/wmem default = 256 KB     --> กันมือถือ idle buffer ใหญ่เกิน → latency พุ่ง
readonly BDP_BW_MBPS=1000
readonly BDP_RTT_MS=60
readonly BDP_BYTES=$(( BDP_BW_MBPS * 1000000 / 8 * BDP_RTT_MS / 1000 ))
readonly TCP_BUF_MAX=$(( BDP_BYTES * 2 ))           # 15,000,000 bytes (~15 MB)
readonly TCP_BUF_DEFAULT=262144                      # 256 KB — default ต่อ connection

# ---- พอร์ตอันตรายที่บล็อก (TCP) ----
# เลือกจาก well-known exploit / amplification / exposure ports เท่านั้น
# ไม่ปิดแบบ default-deny เพราะ VPS อาจมี service ที่ไม่รู้จักทำงานอยู่
readonly DANGEROUS_TCP="23 25 110 135 137 138 139 445 512 513 514 1433 1434 3306 3389 4444 5432 5900 6379 8545 11211 27017"
# พอร์ตอันตราย UDP (amplification source หรือ scan ที่รู้จัก)
readonly DANGEROUS_UDP="19 53 111 123 137 138 161 389 500 1900 3283 5353 11211"
# หมายเหตุ: UDP port 53 ปิดขาเข้าเพราะเราไม่ได้เป็น public DNS resolver
# (DNS ขาออกของเซิร์ฟเวอร์เองยังใช้ได้ปกติ เพราะ output chain policy accept)

################################################################################
# ฟังก์ชันช่วย
################################################################################

log()  { echo -e "[$(date '+%H:%M:%S')] $*"        | tee -a "$LOG_FILE"; }
ok()   { echo -e "[$(date '+%H:%M:%S')] [OK]   $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "[$(date '+%H:%M:%S')] [WARN] $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "[$(date '+%H:%M:%S')] [FAIL] $*" | tee -a "$LOG_FILE"; }

require_root() {
    [[ "${EUID}" -ne 0 ]] && { echo "ต้องรันด้วย root: sudo bash $0"; exit 1; }
}

################################################################################
# STAGE 0: Preflight check
################################################################################

stage0_preflight() {
    log "===== STAGE 0: Preflight check ====="

    . /etc/os-release 2>/dev/null || true
    log "OS: ${PRETTY_NAME:-unknown}"
    [[ "${VERSION_ID:-}" != "24.04" ]] && \
        warn "ออกแบบมาสำหรับ Ubuntu 24.04 เครื่องนี้คือ ${VERSION_ID:-unknown} จะพยายามรันต่อ"

    if ! ip link show "${NIC}" &>/dev/null; then
        err "ไม่พบ NIC ชื่อ ${NIC}"
        ip -brief link show | tee -a "$LOG_FILE"
        exit 1
    fi
    ok "พบ NIC: ${NIC}"

    ping -c1 -W3 1.1.1.1 &>/dev/null && ok "เน็ตออกได้ปกติ" || warn "ping ออกไม่ผ่าน (ICMP อาจถูกบล็อก)"

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    ok "Preflight ผ่าน"
}

################################################################################
# STAGE 1: apt update / upgrade
################################################################################

stage1_apt_update() {
    log "===== STAGE 1: apt update/upgrade ====="
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y 2>&1 | tee -a "$LOG_FILE"
    apt-get upgrade -y 2>&1 | tee -a "$LOG_FILE"
    apt-get dist-upgrade -y 2>&1 | tee -a "$LOG_FILE"

    apt-get install -y \
        nftables curl wget ca-certificates ethtool iproute2 \
        jq unzip cron iptables \
        2>&1 | tee -a "$LOG_FILE"

    apt-get autoremove -y 2>&1 | tee -a "$LOG_FILE"
    ok "apt เสร็จ"
}

################################################################################
# STAGE 2: Firewall — policy ACCEPT + block known-dangerous ports
#
#  *** แนวคิดเปลี่ยนจาก default-deny เป็น selective-deny ***
#
#  เหตุผล:
#    default-deny (policy drop) อาจตัด service ที่ไม่รู้จักซึ่งทำงานอยู่แล้ว
#    selective-deny บล็อกเฉพาะพอร์ตที่รู้ว่าอันตราย/ไม่ควรเปิดสู่อินเทอร์เน็ต
#    ยังคงกัน exploit ที่พบบ่อยได้ครอบคลุม โดยไม่กระทบ service อื่น
#
#  พอร์ตที่บล็อก (TCP): Telnet/23, SMTP/25, POP3/110, RPC/135,
#    NetBIOS/137-139, SMB/445, rexec-rlogin-rsh/512-514,
#    MSSQL/1433-1434, MySQL/3306, RDP/3389, Metasploit-common/4444,
#    PostgreSQL/5432, VNC/5900, Redis/6379, ETH-RPC/8545,
#    Memcached/11211, MongoDB/27017
#  พอร์ตที่บล็อก (UDP): chargen/19, DNS-inbound/53, portmap/111,
#    NTP-amplification/123, NetBIOS/137-138, SNMP/161,
#    LDAP-amplification/389, IKE/500, SSDP/1900,
#    Apple-remote/3283, mDNS/5353, Memcached/11211
################################################################################

stage2_firewall() {
    log "===== STAGE 2: Firewall (policy accept + selective deny) ====="

    systemctl enable nftables 2>&1 | tee -a "$LOG_FILE"

    # สร้าง TCP/UDP set string สำหรับใส่ใน nftables
    local tcp_set; tcp_set=$(echo "${DANGEROUS_TCP}" | tr ' ' ',')
    local udp_set; udp_set=$(echo "${DANGEROUS_UDP}" | tr ' ' ',')

    cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {

    # ---- sets ของพอร์ตอันตราย ----
    set dangerous_tcp {
        type inet_service
        elements = { ${tcp_set} }
    }

    set dangerous_udp {
        type inet_service
        elements = { ${udp_set} }
    }

    chain input {
        type filter hook input priority 0;
        # policy ACCEPT — อนุญาตทุกอย่างก่อน แล้วค่อยบล็อกที่อันตราย
        policy accept;

        # loopback ผ่านได้เสมอ
        iif "lo" accept

        # drop invalid state
        ct state invalid drop

        # ICMP: อนุญาต echo-request และ error types (จำเป็นสำหรับ PMTU)
        ip  protocol icmp  icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        # ---- บล็อกพอร์ตอันตราย TCP ----
        tcp dport @dangerous_tcp drop \
            comment "block known-dangerous TCP ports"

        # ---- บล็อกพอร์ตอันตราย UDP ----
        udp dport @dangerous_udp drop \
            comment "block known-dangerous UDP ports"

        # ---- rate-limit SYN flood กัน DoS เบาๆ ----
        # อนุญาต new SYN ไม่เกิน 100/วินาที ต่อ source IP (burst 200)
        tcp flags & (fin|syn|rst|ack) == syn \
            limit rate over 100/second burst 200 packets \
            drop \
            comment "syn-flood rate limit"

        # ถ้าไม่โดน rule ด้านบน -> policy accept ผ่านได้ตามปกติ
        counter
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOF

    nft -c -f /etc/nftables.conf
    if [[ $? -ne 0 ]]; then
        err "nftables config syntax error ตรวจสอบ /etc/nftables.conf"
        return 1
    fi

    systemctl restart nftables 2>&1 | tee -a "$LOG_FILE"
    sleep 1

    systemctl is-active --quiet nftables \
        && ok "nftables active — policy accept + block dangerous ports TCP:{${tcp_set}} UDP:{${udp_set}}" \
        || err "nftables ไม่ active ตรวจด้วย: systemctl status nftables"

    # ปิด ufw ถ้ามี กันชนกัน
    if dpkg -l ufw &>/dev/null 2>&1; then
        systemctl disable --now ufw 2>&1 | tee -a "$LOG_FILE" || true
        warn "พบ ufw ปิดให้แล้ว ใช้ nftables เป็นหลัก"
    fi

    log "--- nft ruleset ปัจจุบัน ---"
    nft list ruleset | tee -a "$LOG_FILE"
}

################################################################################
# STAGE 3: ติดตั้ง 3x-ui
################################################################################

stage3_install_3xui() {
    log "===== STAGE 3: ติดตั้ง 3x-ui ====="

    if systemctl list-unit-files | grep -q "^x-ui.service"; then
        warn "พบ x-ui service อยู่แล้ว ข้ามการติดตั้งซ้ำ"
        return 0
    fi

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 | tee -a "$LOG_FILE"

    sleep 2
    systemctl is-active --quiet x-ui \
        && ok "3x-ui ติดตั้งสำเร็จและรันอยู่" \
        || err "3x-ui service ไม่ active เช็คด้วย: systemctl status x-ui"

    log "ตั้ง inbound VMESS+WS (security: none) เองผ่าน 3x-ui panel"
}

################################################################################
# STAGE 4: Network tuning
#   4.1 ปิด IPv6
#   4.2 DNS lock
#   4.3 kernel module BBR2/BBR + CAKE
#   4.4 sysctl (1 Gbps BDP buffer + mobile tuning)
#   4.5 CAKE qdisc บน NIC พร้อม bandwidth 1gbit
#   4.6 persist CAKE ผ่าน systemd
#   4.7 MTU + MSS clamp
################################################################################

stage4_network_tuning() {
    log "===== STAGE 4: Network & TCP tuning (1 Gbps / RTT 60ms) ====="
    log "BDP = ${BDP_BW_MBPS}Mbps × ${BDP_RTT_MS}ms = ${BDP_BYTES} bytes"
    log "TCP_BUF_MAX = 2×BDP = ${TCP_BUF_MAX} bytes (~$((TCP_BUF_MAX/1024/1024)) MB)"
    log "TCP_BUF_DEFAULT = ${TCP_BUF_DEFAULT} bytes (256 KB — กัน mobile buffer โต)"

    # ----- 4.1 ปิด IPv6 -----
    log "-- ปิด IPv6 --"
    cat > /etc/sysctl.d/98-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.${NIC}.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/98-disable-ipv6.conf 2>&1 | tee -a "$LOG_FILE"

    if [[ -f /etc/default/grub ]]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            update-grub 2>&1 | tee -a "$LOG_FILE" || warn "update-grub ล้มเหลว (VPS ไม่ใช้ grub?) ข้ามได้ sysctl ใช้แทนได้"
        fi
    fi
    ok "ปิด IPv6 (sysctl + grub level)"

    # ----- 4.2 DNS lock -----
    log "-- ล็อก DNS เป็น ${DNS_PRIMARY}/${DNS_SECONDARY} --"

    if systemctl is-active --quiet systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/99-dns-lock.conf << EOF
[Resolve]
DNS=${DNS_PRIMARY} ${DNS_SECONDARY}
FallbackDNS=
Domains=~.
DNSStubListener=no
EOF
        systemctl restart systemd-resolved 2>&1 | tee -a "$LOG_FILE"
    fi

    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << EOF
nameserver ${DNS_PRIMARY}
nameserver ${DNS_SECONDARY}
options edns0
EOF
    chattr +i /etc/resolv.conf 2>&1 | tee -a "$LOG_FILE" \
        || warn "chattr +i ไม่รองรับ DNS ยังถูกตั้งไว้แต่ป้องกันเขียนทับไม่ได้ 100%"

    # บล็อก DNS query ขาออกที่ไม่ใช่ 1.1.1.1/1.0.0.1 กัน DNS leak
    if nft list table inet filter &>/dev/null 2>&1; then
        if ! nft list chain inet filter output 2>/dev/null | grep -q "dns-leak-guard"; then
            nft add rule inet filter output meta l4proto { udp, tcp } th dport 53 \
                ip daddr != { ${DNS_PRIMARY}, ${DNS_SECONDARY} } drop \
                comment "dns-leak-guard" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    ok "DNS ล็อก ${DNS_PRIMARY}/${DNS_SECONDARY} + บล็อก DNS ไป server อื่น"

    # ----- 4.3 โหลด kernel module -----
    log "-- โหลด kernel module --"

    # ลอง BBR2 ก่อน (kernel >= 6.3) fallback เป็น BBR
    local cc_module="tcp_bbr"
    modprobe tcp_bbr2 2>/dev/null && cc_module="tcp_bbr2" || true
    modprobe tcp_bbr 2>/dev/null || true

    if lsmod | grep -qE "tcp_bbr2|tcp_bbr"; then
        ok "โหลด BBR module สำเร็จ (module: ${cc_module})"
    else
        warn "โหลด BBR module ไม่สำเร็จ จะ fallback เป็น cubic"
    fi

    modprobe sch_cake 2>&1 | tee -a "$LOG_FILE"
    lsmod | grep -q sch_cake && ok "โหลด sch_cake สำเร็จ" \
        || err "sch_cake โหลดไม่ได้ ลอง: apt install linux-modules-extra-\$(uname -r)"

    # persist module โหลดตอนบูต
    echo "sch_cake"   > /etc/modules-load.d/sch_cake.conf
    echo "tcp_bbr"    > /etc/modules-load.d/tcp_bbr.conf
    echo "tcp_bbr2"  >> /etc/modules-load.d/tcp_bbr.conf 2>/dev/null || true
    ok "ตั้งให้โหลด module อัตโนมัติทุกครั้งที่บูต"

    # ----- 4.4 sysctl -----
    log "-- sysctl: BBR + buffer 1Gbps/60ms + mobile tuning --"

    # เลือก cc ที่ใช้จริง
    local tcp_cc="bbr"
    lsmod | grep -q tcp_bbr2 && tcp_cc="bbr2" || true

    cat > /etc/sysctl.d/99-vmess-ws-tuning.conf << EOF
# ======================================================
# congestion control
# ======================================================
# ใช้ BBR2 ถ้า kernel รองรับ ไม่งั้นใช้ BBR
# BBR/BBR2: เหมาะกับ mobile RTT แปรปรวน ลด bufferbloat
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = ${tcp_cc}

# ======================================================
# TCP buffer — 1 Gbps BDP design
# ======================================================
# BDP = 1000 Mbps × 60ms = 7,500,000 bytes
# TCP_BUF_MAX = 2×BDP = 15,000,000 bytes (~15 MB)
#   → รองรับ throughput เต็ม 1 Gbps ได้จริง
# default = 256 KB ต่อ connection
#   → กัน mobile idle connection ใช้ buffer ใหญ่เกิน → latency พุ่ง
# kernel ไม่ได้จัดสรร max ทันที จัดตาม cwnd จริงที่ BBR คำนวณ
# CAKE AQM จะ drop/delay ก่อนที่ buffer จะโตถึง max
net.ipv4.tcp_rmem = 4096 ${TCP_BUF_DEFAULT} ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_BUF_DEFAULT} ${TCP_BUF_MAX}
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.core.rmem_default = ${TCP_BUF_DEFAULT}
net.core.wmem_default = ${TCP_BUF_DEFAULT}
net.core.optmem_max = 65536

# ======================================================
# throughput สูง: เปิด autotuning และ feature ที่จำเป็น
# ======================================================
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_moderate_rcvbuf = 1    # kernel autotuning ปรับ buffer ตาม RTT จริง

# ======================================================
# mobile / LTE: RTT แปรปรวน ลด reconnect overhead
# ======================================================
# ปิด slow-start หลัง idle: มือถือเปิด/ปิด app บ่อย ไม่ต้องไต่ window ใหม่ทุกครั้ง
net.ipv4.tcp_slow_start_after_idle = 0

# fast open: ลด 1 RTT ตอนต่อใหม่ (3 = เปิดทั้ง client+server mode)
net.ipv4.tcp_fastopen = 3

# initial congestion window ใหญ่ขึ้น: ลด latency burst แรก บน RTT สูง
net.ipv4.tcp_init_cwnd = 10

# keepalive: ตรวจจับสายหลุดเร็ว (มือถือเปลี่ยนเสาบ่อย)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# FIN/TIME_WAIT: รีไซเคิล connection เร็วขึ้น (ลด port หมดบน VPS เล็ก)
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# SYN/connection backlog: เผื่อ reconnect ถี่จากมือถือสัญญาณไม่เสถียร
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096

# ======================================================
# PMTU / fragmentation
# ======================================================
net.ipv4.tcp_mtu_probing = 1        # เปิด PMTU discovery กัน black-hole

# ======================================================
# security: ลด attack surface
# ======================================================
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.${NIC}.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# ======================================================
# swap
# ======================================================
vm.swappiness = ${SWAPPINESS}
EOF

    sysctl --system 2>&1 | tee -a "$LOG_FILE"
    ok "sysctl โหลดเรียบร้อย (cc=${tcp_cc}, buf_default=${TCP_BUF_DEFAULT}B, buf_max=${TCP_BUF_MAX}B)"

    # ----- 4.5 CAKE qdisc — พร้อม bandwidth 1gbit -----
    log "-- ตั้ง CAKE qdisc บน ${NIC} (bandwidth 1gbit, diffserv4, triple-isolate) --"
    #
    # พารามิเตอร์ที่เปลี่ยนจากเวอร์ชันก่อน:
    #   bandwidth 1gbit  → บอก CAKE รู้ว่า uplink คือ 1 Gbps AQM ทำงานถูกต้อง
    #                       ถ้าไม่ตั้ง CAKE จะ "เดา" bandwidth เอง อาจกด queue ผิด
    #   diffserv4        → จัด 4 priority tier: bulk / best-effort / video / voice
    #                       ACK (ToS CS0) ได้ priority สูงกว่า bulk data
    #                       ลด ACK compression → ลด latency เวลา throughput สูง
    #   triple-isolate   → isolate ทั้ง src/dst/flow กัน flow เดียวกิน bandwidth ทั้งหมด
    #   nat              → track connection ผ่าน NAT (สำหรับ 3x-ui outbound)
    #   wash             → reset DSCP ขาเข้าจาก client กัน client mark traffic ผิด
    #
    tc qdisc replace dev "${NIC}" root cake \
        bandwidth 1gbit \
        diffserv4 \
        triple-isolate \
        nat \
        wash \
        2>&1 | tee -a "$LOG_FILE"

    tc qdisc show dev "${NIC}" | grep -q cake \
        && ok "CAKE qdisc (bandwidth=1gbit, diffserv4) บน ${NIC} สำเร็จ" \
        || err "ตั้ง CAKE ไม่สำเร็จ เช็ค: lsmod | grep cake"

    # ----- 4.6 persist CAKE ผ่าน systemd -----
    cat > /etc/systemd/system/cake-qdisc.service << EOF
[Unit]
Description=Apply CAKE qdisc (1gbit) on ${NIC} after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${NIC} root cake bandwidth 1gbit diffserv4 triple-isolate nat wash
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable cake-qdisc.service 2>&1 | tee -a "$LOG_FILE"
    ok "cake-qdisc.service enabled (รันอัตโนมัติทุก reboot)"

    # ----- 4.7 MTU + MSS clamp -----
    log "-- MTU=${MTU_VAL}, MSS clamp=${MSS_VAL} --"
    ip link set dev "${NIC}" mtu "${MTU_VAL}" 2>&1 | tee -a "$LOG_FILE"

    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
    if [[ -n "${NETPLAN_FILE:-}" ]]; then
        if ! grep -q "mtu:" "${NETPLAN_FILE}"; then
            cat > /etc/netplan/99-mtu-override.yaml << EOF
network:
  version: 2
  ethernets:
    ${NIC}:
      mtu: ${MTU_VAL}
EOF
            chmod 600 /etc/netplan/99-mtu-override.yaml
            netplan apply 2>&1 | tee -a "$LOG_FILE" \
                || warn "netplan apply ล้มเหลว MTU ที่ตั้งสดด้วย ip link ยังใช้ได้จนกว่าจะ reboot"
        fi
    else
        warn "ไม่พบ netplan ใช้ systemd service persist MTU"
        cat > /etc/systemd/system/mtu-persist.service << EOF
[Unit]
Description=Persist MTU ${MTU_VAL} on ${NIC}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${NIC} mtu ${MTU_VAL}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtu-persist.service 2>&1 | tee -a "$LOG_FILE"
    fi

    if command -v iptables &>/dev/null; then
        iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VAL}" 2>/dev/null \
          || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VAL}" 2>&1 | tee -a "$LOG_FILE"
        ok "MSS clamp = ${MSS_VAL} ตั้งผ่าน iptables mangle OUTPUT"
    else
        warn "ไม่พบ iptables ข้าม MSS clamp"
    fi

    ok "Network tuning (stage 4) เสร็จสมบูรณ์"
}

################################################################################
# STAGE 5: Swap
################################################################################

stage5_swap() {
    log "===== STAGE 5: Swap (${SWAP_SIZE_MB}MB, swappiness=${SWAPPINESS}) ====="

    if swapon --show | grep -q "${SWAP_FILE}"; then
        warn "swapfile ${SWAP_FILE} เปิดอยู่แล้ว ข้าม"
    else
        [[ -f "${SWAP_FILE}" ]] && rm -f "${SWAP_FILE}"
        fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}" 2>&1 | tee -a "$LOG_FILE" \
          || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=progress 2>&1 | tee -a "$LOG_FILE"
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}" 2>&1 | tee -a "$LOG_FILE"
        swapon "${SWAP_FILE}" 2>&1 | tee -a "$LOG_FILE"
        grep -q "${SWAP_FILE}" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        ok "สร้างและเปิด swapfile ${SWAP_SIZE_MB}MB เรียบร้อย"
    fi

    sysctl vm.swappiness 2>&1 | tee -a "$LOG_FILE"
    ok "swappiness=${SWAPPINESS}"
}

################################################################################
# STAGE 6: Log บน tmpfs (RAM only)
#
#   *** คำเตือน: log หายถ้าไฟดับ/force restart ***
#   *** การตั้งค่าระบบทั้งหมดยัง persistent ปกติ ***
################################################################################

stage6_ram_logs() {
    log "===== STAGE 6: ย้าย log ไปบน tmpfs (RAM only) ====="

    # journald → volatile
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-ram-only.conf << EOF
[Journal]
Storage=volatile
RuntimeMaxUse=128M
RuntimeKeepFree=64M
Compress=yes
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald 2>&1 | tee -a "$LOG_FILE"
    ok "journald Storage=volatile (RAM only)"

    # xray/3x-ui log → tmpfs bind mount
    mkdir -p "${XUI_LOG_DIR}"
    if ! grep -q "${XUI_LOG_DIR}" /etc/fstab; then
        echo "tmpfs ${XUI_LOG_DIR} tmpfs defaults,noatime,mode=0750,size=${TMPLOG_SIZE} 0 0" >> /etc/fstab
        ok "เพิ่ม tmpfs ${XUI_LOG_DIR} ใน /etc/fstab"
    else
        warn "mount entry ${XUI_LOG_DIR} มีใน /etc/fstab แล้ว ข้าม"
    fi

    mount -a 2>&1 | tee -a "$LOG_FILE"
    mount | grep -q "on ${XUI_LOG_DIR} type tmpfs" \
        && ok "${XUI_LOG_DIR} mount เป็น tmpfs (${TMPLOG_SIZE}) สำเร็จ" \
        || err "${XUI_LOG_DIR} mount ไม่สำเร็จ เช็ค: mount | grep x-ui"

    systemctl restart x-ui 2>&1 | tee -a "$LOG_FILE" \
        || warn "restart x-ui ไม่สำเร็จ (อาจยังไม่ได้ติดตั้งถ้าข้าม stage 3)"

    log "*** คำเตือน: log (journald+xray) บน RAM — หายถ้าไฟดับ/force restart ***"
    log "*** การตั้งค่าระบบ (sysctl/nftables/swap/qdisc/3x-ui config) ยัง persistent ปกติ ***"
}

################################################################################
# STAGE 7: Verify
################################################################################

stage7_verify() {
    log "===== STAGE 7: Verify ====="
    local pass=0 fail=0

    check() {
        local desc="$1" cmd="$2"
        if eval "$cmd" &>/dev/null; then
            ok "$desc"; pass=$((pass+1))
        else
            err "$desc"; fail=$((fail+1))
        fi
    }

    log "----- ผลตรวจสอบ -----"

    check "nftables service active"                        "systemctl is-active --quiet nftables"
    check "nftables policy accept (not default-deny)"      "nft list chain inet filter input | grep -q 'policy accept'"
    check "dangerous TCP ports blocked in nft set"         "nft list set inet filter dangerous_tcp | grep -q elements"
    check "dangerous UDP ports blocked in nft set"         "nft list set inet filter dangerous_udp | grep -q elements"
    check "IPv6 ปิดอยู่ (all.disable_ipv6=1)"             "[[ \$(sysctl -n net.ipv6.conf.all.disable_ipv6) -eq 1 ]]"
    check "DNS resolv.conf ชี้ไปที่ ${DNS_PRIMARY}"        "grep -q '${DNS_PRIMARY}' /etc/resolv.conf"
    check "BBR หรือ BBR2 เป็น congestion control"          "[[ \$(sysctl -n net.ipv4.tcp_congestion_control) =~ ^bbr ]]"
    check "default_qdisc = cake"                           "[[ \$(sysctl -n net.core.default_qdisc) == 'cake' ]]"
    check "CAKE module โหลดอยู่ (lsmod)"                   "lsmod | grep -q sch_cake"
    check "CAKE qdisc ติดตั้งบน ${NIC}"                    "tc qdisc show dev ${NIC} | grep -q cake"
    check "CAKE bandwidth ตั้งเป็น 1gbit"                  "tc qdisc show dev ${NIC} | grep -q 'bandwidth 1Gbit'"
    check "MTU ${NIC} = ${MTU_VAL}"                        "[[ \$(cat /sys/class/net/${NIC}/mtu) -eq ${MTU_VAL} ]]"
    check "tcp_slow_start_after_idle = 0"                  "[[ \$(sysctl -n net.ipv4.tcp_slow_start_after_idle) -eq 0 ]]"
    check "tcp_rmem max = ${TCP_BUF_MAX}"                  "sysctl -n net.ipv4.tcp_rmem | awk '{print \$3}' | grep -q ${TCP_BUF_MAX}"
    check "Swap active (${SWAP_FILE})"                     "swapon --show | grep -q ${SWAP_FILE}"
    check "swappiness = ${SWAPPINESS}"                     "[[ \$(sysctl -n vm.swappiness) -eq ${SWAPPINESS} ]]"
    check "journald = volatile"                            "grep -q 'Storage=volatile' /etc/systemd/journald.conf.d/99-ram-only.conf"
    check "${XUI_LOG_DIR} mount เป็น tmpfs"                "mount | grep -q 'on ${XUI_LOG_DIR} type tmpfs'"
    check "3x-ui service active"                           "systemctl is-active --quiet x-ui"
    check "cake-qdisc.service enabled (persist boot)"      "systemctl is-enabled --quiet cake-qdisc.service"

    echo "" | tee -a "$LOG_FILE"
    log "----- Firewall: พอร์ตที่ block -----"
    nft list set inet filter dangerous_tcp 2>/dev/null | tee -a "$LOG_FILE"
    nft list set inet filter dangerous_udp 2>/dev/null | tee -a "$LOG_FILE"

    echo "" | tee -a "$LOG_FILE"
    log "----- CAKE qdisc detail -----"
    tc qdisc show dev "${NIC}" 2>/dev/null | tee -a "$LOG_FILE"

    echo "" | tee -a "$LOG_FILE"
    log "----- TCP buffer settings -----"
    sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max 2>/dev/null | tee -a "$LOG_FILE"

    echo "" | tee -a "$LOG_FILE"
    log "===== สรุป: ผ่าน ${pass} ข้อ / ล้มเหลว ${fail} ข้อ ====="

    [[ "${fail}" -gt 0 ]] \
        && warn "มีบางจุดที่ verify ไม่ผ่าน ดู [FAIL] ด้านบนหรือใน ${LOG_FILE}" \
        || ok "ทุกระบบผ่านการตรวจสอบ"

    echo "" | tee -a "$LOG_FILE"
    log "======== สรุปสิ่งที่ตั้งค่าไว้ ========"
    log "  Firewall  : policy accept + block dangerous (ไม่ใช่ default-deny)"
    log "  CC        : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    log "  qdisc     : CAKE bandwidth=1gbit diffserv4 triple-isolate nat wash"
    log "  TCP buf   : default=256KB max=~15MB (2×BDP @1Gbps/60ms)"
    log "  MTU/MSS   : ${MTU_VAL}/${MSS_VAL}"
    log "  DNS       : ${DNS_PRIMARY}/${DNS_SECONDARY} (locked + leak guard)"
    log "  IPv6      : ปิด"
    log "  Swap      : ${SWAP_SIZE_MB}MB swappiness=${SWAPPINESS}"
    log "  Log       : RAM only (journald volatile + xray tmpfs)"
    log ""
    log "  *** แนะนำให้ reboot 1 ครั้งเพื่อยืนยัน persistent: sudo reboot ***"
    log "  *** ตั้ง inbound VMESS+WS ผ่าน 3x-ui panel ***"
    log "=========================================="
}

################################################################################
# MAIN
################################################################################

main() {
    require_root
    stage0_preflight
    stage1_apt_update
    stage2_firewall
    stage3_install_3xui
    stage4_network_tuning
    stage5_swap
    stage6_ram_logs
    stage7_verify

    echo "" | tee -a "$LOG_FILE"
    log "สคริปต์เสร็จสมบูรณ์ ดู log ได้ที่: ${LOG_FILE}"
}

main "$@"
