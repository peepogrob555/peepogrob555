# VPS Setup — VMESS/WS สำหรับทำใช้ส่วนตัว ผมทำให้มันรองรับแค่500Mbps

## ติดตั้ง

```bash
bash <(curl -Ls 'https://raw.githubusercontent.com/peepogrob555/peepogrob555/refs/heads/main/install.sh')
```

> ต้องรันด้วย root และใช้กับ **ReadyIDC 1vCPU/2GB Ubuntu 22.04 เท่านั้น**

---

สคริปต์ติดตั้งและ optimize VPS สำหรับใช้งาน VMESS WebSocket แบบส่วนตัว  
ออกแบบและล็อคสเปคเฉพาะสำหรับ **ReadyIDC VPS 1vCPU / 2GB RAM** เท่านั้น  
พัฒนาเพื่อใช้งานส่วนตัว ไม่ใช่เพื่อการค้าหรือให้บริการสาธารณะ

---

## สเปคที่ล็อคไว้

สคริปต์นี้คำนวณและ hardcode ทุกค่าจากสเปคด้านล่าง  
**ห้ามใช้กับ VPS สเปคอื่น** เพราะค่าต่างๆ จะไม่ถูกต้อง

| รายการ | ค่า |
|---|---|
| Provider | ReadyIDC |
| vCPU | 1 core @ 2.69 GHz |
| RAM | 2 GB |
| Network Interface | eth0 |
| OS | Ubuntu 22.04 LTS |
| Panel | 3X-UI (mhsanaei) |
| Panel Port | 2053 |

---

## Protocol Spec

| รายการ | ค่า |
|---|---|
| Protocol | VMESS |
| Transport | WebSocket (WS) |
| TLS | none |
| Security | none |
| Inbound Port | 80 |
| Host Header | speedtest.net |
| Path | กำหนดเองใน x-ui panel |

> **หมายเหตุ:** การตั้งค่า host เป็น `speedtest.net` port `80` เป็นเงื่อนไขสำคัญของ setup นี้  
> การเปลี่ยน host หรือ port จะทำให้ bypass ไม่ทำงานและประสิทธิภาพลดลง

---

## Network Design & BDP Calculation

สเปคเครือข่ายที่ใช้คำนวณค่าทั้งหมดในสคริปต์

| รายการ | ค่า | หมายเหตุ |
|---|---|---|
| RTT (measured) | 40ms | วัดจริงจาก client มือถือขณะใช้ VPN |
| Target bandwidth | 500 Mbps | VPS outbound |
| Users | 2 คน | ใช้งานพร้อมกันสูงสุด |
| Client network | AIS 4G/5G | |
| Client upstream cap | 128 Kbps | ก่อน bypass |
| Client downstream | ไม่จำกัด | หลัง bypass ผ่าน speedtest.net |

### สูตรคำนวณ BDP

```
BDP = (Bandwidth ÷ 8) × RTT
    = (500,000,000 ÷ 8) × 0.040
    = 62,500,000 × 0.040
    = 2,500,000 bytes  (~2.4 MB)

rmem/wmem max      = BDP × 13.4  →  33,554,432 bytes  (32 MB, 2^25)
rmem/wmem default  = BDP × 0.21  →  524,288 bytes      (512 KB, 2^19)
notsent_lowat      = 32,768                             (cap anti-bufferbloat)
limit_output_bytes = BDP × 1.68  →  4,194,304 bytes    (4 MB, 2^22)
tcp_fin_timeout    = RTT × 0.40  →  16ms
```

> upstream 128Kbps ของ client ไม่กระทบการคำนวณ BDP เพราะ BBR จัดการ asymmetric bandwidth อัตโนมัติผ่าน congestion window  
> BDP คำนวณจาก VPS outbound 500Mbps ซึ่งเป็น bottleneck จริงของ downstream

---

## Ports ที่เปิด (TCP IPv4)

| Port | ใช้สำหรับ |
|---|---|
| 22 | SSH |
| 80 | VMESS WS inbound |
| 443 | HTTPS / alternate |
| 2053 | x-ui panel |
| 2083 | x-ui alternate |
| 2087 | x-ui alternate |
| 2096 | x-ui alternate |
| 8080 | alternate |
| 8443 | alternate |
| 54321 | x-ui default fallback |

---

## โครงสร้าง Steps

| Step | ชื่อ | Mode | ทำอะไร |
|---|---|---|---|
| 1 | UPDATE & DEPS | skip ถ้าเคยทำ | หยุด unattended-upgrades, dpkg fix, ติดตั้ง packages |
| 2 | FIREWALL | skip ถ้าเคยทำ | UFW reset + เปิด 10 ports |
| 3 | INSTALL 3X-UI | skip ถ้าเคยทำ | ติดตั้งจาก official repo + enable service |
| 4 | PANEL PORT | skip ถ้าเคยทำ | เปลี่ยน port เป็น 2053 |
| 5 | KERNEL TCP TUNE | **เขียนทับทุกครั้ง** | sysctl 30+ ค่า คำนวณจาก BDP |
| 6 | DISABLE THP | **เขียนทับทุกครั้ง** | ปิด Transparent Huge Pages + persist |
| 7 | NIC TUNE | **เขียนทับทุกครั้ง** | GRO off, TSO/GSO on, txqueuelen 2000 |
| 8 | I/O SCHEDULER | **เขียนทับทุกครั้ง** | none สำหรับ SSD/NVMe, mq-deadline สำหรับ HDD |
| 9 | CPU GOVERNOR | **เขียนทับทุกครั้ง** | performance mode + persist |
| 10 | SYSTEM LIMITS | **เขียนทับทุกครั้ง** | nofile 1M, nproc 65535, fs.file-max 2M |
| 11 | X-UI OVERRIDE | **เขียนทับทุกครั้ง** | systemd drop-in: GOMAXPROCS=1, OOMScoreAdjust |
| 12 | VERIFY SERVICE | **เขียนทับทุกครั้ง** | สร้าง vps-verify + systemd auto-run หลัง boot |

> step 1-4 ใช้ `run_skip` — อ่านจาก `/var/lib/vps-setup/steps.done` ถ้าเคยสำเร็จแล้วจะข้ามทันที  
> step 5-12 ใช้ `run_always` — ลบ state แล้วรันใหม่ทุกครั้ง เพื่อให้ tune ล่าสุดมีผลเสมอ

---

## รายละเอียด Kernel Tuning (Step 5)

### TCP Congestion & Queue
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| tcp_congestion_control | bbr | รับมือ packet loss มือถือดีกว่า CUBIC |
| default_qdisc | fq | Fair Queue คู่กับ BBR จำเป็น |

### Socket Buffers
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| rmem_max / wmem_max | 33,554,432 | BDP × 13.4, headroom สำหรับ WS framing |
| rmem_default / wmem_default | 524,288 | BDP × 0.21 |
| tcp_rmem | 4096 / 524288 / 33554432 | min / default / max |
| tcp_wmem | 4096 / 524288 / 33554432 | min / default / max |

### Anti-Bufferbloat (สำคัญสำหรับ mobile RTT)
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| tcp_notsent_lowat | 32,768 | จำกัด unsent queue ลด lag มือถือ |
| tcp_limit_output_bytes | 4,194,304 | จำกัด output queue ป้องกัน bufferbloat |

### Backlog & Connection Handling
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| netdev_max_backlog | 16,384 | NIC → kernel queue |
| somaxconn | 8,192 | listen backlog |
| tcp_max_syn_backlog | 8,192 | SYN queue |
| optmem_max | 131,072 | ancillary buffer |

### MTU & TCP Features
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| tcp_mtu_probing | 1 | probe MTU อัตโนมัติ |
| tcp_base_mss | 1440 | MSS เริ่มต้น ตรงกับ x-ui Sockopt |
| tcp_fastopen | 3 | TFO client+server ลด handshake |
| tcp_window_scaling | 1 | window > 64KB |
| tcp_timestamps | 1 | RTT measurement accuracy |
| tcp_sack / tcp_dsack | 1 | Selective ACK ลด retransmit |
| tcp_ecn | 1 | Explicit Congestion Notification |

### TIME_WAIT & Port Management
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| tcp_tw_reuse | 1 | reuse TIME_WAIT socket |
| tcp_max_tw_buckets | 65,536 | จำกัด entries |
| ip_local_port_range | 1024–65535 | ephemeral ports |

### Keepalive (ป้องกัน WebSocket zombie connection)
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| tcp_keepalive_time | 60 | เริ่ม probe หลัง idle 60s |
| tcp_keepalive_intvl | 10 | ส่ง probe ทุก 10s |
| tcp_keepalive_probes | 5 | 5 ครั้งก่อนตัด connection |
| tcp_fin_timeout | 16 | RTT × 0.4 |
| tcp_syn_retries | 3 | retry SYN (ลดจาก default 6) |
| tcp_synack_retries | 3 | retry SYNACK |
| tcp_retries2 | 8 | ตัด dead connection เร็วขึ้น (default 15) |

### TCP Auto-Tune
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| tcp_moderate_rcvbuf | 1 | kernel auto-tune receive buffer |
| tcp_adv_win_scale | 2 | application buffer ratio ดีขึ้น |

### Memory Management
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| vm.swappiness | 10 | ใช้ swap น้อย preferring RAM |
| vm.dirty_ratio | 20 | flush เมื่อ dirty cache 20% |
| vm.dirty_background_ratio | 5 | background flush 5% |
| vm.dirty_expire_centisecs | 1000 | expire dirty pages ทุก 10s |
| vm.dirty_writeback_centisecs | 500 | writeback ทุก 5s |
| vm.min_free_kbytes | 131,072 | reserve 128MB ป้องกัน OOM spike |
| vm.vfs_cache_pressure | 50 | cache inode/dentry มากขึ้น |
| vm.overcommit_memory | 1 | Go runtime (xray) allocate ไม่สะดุด |

### Kernel & Security
| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| sched_autogroup_enabled | 0 | ปิด autogroup ไม่จำเป็นสำหรับ server |
| pid_max | 65,536 | process limit |
| accept_redirects | 0 | ปิด ICMP redirect |
| send_redirects | 0 | ปิด redirect |
| rp_filter | 1 | reverse path filter |
| icmp_echo_ignore_broadcasts | 1 | ป้องกัน smurf attack |
| tcp_abort_on_overflow | 0 | ไม่ reset connection ตอน backlog เต็ม |

---

## NIC Tuning (Step 7)

| การตั้งค่า | ค่า | เหตุผล |
|---|---|---|
| GRO | off | ลด latency สำหรับ proxy |
| LRO | off | ลด latency สำหรับ proxy |
| TSO | on | offload TCP segmentation ไปที่ NIC |
| GSO | on | offload generic segmentation |
| rx-usecs | 50 | interrupt coalescing ลด CPU overhead |
| txqueuelen | 2,000 | TX queue length |

persist ผ่าน `/etc/networkd-dispatcher/routable.d/50-nic-tune.sh`

---

## I/O Scheduler (Step 8)

| Disk type | Scheduler | เหตุผล |
|---|---|---|
| SSD / NVMe | none | zero overhead, hardware จัดการเอง |
| HDD | mq-deadline | deadline guarantee |

เพิ่มเติม:
- `add_random = 0` ปิด entropy collection จาก I/O
- `nr_requests = 256` queue depth

persist ผ่าน udev rules รองรับ: sda, vda, xvda, nvme0n1

---

## System Limits (Step 10)

| Limit | ค่า | เหตุผล |
|---|---|---|
| nofile soft/hard | 1,048,576 | file descriptor per process |
| nproc soft/hard | 65,535 | process/thread per user |
| fs.file-max | 2,097,152 | kernel global file descriptor limit |

---

## x-ui Systemd Override (Step 11)

| ค่า | ตั้งเป็น | เหตุผล |
|---|---|---|
| LimitNOFILE | 1,048,576 | file descriptor สำหรับ x-ui process |
| LimitNPROC | 65,535 | process/thread limit |
| LimitCORE | infinity | เก็บ core dump ถ้า crash เพื่อ debug |
| Restart | always | restart อัตโนมัติทุกกรณี crash |
| RestartSec | 3s | รอ 3s ก่อน restart |
| GOMAXPROCS | 1 | ล็อค Go runtime ที่ 1 core (ตรงสเปค) |
| OOMScoreAdjust | -500 | ลด OOM score ป้องกัน kernel kill x-ui |

---

## x-ui Inbound Sockopt Settings

ต้องตั้งค่าเองใน panel หลังรันสคริปต์เสร็จ

| Field | ค่า | สอดคล้องกับ |
|---|---|---|
| Sockopt | เปิด | — |
| Route Mark | 0 | — |
| TCP Keep Alive Interval | 10 | tcp_keepalive_intvl = 10 |
| TCP Keep Alive Idle | 60 | tcp_keepalive_time = 60 |
| TCP Max Seg | 1440 | tcp_base_mss = 1440 |
| TCP User Timeout | 16000 | tcp_fin_timeout = 16 (ms) |
| TCP Window Clamp | 0 | ปล่อย kernel จัดการ |

---

## vps-verify

สคริปต์ตรวจสอบความสมบูรณ์ของระบบ รันได้ตลอดเวลา

```bash
vps-verify
```

รันอัตโนมัติหลัง reboot ผ่าน `vps-verify.service`  
ดู log ได้ด้วย:

```bash
journalctl -u vps-verify.service
```

### สิ่งที่ vps-verify เช็ค

- UFW active + ports ครบ 10 ports
- x-ui running / enabled / RAM usage
- BBR active + FQ qdisc
- rmem_max / wmem_max (≥ 32MB)
- notsent_lowat + limit_output_bytes
- ECN enabled
- swappiness + min_free_kbytes + overcommit_memory
- THP disabled
- eth0 up + TX queue length + GRO off
- I/O Scheduler (none หรือ mq-deadline)
- nofile limit (≥ 1,048,576) + fs.file-max
- Port 80 listening (inbound check)
- WebSocket active connection count
- CPU steal time (วัด delta 1 วินาที จริง)
- RAM available (MB)

---

## วิธีใช้งาน

### รันครั้งแรก

```bash
bash <(curl -Ls 'https://raw.githubusercontent.com/peepogrob555/peepogrob555/refs/heads/main/install.sh')
```

ระหว่าง step 3 (ติดตั้ง 3x-ui) จะมี interactive prompt ให้กรอกเอง:
- Database type
- Username / Password
- Panel port (กด enter ผ่านได้ เพราะ step 4 จะเปลี่ยนให้)
- SSL setup (แนะนำ skip เพราะใช้ port 80 none-TLS)

### หลัง reboot

```bash
vps-verify
```

### รัน tune ใหม่ (step 5-12 เขียนทับ)

```bash
bash <(curl -Ls 'https://raw.githubusercontent.com/peepogrob555/peepogrob555/refs/heads/main/install.sh')
```

step 1-4 จะ skip อัตโนมัติ step 5-12 จะรันใหม่ทั้งหมด

---

## State File

```
/var/lib/vps-setup/steps.done
```

เก็บชื่อ step ที่สำเร็จแล้ว บรรทัดละ 1 step  
ลบไฟล์นี้ถ้าต้องการรัน step 1-4 ใหม่ทั้งหมด

```bash
rm /var/lib/vps-setup/steps.done
```

---

## Persist หลัง Reboot

| สิ่งที่ทำ | วิธี persist |
|---|---|
| UFW rules | UFW เก็บเองใน `/etc/ufw/` |
| sysctl TCP tune | `/etc/sysctl.d/99-vmess-tune.conf` |
| fs.file-max | `/etc/sysctl.d/98-file-max.conf` |
| THP disable | systemd `thp-disable.service` |
| NIC tune | `/etc/networkd-dispatcher/routable.d/50-nic-tune.sh` |
| I/O scheduler | `/etc/udev/rules.d/60-io-scheduler.rules` |
| CPU governor | systemd `cpu-performance.service` |
| System limits | `/etc/security/limits.d/99-xui.conf` + pam |
| x-ui override | `/etc/systemd/system/x-ui.service.d/override.conf` |
| vps-verify | `/usr/local/bin/vps-verify` + systemd `vps-verify.service` |

---

## ข้อจำกัดและหมายเหตุ

- สคริปต์นี้ทำเพื่อใช้งานส่วนตัวล้วนๆ ไม่เหมาะสำหรับ production หรือให้บริการสาธารณะ
- ล็อคสเปคสำหรับ ReadyIDC 1vCPU/2GB เท่านั้น ค่าต่างๆ ถูกคำนวณและ hardcode ไว้แล้ว ห้ามนำไปใช้กับ VPS สเปคอื่น
- RTT 40ms มาจากการวัดจริง ถ้า RTT เปลี่ยนในอนาคตต้องคำนวณและปรับค่า BDP ใหม่
- `GOMAXPROCS=1` ตั้งตามสเปค 1 vCPU ถ้าเปลี่ยนสเปคต้องแก้ค่านี้ด้วย
- `OOMScoreAdjust=-500` ป้องกัน OOM killer แต่ถ้า RAM เต็มจริงๆ process อื่นอาจถูก kill แทน
- การ disable `unattended-upgrades` ทำให้ไม่มี security update อัตโนมัติ ควรอัพเดตด้วยตนเองเป็นระยะ

---

## Dependencies

สิ่งที่สคริปต์ติดตั้งให้อัตโนมัติ:

```
curl ufw ethtool sqlite3 irqbalance
```

3x-ui ติดตั้งจาก: `https://github.com/mhsanaei/3x-ui`
