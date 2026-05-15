# AIS 64kbps-512Kbps — Anti-Bufferbloat VPS Setup(ทำใช้เองเอาไปใช้ได้ฟรี)
# หลักๆทำมาเพื่อเน็ต 128kbps

# อันนี้ไว้เช็คหลังจากทำเสร็จ
```
bash <(curl -Ls https://raw.githubusercontent.com/peepogrob555/peepogrob555/main/Mypeepogrob555V2.sh)
```

**By (IG:peepogrob555 FB:Shogun)**

สคริปต์ตั้งค่า VPS สำหรับ 3x-ui + VLESS+Reality
บน AIS มือถือ 128kbps

**เป้าหมายหลัก: ลด jitter และ queue delay — ไม่ใช่เพิ่ม throughput**

---

## รันสคริปต์

```bash
bash <(curl -Ls https://raw.githubusercontent.com/peepogrob555/peepogrob555/main/Mypeepogrob555.sh)
```

หรือ download มาก่อน:

```bash
wget https://raw.githubusercontent.com/peepogrob555/peepogrob555/main/Mypeepogrob555.sh
chmod +x Mypeepogrob555.sh
sudo bash Mypeepogrob555.sh
```

---

## ความต้องการของระบบ

| รายการ | รายละเอียด |
|---|---|
| OS | Ubuntu 22.04 LTS |
| Kernel | 5.15+ |
| RAM | 1 GB ขึ้นไป |
| CPU | 1 vCPU ขึ้นไป |
| Domain | FQDN ที่ชี้มาที่ IP ของ VPS แล้ว |
| Virtualization | KVM หรือ bare-metal (LXC/OpenVZ ได้บางส่วน — script ตรวจอัตโนมัติ) |

---

## สคริปต์ทำอะไรบ้าง

| ขั้นตอน | สิ่งที่ทำ |
|---|---|
| Pre-flight | ตรวจ virt type, RAM, kernel — ปรับค่าให้อัตโนมัติ |
| Step 1 | ติดตั้ง 3x-ui (latest stable) ผ่าน official installer |
| Step 2 | ขอ TLS cert ด้วย certbot standalone + ตั้ง auto-renew hook |
| Step 3 | benchmark DNS resolver 8 ตัว เลือก 3 ที่เร็วที่สุด deploy dnsmasq cache |
| Step 4 | probe bandwidth จริง + sysctl BBR + anti-bufferbloat ตาม RAM/virt |
| Step 5 | ติดตั้ง CAKE egress + IFB ingress shaping (dual-direction) |
| Step 6 | nftables: policy drop + dynamic SSH blocklist + DSCP marking |
| Step 7 | tuning Xray: fd limits, systemd override, keepalive, hint file |

---

## สิ่งที่สคริปต์ถามก่อนรัน

1. **Server domain** — FQDN ที่ชี้มา VPS นี้
2. **SSH port** — detect อัตโนมัติ กด Enter ยืนยัน หรือพิมพ์ใหม่
3. **Admin email** — สำหรับ Let's Encrypt
4. **Target bandwidth** — default 128kbps สคริปต์จะ probe ความเร็วจริงด้วย

---

## จุดเด่นที่ต่างจากสคริปต์ทั่วไป

### Dual CAKE (Egress + IFB Ingress)
สคริปต์ส่วนใหญ่ shape แค่ฝั่ง upload AIS 128kbps bufferbloat ฝั่ง download หนักกว่า upload อีก
IFB redirect traffic ขาเข้าผ่าน CAKE อีกตัว — ทั้งสองทิศทางถูก shape พร้อมกัน

### Adaptive Bandwidth Probe
ไม่ใช้ค่าตายตัว 128kbit สคริปต์วัด throughput จริงในขณะรัน
CAKE ถูกตั้งที่ 90% ของที่วัดได้ เผื่อ headroom ให้ ISP queue

### DNS Benchmark
วัด latency DNS resolver 8 ตัวจริง ๆ แล้วเลือก 3 อันดับแรกใส่ dnsmasq
Reality handshake ต้องการ DNS lookup ทุก connection ใหม่ — ลด latency ได้ ~35ms ต่อครั้ง

### `tcp_notsent_lowat = 16384`
ที่ 128kbps ถ้า kernel buffer ข้อมูลเกิน 1 วินาทีก่อนที่ xray จะเข้ารหัส
client จะเห็น latency spike หลายวินาที ค่านี้ล็อก buffer ให้แน่น
เป็นหนึ่งในค่าที่ส่งผลมากที่สุดสำหรับ XTLS-Vision บน low-bandwidth link

### `tcp_limit_output_bytes = 131072`
จำกัด bytes ใน kernel output queue ก่อนที่ pacing layer จะเห็น
ลด burstiness ระดับ socket ช่วยเสริม CAKE flow shaping

### Dynamic SSH Blocklist (nftables)
IP ที่ brute force SSH เกิน 10 ครั้ง/นาที ถูก ban อัตโนมัติ 1 ชั่วโมง
ไม่ต้องติดตั้ง fail2ban — nftables จัดการด้วย dynamic sets โดยตรง

### Auto-detect Virtualization
ตรวจ KVM / LXC / OpenVZ / bare-metal
LXC/OpenVZ: ข้าม feature ที่ไม่รองรับ (IFB, conntrack) แล้ว warn แทน crash

### Conntrack ตาม RAM จริง
คำนวณ `RAM_MB × 8` ไม่ใช้ค่า default 131072 ที่เปลือง RAM ฟรี
VPS 1GB → conntrack_max = 8192 พอสำหรับ 2 user

---

## หลังรันสคริปต์ — ขั้นตอนใน 3x-ui Panel

**1. เปิด panel:**
```
https://YOUR_DOMAIN:2053/YOUR_PATH/
```
fallback (ถ้า HTTPS ยังไม่ work):
```
http://YOUR_IP:2053/YOUR_PATH/
```

**2. ตั้งใบ cert:**

Panel Settings → Panel Certificate
```
Certificate File : /etc/ssl/xray/fullchain.pem
Private Key File : /etc/ssl/xray/key.pem
```
Save → restart panel → ใช้ HTTPS URL

**3. เพิ่ม Inbound:**

| ค่า | รายละเอียด |
|---|---|
| Protocol | VLESS |
| Port | 443 |
| Security | Reality |
| Destination | th.speedtest.net:443 |
| uTLS | firefox |
| Flow | xtls-rprx-vision |
| tcpNoDelay | true (ใน Advanced / Stream Settings) |
| Generate | UUID + keypair + shortId ผ่าน panel |

**4. เพิ่ม users** → panel สร้าง client URI + QR code ให้อัตโนมัติ

**5. ดู Xray tuning hints:**
```bash
cat /root/xray-inbound-settings.txt
```

---

## สิ่งที่สคริปต์ไม่ทำ (by design)

- ไม่ติดตั้ง xray standalone (3x-ui จัดการ xray ภายในอยู่แล้ว)
- ไม่สร้าง VLESS inbound หรือ user
- ไม่สร้าง UUID, key หรือ client URI
- ไม่ตั้งค่า IPv6 routing (มี ICMPv6 rule แต่ full v6 strategy ต้องทำเอง)
- ไม่ rollback อัตโนมัติถ้า error (มี `.bak.TIMESTAMP` ก่อนทับไฟล์ทุกครั้ง)

---

## Idempotency — รันซ้ำได้ปลอดภัย

แต่ละ step มี guard check — ถ้าทำไปแล้วจะข้ามโดยไม่ error
ไฟล์ที่จะถูกทับมี backup `.bak.TIMESTAMP` ก่อนทุกครั้ง
ถ้า error: restore จาก `.bak` แล้วดู log ที่ `/var/log/3x-ui-ais-setup.log`

---

## ทดสอบบน

- Ubuntu 22.04 LTS / kernel 5.15 / KVM VPS
- AIS 4G มือถือ แผน 128kbps
- 2 user พร้อมกัน: เล่นเกม (UDP) + ดูวิดีโอ (TCP)

---

*MIT License — ใช้ได้เลย ขอบคุณถ้า credit ด้วย*
