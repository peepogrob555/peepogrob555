#!/bin/bash
# ====================================================================
#  3x-ui & System Fixed-Profile Verification Script (1vCPU 2GB)
# ====================================================================

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; N='\033[0m'

check_ok()  { echo -e "${G}[✓ PASS]${N} $1"; }
check_fail() { echo -e "${R}[✗ FAIL]${N} $1"; }
check_warn() { echo -e "${Y}[! WARN]${N} $1"; }
print_sec()  { echo -e "\n${B}${C}👥 ตรวจสอบ: $1${N}\n------------------------------------------"; }

[[ $EUID -ne 0 ]] && { echo "กรุณารันสคริปต์นี้ในฐานะ root (sudo bash $0)"; exit 1; }

ETH=$(ip -o -4 route show to default | awk '{print $5}' | head -1)

clear
echo -e "${B}${C}====================================================${N}"
echo -e "${B}${C}    ระบบตรวจสอบความสมบูรณ์เซิร์ฟเวอร์ (VMESS WS 500Mbps) ${N}"
echo -e "${B}${C}====================================================${N}"

# 1. ตรวจสอบฮาร์ดแวร์และข้อจำกัดของระบบ
print_sec "Hardware Profile & System Limits"

RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
if [ "$RAM_TOTAL" -le 2100 ]; then
    check_ok "สเปก RAM สอดคล้อง: ${RAM_TOTAL}MB (ตรงตามโปรไฟล์ 2GB)"
else
    check_warn "ขนาด RAM คือ ${RAM_TOTAL}MB (ต่างจากโปรไฟล์ 2GB ข้อมูลบางอย่างอาจต้องจูนใหม่)"
fi

SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [ "$SWAP_TOTAL" -ge 450 ]; then
    check_ok "SWAP Space ทำงานอยู่: ${SWAP_TOTAL}MB"
else
    check_fail "ไม่พบ SWAP หรือมีขนาดต่ำกว่า 512MB (เสี่ยง RAM หมด)"
fi

NOFILE_SOFT=$(ulimit -Sn)
NOFILE_HARD=$(ulimit -Hn)
if [ "$NOFILE_SOFT" -ge 1000000 ] && [ "$NOFILE_HARD" -ge 1000000 ]; then
    check_ok "System Limits (nofile): soft=$NOFILE_SOFT, hard=$NOFILE_HARD"
else
    check_fail "System Limits (nofile) ต่ำกว่า 1,000,000 (ปัจจุบัน soft=$NOFILE_SOFT) *อาจต้อง Reboot เซิร์ฟเวอร์*"
fi

# 2. ตรวจสอบค่าภายใน Sysctl Kernel (STEP 5)
print_sec "Sysctl Optimization (99-ais-vmess.conf)"

check_sysctl() {
    local param=$1
    local expected=$2
    local actual=$(sysctl -n $param 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        check_ok "$param = $actual (ถูกต้อง)"
    else
        check_fail "$param = '$actual' (คาดหวัง: $expected)"
    fi
}

check_sysctl "net.ipv4.tcp_congestion_control" "bbr"
check_sysctl "net.core.default_qdisc" "fq"
check_sysctl "net.ipv4.tcp_fastopen" "3"
check_sysctl "net.ipv4.tcp_limit_output_bytes" "655360"
check_sysctl "net.ipv4.tcp_keepalive_time" "8"
check_sysctl "net.ipv4.tcp_keepalive_intvl" "2"
check_sysctl "vm.swappiness" "5"

# 3. ตรวจสอบการจำกัดคิวเครือข่ายด้วย CAKE Qdisc
print_sec "Network Traffic Control & CAKE Qdisc"

if tc qdisc show dev "$ETH" | grep -q "cake"; then
    QDISC_INFO=$(tc qdisc show dev "$ETH" | grep "cake")
    check_ok "เปิดใช้งาน CAKE บน Interface [$ETH] สำเร็จ"
    echo -e "   └─ ค่าที่กำลังรัน: ${Y}$QDISC_INFO${N}"
    
    # เช็คว่าล็อกแบนด์วิดท์ตรงสเปกไหม
    if echo "$QDISC_INFO" | grep -q "bandwidth 500Mbit"; then
        check_ok "จำกัดความเร็วเน็ตไว้ที่ 500Mbit ถูกต้อง"
    else
        check_warn "ความเร็วใน CAKE ไม่ตรงกับ 500Mbit หรือเป็นค่า Default"
    fi
else
    check_fail "CAKE Qdisc ไม่ได้ทำงานบนอินเทอร์เฟซหลัก ($ETH) (ระบบถอยไปใช้ fq_codel หรือค่าเริ่มต้น)"
fi

if [ -f "/etc/systemd/system/cake-qdisc.service" ] && systemctl is-enabled --quiet cake-qdisc.service; then
    check_ok "ระบบเปิดคงสภาพ CAKE หลังรีบูตอัตโนมัติ (cake-qdisc.service Enabled)"
else
    check_fail "ไม่มีไฟล์หรือยังไม่ได้เปิดใช้งานระบบคงสภาพล้างคิวหลังรีบูตเซิร์ฟเวอร์"
fi

# 4. ตรวจสอบไฟล์การตั้งค่าภายใน Xray (จุดตายเรื่องปิง/ความเร็วตก)
print_sec "Xray Core Config & SOCKOPT Patch"

XRAY_CFG=""
PATHS=("/usr/local/x-ui/bin/config.json" "/etc/x-ui/config.json" "/root/x-ui/bin/config.json")
for p in "${PATHS[@]}"; do
    if [ -f "$p" ]; then XRAY_CFG=$p; break; fi
done

if [ -n "$XRAY_CFG" ]; then
    check_ok "พบไฟล์การตั้งค่าคอนฟิกที่: $XRAY_CFG"
    
    # ส่องดูค่าในไฟล์ json ตรงๆ
    if grep -q '"tcpMaxSeg": *1360' "$XRAY_CFG"; then
        check_ok "SOCKOPT Patch -> tcpMaxSeg ถูกปรับเป็น 1360 สำเร็จ (หมดปัญหาแพ็กเก็ตแตก)"
    elif grep -q '"tcpMaxSeg":' "$XRAY_CFG"; then
        CURRENT_SEG=$(grep '"tcpMaxSeg":' "$XRAY_CFG" | head -1 | tr -d ' ,"\n')
        check_fail "SOCKOPT Patch -> พบค่า tcpMaxSeg เป็น $CURRENT_SEG (สคริปต์ Python ยังไม่ยอมแก้เป็น 1360)"
    else
        check_fail "SOCKOPT Patch -> ไม่พบออปชัน tcpMaxSeg ในไฟล์คอนฟิก (สคริปต์ตัวตบพารามิเตอร์ยังไม่ทำงาน)"
    fi
else
    check_fail "ไม่พบไฟล์ config.json ของ Xray ในระบบเลย (กรุณาสร้าง Inbound ในหน้า 3x-ui ก่อนรันตรวจสอบ)"
fi

# 5. ตรวจสอบการล็อกโปรเซสการทำงานของ CPU & I/O Priority
print_sec "Process Isolation (taskset & ionice)"

XRAY_PID=$(pgrep -x xray 2>/dev/null | head -1)
if [ -n "$XRAY_PID" ]; then
    check_ok "Xray-core กำลังทำงานในระบบ (PID: $XRAY_PID)"
    
    # เช็คคอร์ CPU
    CPU_MASK=$(taskset -cp "$XRAY_PID" 2>/dev/null | awk -F: '{print $2}' | tr -d ' ')
    if [ "$CPU_MASK" = "0" ]; then
        check_ok "การแยกแกนประมวลผล: ดึง Xray ไปตรึงไว้ที่ Core 0 สำเร็จ"
    else
        check_warn "Xray ยังไม่โดนล็อกคอร์ (รันอยู่ที่ Core Mask: $CPU_MASK)"
    fi
    
    # เช็คสภาพ I/O Priority
    if command -v ionice &>/dev/null; then
        IO_CLASS=$(ionice -p "$XRAY_PID" 2>/dev/null)
        if echo "$IO_CLASS" | grep -q "realtime"; then
            check_ok "I/O Priority: สิทธิ์ในการเขียนอ่านข้อมูลถูกยกเป็น Realtime สำเร็จ"
        else
            check_warn "I/O Priority: ปัจจุบันคือ '$IO_CLASS' (ยังไม่ใช่ระดับสูงสุด)"
        fi
    fi
else
    check_fail "Xray Service หรือตู้คอนเทนเนอร์ไม่ได้เปิดอยู่ ไม่สามารถตรวจสอบกระบวนการได้"
fi

echo -e "\n${B}${C}====================================================${N}"
echo -e "   [สรุปการเช็ค]: หากส่วนใหญ่เป็นสีเขียว สคริปต์ซิ่งของคุณพร้อมลุยเน็ตเวิร์กแล้วครับ!"
echo -e "${B}${C}====================================================${N}\n"
