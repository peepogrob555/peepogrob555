# รายละเอียดการทำงานของสคริปต์ (Technical Breakdown)

เอกสารนี้อธิบาย**กลไกการทำงานภายใน**ของสคริปต์ `vless-reality-setup.sh` แบบละเอียดทุกขั้นตอน ทุกคำสั่ง และเหตุผลของแต่ละค่า สำหรับผู้ที่ต้องการเข้าใจว่าระบบจะถูกเปลี่ยนแปลงอย่างไรบ้างก่อนใช้งานจริง หรือต้องการแก้ไข/ต่อยอดสคริปต์ต่อ

---

## 1. ภาพรวมโครงสร้างสคริปต์

สคริปต์เป็น Bash script ตัวเดียว รันด้วย root แบ่งการทำงานเป็น **4 STEP หลัก** บวก **VERIFY** ท้ายสุด โดยมีกลไกพื้นฐานดังนี้:

### 1.1 Error handling
ใช้ `set -uo pipefail` (ไม่มี `-e`) ซึ่งหมายความว่า:
- ตัวแปรที่ไม่ได้ถูกกำหนดค่าจะทำให้สคริปต์หยุด (ป้องกัน typo ตัวแปร)
- exit code ของ pipeline จะใช้ค่าจาก command ที่ fail ตัวสุดท้าย (ไม่ถูกบัง by `| tee` หรือ `| grep`)
- **แต่ไม่มี `-e`** แปลว่าคำสั่งที่ fail จะไม่ทำให้สคริปต์หยุดทันที — เป็นการตัดสินใจออกแบบเพื่อให้สคริปต์ "รันต่อไปได้" แม้บางคำสั่งย่อยล้มเหลว (เช่น `ethtool` บาง flag ไม่รองรับบน virtual NIC) คำสั่งที่อาจ fail ได้จะลงท้ายด้วย `2>/dev/null || true` เพื่อกลืน error และไม่กระทบ flow หลัก

### 1.2 Logging
```bash
STATE_DIR="/var/lib/vless-setup"
LOG_FILE="${STATE_DIR}/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
```
บรรทัดนี้ทำให้ output ทั้งหมด (stdout+stderr) ของสคริปต์ตั้งแต่จุดนี้เป็นต้นไป **ถูกแสดงบนหน้าจอ AND เขียนลงไฟล์ log พร้อมกัน** ผ่าน process substitution กับ `tee -a` (append mode) — ทำให้รันซ้ำได้หลายครั้งโดย log สะสมต่อกันไม่ถูกทับ ไฟล์นี้อยู่ที่ `/var/lib/vless-setup/setup.log` (path เดียวที่ไม่ถูกล้างโดยส่วน journald-volatile เพราะเป็นไฟล์ปกติบน disk ไม่ใช่ journal)

### 1.3 ฟังก์ชันแสดงผล
มี helper function 6 ตัวสำหรับพิมพ์ข้อความสีต่างๆ:
- `sep` — เส้นแบ่ง
- `hdr` — หัวข้อ STEP (สีฟ้า ตัวหนา)
- `ok` — เครื่องหมาย ✔ สีเขียว (สำเร็จ)
- `warn` — เครื่องหมาย ⚠ สีเหลือง (เตือน ไม่ fatal)
- `info` — เครื่องหมาย ℹ สีฟ้า (ข้อมูล)
- `die` — เครื่องหมาย ✘ สีแดง + `exit 1` (fatal เท่านั้น — ใช้แค่ 2 จุดในสคริปต์)

### 1.4 ตรวจสิทธิ์ root
```bash
[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root"
```
เช็คทันทีก่อนทำอะไร เพราะทุกคำสั่งหลังจากนี้ (sysctl, systemctl, แก้ /etc/...) ต้องการ root

### 1.5 การ detect ค่าตั้งต้นของระบบ
ก่อนเข้า STEP 1 สคริปต์จะ detect ค่า 4 อย่างเพื่อใช้คำนวณ tuning ในภายหลัง:

| ตัวแปร | วิธี detect | Fallback |
|---|---|---|
| `NIC` | `ip route show default` → ดึงชื่อ interface จาก default route | ลอง `ip link show` ตัวแรกที่ไม่ใช่ `lo`, ถ้ายังไม่ได้ใช้ `eth0` |
| `RAM_MB` | `free -m` คอลัมน์ total ของแถว Mem | — |
| `VCPU` | `nproc` | — |
| `PUB_IP` | `curl ifconfig.me` หรือ `api.ipify.org` (timeout 8s) | `"N/A"` |

ค่าเหล่านี้ถูกใช้ใน STEP 3 (คำนวณ buffer ตาม RAM, ตั้ง GOMAXPROCS ตาม vCPU) และ STEP 4/VERIFY (แสดง IP, ทำ NIC tuning)

---

## 2. STEP 1 — System Update + Firewall + Swap

### 2.1 จัดการ apt lock (1.1)
เซิร์ฟเวอร์ที่เพิ่งสร้างใหม่มักมี `unattended-upgrades` กำลังรันอยู่เบื้องหลังและถือ apt lock ไว้ สคริปต์จะ:
1. `systemctl stop/disable/kill` unattended-upgrades ทิ้งก่อน (จะเปิดกลับมาทีหลังใน STEP 4.10 แบบตั้งค่าใหม่)
2. วน loop เช็ค lock file 3 ตัว (`/var/lib/dpkg/lock-frontend`, `/var/lib/dpkg/lock`, `/var/cache/apt/archives/lock`) ด้วย `fuser` ทุก 5 วินาที
3. ถ้ารอเกิน 90 วินาที จะ **force kill process ที่ถือ lock** ด้วย `fuser -k` แล้วรอ 3 วินาทีก่อนไปต่อ (fail-safe กันสคริปต์ค้างตลอดกาล)
4. `dpkg --configure -a` เพื่อ finish การติดตั้ง package ที่อาจค้างครึ่งๆกลางๆจากการสร้าง VPS

### 2.2 Update + Upgrade (1.2)
`apt-get update -y` แล้ว `apt-get upgrade -y` แบบ `DEBIAN_FRONTEND=noninteractive` (ไม่ถาม prompt ใดๆ ใช้ค่า default ของ maintainer สำหรับ config file conflict)

### 2.3 ติดตั้ง dependency (1.3)
```
curl ufw nftables sqlite3 ethtool iproute2
fail2ban auditd
python3 libcap2-bin irqbalance
unattended-upgrades
```
แต่ละตัวถูกใช้ที่:
- `curl` — เช็ค public IP, ดาวน์โหลด 3x-ui installer
- `ufw` — firewall (STEP 1.4)
- `nftables` — บล็อก DNS port 53 (STEP 4.2)
- `sqlite3` — แก้ x-ui database โดยตรง (STEP 3.6, 4.4, 4.5)
- `ethtool`, `iproute2` — NIC tuning (STEP 3.2b)
- `fail2ban` — กัน brute-force SSH (STEP 4.9)
- `auditd` — ติดตั้งไว้เป็น dependency ของ kernel hardening บางจุด (ไม่ได้ configure เพิ่มในสคริปต์นี้)
- `python3` — แก้ JSON config ของ xray ผ่าน x-ui database (STEP 4.4, 4.5)
- `libcap2-bin` — มี `setcap` binary (ปัจจุบันไม่ได้ใช้ setcap แล้ว แต่ติดตั้งไว้เผื่อ)
- `irqbalance` — กระจาย interrupt handling (STEP 3.7)
- `unattended-upgrades` — auto security update (STEP 4.10)

### 2.4 UFW Firewall (1.4)
ลำดับการตั้งค่า:
1. `ufw --force reset` — ล้างกฎเดิมทั้งหมด เริ่มจาก clean state
2. Default policy: `deny incoming`, `allow outgoing`, `deny forward`
3. เปิดพอร์ตที่จำเป็น (TCP เท่านั้น):
   - `22/tcp` ด้วย `ufw limit` (ไม่ใช่ `allow`) — `limit` จะบล็อก IP ที่ connect ถี่เกินไปอัตโนมัติ (built-in rate limiting ของ UFW เพิ่มเติมจาก fail2ban)
   - `80/tcp` — เผื่อ redirect/health-check ของ provider
   - `443/tcp` — พอร์ตหลักของ VLESS Reality
   - `${PANEL_PORT}/tcp` (default 2053) — 3x-ui panel
4. `ufw deny proto udp from any to any` — บล็อก UDP ทุก port ทุก source
5. บล็อกพอร์ตอันตรายเพิ่มเติมเป็นการเฉพาะ: `23/tcp` (telnet), `25/tcp` (SMTP — กัน relay), `3389/tcp` (RDP)
6. `sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw` — ปิด IPv6 filtering ใน UFW (เพราะ IPv6 ถูกปิดทั้งระบบใน STEP 4.1 อยู่แล้ว ไม่จำเป็นต้องมี IPv6 rules)
7. `ufw --force enable` แล้ว `ufw status verbose` แสดงผลลัพธ์

### 2.5 Swap (1.5)
สร้าง swapfile ขนาด 512MB ที่ `/swapfile`:
- เช็คก่อนว่ามี swapfile mount อยู่แล้วหรือไม่ (`swapon --show | grep '/swapfile'`) — ถ้ามีแล้วข้าม (idempotent)
- ถ้าไม่มี: ลบของเก่าถ้ามีไฟล์ค้าง → `fallocate -l 512M /swapfile` (เร็วกว่า `dd` เพราะเป็น sparse allocation ระดับ filesystem) ถ้า `fallocate` ไม่รองรับ (บาง filesystem เช่น overlay) จะ fallback เป็น `dd if=/dev/zero ... status=progress`
- `chmod 600` (อ่านได้แค่ root — swap อาจมีข้อมูลในหน่วยความจำหลุดมา ต้องป้องกัน)
- `mkswap` + `swapon`
- เพิ่มเข้า `/etc/fstab` ถ้ายังไม่มี เพื่อให้ mount อัตโนมัติหลัง reboot

---

## 3. STEP 2 — ติดตั้ง 3x-ui

ส่วนนี้สั้นที่สุดในเชิงโค้ด แต่เป็น **interactive step เดียว** ในสคริปต์:

1. แสดงคำเตือนว่า 3x-ui installer จะถามอะไรบ้าง (username, password, panel port, web path)
2. `read -r` — รอให้ผู้ใช้กด Enter ก่อนเริ่ม (จุดเดียวที่สคริปต์หยุดรอ input)
3. ดาวน์โหลด installer script จาก GitHub ของ mhsanaei/3x-ui ผ่าน `mktemp` (ไฟล์ temp ชื่อ random กัน race condition) — retry สูงสุด 3 ครั้ง ครั้งละเว้น 5 วินาที ถ้าครบ 3 ครั้งยัง fail จะ `die` (จุด fatal จุดที่ 2)
4. `bash "$installer"` — รัน installer ตรงๆ ให้ผู้ใช้เห็นและตอบ prompt เองทั้งหมด **สคริปต์ไม่ได้แอบส่งค่า default หรือ auto-answer ใดๆ**
5. ลบไฟล์ installer ทิ้งหลังรันเสร็จ
6. วน loop สูงสุด 30 ครั้ง (ครั้งละ 2 วินาที = รอสูงสุด 60 วินาที) เช็คว่า `x-ui.service` active หรือยัง — ถ้าไม่ active หลังจากนั้นจะ `warn` เฉยๆ ไม่ใช่ fatal (เผื่อ user ตั้งชื่อ service ต่างออกไป หรือ x-ui ใช้เวลา start นานกว่าปกติ)

---

## 4. STEP 3 — Kernel / Network / TCP Optimization

นี่คือส่วนที่ใหญ่ที่สุดของสคริปต์ แบ่งเป็น 3.1 ถึง 3.7

### 4.1 STEP 3.1 — BBR + TCP sysctl

**Module loading:**
```bash
modprobe tcp_bbr
modprobe nf_conntrack
```
โหลด kernel module สำหรับ BBR congestion control และ connection tracking (ถ้า built-in ในเคอร์เนลอยู่แล้วคำสั่งนี้จะไม่ error แต่ก็ไม่มีผลเสีย)

**Capability detection:**
- เช็ค `/proc/sys/net/ipv4/tcp_available_congestion_control` ว่ามี `bbr` หรือไม่ → ถ้าไม่มี fallback เป็น `cubic`
- เช็ค `modinfo sch_fq` ว่า kernel มี `fq` qdisc หรือไม่ → ถ้าไม่มี fallback เป็น `fq_codel`

ทั้งสองค่านี้ (`CC`, `QDISC`) ถูกแทรกเข้าไปใน sysctl conf แบบ dynamic ด้วย heredoc แบบไม่ใส่ quote (`<< EOF` ไม่ใช่ `<< 'EOF'`) เพื่อให้ bash ขยายตัวแปรได้

**ค่าบัฟเฟอร์ (คำนวณจากงบ RAM 2048MB):**
```
RMEM_MAX=67108864   # 64MB — เพดานสูงสุดต่อ socket
WMEM_MAX=67108864
RMEM_DEF=4194304    # 4MB — ค่าเริ่มต้นต่อ socket
WMEM_DEF=4194304
```
เขียนเป็น sysctl:
```
net.core.rmem_max / wmem_max           = 67108864
net.core.rmem_default / wmem_default   = 4194304
net.ipv4.tcp_rmem  = 4096 4194304 67108864   (min default max)
net.ipv4.tcp_wmem  = 4096 4194304 67108864
net.ipv4.tcp_mem   = 163840 262144 327680    (pages, 4KB/page)
                   = 640MB     1024MB  1280MB
```
`tcp_mem` คือเพดาน **รวมทั้งระบบ** ของ memory ที่ TCP stack ใช้ได้ ไม่ใช่ต่อ socket — ทำหน้าที่เป็น global ceiling อีกชั้นที่คุมไม่ให้ socket จำนวนมากรวมกันใช้ buffer เกิน 1280MB แม้แต่ละ socket มี cap 64MB

`tcp_moderate_rcvbuf=1` — ให้ kernel ปรับขนาด receive buffer แบบ dynamic อัตโนมัติตาม traffic จริง (ไม่ fix ที่ค่า max ตลอดเวลา)

**Loss recovery:**
```
tcp_reordering=6      # จำนวน duplicate ACK ก่อนถือว่า packet หาย (ค่า default คือ 3, เพิ่มเพื่อทนต่อ network ที่ packet มาไม่ตามลำดับบ่อย)
tcp_frto=2            # Forward RTO — ตรวจจับ spurious retransmission timeout แบบ aggressive
tcp_recovery=1        # เปิด RACK loss detection (bitmask 1 = enable RACK)
```

**TCP Fast:**
- `tcp_fastopen=3` — เปิด TFO ทั้ง client และ server (ลด 1 RTT ตอน handshake สำหรับ connection ที่เคยเชื่อมต่อมาก่อน)
- `tcp_window_scaling=1`, `tcp_timestamps=1`, `tcp_sack=1`, `tcp_dsack=1` — feature พื้นฐานของ TCP สมัยใหม่ (เปิดอยู่แล้วโดย default แต่ระบุชัดเจนไว้)
- `tcp_ecn=1` — Explicit Congestion Notification
- `tcp_mtu_probing=1` + `tcp_base_mss=1440` — auto-discover MTU ที่ใหญ่ที่สุดที่ path รองรับ โดยเริ่ม probe จาก 1440 bytes (ปลอดภัยกว่า 1500 เผื่อ overhead จาก encapsulation)
- `tcp_slow_start_after_idle=0` — connection ที่ idle ไปแล้วกลับมาใช้ใหม่ ไม่ต้องเริ่ม slow-start ใหม่ (สำคัญมากสำหรับ proxy ที่ connection มัก idle เป็นช่วงๆ)
- `tcp_autocorking=0` — ปิด auto-corking เพื่อลด latency (ยอม trade-off เรื่อง packet efficiency เล็กน้อยเพื่อ response time ที่เร็วขึ้น)
- `tcp_thin_linear_timeouts=1` — connection ที่มี data น้อย (thin stream) ใช้ retransmit timeout แบบ linear ไม่ exponential (ลด latency สำหรับ traffic เบาๆ)
- `tcp_early_retrans=3`, `tcp_no_metrics_save=1` — retransmit เร็วขึ้น, ไม่ cache metric ของ connection เก่ามาใช้กับ connection ใหม่ (กัน metric เพี้ยนจาก network ที่ condition เปลี่ยนบ่อย)

**Keepalive/Timeout:**
```
tcp_keepalive_time=35    # ส่ง keepalive probe ครั้งแรกหลัง idle 35 วินาที
tcp_keepalive_intvl=5    # ส่งซ้ำทุก 5 วินาทีถ้าไม่ได้ตอบ
tcp_keepalive_probes=5   # ลองสูงสุด 5 ครั้งก่อนตัด connection
tcp_fin_timeout=10       # FIN_WAIT2 timeout 10 วินาที (เร็วกว่า default 60)
tcp_syn_retries=3, tcp_synack_retries=3   # ลด retry handshake เพื่อ fail เร็วถ้าเชื่อมต่อไม่ได้
tcp_retries2=8           # จำนวนครั้งสูงสุดที่ retransmit ก่อนตัด connection
tcp_orphan_retries=2     # connection ที่ปิดไปแล้วฝั่ง local แต่ remote ไม่ตอบ
tcp_max_orphans=32768    # จำนวน orphan socket สูงสุดที่ kernel จะเก็บ
```
ค่าชุดนี้ทั้งหมดออกแบบให้ connection ที่ "ตาย" (เน็ตหลุด, เปลี่ยนเครือข่าย) ถูกตรวจจับและเคลียร์ทิ้งเร็วกว่า default — สำคัญสำหรับ client ที่เชื่อมต่อจาก network ที่เปลี่ยนบ่อย

**Queue/Backlog:**
```
somaxconn=32768              # ขนาด accept queue สูงสุดต่อ listening socket
tcp_max_syn_backlog=32768    # ขนาด queue สำหรับ connection ที่ handshake ยังไม่จบ
netdev_max_backlog=32768     # packet queue ระดับ NIC ก่อนเข้า kernel network stack
netdev_budget=600            # จำนวน packet สูงสุดที่ประมวลผลต่อ NAPI poll cycle
netdev_budget_usecs=4000     # เวลาสูงสุดต่อ NAPI poll cycle (microsecond)
ip_local_port_range=1024 65535   # ช่วง ephemeral port ที่ใช้ได้
```

**Busy poll:**
```
net.core.busy_poll=50
net.core.busy_read=50
```
ค่าเป็น microsecond — เมื่อ process เรียก `epoll_wait`/`select`/`poll` และไม่มี event ทันที kernel จะ "busy-spin" CPU รอ event เป็นเวลานี้ก่อนยอม sleep แทนการ sleep ทันที ผลคือ latency การตอบสนองต่ำลง (ไม่ต้องรอ context switch กลับมา) แต่แลกมาด้วย CPU usage ที่สูงขึ้นในช่วงที่ socket ว่าง

**TIME_WAIT:**
```
tcp_tw_reuse=1          # อนุญาตใช้ socket ใน TIME_WAIT ซ้ำสำหรับ connection ใหม่ (ถ้าเงื่อนไข timestamp ตรง)
tcp_max_tw_buckets=1440000   # จำนวน TIME_WAIT socket สูงสุดที่เก็บไว้
```

**Forwarding:**
```
ip_forward=1
conf.all.forwarding=1
conf.default.forwarding=1
ipv6.conf.all.forwarding=0
```
จำเป็นสำหรับ Xray ที่ทำหน้าที่ proxy/relay traffic — ถ้าไม่เปิด kernel จะ drop packet ที่ไม่ใช่ของตัวเองโดยทันที (IPv6 forwarding ปิดเพราะ IPv6 ถูก disable ทั้งระบบอยู่แล้ว)

**SYN Protection:**
```
tcp_syncookies=1            # ป้องกัน SYN flood โดยไม่ต้องเก็บ state ของ half-open connection
tcp_rfc1337=1                # ป้องกัน TIME-WAIT assassination attack ตาม RFC 1337
tcp_challenge_ack_limit=1000 # จำกัดอัตรา challenge ACK (ลด info leak สำหรับ blind in-window attack)
```

**VM/Swap:**
```
vm.swappiness=10              # ใช้ swap น้อยที่สุด ใช้เมื่อจำเป็นจริงๆ (ค่า default คือ 60)
vm.dirty_ratio=10              # % ของ RAM ที่ dirty page สะสมได้ก่อนถูก force write
vm.dirty_background_ratio=3    # % ที่เริ่ม background write กลับ disk
vm.dirty_expire_centisecs=500  # dirty page เก่ากว่า 5 วินาทีต้องถูก write
vm.dirty_writeback_centisecs=100  # ตรวจ dirty page ทุก 1 วินาที
vm.min_free_kbytes=98304       # เผื่อ free memory ไว้ 96MB สำหรับ kernel allocation ฉุกเฉิน
vm.vfs_cache_pressure=50       # ลดความ aggressive ในการเคลียร์ inode/dentry cache (default 100)
vm.overcommit_memory=1         # อนุญาต memory allocation แม้ดูแล้วรวมเกิน RAM จริง (heuristic overcommit)
```

**File descriptors:**
```
fs.file-max=1048576
fs.nr_open=1048576
```
จำกัด/อนุญาตจำนวน file descriptor สูงสุดในระบบและต่อ process ที่ 1,048,576 — เผื่อสำหรับ connection จำนวนมากพร้อมกัน (เป็นแค่ limit ไม่ใช่การจอง memory ล่วงหน้า)

ปิดท้ายด้วย `sysctl -p /etc/sysctl.d/99-vless-perf.conf` เพื่อ apply ค่าทั้งหมดทันทีโดยไม่ต้อง reboot

### 4.2 STEP 3.2 — Conntrack
```bash
echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max
echo 600    > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established
echo 1      > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal
```
- `nf_conntrack_max=262144` — จำนวน connection ที่ conntrack table เก็บ state ได้สูงสุด (ใช้ RAM ประมาณ 300 bytes/entry → ~80MB ที่ full)
- `tcp_timeout_established=600` — entry ของ connection ที่ established แล้วจะถูกลบถ้า idle เกิน 600 วินาที (10 นาที, สั้นกว่า default 5 วัน มาก — ลด memory footprint สำหรับ connection ที่ตายไปแล้วแต่ conntrack ยังจำ state)
- `tcp_be_liberal=1` — ไม่ drop packet ที่ sequence/flag ดูแปลกๆ (out-of-window) จัดเป็น `INVALID` แทนการ drop ทันที — สำคัญเมื่อมี asymmetric routing หรือ NAT หลายชั้นซึ่งทำให้ conntrack เห็น sequence number ไม่ตรงกับที่คาด

ค่าเดียวกันถูกเขียนซ้ำลง `/etc/sysctl.d/99-vless-perf.conf` (append ด้วย `>>`) เพื่อให้ apply ใหม่อัตโนมัติหลัง reboot ด้วย (ค่าที่ echo เข้า `/proc` จะหายไปถ้า reboot โดยไม่มี sysctl persist)

### 4.3 STEP 3.2b — NIC Tuning
```bash
ethtool -K "${NIC}" gro on gso on tso on
```
เปิด 3 offload feature:
- **GRO** (Generic Receive Offload) — รวม packet เล็กๆที่เข้ามาติดกันให้เป็น packet ใหญ่ก่อนส่งขึ้น kernel stack ลดจำนวนครั้งที่ CPU ต้อง interrupt/ประมวลผล header
- **GSO** (Generic Segmentation Offload) — ฝั่งส่ง ให้ kernel ส่ง packet ขนาดใหญ่ทีเดียวแล้วค่อยแบ่งเป็น MTU-size ทีหลัง (ใกล้กับ NIC มากที่สุด)
- **TSO** (TCP Segmentation Offload) — ถ้า NIC hardware รองรับ จะให้ NIC แบ่ง segment เอง ลดงาน CPU ไปอีก

ทั้งสามตัวนี้ลดจำนวนครั้งที่ CPU ต้อง "แตะ" แต่ละ packet — มีผลชัดเจนบน 1 vCPU ที่ throughput สูง

**Ring buffer:**
```bash
RX_MAX=$(ethtool -g "${NIC}" | awk ... RX: ...)
TX_MAX=$(ethtool -g "${NIC}" | awk ... TX: ...)
ethtool -G "${NIC}" rx "$RX_MAX" tx "$TX_MAX"
```
อ่านค่า "Pre-set maximums" ของ ring buffer จาก `ethtool -g` ด้วย `awk` (parse บรรทัดที่มี `RX:`/`TX:` ในช่วง section "Pre-set maximums") แล้วตั้ง ring buffer ปัจจุบันให้เท่ากับค่าสูงสุดที่ driver รองรับ — ring buffer ใหญ่ขึ้นช่วยรองรับ traffic burst โดยไม่ drop packet ตอน CPU ประมวลผลไม่ทัน ถ้า parse ไม่ได้ (driver บางตัวรายงาน `n/a`) จะ fallback เป็น 1024

**txqueuelen + qdisc:**
```bash
ip link set "${NIC}" txqueuelen 10000
tc qdisc del dev "${NIC}" root
tc qdisc add dev "${NIC}" root handle 1: "${QDISC}"
```
เพิ่ม queue length ของ interface จาก default (มักเป็น 1000) เป็น 10000 แล้วตั้ง root qdisc เป็น `fq` (หรือ `fq_codel` ถ้า fq ไม่มี) ให้ตรงกับ `net.core.default_qdisc` ที่ตั้งไว้ใน sysctl — `fq` ทำงานคู่กับ BBR ได้ดีที่สุดเพราะ BBR ออกแบบมาโดยคาดว่า qdisc จะ pace packet ให้ตามอัตราที่ BBR คำนวณ

**Persistence:**
ค่า ethtool/tc/ip link เหล่านี้**ไม่ persist ข้าม reboot โดย default** สคริปต์จึงสร้าง `nic-tune.service` (systemd oneshot, `After=network-online.target`) ที่รันคำสั่งเดิมซ้ำทุกครั้งที่บูต แล้ว `systemctl enable` ไว้ (ไม่ `--now` เพราะตอนรันสคริปต์ได้ทำไปแล้วในขั้นตอนก่อนหน้า)

### 4.4 STEP 3.3 — Transparent Huge Pages (THP)
```bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```
THP คือ feature ที่ kernel รวม memory page เล็กๆ (4KB) เป็น page ใหญ่ (2MB) อัตโนมัติเพื่อลด TLB miss — แต่สำหรับ application ที่ allocate/free memory เล็กๆบ่อย (เช่น Go runtime ของ x-ui/xray) THP ทำให้เกิด latency spike ตอน kernel พยายาม defragment memory เป็น huge page เป็นพักๆ จึงปิดทั้ง `enabled` และ `defrag`

Persistence ทำผ่าน `thp-disable.service` — systemd oneshot ที่มี `Before=x-ui.service` (รับประกันว่า THP ถูกปิด**ก่อน** x-ui เริ่มทำงานทุกครั้งหลัง boot, ลำดับสำคัญเพราะ Go runtime จะ "เห็น" THP setting ตอน process start)

### 4.5 STEP 3.4 — System Limits
สร้าง `/etc/security/limits.d/99-vless.conf`:
```
*    soft/hard nofile  2097152
*    soft/hard nproc   131072
root soft/hard nofile  2097152
root soft/hard nproc   131072
```
`fs.file-max`/`fs.nr_open` ใน sysctl คือเพดานระดับ**ทั้งระบบ** ส่วนไฟล์นี้คือเพดานระดับ**ต่อ user/process** — ทั้งสองต้องตั้งคู่กันไม่งั้น process จะถูกจำกัดด้วยค่า ulimit เดิม (มักเป็น 1024) แม้ kernel จะอนุญาตมากกว่านั้น

จากนั้นเช็ค `/etc/pam.d/common-session` และ `common-session-noninteractive` ว่ามีบรรทัด `session required pam_limits.so` หรือไม่ — ถ้าไม่มีจะ append เข้าไป (บรรทัดนี้คือสิ่งที่ทำให้ PAM **โหลด** ค่าจาก `limits.d/` ตอน login/start service จริง ถ้าไม่มีบรรทัดนี้ ไฟล์ `99-vless.conf` ข้างบนจะไม่มีผลอะไรเลย)

### 4.6 STEP 3.5 — x-ui systemd override
```bash
xui_bin=$(command -v x-ui || echo "/usr/local/x-ui/x-ui")
if [ -x "$xui_bin" ]; then
  ram_avail=$(free -m | awk '/^Mem:/ {print $7}')
  gomemlimit=$(( ram_avail - 150 ))
  [ "$gomemlimit" -lt 400 ] && gomemlimit=400
  ...
fi
```
ดึงค่า "available memory" (คอลัมน์ที่ 7 ของ `free -m`, คือ memory ที่ใช้ได้จริงรวม cache ที่ reclaim ได้) แล้วลบ 150MB เป็น margin แล้วใช้เป็น `GOMEMLIMIT` — ถ้าผลลัพธ์ต่ำกว่า 400 จะ floor ไว้ที่ 400MB (กัน edge case ที่เครื่อง RAM ต่ำมากจน x-ui ไม่มี memory พอจะรันเลย)

เขียน `/etc/systemd/system/x-ui.service.d/override.conf`:
```ini
[Service]
LimitNOFILE=2097152
LimitNPROC=131072
Restart=always
RestartSec=2
Environment=GOMAXPROCS=${VCPU}
Environment=GOGC=100
Environment=GODEBUG=madvdontneed=1
Environment=GOMEMLIMIT=${gomemlimit}MiB
OOMScoreAdjust=-1000
PrivateTmp=yes
NoNewPrivileges=no
```
อธิบายแต่ละบรรทัด:
- `LimitNOFILE/LimitNPROC` — override ulimit เฉพาะ service นี้ (ซ้ำกับ STEP 3.4 แต่ระดับ systemd unit คุมแน่นกว่า PAM สำหรับ service ที่ไม่ผ่าน login shell)
- `Restart=always` + `RestartSec=2` — ถ้า x-ui crash จะถูก systemd restart อัตโนมัติภายใน 2 วินาที
- `GOMAXPROCS=${VCPU}` — บอก Go runtime ว่ามี CPU กี่ตัว (สำคัญเพราะ container/VPS บางแบบ Go อ่านค่า CPU ผิดจาก cgroup)
- `GOGC=100` — ค่า default ของ Go GC (เก็บไว้ explicit เพื่อให้แก้ง่ายถ้าต้องการ tune เพิ่ม)
- `GODEBUG=madvdontneed=1` — บอก Go runtime ให้คืน memory กลับ OS ทันทีด้วย `MADV_DONTNEED` แทนการเก็บ memory ที่ free แล้วไว้เผื่อใช้ใหม่ (`MADV_FREE`) — ทำให้ `free -m` แสดงค่าตรงกับที่ x-ui ใช้จริงมากขึ้น และลด RSS โดยรวม สำคัญมากบนเครื่อง RAM 2GB
- `GOMEMLIMIT=${gomemlimit}MiB` — soft memory limit ของ Go GC, ถ้าใกล้ limit นี้ GC จะทำงานถี่ขึ้นเพื่อพยายามไม่ให้ memory เกิน (ไม่ใช่ hard limit แต่ช่วยลดโอกาส OOM ได้มาก)
- `OOMScoreAdjust=-1000` — บอก kernel OOM killer ว่า**ห้ามฆ่า x-ui เป็นอันดับแรก** (ค่ายิ่งต่ำ ยิ่งรอด — -1000 คือเกือบ immune)
- `PrivateTmp=yes` — x-ui มี `/tmp` ของตัวเองแยกจาก namespace อื่น (security isolation)
- `NoNewPrivileges=no` — **ไม่** บล็อกการขอ privilege เพิ่ม (จำเป็นเพราะ xray ต้อง bind port 443 ซึ่งต้องการ capability บางอย่างที่ inherit จาก x-ui)

หลังเขียนไฟล์: `systemctl daemon-reload` แล้ว `systemctl restart x-ui` (ถ้า restart fail จะ `|| true` ไม่ทำให้สคริปต์หยุด)

### 4.7 STEP 3.6 — SQLite WAL
ถ้าพบไฟล์ `/etc/x-ui/x-ui.db` (กรณีผู้ใช้กรอกข้อมูลตอน STEP 2 เสร็จแล้ว x-ui สร้าง database ไปแล้ว):
```sql
PRAGMA journal_mode=WAL;        -- เปลี่ยนจาก rollback journal เป็น Write-Ahead Log
PRAGMA synchronous=NORMAL;       -- ลดจำนวนครั้งที่ fsync (ปลอดภัยพอสำหรับ WAL mode)
PRAGMA cache_size=-65536;        -- cache 64MB (ค่าลบ = หน่วยเป็น KB)
PRAGMA temp_store=MEMORY;        -- temp table เก็บใน RAM ไม่เขียน disk
PRAGMA mmap_size=268435456;      -- memory-map ไฟล์ database สูงสุด 256MB
VACUUM;                          -- defragment + คืนพื้นที่ว่าง
ANALYZE;                         -- อัปเดต query planner statistics
```
WAL mode ลด I/O contention เวลา x-ui อ่าน/เขียน database พร้อมกัน (เช่น ตอน panel โหลด stats ขณะ xray log connection ใหม่) — สำคัญบน VPS ที่ disk I/O ช้า

สร้าง `xui-db-wal.timer` (systemd timer, `OnBootSec=5min`, `OnUnitActiveSec=30min`) ที่รัน `PRAGMA wal_checkpoint(TRUNCATE)` ทุก 30 นาที — WAL mode จะมีไฟล์ `.db-wal` โตขึ้นเรื่อยๆถ้าไม่ checkpoint บ่อยๆ คำสั่งนี้ merge WAL กลับเข้า main database file แล้ว truncate ไฟล์ wal ให้เล็กลง

ถ้าไม่พบ `x-ui.db` (ผู้ใช้ข้าม setup ตอน STEP 2 หรือยังไม่สร้าง inbound) จะ `warn` และข้ามไป — ไม่ fatal

### 4.8 STEP 3.7 — irqbalance
```bash
systemctl enable --now irqbalance
```
กระจาย hardware interrupt (IRQ) ของ NIC/disk ไปยัง CPU core ต่างๆ — บน 1 vCPU มีผลจำกัด (core เดียวก็รับ IRQ ทั้งหมดอยู่ดี) แต่เก็บไว้เผื่ออัพเกรดเป็น multi-core ในอนาคต ไม่มี downside

---

## 5. STEP 4 — Privacy & Security

### 5.1 STEP 4.1 — ปิด IPv6 (3 ชั้น)
**ชั้น 1 — sysctl:**
```
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
```
apply ทันทีด้วย `sysctl -p` แล้ว loop ผ่านทุก interface ที่มีอยู่ ณ ขณะนั้น (`ip link show`) เขียน `1` ลง `/proc/sys/net/ipv6/conf/<iface>/disable_ipv6` ตรงๆ — ครอบคลุม interface ที่อาจไม่ได้อยู่ใน sysctl pattern matching

**ชั้น 2 — ip6tables:**
```bash
ip6tables -F OUTPUT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -j DROP
ip6tables-save > /etc/iptables/rules.v6
```
แม้ IPv6 ถูก disable ใน kernel แล้ว แต่เผื่อ kernel module บางตัว/บาง process ยังพยายามส่ง IPv6 packet ออกได้อยู่ (เช่นช่วงสั้นๆก่อน sysctl apply) ชั้นนี้ block ที่ netfilter เป็น defense-in-depth — อนุญาตเฉพาะ loopback, drop ทุกอย่างที่เหลือ

**ชั้น 3 — GRUB kernel parameter:**
```bash
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
update-grub
```
เพิ่ม `ipv6.disable=1` เข้า kernel boot parameter — ปิด IPv6 ตั้งแต่ kernel boot ขึ้นมาเลย (แน่นที่สุด เพราะ sysctl/ip6tables ยังมีช่วงเวลาสั้นๆตอน boot ก่อนสคริปต์/service เหล่านี้รัน แต่ kernel parameter มีผลตั้งแต่ initramfs)

### 5.2 STEP 4.2 — DNS over TLS + บล็อก plain DNS
**systemd-resolved config** (`/etc/systemd/resolved.conf.d/99-dot.conf`):
```ini
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
FallbackDNS=9.9.9.9#dns.quad9.net
DNSOverTLS=yes
DNSSEC=no
Cache=yes
DNSStubListener=yes
ReadEtcHosts=yes
```
syntax `IP#hostname` คือ SNI ที่ใช้ตอน TLS handshake กับ DNS server (Cloudflare/Quad9 ต้องเห็น SNI ตรงกับ certificate ของเขาถึงจะ verify ผ่าน) — `DNSOverTLS=yes` (ไม่ใช่ `opportunistic`) แปลว่า**บังคับ** ใช้ TLS เท่านั้น ถ้า handshake fail จะ resolve ไม่ได้เลย ไม่ fallback เป็น plaintext

`DNSSEC=no` — ปิดเพราะบางครั้ง DNSSEC validation ทำให้ query fail บน network ที่มี DNS hijacking/transparent proxy (ป้องกัน false negative)

`DNSStubListener=yes` — เปิด stub resolver ที่ `127.0.0.53:53` ให้ application ทั่วไป (รวม xray ถ้า config ให้ใช้ system DNS) เรียกผ่าน localhost ได้ตามปกติ แล้ว systemd-resolved จะ proxy ไปที่ DoT upstream ให้

`ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf` — บังคับให้ทุก process ที่อ่าน `/etc/resolv.conf` (วิธี resolve DNS แบบดั้งเดิม) ไปที่ stub `127.0.0.53` แทน

**nftables block port 53:**
```
table inet dns_privacy {
  chain output_dns_block {
    type filter hook output priority 0; policy accept;
    ip daddr 127.0.0.53 udp dport 53 accept
    ip daddr 127.0.0.53 tcp dport 53 accept
    udp dport 53 drop
    tcp dport 53 drop
  }
}
```
อ่านจากบนลงล่าง: **อนุญาต** traffic ไป `127.0.0.53:53` (คือ stub resolver ของ systemd-resolved เอง) ก่อน แล้ว**ปฏิเสธ**ทุก traffic ที่ไป port 53 ที่เหลือ (คือ DNS query ไปยัง server อื่นโดยตรงแบบ plaintext) ผลคือ application ใดๆในระบบที่พยายาม query DNS แบบ plaintext ไปยัง public DNS server ตรงๆ (ข้าม systemd-resolved) จะถูก drop บังคับให้ทุก DNS query ต้องผ่าน systemd-resolved → DoT เท่านั้น

Persist ผ่าน `dns-privacy-nft.service` (systemd oneshot, `After=network.target`) ที่รัน `nft -f /etc/nftables-dns-block.conf` ทุก boot

### 5.3 STEP 4.3 — Kernel Security Hardening
สร้าง `/etc/sysctl.d/99-security.conf`:

| Sysctl | ค่า | ผล |
|---|---|---|
| `kernel.kptr_restrict` | 2 | ซ่อน kernel pointer address จาก `/proc` ทุก user (รวม root ที่ไม่มี CAP_SYSLOG) — กัน kernel exploit ที่ต้องรู้ address |
| `kernel.dmesg_restrict` | 1 | จำกัดการอ่าน `dmesg` ให้เฉพาะ user ที่มี CAP_SYSLOG |
| `kernel.perf_event_paranoid` | 3 | จำกัดการใช้ `perf_event_open` syscall — ลดช่องทาง side-channel attack ผ่าน performance counter |
| `kernel.unprivileged_bpf_disabled` | 1 | user ทั่วไป (ไม่ใช่ root) ใช้ BPF ไม่ได้ — ปิดช่องโหว่ BPF privilege escalation |
| `net.core.bpf_jit_harden` | 2 | harden BPF JIT compiler สำหรับทั้ง privileged และ unprivileged |
| `fs.suid_dumpable` | 0 | process ที่ setuid ห้าม generate core dump (กันข้อมูลหลุดผ่าน core dump) |
| `kernel.yama.ptrace_scope` | 2 | จำกัด `ptrace` ให้เฉพาะ process ที่เป็น parent โดยตรง (และต้องมี CAP_SYS_PTRACE สำหรับกรณีอื่น) |
| `kernel.randomize_va_space` | 2 | เปิด full ASLR (randomize stack, heap, libraries, ทุกอย่าง) |
| `kernel.sysrq` | 0 | ปิด magic SysRq key ทั้งหมด |
| `fs.protected_hardlinks` | 1 | user ทั่วไปสร้าง hardlink ไปยังไฟล์ที่ตัวเองไม่มีสิทธิ์ไม่ได้ |
| `fs.protected_symlinks` | 1 | กัน symlink attack ใน world-writable directory (เช่น `/tmp`) |
| `net.ipv4.conf.all/default.rp_filter` | 1 | Reverse Path Filtering แบบ strict — drop packet ที่ source IP ไม่ตรงกับ routing table (กัน IP spoofing) |
| `net.ipv4.conf.all.accept_redirects` | 0 | ไม่รับ ICMP redirect (กัน MITM ผ่านการ inject route ปลอม) |
| `net.ipv4.conf.default.accept_redirects` | 0 | เหมือนกันสำหรับ interface ใหม่ที่จะถูกสร้างทีหลัง |
| `net.ipv4.conf.all.send_redirects` | 0 | ไม่ส่ง ICMP redirect ออกไป (เครื่องนี้ไม่ใช่ router ที่ควร redirect ใคร) |
| `net.ipv4.conf.all.accept_source_route` | 0 | ไม่รับ packet ที่มี source routing option (legacy attack vector) |
| `net.ipv4.conf.all.log_martians` | 1 | log packet ที่มี source/destination address ผิดปกติ (impossible address) |
| `net.ipv4.icmp_echo_ignore_broadcasts` | 1 | ไม่ตอบ ping ที่ยิงมาแบบ broadcast (กัน Smurf attack) |
| `net.ipv4.icmp_ignore_bogus_error_responses` | 1 | ไม่ log ICMP error response ที่ผิด RFC (ลด log noise/false alarm) |

### 5.4 STEP 4.4 — ปิด Xray Log
อ่าน column `value` จากตาราง `settings` ที่ `key='xrayTemplateConfig'` ของ `x-ui.db` (นี่คือ JSON template ที่ x-ui ใช้ generate xray config file จริงตอน start service) — ส่งเข้า python3 ผ่าน stdin:
```python
import sys, json
d = json.load(sys.stdin)
d['log'] = {'access': 'none', 'error': '', 'loglevel': 'none', 'dnsLog': False}
print(json.dumps(d, separators=(',',':')))
```
แทนที่ key `"log"` ทั้ง object ด้วยค่าที่ปิดทุก log type แล้ว serialize กลับเป็น JSON แบบไม่มี whitespace (`separators=(',',':')`) จากนั้น escape single quote (สำหรับ SQL string literal: `'` → `''`) แล้ว `UPDATE settings SET value='...' WHERE key='xrayTemplateConfig'`

ทุกขั้นตอนมี guard: เช็คว่าไฟล์ db มีอยู่, sqlite3/python3 มีอยู่, ค่า `template` ไม่ว่าง, ผลลัพธ์ python ไม่ว่าง — ถ้าขั้นไหน fail จะ `warn` และข้าม ไม่ทำให้สคริปต์หยุด (เพราะถ้า user ยังไม่สร้าง inbound เลย ตาราง/key นี้อาจยังไม่มีข้อมูล)

### 5.5 STEP 4.5 — Patch Sockopt + Fingerprint + SNI
ค่า sockopt ที่จะ inject:
```json
{
  "acceptProxyProtocol": false,
  "tcpFastOpen": true,
  "mark": 0,
  "tproxy": "off",
  "tcpcongestion": "bbr",
  "tcpNoDelay": true,
  "tcpKeepAliveInterval": 35,
  "tcpKeepAliveIdle": 35,
  "tcpUserTimeout": 30000,
  "V6Only": false,
  "domainStrategy": "AsIs"
}
```
- `tcpFastOpen: true` — สอดคล้องกับ `tcp_fastopen=3` ใน sysctl
- `tcpcongestion: "bbr"` — บังคับ inbound นี้ใช้ BBR แม้ default ของระบบจะเปลี่ยนไปในอนาคต
- `tcpNoDelay: true` — ปิด Nagle's algorithm (ส่ง packet ทันทีไม่รอ buffer เต็ม — ลด latency สำหรับ proxy traffic ที่เป็น small packet จำนวนมาก)
- `tcpKeepAliveInterval/Idle: 35` — ตรงกับค่า `tcp_keepalive_time=35` ใน sysctl
- `tcpUserTimeout: 30000` — 30 วินาที, ถ้า TCP ส่งข้อมูลแล้วไม่ได้ ACK ภายในนี้จะตัด connection (เร็วกว่า kernel default มาก)
- `domainStrategy: "AsIs"` — xray ไม่ resolve domain เองสำหรับ routing decision (ปล่อยให้ destination จัดการ — เร็วกว่าและลด DNS query ฝั่ง server)

**ขั้นตอน patch:**
1. `SELECT COUNT(*) FROM inbounds WHERE port=443 AND protocol='vless'` — เช็คว่ามี inbound ตามที่ระบุไว้หรือยัง ถ้า `count=0` แสดงว่า user ยังไม่สร้าง inbound ใน panel → `warn` + แนะนำให้รันสคริปต์ใหม่หลังสร้าง หรือตั้งค่าเองใน panel
2. ถ้ามี: `SELECT stream_settings FROM inbounds WHERE port=443 AND protocol='vless' LIMIT 1` — ดึง JSON ของ stream settings (มี `realitySettings`/`tlsSettings`, `network`, ฯลฯ)
3. ส่งเข้า python3 พร้อม `$SOCKOPT` เป็น `sys.argv[1]`:
   ```python
   d['sockopt'] = json.loads(sys.argv[1])
   if 'realitySettings' in d:
       d['realitySettings']['fingerprint'] = 'firefox'
       d['realitySettings']['serverNames'] = ['speedtest.net', 'www.speedtest.net']
   if 'tlsSettings' in d:
       d['tlsSettings']['fingerprint'] = 'firefox'
   ```
   เพิ่ม/แทนที่ key `sockopt` ทั้ง object ด้วยค่าด้านบน แล้วถ้ามี `realitySettings` (กรณี security=reality) จะ set `fingerprint=firefox` และ `serverNames` เป็น `speedtest.net`/`www.speedtest.net` — ถ้าเป็น `tlsSettings` (กรณี security=tls ปกติ) ก็ set fingerprint เหมือนกัน
4. Escape quote แล้ว `UPDATE inbounds SET stream_settings='...' WHERE port=443 AND protocol='vless'`

**Fingerprint = firefox** หมายถึง TLS ClientHello (cipher suite order, extension list, ฯลฯ) ที่ xray ส่งออกไปจะถูกปลอมให้มีลักษณะเหมือน Firefox browser จริง — ส่วน **SNI = speedtest.net** คือชื่อโดเมนที่ปรากฏใน ClientHello ตอน TLS handshake กับปลายทาง (Reality ใช้ domain นี้เป็น "target" สำหรับทำ TLS handshake จริงเพื่อขโมย certificate มาใช้ตอบ — ผู้สังเกตการณ์ network จะเห็นเหมือนกำลังต่อไปยัง speedtest.net ด้วย Firefox ปกติ)

### 5.6 STEP 4.6 — journald Volatile
สร้าง `/etc/systemd/journald.conf.d/99-volatile.conf`:
```ini
[Journal]
Storage=volatile
Compress=no
SystemMaxUse=32M
RuntimeMaxUse=32M
RateLimitIntervalSec=0
RateLimitBurst=0
Seal=no
ReadKMsg=no
```
- `Storage=volatile` — journal เก็บใน `/run/log/journal` (tmpfs/RAM) ไม่ใช่ `/var/log/journal` (disk) → หาย 100% ทุก reboot
- `Compress=no` — ไม่ compress (RAM ไม่ต้อง save space ระดับเดียวกับ disk, compress กิน CPU เพิ่มโดยไม่จำเป็น)
- `SystemMaxUse=32M` / `RuntimeMaxUse=32M` — เพดาน RAM ที่ journal ใช้ได้ (32MB เพียงพอสำหรับ debug ระยะสั้น)
- `RateLimitIntervalSec=0` + `RateLimitBurst=0` — ปิด rate limiting ของ journald (ไม่ drop log message ที่มาถี่ — ในที่นี้ใช้เพื่อให้เห็น log ครบตอน debug แม้ volatile)
- `Seal=no` — ปิด Forward Secure Sealing (feature สำหรับป้องกันการแก้ไข log ย้อนหลัง — ไม่จำเป็นเพราะ log หายทุก reboot อยู่แล้ว)
- `ReadKMsg=no` — journald ไม่อ่าน kernel message ring buffer (ลด overhead เล็กน้อย)

จากนั้น `journalctl --rotate` + `--vacuum-time=1s` + ลบไฟล์ `.journal` ที่เหลือใน `/var/log/journal` ด้วยตัวเอง แล้ว `systemctl restart systemd-journald` — เคลียร์ log ที่สะสมมาตั้งแต่ก่อนรันสคริปต์ (รวม log จาก STEP 1-4 เองด้วย ยกเว้น `setup.log` ที่เป็นไฟล์แยก)

### 5.7 STEP 4.7 — /tmp เป็น tmpfs
เพิ่มบรรทัดใน `/etc/fstab`:
```
tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,size=256m 0 0
```
- `noatime` — ไม่ update access time ของไฟล์ใน `/tmp` (ลด write operation)
- `nosuid` — ไฟล์ executable ใน `/tmp` จะไม่ honor setuid/setgid bit (กัน privilege escalation ผ่านไฟล์ที่ถูกวางใน `/tmp`)
- `nodev` — ห้ามสร้าง device file ใน `/tmp`
- `size=256m` — เพดาน RAM ที่ `/tmp` ใช้ได้

`mount -o remount /tmp` — apply ทันทีถ้า `/tmp` mount อยู่แล้ว (ถ้าเป็น fresh entry ใน fstab อาจต้องรอ reboot ถึงจะกลายเป็น tmpfs จริง ขึ้นกับว่า `/tmp` เดิม mount แบบไหน)

### 5.8 STEP 4.8 — SSH Hardening
สร้าง `/etc/ssh/sshd_config.d/99-hardened.conf`:

| Directive | ค่า | ความหมาย |
|---|---|---|
| `Protocol` | 2 | SSH protocol v2 เท่านั้น (v1 มีช่องโหว่เก่า) |
| `PermitRootLogin` | `prohibit-password` | root login ได้เฉพาะผ่าน key (ห้าม password) |
| `PasswordAuthentication` | no | ปิด password login ทุก user |
| `ChallengeResponseAuthentication` | no | ปิด PAM challenge-response (เช่น OTP ผ่าน PAM) |
| `PubkeyAuthentication` | yes | เปิด key-based auth |
| `AuthenticationMethods` | publickey | **บังคับ** ว่า method ที่ใช้ login ได้มีแค่ publickey เท่านั้น (เข้มกว่าการปิดแค่ PasswordAuthentication) |
| `MaxAuthTries` | 3 | พยายาม auth ผิดเกิน 3 ครั้งต่อ connection จะถูกตัด |
| `MaxSessions` | 5 | จำกัด session ต่อ connection |
| `LoginGraceTime` | 20 | ต้อง auth สำเร็จภายใน 20 วินาทีหลัง connect ไม่งั้นตัดการเชื่อมต่อ |
| `ClientAliveInterval` | 120 / `ClientAliveCountMax` 3 | ส่ง keepalive ทุก 120s, ถ้าไม่ตอบ 3 ครั้ง (6 นาที) ตัด connection |
| `AllowTcpForwarding` | no | ปิด SSH tunneling/port forwarding ผ่าน session นี้ |
| `X11Forwarding` | no | ปิด X11 forwarding |
| `PermitEmptyPasswords` | no | ห้าม empty password (ซ้ำซ้อนกับการปิด password auth แต่ explicit ไว้) |
| `IgnoreRhosts` | yes | ปิด `.rhosts`-based auth (legacy) |
| `HostbasedAuthentication` | no | ปิด host-based auth |
| `Ciphers` | chacha20-poly1305, aes256/128-gcm | จำกัด cipher ให้เหลือเฉพาะ AEAD cipher สมัยใหม่ |
| `MACs` | hmac-sha2-512/256-etm | จำกัด MAC ให้เหลือเฉพาะ ETM (encrypt-then-mac) แบบ SHA2 |
| `KexAlgorithms` | curve25519-sha256 (x2), diffie-hellman-group16-sha512 | จำกัด key exchange algorithm ให้เหลือเฉพาะตัวที่ปลอดภัยตามมาตรฐานปัจจุบัน |

ก่อน reload: `sshd -t` (test syntax) — ถ้า config ผิด syntax จะ `warn` และ**ไม่ reload** (กัน lockout จาก config พัง — sshd ตัวเดิมที่กำลังรันยังทำงานต่อด้วย config เก่า) ถ้า syntax ถูกต้องจะ `systemctl reload sshd` (graceful, ไม่ตัด connection ที่เปิดอยู่) หรือ `restart` ถ้า reload ไม่สำเร็จ

### 5.9 STEP 4.9 — fail2ban
สร้าง `/etc/fail2ban/jail.d/99-vless.conf`:
```ini
[DEFAULT]
bantime  = 3600
findtime = 300
maxretry = 3
banaction = ufw

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 86400
```
`[DEFAULT]` คือค่าตั้งต้นสำหรับทุก jail (ban 1 ชม. ถ้า fail 3 ครั้งใน 5 นาที, ใช้ UFW เป็น banaction คือสั่ง `ufw insert ... deny from <ip>` ตอนแบน) — jail `[sshd]` override เฉพาะ `bantime=86400` (24 ชม. สำหรับ SSH โดยเฉพาะ เข้มกว่า default)

`logpath=/var/log/auth.log` — **ข้อสังเกต:** journald ถูกตั้งเป็น volatile ใน STEP 4.6 แต่ `/var/log/auth.log` เป็นไฟล์ปกติที่ rsyslog (ถ้ามี) หรือ journald-with-syslog-forwarding เขียน ซึ่งเป็นคนละ mechanism กับ journal binary log — ไฟล์นี้ยังถูกเขียนตามปกติเพื่อให้ fail2ban อ่านได้

### 5.10 STEP 4.10 — Auto Security Updates
สร้าง `/etc/apt/apt.conf.d/50unattended-upgrades-security`:
```
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
```
จำกัด auto-update ให้เฉพาะ **security repository** เท่านั้น (ไม่ดึง update ทั่วไปที่อาจเปลี่ยน behavior โดยไม่ตั้งใจ) `AutoFixInterruptedDpkg=true` แก้ dpkg state ที่ค้างอัตโนมัติ `Remove-Unused-Dependencies=true` ล้าง package ที่ไม่ใช้แล้ว `Automatic-Reboot=false` — **สำคัญ**: แม้ kernel update ต้องการ reboot ก็จะไม่ reboot เอง (กัน downtime ไม่คาดคิด — ผู้ดูแลต้อง reboot manual เอง)

`/etc/apt/apt.conf.d/20auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```
เปิด periodic update list ทุกวัน, unattended-upgrade ทุกวัน, autoclean (ลบ .deb cache เก่า) ทุก 7 วัน — จำได้ว่า STEP 1.1 **ปิด** service นี้ไปก่อน ตรงนี้คือการเปิดกลับมาแบบมี config ใหม่ที่ปลอดภัยกว่า

### 5.11 STEP 4.11 — DB Backup
สร้าง script `/usr/local/bin/xui-backup.sh` (generate ด้วย heredoc ที่มี variable expansion สำหรับ `$DB`/`$BACKUP_DIR` แต่ escape `\$` สำหรับตัวแปรภายใน script ที่ต้อง evaluate ตอนรันจริง เช่น `\$TS`, `\$DB`):
```bash
DB="/etc/x-ui/x-ui.db"
BACKUP_DIR="/var/lib/vless-setup/backups"
[ -f "$DB" ] || exit 0
TS=$(date '+%Y%m%d_%H%M%S')
sqlite3 "$DB" ".backup ${BACKUP_DIR}/x-ui_${TS}.db" || cp "$DB" "${BACKUP_DIR}/x-ui_${TS}.db"
chmod 600 "${BACKUP_DIR}/x-ui_${TS}.db"
find "$BACKUP_DIR" -name "x-ui_*.db" -mtime +7 -delete
```
`sqlite3 .backup` คือ online backup API ของ SQLite (ปลอดภัยกว่า `cp` ตรงๆ เพราะไม่เสี่ยง copy ไฟล์ขณะมี transaction ค้าง — ถ้า sqlite3 backup fail ค่อย fallback เป็น `cp`) ลบ backup ที่เก่ากว่า 7 วันทุกครั้งที่รัน (`-mtime +7`)

`xui-backup.timer`: `OnCalendar=daily` + `RandomizedDelaySec=30min` (สุ่มเวลาภายใน 30 นาทีหลังเที่ยงคืน กัน load spike ถ้ามีหลายเครื่องรันพร้อมกัน — แม้ในที่นี้มีเครื่องเดียวก็ไม่เสียหาย) + `Persistent=true` (ถ้าเครื่องดับช่วงที่ควรรัน จะรันทันทีตอนเครื่องกลับมา online แทนที่จะรอรอบถัดไป) สคริปต์รัน backup ทันที 1 ครั้งหลัง setup เสร็จด้วย (`/usr/local/bin/xui-backup.sh 2>/dev/null || true`)

### 5.12 STEP 4.12 — Persist ip6tables
สร้าง `ip6tables-restore.service` (`After=network.target`) ที่รัน `ip6tables-restore < /etc/iptables/rules.v6` ทุก boot — rules ที่สร้างใน STEP 4.1 (block IPv6 OUTPUT) จะถูก restore กลับมาทุกครั้งที่ระบบ boot ใหม่ (ip6tables rules ไม่ persist เองโดย default)

---

## 6. VERIFY — ขั้นตอนตรวจสอบท้ายสุด

### 6.1 ฟังก์ชันตรวจสอบ
- `chk_svc <name>` — เช็คว่า systemd unit ถูก `enable` ไว้หรือไม่ (`systemctl is-enabled`) ถ้าไม่ → `warn` + เพิ่ม `errors` counter
- `chk_val <label> <got> <want>` — เช็คว่า string `got` มี substring `want` อยู่หรือไม่ (`grep -qF`) ถ้าไม่ → `warn` + เพิ่ม `errors`

### 6.2 รายการที่ตรวจ
**Services ที่ต้อง enabled:** `x-ui`, `fail2ban`, `thp-disable.service`, `nic-tune.service`, `dns-privacy-nft.service`, `unattended-upgrades`

**ค่า sysctl ที่ต้องตรงตามคาด:**
- `net.ipv4.tcp_congestion_control` ต้องมีคำว่า `bbr`
- `tc qdisc show dev <NIC>` บรรทัดแรกต้องมีคำว่า `fq`
- `/sys/kernel/mm/transparent_hugepage/enabled` ต้องมีคำว่า `never`
- `net.ipv6.conf.all.disable_ipv6` ต้องเป็น `1`
- `net.ipv4.ip_forward` ต้องเป็น `1`
- `kernel.kptr_restrict` ต้องเป็น `2`

**RAM budget check:** เทียบ `$RAM_MB` ที่ detect ไว้ตอนต้นสคริปต์กับ 1800 — ถ้าน้อยกว่า แสดงว่าเครื่องนี้ RAM ต่ำกว่าที่ใช้คำนวณค่า `tcp_mem`/`rmem_max` ใน STEP 3.1 (สมมติฐาน 2048MB) จะ `warn` ให้พิจารณาลดค่าเหล่านั้นลง

### 6.3 สรุปผลลัพธ์
ดึง `PUB_IP` ใหม่อีกครั้ง (เผื่อเปลี่ยนจากตอนต้นสคริปต์ในกรณีที่ provider เปลี่ยน IP แบบ dynamic ระหว่างรัน) แล้วพิมพ์สรุปแบบ dashboard:
- ข้อมูล connection (Protocol/Port/Security/Flow/SNI/Fingerprint/SpiderX)
- รายการ Privacy ที่เปิดใช้
- รายการ Performance tuning ที่ apply
- รายการ Security ที่เปิดใช้
- คำสั่งสำหรับดู log/debug
- ถ้า `errors=0` → ขึ้นข้อความสีเขียว "ทุก step ผ่านหมด" ถ้ามากกว่า 0 → เตือนจำนวน error ให้กลับไปดูรายละเอียดข้างบน
- รายการ "ขั้นตอนต่อไป" (เข้า panel, ค่าที่ต้องตั้งใน inbound, reboot)
- คำเตือนสุดท้ายตัวหนาสีแดง: ตรวจ `authorized_keys` ก่อน reboot

---

## 7. สรุปภาพรวมสุดท้าย

เมื่อสคริปต์รันจบและ reboot แล้ว เซิร์ฟเวอร์จะอยู่ในสถานะ:

**Network stack:** IPv4-only (IPv6 ปิด 3 ชั้น: sysctl, ip6tables, GRUB), BBR+fq congestion control, TCP buffer/memory ceiling คำนวณตามงบ RAM ของเครื่อง, NIC offload (GRO/GSO/TSO) เปิด, conntrack table ขยายเป็น 262144 entries, ทุกค่า persist ข้าม reboot ผ่าน sysctl.d + systemd oneshot service

**Proxy:** x-ui panel รันที่พอร์ตที่ผู้ใช้ตั้งไว้ตอน STEP 2 (default 2053), inbound VLESS ที่พอร์ต 443 ใช้ Reality + xtls-rprx-vision, sockopt patch ให้ BBR/TFO/keepalive ตรงกับ kernel tuning, fingerprint ปลอมเป็น Firefox, SNI เป็น speedtest.net, xray ไม่เขียน access/error log

**Process management:** x-ui มี systemd override คุม memory limit (GOMEMLIMIT), GC behavior, OOM priority, auto-restart, ulimit สูง; SQLite database ของ x-ui อยู่ใน WAL mode พร้อม auto-checkpoint และ backup รายวันเก็บ 7 วัน

**DNS:** ทุก DNS query ถูกบังคับผ่าน systemd-resolved → DNS-over-TLS ไปยัง Cloudflare/Quad9 เท่านั้น, plaintext DNS query ไปยัง server อื่นถูก drop ที่ nftables

**Logging:** journald เก็บ log ใน RAM เท่านั้น (volatile, 32MB cap, หายทุก reboot) ยกเว้น `/var/log/auth.log` (สำหรับ fail2ban) และ `/var/lib/vless-setup/setup.log` (log การติดตั้งของสคริปต์เอง) ที่ยังอยู่บน disk ตามปกติ

**Access control:** SSH รับเฉพาะ public key (`AuthenticationMethods publickey`), cipher/MAC/KEX จำกัดเฉพาะอัลกอริทึมสมัยใหม่, fail2ban แบน IP ที่ brute-force SSH 24 ชม., UFW เปิดเฉพาะ TCP 4 พอร์ต (22/80/443/panel) บล็อก UDP ทั้งหมดและพอร์ตอันตรายเฉพาะเจาะจง, kernel hardening ปิด ptrace/BPF/kptr สำหรับ unprivileged user

**Maintenance:** unattended security updates ทำงานทุกวัน (ไม่ auto-reboot), x-ui database backup ทุกวันเก็บ 7 วัน, WAL checkpoint ทุก 30 นาที, swap 512MB เป็น safety net สำหรับ memory pressure

ทุก config ที่สคริปต์สร้างเป็น **ไฟล์แยกต่างหาก** (`/etc/sysctl.d/99-*.conf`, `/etc/*/conf.d/99-*`, `systemd unit ใหม่`) ไม่ได้แก้ไฟล์ config หลักของระบบโดยตรง (ยกเว้น `/etc/fstab`, `/etc/default/ufw`, `/etc/default/grub`, `/etc/resolv.conf` ที่จำเป็นต้องแก้ตรงเพื่อให้ effect) — ทำให้ revert การเปลี่ยนแปลงส่วนใหญ่ทำได้โดยลบไฟล์ `99-*` แล้ว `sysctl --system` หรือ `systemctl disable` unit ที่เกี่ยวข้อง โดยไม่ต้องแก้ config เดิมของระบบกลับ
