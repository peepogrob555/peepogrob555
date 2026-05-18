AIS Narrowband VPS Stack

ทำไว้ใช้เอง เอาไปใช้ได้ฟรี
เหมาะสำหรับคนเปิด VPS ใช้เอง ไม่เหมาะกับทำขายหรือหลาย user

เน้นลด:

- bufferbloat
- jitter
- queue delay

ไม่ได้ทำมาเพื่อเร่งสปีด

---

เหมาะกับ

- AIS FUP 128kbps(+++)
- เน็ต 128kbps
- เล่นเกม
- Discord
- ใช้งานทั่วไป เล่นเกมส์,ดูหนัง,ทั่วๆไป
- VPS 1-2GB RAM
- ใช้ 1-2 คน

---

ระบบที่รองรับ

รายการ| รายละเอียด
OS| Ubuntu 22.04 LTS
RAM| 1GB+
CPU| 1 vCPU+
VPS| KVM แนะนำ
Domain| ต้องชี้เข้า VPS แล้ว

---

สิ่งที่สคริปต์ทำ

- ติดตั้ง 3x-ui
- ตั้งค่า BBR
- ตั้งค่า CAKE + IFB
- optimize sysctl
- ตั้ง nftables
- ขอ TLS cert อัตโนมัติ
- benchmark DNS
- optimize สำหรับเน็ตมือถือ bandwidth ต่ำ

---

Architecture

AIS 128kbps
     ↓
VLESS+Reality
     ↓
Xray
     ↓
CAKE + IFB shaping
     ↓
BBR pacing
     ↓
Low latency / low jitter

---

ติดตั้ง

เข้า VPS

sudo -i

รันสคริปต์

bash <(curl -Ls https://raw.githubusercontent.com/peepogrob555/peepogrob555/main/Mypeepogrob555.sh)

หรือโหลดมาก่อน

wget https://raw.githubusercontent.com/peepogrob555/peepogrob555/main/Mypeepogrob555.sh

chmod +x Mypeepogrob555.sh

sudo bash Mypeepogrob555.sh

---

หลังติดตั้ง

เปิด panel

https://YOUR_DOMAIN:2053

---

ตั้งค่าใน 3x-ui

เพิ่ม Inbound

ค่า| ตั้งเป็น
Protocol| VLESS
Port| 443
Security| Reality
Flow| xtls-rprx-vision
uTLS| firefox
Dest| th.speedtest.net:443

---

แนะนำ

เปิด

- tcpNoDelay
- Reality
- Vision

ปิด

- mux
- sniffing

---

เช็คสถานะหลังติดตั้ง

bash <(curl -Ls https://raw.githubusercontent.com/peepogrob555/peepogrob555/main/Mypeepogrob555V2.sh)

---

จุดเด่น

CAKE + IFB

จัดการ queue ทั้ง upload และ download
ลด bufferbloat บนเน็ต AIS FUP

BBR

ช่วย pacing traffic ให้ latency นิ่งขึ้น

DNS Benchmark

เลือก DNS ที่ latency ต่ำที่สุดอัตโนมัติ

nftables

- policy drop
- SSH anti brute-force
- DSCP marking

Adaptive tuning

ปรับตาม:

- RAM
- virtualization
- kernel capability

---

ไม่เหมาะกับ

- แชร์หลาย user
- VPS ขายลูกค้า
- ดู 720p/1080p
- throughput สูง
- OpenVZ เก่า ๆ

---

Log

/var/log/3x-ui-gaming.log

---

Reset qdisc

tc qdisc del dev eth0 root
tc qdisc del dev eth0 ingress

---

Disable nftables

systemctl stop nftables

nft flush ruleset

---

ทดสอบบน

- Ubuntu 22.04
- Kernel 5.15+
- KVM VPS
- AIS 4G FUP 128kbps

---

Warning

สคริปต์แก้:

- sysctl
- nftables
- qdisc
- network stack

ควรใช้บน VPS ใหม่หรือ clean install

---

By:

- IG: peepogrob555
- FB: Shogun
