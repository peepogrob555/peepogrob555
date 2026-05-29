cat << 'EOF' > check-spec.sh
#!/bin/bash
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
clear
echo -e "${B}${C}=======================================================${N}"
echo -e "${B}${C}      VPS DETAILED HARDWARE & SYSTEM REPORT            ${N}"
echo -e "${B}${C}=======================================================${N}"

echo -e "\n${B}${Y}[1] OS & KERNEL INFORMATION${N}"
echo -e "  ▸ OS Version      : ${G}$(lsb_release -d | awk -F: '{print $2}' | sed 's/^[ \t]*//')${N}"
echo -e "  ▸ Kernel Version  : ${G}$(uname -r)${N}"
echo -e "  ▸ Architecture    : ${G}$(uname -m)${N}"
echo -e "  ▸ Uptime          : ${G}$(uptime -p)${N}"

echo -e "\n${B}${Y}[2] CPU SPECIFICATION${N}"
echo -e "  ▸ CPU Model Name  : ${G}$(lscpu | grep "Model name:" | sed 's/Model name:[[:space:]]*//')${N}"
echo -e "  ▸ Vendor ID       : ${G}$(lscpu | grep "Vendor ID:" | sed 's/Vendor ID:[[:space:]]*//')${N}"
echo -e "  ▸ Core(s) per soc : ${G}$(lscpu | grep "CPU(s):" | head -1 | sed 's/CPU(s):[[:space:]]*//') คอร์${N}"
echo -e "  ▸ CPU Max Speed   : ${G}$(lscpu | grep "CPU max MHz:" | sed 's/CPU max MHz:[[:space:]]*//' | awk '{print $1/1000 " GHz"}' || echo "Host Controlled")${N}"
echo -e "  ▸ Virtualization  : ${G}$(lscpu | grep "Hypervisor vendor:" | sed 's/Hypervisor vendor:[[:space:]]*//' || echo "None (Baremetal)")${N}"

echo -e "\n${B}${Y}[3] RAM & MEMORY SPECIFICATION${N}"
echo -e "  ▸ Total RAM       : ${G}$(free -h | awk '/^Mem:/ {print $2}')${N}"
echo -e "  ▸ RAM Used/Free   : ${G}ใช้ไป $(free -h | awk '/^Mem:/ {print $3}') / เหลือว่าง $(free -h | awk '/^Mem:/ {print $4}')${N}"

# เจาะลึกความเร็ว RAM และประเภทรุ่น (รองรับ KVM/物理機)
if command -v dmidecode &>/dev/null; then
    RAM_SPEED=$(sudo dmidecode --type memory 2>/dev/null | grep "Speed:" | grep -v "Unknown" | head -1 | sed 's/^[ \t]*Speed:[[:space:]]*//')
    RAM_TYPE=$(sudo dmidecode --type memory 2>/dev/null | grep "Type:" | grep -v "Unknown" | head -1 | sed 's/^[ \t]*Type:[[:space:]]*//')
    RAM_MANUF=$(sudo dmidecode --type memory 2>/dev/null | grep "Manufacturer:" | grep -v "Unknown" | head -1 | sed 's/^[ \t]*Manufacturer:[[:space:]]*//')
    
    echo -e "  ▸ RAM Type        : ${G}${RAM_TYPE:-Virtual RAM (QEMU/KVM)}${N}"
    echo -e "  ▸ RAM Speed (Bus) : ${G}${RAM_SPEED:-ไม่เปิดเผยค่า (Host ควบคุมความเร็วเบื้องหลัง)}${N}"
    echo -e "  ▸ RAM Manufacturer: ${G}${RAM_MANUF:-Virtual Interface}${N}"
else
    echo -e "  ▸ RAM Speed/Type  : ${R}ต้องติดตั้ง dmidecode ก่อน (sudo apt install dmidecode)${N}"
fi

echo -e "\n${B}${Y}[4] STORAGE (DISK) SPEED & TYPE${N}"
echo -e "  ▸ Disk Space      : ${G}$(df -h / | awk 'NR==2 {print $2}')${N}"
echo -e "  ▸ Disk Type Check : ${G}$(lsblk -d -o NAME,ROTA | grep -v "NAME" | awk '{if($2==0) print "SSD / NVMe (ความเร็วสูง)"; else print "HDD (จานหมุน)"}' | head -1)${N}"
echo -e "${B}${C}=======================================================${N}\n"
EOF
chmod +x check-spec.sh && ./check-spec.sh
