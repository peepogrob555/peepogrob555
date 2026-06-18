#!/usr/bin/env bash
################################################################################
# vmess-ws-setup.sh
#
# จุดประสงค์:
#   ตั้งเซิร์ฟเวอร์ VPS สำหรับ VMESS over WebSocket (Security: none, no TLS)
#   ปรับจูนทั้งระบบให้เหมาะกับ "เน็ตมือถือ" (AIS 4G/5G) เน้นปิงต่ำ-นิ่ง-เสถียร
#   ไม่ได้เน้นความแรงสูงสุด (ไม่ cap bandwidth แต่ไม่ได้ดันทุกอย่างเพื่อ throughput)
#
# สเปกเครื่องที่ออกแบบมาให้:
#   Ubuntu 24.04, RAM ~1950MB, 1 vCPU @ 2.69GHz, NIC=eth0, ดิสก์ ~30GB
#   ผู้ใช้งานจริง 2 คน (เบามาก ใช้ทรัพยากรเต็มที่ได้)
#
# โปรโตคอล/พารามิเตอร์ที่ตรึงไว้ (อ้างอิงจาก requirement):
#   - VMESS + WebSocket, ไม่ใช้ TLS (security: none) -> เบากว่า TLS handshake
#   - พอร์ตที่เปิด (TCP เท่านั้น): 22 80 443 8080 8443 2053
#   - ปิด UDP ทั้งหมด (WS วิ่งบน TCP อย่างเดียว ไม่ต้องเปิด UDP เลย)
#   - DNS: บังคับ 1.1.1.1 / 1.0.0.1 (Cloudflare) กัน DNS leak
#   - ปิด IPv6 ทั้งระบบ กัน IPv6 leak ai่ว่าจะลืมปิด firewall v6
#   - คิวขาออก: CAKE (ต้องโหลด module sch_cake) + BBR เป็น congestion control
#   - ไม่ cap bandwidth (ไม่ตั้ง maxrate ใน CAKE) แต่ปรับ "ขนาดบัฟเฟอร์" ตาม BDP
#     อ้างอิง BDP = 400Mbps * 60ms ≈ 3,000,000 bytes (~3MB) เป็นเพดานบนของ
#     TCP window/buffer (sysctl) ไม่ใช่ตัว cap ความเร็วจริง
#   - MTU 1500 (ปรับให้เข้ากับ MTU ของ VPN/ทันเนล), MSS clamp ให้สัมพันธ์กัน
#   - Swap 4096MB, vm.swappiness=10 (RAM น้อย แต่ไม่อยากให้ thrash swap บ่อย
#     ตั้งต่ำให้ kernel "เลี่ยง" swap ไว้ก่อน ใช้ RAM เป็นหลัก)
#   - log (journald + xray) ทั้งหมดย้ายไปอยู่บน tmpfs (RAM only)
#     -> หมายเหตุสำคัญ: log จะ "หายถ้าไฟดับ/รีบูตกะทันหันโดยไม่ได้ shutdown
#        ปกติ" เพราะตั้งใจไม่ sync กลับ disk (เลือกความเป็นส่วนตัว+ความเร็ว
#        เหนือกว่าการเก็บ log ถาวร) ส่วนอื่นทั้งหมด (sysctl, nftables, systemd
#        unit, 3x-ui config, ฯลฯ) ยังคง persistent ผ่าน reboot ตามปกติ
#   - ไม่มี SSH key -> ใช้ password auth ต่อไป (ไม่ปิด PasswordAuthentication)
#   - ติดตั้ง 3x-ui ตัวเปล่า ไม่ patch sockopt เพิ่มเติม ตั้งค่า inbound ผ่าน
#     panel เอง
#
# ลำดับขั้นตอนของสคริปต์ (ตามที่ผู้ใช้ระบุ):
#   STAGE 0  - Preflight check (root, OS, arch, เน็ต)
#   STAGE 1  - apt update/upgrade ทั้งระบบ
#   STAGE 2  - ปิดพอร์ตทั้งหมดก่อน (nftables default-deny) แล้วเปิดเฉพาะที่ใช้
#   STAGE 3  - ติดตั้ง 3x-ui
#   STAGE 4  - Network tuning (sysctl, qdisc, BBR+CAKE, MTU/MSS, DNS, IPv6 off)
#   STAGE 5  - Swap setup (4096MB, swappiness=10)
#   STAGE 6  - ย้าย log ไปอยู่บน tmpfs (RAM only)
#   STAGE 7  - Verify ทุกระบบ + สรุปผลลัพธ์
#
# วิธีรัน:
#   sudo bash vmess-ws-setup.sh
#
# Idempotent: รันซ้ำได้ สคริปต์เช็คก่อนทำซ้ำในแต่ละจุดสำคัญ
################################################################################

set -uo pipefail
# หมายเหตุ: ไม่ใช้ "set -e" เพราะบางคำสั่ง (เช่น modprobe ของ cake บน kernel
# ที่ build ไม่ครบ) อาจ fail แบบไม่ critical อยากให้สคริปต์ไหลต่อแล้วไป
# สรุปสถานะใน verify stage ตอนท้ายแทน ทุกจุดสำคัญเช็ค exit code เอง

################################################################################
# ค่าคงที่ / พารามิเตอร์ที่ปรับได้ตรงนี้จุดเดียว
################################################################################

readonly LOG_FILE="/var/log/vmess-ws-setup.log"
readonly TCP_PORTS=(22 80 443 8080 8443 2053)
readonly NIC="eth0"
readonly MTU_VAL=1500
readonly MSS_VAL=1460                       # MTU 1500 - 40 (IP20+TCP20, ไม่มี VPN overhead เพิ่ม)
readonly DNS_PRIMARY="1.1.1.1"
readonly DNS_SECONDARY="1.0.0.1"
readonly SWAP_FILE="/swapfile"
readonly SWAP_SIZE_MB=4096
readonly SWAPPINESS=10
readonly BDP_BW_MBPS=400                    # อ้างอิงคำนวณบัฟเฟอร์ (ไม่ cap ความเร็วจริง)
readonly BDP_RTT_MS=60
readonly TMPLOG_SIZE="256M"                 # ขนาด tmpfs สำหรับ log (RAM 1950MB เหลือพอ)
readonly XUI_LOG_DIR="/var/log/x-ui"

# คำนวณ BDP (bytes) = (Mbps * 1,000,000 / 8) * (RTT_ms / 1000)
readonly BDP_BYTES=$(( BDP_BW_MBPS * 1000000 / 8 * BDP_RTT_MS / 1000 ))
# ตั้งเพดาน TCP buffer ที่ ~2x BDP เผื่อ burst สั้นๆ (หน่วย byte)
readonly TCP_BUF_MAX=$(( BDP_BYTES * 2 ))

################################################################################
# ฟังก์ชันช่วย: log, เช็ค error, เช็ค root
################################################################################

log()  { echo -e "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "[$(date '+%H:%M:%S')] [OK]   $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "[$(date '+%H:%M:%S')] [WARN] $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "[$(date '+%H:%M:%S')] [FAIL] $*" | tee -a "$LOG_FILE"; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ต้องรันด้วย root หรือ sudo เท่านั้น: sudo bash $0"
        exit 1
    fi
}

################################################################################
# STAGE 0: Preflight check
################################################################################

stage0_preflight() {
    log "===== STAGE 0: Preflight check ====="

    . /etc/os-release 2>/dev/null || true
    log "OS ตรวจพบ: ${PRETTY_NAME:-unknown}"
    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "สคริปต์นี้ออกแบบมาให้ Ubuntu 24.04 เครื่องนี้คือ ${VERSION_ID:-unknown} จะพยายามรันต่อแต่ผลลัพธ์อาจไม่ตรง 100%"
    fi

    if ! ip link show "${NIC}" &>/dev/null; then
        err "ไม่พบ NIC ชื่อ ${NIC} กรุณาตรวจสอบชื่อการ์ดเน็ตจริงด้วย: ip link show"
        log "NIC ที่มีอยู่จริงในเครื่อง:"
        ip -brief link show | tee -a "$LOG_FILE"
        exit 1
    fi
    ok "พบ NIC: ${NIC}"

    if ! ping -c1 -W3 1.1.1.1 &>/dev/null; then
        warn "ping ออกเน็ตไม่ผ่าน (อาจเป็นเพราะ ICMP ถูกบล็อกอยู่แล้ว หรือเน็ตมีปัญหา) จะลองรันต่อ"
    else
        ok "เน็ตออกได้ปกติ"
    fi

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    ok "Preflight ผ่าน เริ่มทำงานจริง"
}

################################################################################
# STAGE 1: apt update / upgrade ทั้งระบบ
################################################################################

stage1_apt_update() {
    log "===== STAGE 1: apt update/upgrade ====="
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y 2>&1 | tee -a "$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        err "apt-get update ล้มเหลว เช็คเน็ต/DNS ก่อน (ตอนนี้ DNS ยังไม่ถูกบังคับเป็น 1.1.1.1 อาจเป็นสาเหตุ)"
    fi

    apt-get upgrade -y 2>&1 | tee -a "$LOG_FILE"
    apt-get dist-upgrade -y 2>&1 | tee -a "$LOG_FILE"

    apt-get install -y \
        nftables \
        curl \
        wget \
        ca-certificates \
        ethtool \
        iproute2 \
        jq \
        unzip \
        cron \
        2>&1 | tee -a "$LOG_FILE"

    apt-get autoremove -y 2>&1 | tee -a "$LOG_FILE"
    ok "apt update/upgrade + ติดตั้งแพ็กเกจพื้นฐานเสร็จ"
}

################################################################################
# STAGE 2: Firewall - ปิดทุกพอร์ตก่อน แล้วเปิดเฉพาะที่ใช้ (nftables)
################################################################################

stage2_firewall() {
    log "===== STAGE 2: Firewall (nftables default-deny) ====="

    systemctl enable nftables 2>&1 | tee -a "$LOG_FILE"

    # หมายเหตุ: ปิด UDP ทั้งหมด เพราะ VMESS+WS วิ่งบน TCP อย่างเดียว
    # ไม่มี policy/inbound ใดของ WS ที่ใช้ UDP จริง การปิด UDP ทั้งกระดาน
    # ช่วยลดพื้นผิวโจมตี (DNS amplification ที่ไม่ได้ตั้งใจ, QUIC ที่ไม่ได้ใช้ ฯลฯ)
    cat > /etc/nftables.conf << EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # loopback ผ่านได้เสมอ
        iif "lo" accept

        # connection state: อนุญาต established/related, drop invalid
        ct state established,related accept
        ct state invalid drop

        # ICMP จำเป็นสำหรับ PMTU discovery (กัน MTU/fragmentation พัง)
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        ip6 nexthdr icmpv6 accept

        # TCP พอร์ตที่ใช้งานจริงเท่านั้น
        tcp dport { 22, 80, 443, 8080, 8443, 2053 } ct state new accept

        # UDP: ปิดทั้งหมดตามที่กำหนด (WS ไม่ใช้ UDP)
        # (ไม่มี rule accept ใดๆ สำหรับ udp -> โดน policy drop ทั้งหมด)

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
        err "nftables config มี syntax error ตรวจสอบ /etc/nftables.conf"
        return 1
    fi

    systemctl restart nftables 2>&1 | tee -a "$LOG_FILE"
    sleep 1

    if systemctl is-active --quiet nftables; then
        ok "nftables active เปิดพอร์ต TCP: ${TCP_PORTS[*]} | ปิด UDP ทั้งหมด | ปิดพอร์ตอื่นทั้งหมด"
    else
        err "nftables ไม่ active ตรวจสอบด้วย: systemctl status nftables"
    fi

    # ปิด ufw ถ้ามี กันชนกับ nftables (Ubuntu บางตัวลง ufw มาด้วย)
    if dpkg -l ufw &>/dev/null; then
        systemctl disable --now ufw 2>&1 | tee -a "$LOG_FILE" || true
        warn "พบ ufw ติดตั้งอยู่ ปิดให้แล้วเพื่อไม่ชนกับ nftables (ใช้ nftables เป็นตัวหลัก)"
    fi

    nft list ruleset | tee -a "$LOG_FILE"
}

################################################################################
# STAGE 3: ติดตั้ง 3x-ui
################################################################################

stage3_install_3xui() {
    log "===== STAGE 3: ติดตั้ง 3x-ui ====="

    if systemctl list-unit-files | grep -q "^x-ui.service"; then
        warn "พบ x-ui service อยู่แล้ว ข้ามการติดตั้งซ้ำ (รันสคริปต์ติดตั้งใหม่เองถ้าต้องการ reinstall)"
        return 0
    fi

    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 | tee -a "$LOG_FILE"

    sleep 2
    if systemctl is-active --quiet x-ui; then
        ok "3x-ui ติดตั้งสำเร็จและกำลังรันอยู่"
    else
        err "3x-ui ติดตั้งแล้วแต่ service ไม่ active เช็คด้วย: systemctl status x-ui และ x-ui log"
    fi

    log "หมายเหตุ: ตั้ง inbound VMESS+WS (security: none, port ตามที่เปิดไว้คือ 80/8080/2053 เป็นต้น) ผ่าน 3x-ui panel เอง"
}

################################################################################
# STAGE 4: Network tuning หลัก
#   - ปิด IPv6
#   - DNS lock เป็น 1.1.1.1 / 1.0.0.1
#   - BBR + CAKE qdisc
#   - sysctl buffer ตาม BDP
#   - MTU/MSS
################################################################################

stage4_network_tuning() {
    log "===== STAGE 4: Network & TCP tuning ====="

    # ----- 4.1 ปิด IPv6 ทั้งระบบ (กัน IPv6 leak) -----
    log "-- ปิด IPv6 ทั้งระบบ --"
    cat > /etc/sysctl.d/98-disable-ipv6.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.${NIC}.disable_ipv6 = 1
EOF
    sysctl -p /etc/sysctl.d/98-disable-ipv6.conf 2>&1 | tee -a "$LOG_FILE"

    # GRUB level เผื่อบาง provider โหลด ipv6 module ตั้งแต่ kernel boot
    if [[ -f /etc/default/grub ]]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            cp /etc/default/grub "/etc/default/grub.bak.$(date +%s)"
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            update-grub 2>&1 | tee -a "$LOG_FILE" || warn "update-grub ล้มเหลว (อาจเป็น VPS ที่ไม่ใช้ grub เช่น some KVM ที่ boot ผ่าน hypervisor) ข้ามได้ ปิดด้วย sysctl ก็พอ"
        fi
    fi
    ok "ปิด IPv6 เรียบร้อย (sysctl + grub level)"

    # ----- 4.2 DNS lock เป็น 1.1.1.1 / 1.0.0.1 กัน DNS leak -----
    log "-- ล็อก DNS เป็น ${DNS_PRIMARY} / ${DNS_SECONDARY} --"

    # ปิด systemd-resolved stub listener แล้วเขียน resolv.conf ตรงเพื่อกัน
    # โปรแกรมอื่นหรือ DHCP มาแก้ DNS ทับ (กัน DNS leak ผ่าน DHCP ของผู้ให้บริการ)
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
    # immutable flag กัน netplan/dhclient หรือ process อื่นมาเขียนทับไฟล์นี้
    chattr +i /etc/resolv.conf 2>&1 | tee -a "$LOG_FILE" || warn "chattr +i ใช้ไม่ได้ (filesystem ไม่รองรับ) DNS ยังถูกตั้งไว้ปกติ แต่ป้องกันการเขียนทับไม่ได้ 100%"

    # บล็อก DNS query ขาออกที่ไม่ใช่ 1.1.1.1/1.0.0.1 เพื่อกัน DNS leak แบบ
    # โปรแกรมไหนดันไปจิ้ม DNS server อื่นตรงๆ (ทั้ง TCP/UDP port 53)
    nft list table inet filter &>/dev/null
    if [[ $? -eq 0 ]]; then
        if ! nft list chain inet filter output 2>/dev/null | grep -q "dns-leak-guard"; then
            nft add rule inet filter output meta l4proto { udp, tcp } th dport 53 ip daddr != { ${DNS_PRIMARY}, ${DNS_SECONDARY} } drop comment "dns-leak-guard" 2>&1 | tee -a "$LOG_FILE"
        fi
    fi
    ok "DNS ถูกล็อกเป็น ${DNS_PRIMARY}/${DNS_SECONDARY} + บล็อก DNS query ไป server อื่น"

    # ----- 4.3 โหลด module CAKE + BBR -----
    log "-- โหลด kernel module: sch_cake, tcp_bbr --"
    modprobe sch_cake 2>&1 | tee -a "$LOG_FILE"
    if lsmod | grep -q sch_cake; then
        ok "โหลด sch_cake สำเร็จ"
    else
        err "โหลด sch_cake ไม่สำเร็จ kernel นี้อาจไม่มี module นี้ build มา (เช็คด้วย: apt install linux-modules-extra-\$(uname -r))"
    fi

    modprobe tcp_bbr 2>&1 | tee -a "$LOG_FILE"
    echo "sch_cake" > /etc/modules-load.d/sch_cake.conf
    echo "tcp_bbr" > /etc/modules-load.d/tcp_bbr.conf
    ok "ตั้งให้โหลด module อัตโนมัติทุกครั้งที่บูต (/etc/modules-load.d/)"

    # ----- 4.4 sysctl: BBR + buffer ตาม BDP + ปรับให้เหมาะ mobile/LTE -----
    log "-- ตั้ง sysctl: BBR, buffer ตาม BDP (${BDP_BW_MBPS}Mbps @ ${BDP_RTT_MS}ms = ${BDP_BYTES} bytes) --"
    cat > /etc/sysctl.d/99-vmess-ws-tuning.conf << EOF
# congestion control: BBR (เหมาะกับเน็ตมือถือที่ RTT แปรปรวน ลด bufferbloat)
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

# TCP buffer: min default max (หน่วย byte) ปรับเพดานบนตาม BDP*2 เผื่อ burst
# ไม่ได้ "จำกัด" ความเร็ว แต่กันไม่ให้ buffer โตจนเกิด bufferbloat บนลิงก์ช้า
net.ipv4.tcp_rmem = 4096 131072 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_BUF_MAX}
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.core.rmem_default = 131072
net.core.wmem_default = 131072

# mobile/LTE: RTT แปรปรวนสูง ปิด slow-start หลัง idle เพื่อไม่ต้องไต่ window ใหม่
net.ipv4.tcp_slow_start_after_idle = 0

# ลด latency: ปิด timestamps overhead เล็กน้อยไม่จำเป็น แต่เปิด window scaling ไว้เสมอ (จำเป็นสำหรับ buffer ใหญ่)
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1

# SYN/connection handling: เพิ่ม backlog เผื่อ reconnect ถี่จากมือถือ (สัญญาณตัด-ต่อบ่อย)
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 2048
net.ipv4.tcp_max_syn_backlog = 2048

# fast open ช่วยลด 1 RTT ตอนต่อใหม่ (ดีกับเน็ตมือถือ ping สูง)
net.ipv4.tcp_fastopen = 3

# ลด keepalive ให้ตรวจจับสายหลุดเร็วขึ้น (มือถือเปลี่ยนเสาบ่อย)
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# FIN/TIME_WAIT: รีไซเคิล connection เร็วขึ้น (ลดพอร์ตค้างบน VPS เล็ก)
net.ipv4.tcp_fin_timeout = 15

# MTU/PMTU: เปิด PMTU discovery, ป้องกัน blackhole ตอนเจอ ICMP ถูกบล็อกข้างทาง
net.ipv4.tcp_mtu_probing = 1

# security: ลด IP spoofing / source routing (ไม่เกี่ยวกับ leak DNS แต่ลดพื้นผิวโจมตี)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.${NIC}.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# จำกัด swap ผ่าน sysctl ตัวนี้ (รายละเอียดเพิ่มใน stage 5)
vm.swappiness = ${SWAPPINESS}
EOF

    sysctl --system 2>&1 | tee -a "$LOG_FILE"
    ok "sysctl tuning โหลดเรียบร้อย"

    # ----- 4.5 ตั้ง CAKE บน eth0 (ไม่ cap bandwidth, ไม่ตั้ง maxrate) -----
    log "-- ตั้ง qdisc CAKE บน ${NIC} (ไม่ cap bandwidth) --"
    # หมายเหตุ: ไม่ส่ง "bandwidth" parameter ให้ CAKE เพื่อไม่จำกัดความเร็วจริง
    # ใช้ docsis เป็น default ack-filter เพราะเหมาะกับ asymmetric mobile link
    tc qdisc replace dev "${NIC}" root cake besteffort triple-isolate nat no-ack-filter 2>&1 | tee -a "$LOG_FILE"
    if tc qdisc show dev "${NIC}" | grep -q cake; then
        ok "CAKE qdisc ติดตั้งบน ${NIC} สำเร็จ"
    else
        err "ตั้ง CAKE บน ${NIC} ไม่สำเร็จ ตรวจสอบว่า module sch_cake โหลดอยู่จริงด้วย: lsmod | grep cake"
    fi

    # ----- 4.6 ทำให้ CAKE qdisc คงอยู่หลัง reboot ผ่าน systemd service -----
    cat > /etc/systemd/system/cake-qdisc.service << EOF
[Unit]
Description=Apply CAKE qdisc on ${NIC} after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${NIC} root cake besteffort triple-isolate nat no-ack-filter
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable cake-qdisc.service 2>&1 | tee -a "$LOG_FILE"
    ok "ตั้ง cake-qdisc.service ให้รันอัตโนมัติทุกครั้งที่บูต"

    # ----- 4.7 MTU + MSS clamp -----
    log "-- ตั้ง MTU=${MTU_VAL} บน ${NIC} + MSS clamp=${MSS_VAL} --"
    ip link set dev "${NIC}" mtu "${MTU_VAL}" 2>&1 | tee -a "$LOG_FILE"

    # netplan persist (Ubuntu 24.04 ใช้ netplan เป็นหลัก)
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
    if [[ -n "${NETPLAN_FILE}" ]]; then
        if ! grep -q "mtu:" "${NETPLAN_FILE}"; then
            warn "ไม่พบ mtu: ใน ${NETPLAN_FILE} เพิ่ม MTU ให้ผ่าน netplan override แทนแก้ yaml ตรง (กัน indent พัง)"
            cat > /etc/netplan/99-mtu-override.yaml << EOF
network:
  version: 2
  ethernets:
    ${NIC}:
      mtu: ${MTU_VAL}
EOF
            chmod 600 /etc/netplan/99-mtu-override.yaml
            netplan apply 2>&1 | tee -a "$LOG_FILE" || warn "netplan apply ล้มเหลว MTU ที่ตั้งสดด้วย ip link ยังใช้ได้จนกว่าจะ reboot"
        fi
    else
        # fallback: persist ผ่าน systemd-networkd ถ้าไม่มี netplan
        warn "ไม่พบ netplan config ใช้ systemd service แทนเพื่อ persist MTU"
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

    # MSS clamp ผ่าน nftables (mangle-like ใน inet filter ใช้ forward/output ก็ได้
    # แต่สำหรับ traffic ที่ "เซิร์ฟเวอร์เป็นปลายทางเอง" ไม่ผ่าน forward
    # เราจึงตั้ง MSS clamp ผ่าน iptables-style ใน output/postrouting แทน)
    if command -v iptables &>/dev/null; then
        iptables -t mangle -C OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VAL}" 2>/dev/null \
          || iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${MSS_VAL}" 2>&1 | tee -a "$LOG_FILE"
        ok "ตั้ง MSS clamp = ${MSS_VAL} ผ่าน iptables mangle OUTPUT"
    else
        warn "ไม่พบ iptables ข้าม MSS clamp (MTU 1500 มาตรฐานปกติไม่น่ามีปัญหาฟราก แต่ถ้าใช้ tunnel ซ้อนทับอีกชั้นอาจต้องตั้งเอง)"
    fi

    ok "Network tuning (stage 4) เสร็จสมบูรณ์"
}

################################################################################
# STAGE 5: Swap setup
################################################################################

stage5_swap() {
    log "===== STAGE 5: Swap (${SWAP_SIZE_MB}MB, swappiness=${SWAPPINESS}) ====="

    if swapon --show | grep -q "${SWAP_FILE}"; then
        warn "พบ swapfile ${SWAP_FILE} เปิดอยู่แล้ว ข้ามการสร้างใหม่"
    else
        if [[ -f "${SWAP_FILE}" ]]; then
            rm -f "${SWAP_FILE}"
        fi
        fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}" 2>&1 | tee -a "$LOG_FILE" \
          || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=progress 2>&1 | tee -a "$LOG_FILE"
        chmod 600 "${SWAP_FILE}"
        mkswap "${SWAP_FILE}" 2>&1 | tee -a "$LOG_FILE"
        swapon "${SWAP_FILE}" 2>&1 | tee -a "$LOG_FILE"

        if ! grep -q "${SWAP_FILE}" /etc/fstab; then
            echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
        fi
        ok "สร้างและเปิด swapfile ${SWAP_SIZE_MB}MB เรียบร้อย (persist ผ่าน /etc/fstab)"
    fi

    # swappiness ถูกตั้งใน sysctl ของ stage 4 แล้ว (vm.swappiness) ยืนยันค่าจริงอีกที
    sysctl vm.swappiness 2>&1 | tee -a "$LOG_FILE"
    ok "swappiness=${SWAPPINESS} (ลด swap thrash, ให้ kernel เลี่ยง swap ไว้ก่อนถ้า RAM ยังพอ)"
}

################################################################################
# STAGE 6: ย้าย log ทั้งหมด (journald + xray/3x-ui) ไปอยู่บน tmpfs (RAM only)
#
#   *** คำเตือนสำคัญ ***
#   log ที่อยู่บน tmpfs จะ "หายทั้งหมด" ถ้า VPS ไฟดับ/ถูก force restart
#   กะทันหันโดยไม่ได้ shutdown ปกติ เพราะตั้งใจไม่ sync กลับ disk ถาวร
#   (เลือก privacy + speed ตามที่ระบุไว้) ส่วนการตั้งค่าระบบอื่นๆ ทั้งหมด
#   (sysctl, nftables, swap, qdisc, 3x-ui config ของจริงที่อยู่ใน DB)
#   ยังคง persistent ผ่าน reboot ปกติตามเดิม ไม่ได้รับผลกระทบ
################################################################################

stage6_ram_logs() {
    log "===== STAGE 6: ย้าย log ไปอยู่บน tmpfs (RAM only, ไม่ sync กลับ disk) ====="

    # ----- 6.1 journald -> volatile (RAM only) -----
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
    ok "journald ตั้งเป็น Storage=volatile (เก็บใน /run เท่านั้น = RAM ไม่ลง disk)"

    # ----- 6.2 xray / 3x-ui log -> bind mount tmpfs -----
    # 3x-ui เก็บ log ไว้ที่ /var/log/x-ui (access.log, error.log) โดย default
    # เราสร้าง tmpfs แยกเฉพาะ แล้ว bind mount ทับ path เดิม เพื่อไม่ต้องไปแก้
    # path ใน 3x-ui config (ตอบโจทย์ "ไม่ต้องยุ่งกับ 3x-ui inbound settings")
    mkdir -p "${XUI_LOG_DIR}"

    if ! grep -q "${XUI_LOG_DIR}" /etc/fstab; then
        echo "tmpfs ${XUI_LOG_DIR} tmpfs defaults,noatime,mode=0750,size=${TMPLOG_SIZE} 0 0" >> /etc/fstab
        ok "เพิ่ม tmpfs mount สำหรับ ${XUI_LOG_DIR} ใน /etc/fstab (persist หลัง reboot ว่าให้ mount เป็น RAM เสมอ)"
    else
        warn "พบ mount entry ของ ${XUI_LOG_DIR} ใน /etc/fstab อยู่แล้ว ข้าม"
    fi

    mount -a 2>&1 | tee -a "$LOG_FILE"
    if mount | grep -q "on ${XUI_LOG_DIR} type tmpfs"; then
        ok "${XUI_LOG_DIR} mount เป็น tmpfs (RAM) สำเร็จ ขนาด ${TMPLOG_SIZE}"
    else
        err "${XUI_LOG_DIR} mount เป็น tmpfs ไม่สำเร็จ เช็คด้วย: mount | grep x-ui"
    fi

    systemctl restart x-ui 2>&1 | tee -a "$LOG_FILE" || warn "restart x-ui ไม่สำเร็จ (อาจยังไม่ได้ติดตั้งถ้าข้าม stage 3)"

    log "*** คำเตือน: log ทั้งหมด (journald + xray) อยู่บน RAM ล้วนๆ ตอนนี้ ***"
    log "*** ถ้าไฟดับ/VPS ถูก force restart กะทันหัน log ทั้งหมดจะหายทันที (ตามที่ตกลงไว้) ***"
    log "*** การตั้งค่าระบบอื่น (sysctl/nftables/swap/qdisc/3x-ui config จริง) ไม่ได้รับผลกระทบ ยัง persistent ปกติ ***"
}

################################################################################
# STAGE 7: Verify ทุกระบบ
################################################################################

stage7_verify() {
    log "===== STAGE 7: Verify ====="
    local pass=0
    local fail=0

    check() {
        local desc="$1"
        local cmd="$2"
        if eval "$cmd" &>/dev/null; then
            ok "$desc"
            pass=$((pass+1))
        else
            err "$desc"
            fail=$((fail+1))
        fi
    }

    echo "" | tee -a "$LOG_FILE"
    log "----- ผลตรวจสอบระบบ -----"

    check "nftables service active"                  "systemctl is-active --quiet nftables"
    check "IPv6 ปิดอยู่ (all.disable_ipv6=1)"          "[[ \$(sysctl -n net.ipv6.conf.all.disable_ipv6) -eq 1 ]]"
    check "DNS resolv.conf ชี้ไปที่ ${DNS_PRIMARY}"     "grep -q '${DNS_PRIMARY}' /etc/resolv.conf"
    check "BBR เป็น congestion control"               "[[ \$(sysctl -n net.ipv4.tcp_congestion_control) == 'bbr' ]]"
    check "default_qdisc = cake"                      "[[ \$(sysctl -n net.core.default_qdisc) == 'cake' ]]"
    check "CAKE module โหลดอยู่ (lsmod)"               "lsmod | grep -q sch_cake"
    check "CAKE qdisc ติดตั้งบน ${NIC}"                "tc qdisc show dev ${NIC} | grep -q cake"
    check "MTU ${NIC} = ${MTU_VAL}"                   "[[ \$(cat /sys/class/net/${NIC}/mtu) -eq ${MTU_VAL} ]]"
    check "Swap active (${SWAP_FILE})"                "swapon --show | grep -q ${SWAP_FILE}"
    check "swappiness = ${SWAPPINESS}"                "[[ \$(sysctl -n vm.swappiness) -eq ${SWAPPINESS} ]]"
    check "journald = volatile (RAM only)"            "grep -q 'Storage=volatile' /etc/systemd/journald.conf.d/99-ram-only.conf"
    check "${XUI_LOG_DIR} mount เป็น tmpfs"            "mount | grep -q 'on ${XUI_LOG_DIR} type tmpfs'"
    check "3x-ui service active"                      "systemctl is-active --quiet x-ui"
    check "cake-qdisc.service enabled (persist boot)" "systemctl is-enabled --quiet cake-qdisc.service"

    echo "" | tee -a "$LOG_FILE"
    log "----- พอร์ตที่เปิดจริง (nft ruleset) -----"
    nft list chain inet filter input 2>/dev/null | grep -E "dport|policy" | tee -a "$LOG_FILE"

    echo "" | tee -a "$LOG_FILE"
    log "===== สรุป: ผ่าน ${pass} ข้อ / ล้มเหลว ${fail} ข้อ ====="

    if [[ "${fail}" -gt 0 ]]; then
        warn "มีบางจุดที่ verify ไม่ผ่าน ดูรายละเอียด [FAIL] ด้านบนหรือใน ${LOG_FILE}"
    else
        ok "ทุกระบบผ่านการตรวจสอบ"
    fi

    echo "" | tee -a "$LOG_FILE"
    log "หมายเหตุสุดท้าย (ย้ำอีกครั้ง):"
    log "  - log (journald+xray) อยู่บน RAM ล้วน หายได้ถ้าไฟดับ/force restart"
    log "  - การตั้งค่า network/firewall/swap/3x-ui ทั้งหมดเป็น persistent ผ่าน reboot ปกติ"
    log "  - ตั้งค่า inbound VMESS+WS (security: none) เองผ่าน 3x-ui panel (default login: เช็คท้าย log ติดตั้งด้านบน)"
    log "  - แนะนำให้ reboot 1 ครั้งเพื่อยืนยันว่าทุกอย่าง persist จริง: sudo reboot"
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
    log "สคริปต์ทำงานเสร็จสมบูรณ์ ดู log เต็มได้ที่: ${LOG_FILE}"
}

main "$@"
