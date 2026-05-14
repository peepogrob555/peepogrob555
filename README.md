# AIS 128Kbps — Anti-Bufferbloat VPS Setup

```
   █████╗ ██╗███████╗    ██╗██████╗  █████╗ ██╗  ██╗██████╗ ██████╗ ███████╗
  ██╔══██╗██║██╔════╝   ███║╚════██╗╚════██╗██║ ██╔╝██╔══██╗██╔══██╗██╔════╝
  ███████║██║███████╗   ╚██║ █████╔╝ █████╔╝█████╔╝ ██████╔╝██████╔╝███████╗
  ██╔══██║██║╚════██║    ██║██╔═══╝  ╚═══██╗██╔═██╗ ██╔══██╗██╔═══╝ ╚════██║
  ██║  ██║██║███████║    ██║███████╗ █████╔╝██║  ██╗██████╔╝██║     ███████║
  ╚═╝  ╚═╝╚═╝╚══════╝   ╚═╝╚══════╝ ╚════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝     ╚══════╝
```

**By (IG:peepogrob555 FB:Shogun)**

Production-grade VPS setup script for 3x-ui + VLESS+Reality on AIS 128kbps mobile connections.
Focus: minimize jitter and queue delay — NOT maximize throughput.

---

## What this script does

| Component | Action |
|---|---|
| **3x-ui** | Install latest stable via official script |
| **TLS Cert** | certbot standalone + auto-renew hook |
| **DNS** | Benchmark resolvers, pick fastest, deploy dnsmasq cache |
| **sysctl** | BBR + anti-bufferbloat tuning calibrated to RAM/virt type |
| **CAKE egress** | Adaptive bandwidth probe → shape at real measured speed |
| **CAKE ingress** | IFB dual-shaping — eliminates download bufferbloat |
| **nftables** | policy drop + dynamic SSH blocklist + DSCP marking |
| **Xray tuning** | File descriptor limits + sockopt hints + keepalive |

---

## Requirements

- Ubuntu 22.04 LTS (kernel 5.15+)
- 1 vCPU / 1 GB RAM minimum
- Domain (FQDN) pointing to VPS IP
- KVM or bare-metal (LXC/OpenVZ: partial — script auto-detects and adjusts)

---

## Quick start

```bash
wget https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/3x-ui-ais-setup.sh
chmod +x 3x-ui-ais-setup.sh
sudo bash 3x-ui-ais-setup.sh
```

Script will prompt for:
1. **Server domain** — FQDN pointing to this VPS
2. **SSH port** — auto-detected, confirm or override
3. **Admin email** — for Let's Encrypt
4. **Target bandwidth** — default 128 (kbps), script will probe actual speed

---

## Key design decisions

### Why CAKE not just fq_codel?
CAKE with `bandwidth` set to the actual link speed shapes traffic *before* it hits the ISP queue. This is where bufferbloat is actually eliminated. Without a bandwidth limit, CAKE runs in unlimited mode and provides no shaping.

### Why dual CAKE (egress + IFB ingress)?
AIS 128kbps download bufferbloat is worse than upload. Without ingress shaping, large downloads fill the ISP's queue and destroy interactive traffic latency. IFB redirects incoming traffic through a CAKE instance so both directions are shaped.

### Why adaptive bandwidth probe?
AIS mobile speed varies (90–140kbps at nominal 128). Hard-coding 128kbit misses this. Script measures actual throughput and sets CAKE to 90% of measured speed, leaving headroom for the ISP's own queue.

### Why DNS benchmarking?
Reality handshakes require a DNS lookup of the SNI target (th.speedtest.net) per new connection. dnsmasq caches this, but the first hit still goes upstream. Picking the lowest-latency resolver from: AdGuard, Cloudflare, Google, Quad9, TWNIC reduces this from ~40ms to ~5ms for Thai routing.

### Why `tcp_notsent_lowat = 16384`?
At 128kbps, 16384 bytes = ~1 second of data. Without this, the kernel buffers multiple seconds of data in the send buffer before xray picks it up. The result is visible multi-second latency spikes on the client. This is one of the most impactful single settings for XTLS-Vision on low-bandwidth links.

### Why `tcp_limit_output_bytes = 131072`?
Limits per-flow bytes in the kernel's output queue before the pacing layer sees them. Reduces burstiness at the socket level, complementing CAKE's flow shaping.

### Why dynamic SSH blocklist in nftables?
IPs that exceed 10 new SSH connections/minute are automatically added to a blocklist (1 hour timeout). No fail2ban needed. nftables handles it natively with dynamic sets.

---

## After running

1. Open panel: `https://YOUR_DOMAIN:2053/YOUR_PATH/`
2. Panel Settings → Panel Certificate → paste paths from summary
3. Add Inbound:
   - Protocol: VLESS | Port: 443 | Security: Reality
   - Destination: `th.speedtest.net:443` | uTLS: firefox
   - Flow: `xtls-rprx-vision`
   - Enable `tcpNoDelay: true` in stream settings
4. Generate UUID + keypair + shortId via panel
5. Add users → panel generates client URIs + QR codes

Full xray tuning hints are saved to `/root/xray-inbound-settings.txt`.

---

## What this script does NOT do

- Install or configure xray standalone (3x-ui manages xray internally)
- Create VLESS inbounds or users
- Generate UUIDs, keys, or client URIs
- Configure IPv6 routing (ICMP6 rules included, full v6 strategy is manual)
- Auto-rollback on failure (backups in `.bak.TIMESTAMP` before every overwrite)

---

## Idempotency

Safe to re-run. Each step checks if already applied and skips. Backups are created before every file overwrite (`.bak.TIMESTAMP`). On error: restore from `.bak` files and check `/var/log/3x-ui-ais-setup.log`.

---

## Tested on

- Ubuntu 22.04 LTS / kernel 5.15 / KVM VPS
- AIS 4G mobile client, 128kbps plan
- 2 concurrent users: gaming (UDP) + streaming (TCP)

---

## License

MIT — use freely, attribution appreciated.
