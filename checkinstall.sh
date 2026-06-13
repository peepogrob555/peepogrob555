#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  DNS LEAK FIX — สำหรับ VPS ที่รัน vless-reality-setup แล้ว
#  แก้: resolv.conf ถูกทับ / DoT ไม่ทำงาน / port 53 รั่ว
#  รันเสร็จ → ทดสอบด้วย: resolvectl status
#                          curl -s https://1.1.1.1/cdn-cgi/trace | grep loc
# ═══════════════════════════════════════════════════════════════════
set -uo pipefail
export LANG=C

GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

ok()   { echo -e "  ${GRN}✔${RST}  $1"; }
warn() { echo -e "  ${YEL}⚠${RST}  $1"; }
info() { echo -e "  ${CYN}ℹ${RST}  $1"; }
die()  { echo -e "\n${RED}${BLD}✘  $1${RST}\n"; exit 1; }
sep()  { echo -e "${CYN}──────────────────────────────────────────────────────${RST}"; }
hdr()  { echo -e "\n${BLD}${CYN}▶  $1${RST}"; sep; }

[ "$(id -u)" -eq 0 ] || die "ต้องรันด้วย root"

echo ""
echo -e "${BLD}${CYN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${CYN}║  DNS LEAK FIX — Force DNS-over-TLS (Cloudflare)     ║${RST}"
echo -e "${BLD}${CYN}╚══════════════════════════════════════════════════════╝${RST}"
echo ""

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 1 — ปิด service ที่อาจแย่ง DNS"
# ═══════════════════════════════════════════════════════════════════

# ── 1.1 NetworkManager: ห้ามจัดการ DNS ──────────────────────────────
info "1.1 ปิด NetworkManager DNS management..."
if command -v nmcli &>/dev/null || systemctl is-active NetworkManager &>/dev/null 2>&1; then
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/99-no-dns.conf << 'NMEOF'
[main]
dns=none
systemd-resolved=false
NMEOF
  systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
  ok "NetworkManager: dns=none"
else
  ok "NetworkManager ไม่มี — ข้าม"
fi

# ── 1.2 cloud-init: ห้ามเขียนทับ resolv.conf ───────────────────────
info "1.2 ปิด cloud-init network/DNS management..."
if [ -d /etc/cloud ]; then
  mkdir -p /etc/cloud/cloud.cfg.d
  cat > /etc/cloud/cloud.cfg.d/99-nodns.cfg << 'CLOUDEOF'
network:
  config: disabled
manage_resolv_conf: false
CLOUDEOF
  ok "cloud-init: manage_resolv_conf=false"
else
  ok "cloud-init ไม่มี — ข้าม"
fi

# ── 1.3 systemd-networkd: ห้ามเขียน DNS ────────────────────────────
info "1.3 ปิด systemd-networkd DNS..."
if systemctl is-active systemd-networkd &>/dev/null 2>&1; then
  mkdir -p /etc/systemd/network
  # Override ทุก .network file ที่อาจมี DNS= อยู่
  for f in /etc/systemd/network/*.network; do
    [ -f "$f" ] || continue
    grep -q '^\[Network\]' "$f" || continue
    if ! grep -q 'UseDNS=no' "$f"; then
      # append [DHCP] section override
      cat >> "$f" << 'NDEOF'

[DHCP]
UseDNS=no
UseDomains=no
NDEOF
      info "Patched: $f"
    fi
  done
  # Global networkd config
  mkdir -p /etc/systemd/networkd.conf.d
  cat > /etc/systemd/networkd.conf.d/99-nodns.conf << 'NWDEOF'
[Network]
UseDNS=no
NWDEOF
  ok "systemd-networkd: UseDNS=no"
else
  ok "systemd-networkd ไม่ active — ข้าม"
fi

# ── 1.4 dhclient / dhcpcd: hook ห้าม overwrite resolv.conf ─────────
info "1.4 ปิด dhclient DNS hook..."
mkdir -p /etc/dhcp
cat > /etc/dhcp/dhclient-enter-hooks.d/nodnsupdate << 'DHEOF'
#!/bin/sh
# ห้าม dhclient เขียนทับ /etc/resolv.conf
make_resolv_conf() { :; }
DHEOF
chmod +x /etc/dhcp/dhclient-enter-hooks.d/nodnsupdate 2>/dev/null || true
ok "dhclient hook: make_resolv_conf disabled"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 2 — ตั้งค่า systemd-resolved (DoT บังคับ)"
# ═══════════════════════════════════════════════════════════════════

info "2.1 เขียน resolved config..."
mkdir -p /etc/systemd/resolved.conf.d

cat > /etc/systemd/resolved.conf.d/99-dot-strict.conf << 'DOTEOF'
[Resolve]
# Primary: Cloudflare DoT
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
# Fallback: Quad9 DoT
FallbackDNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
# บังคับ TLS เท่านั้น — ถ้า handshake fail จะ NXDOMAIN ไม่ fallback plaintext
DNSOverTLS=yes
# ปิด DNSSEC (บาง ISP/middlebox ทำให้ DNSSEC fail แบบ false positive)
DNSSEC=no
# Cache ใน RAM
Cache=yes
CacheFromLocalhost=no
# เปิด stub listener ที่ 127.0.0.53:53
DNSStubListener=yes
# อ่าน /etc/hosts
ReadEtcHosts=yes
# ปิด mDNS และ LLMNR (ไม่จำเป็น อาจ leak)
MulticastDNS=no
LLMNR=no
DOTEOF

ok "resolved config เขียนแล้ว"

info "2.2 restart systemd-resolved..."
# ปิด resolved ก่อนเพื่อ clear state เก่า
systemctl stop systemd-resolved 2>/dev/null || true
sleep 1
systemctl enable systemd-resolved
systemctl start systemd-resolved
sleep 2

# ตรวจว่า start สำเร็จ
if systemctl is-active systemd-resolved &>/dev/null; then
  ok "systemd-resolved: active"
else
  die "systemd-resolved start ล้มเหลว — ดู: journalctl -u systemd-resolved -n 30"
fi

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 3 — Fix /etc/resolv.conf (lock ไม่ให้ถูกทับ)"
# ═══════════════════════════════════════════════════════════════════

info "3.1 ถอด immutable flag เก่า (ถ้ามี)..."
chattr -i /etc/resolv.conf 2>/dev/null || true

info "3.2 ลบ resolv.conf เก่าและสร้าง symlink ใหม่..."
rm -f /etc/resolv.conf

# stub-resolv.conf → ให้ทุก process ใช้ 127.0.0.53 (stub ของ resolved)
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# ตรวจว่า stub socket มีอยู่จริง
if [ -S /run/systemd/resolve/io.systemd.Resolve ]; then
  ok "resolved stub socket: พร้อม"
elif ss -lnup 2>/dev/null | grep -q '127.0.0.53'; then
  ok "resolved stub listening ที่ 127.0.0.53:53"
else
  warn "ไม่เจอ stub socket — อาจต้อง reboot ก่อน"
fi

info "3.3 lock resolv.conf ด้วย chattr +i..."
# ต้องรอให้ symlink target มีอยู่ก่อน
if [ -f /run/systemd/resolve/stub-resolv.conf ]; then
  # lock ตัว symlink เองไม่ได้ — lock target แทน
  chattr +i /run/systemd/resolve/stub-resolv.conf 2>/dev/null \
    && ok "stub-resolv.conf: immutable" \
    || warn "chattr +i ไม่สำเร็จ (อาจเป็น container) — ใช้ systemd path unit แทน"
  
  # สร้าง systemd path unit เฝ้า resolv.conf แทน
  cat > /etc/systemd/system/resolv-guard.service << 'RGEOF'
[Unit]
Description=Guard /etc/resolv.conf from being overwritten
After=systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  chattr -i /etc/resolv.conf 2>/dev/null || true; \
  rm -f /etc/resolv.conf; \
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; \
  chattr +i /run/systemd/resolve/stub-resolv.conf 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RGEOF

  cat > /etc/systemd/system/resolv-guard.path << 'RPEOF'
[Unit]
Description=Watch /etc/resolv.conf for unwanted changes

[Path]
PathChanged=/etc/resolv.conf
PathModified=/etc/resolv.conf
Unit=resolv-guard.service

[Install]
WantedBy=multi-user.target
RPEOF

  systemctl daemon-reload
  systemctl enable --now resolv-guard.path
  ok "resolv-guard.path: เฝ้า resolv.conf หากถูกเปลี่ยนจะ restore อัตโนมัติ"
else
  warn "stub-resolv.conf ยังไม่พร้อม — resolved อาจยัง start ไม่เสร็จ"
fi

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 4 — Block port 53 plaintext (nftables แบบแน่นหนา)"
# ═══════════════════════════════════════════════════════════════════

info "4.1 เขียน nftables ruleset ใหม่..."
# ลบ table เก่าก่อน (ถ้ามี)
nft delete table inet dns_privacy 2>/dev/null || true

cat > /etc/nftables-dns-block.conf << 'NFTEOF'
#!/usr/sbin/nft -f
# ── DNS Privacy: บังคับใช้ DoT เท่านั้น ──────────────────────────
# Logic:
#   ALLOW  → ออกจาก 127.0.0.53 (resolved stub → upstream) ผ่าน port 853 (DoT)
#   ALLOW  → loopback DNS (127.x.x.x port 53 = stub resolver)
#   DROP   → ทุก DNS query plaintext (port 53 UDP/TCP) ที่ไม่ใช่ loopback
#   DROP   → port 53 ขาเข้าจาก internet (ป้องกัน DNS amplification)

table inet dns_privacy {

  # ── Outbound: block plaintext DNS ──────────────────────────────
  chain output_dns_block {
    type filter hook output priority filter + 1; policy accept;

    # อนุญาต loopback ทั้งหมด (127.0.0.53:53 stub, 127.0.0.1:53 ถ้ามี)
    oif "lo" accept

    # อนุญาต resolved ส่ง DoT ออก (port 853)
    tcp dport 853 accept
    udp dport 853 accept

    # DROP plaintext DNS port 53 ทุกทิศทางที่ไม่ใช่ loopback
    udp dport 53 drop
    tcp dport 53 drop
  }

  # ── Inbound: block port 53 จาก internet ─────────────────────────
  chain input_dns_block {
    type filter hook input priority filter + 1; policy accept;

    # อนุญาต loopback
    iif "lo" accept

    # Drop port 53 จาก non-loopback (ป้องกัน DNS amplification attack)
    udp dport 53 drop
    tcp dport 53 drop
  }

  # ── Forward: ห้าม DNS transit ───────────────────────────────────
  chain forward_dns_block {
    type filter hook forward priority filter + 1; policy accept;
    udp dport 53 drop
    tcp dport 53 drop
  }
}
NFTEOF

nft -f /etc/nftables-dns-block.conf
if [ $? -eq 0 ]; then
  ok "nftables DNS block: active"
  nft list table inet dns_privacy 2>/dev/null | head -5 | sed 's/^/    /'
else
  die "nftables load ล้มเหลว — ตรวจ: nft -f /etc/nftables-dns-block.conf"
fi

info "4.2 ตั้ง persist service..."
cat > /etc/systemd/system/dns-privacy-nft.service << 'DNSSEOF'
[Unit]
Description=Block plaintext DNS — force DoT only
After=network.target nftables.service
Before=systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables-dns-block.conf
ExecReload=/usr/sbin/nft -f /etc/nftables-dns-block.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DNSSEOF

systemctl daemon-reload
systemctl enable --now dns-privacy-nft.service
ok "dns-privacy-nft.service: enabled + active"

# ═══════════════════════════════════════════════════════════════════
hdr "STEP 5 — ตรวจสอบว่า DoT ทำงานจริง"
# ═══════════════════════════════════════════════════════════════════

info "5.1 รอ resolved พร้อม..."
for i in $(seq 1 15); do
  resolvectl status 2>/dev/null | grep -q "DNS over TLS" && break
  sleep 1
done

echo ""
info "resolvectl status (สรุป):"
resolvectl status 2>/dev/null | grep -E "(DNS Server|DNS over TLS|Current DNS|DNSSEC)" \
  | head -20 | sed 's/^/    /'

echo ""
info "5.2 ทดสอบ DNS query จริง..."
RESOLVE_OK=0

# วิธี 1: resolvectl query
if resolvectl query cloudflare.com &>/dev/null 2>&1; then
  ok "resolvectl query cloudflare.com: สำเร็จ"
  RESOLVE_OK=1
else
  warn "resolvectl query ล้มเหลว"
fi

# วิธี 2: dig ผ่าน stub
if command -v dig &>/dev/null; then
  DIG_OUT=$(dig @127.0.0.53 cloudflare.com A +short +time=5 2>/dev/null || true)
  if [ -n "$DIG_OUT" ]; then
    ok "dig @127.0.0.53 cloudflare.com: $DIG_OUT"
    RESOLVE_OK=1
  else
    warn "dig @127.0.0.53 ล้มเหลว"
  fi
fi

# วิธี 3: curl (test connectivity)
if curl -sf --max-time 8 https://cloudflare.com -o /dev/null; then
  ok "curl https://cloudflare.com: สำเร็จ"
else
  warn "curl ล้มเหลว (อาจแค่ network ชั่วคราว)"
fi

[ "$RESOLVE_OK" -eq 0 ] && warn "DNS resolve ไม่สำเร็จ — อาจต้อง reboot ก่อน"

info "5.3 ตรวจว่า port 53 ถูก block จริง..."
# ลอง query ตรงไปยัง Google DNS (ควรถูก block)
if command -v dig &>/dev/null; then
  if dig @8.8.8.8 google.com +time=3 +tries=1 &>/dev/null 2>&1; then
    warn "dig @8.8.8.8 ยังผ่านได้ — nftables อาจยังไม่ apply (ลอง reboot)"
  else
    ok "dig @8.8.8.8: ถูก block แล้ว (timeout/refused) ✓"
  fi
else
  info "ไม่มี dig — ข้ามการทดสอบ block"
fi

# ═══════════════════════════════════════════════════════════════════
hdr "สรุปผล"
# ═══════════════════════════════════════════════════════════════════
echo ""
echo -e "  ══════════════════════════════════════════════════════"
echo -e "  ${BLD}DNS over TLS Configuration:${RST}"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  Primary DNS  : 1.1.1.1 + 1.0.0.1 (Cloudflare DoT 853)"
echo -e "  Fallback DNS : 9.9.9.9 + 149.112.112.112 (Quad9 DoT)"
echo -e "  Stub         : 127.0.0.53:53"
echo -e "  Mode         : DNSOverTLS=yes (บังคับ ไม่ fallback)"
echo -e "  ──────────────────────────────────────────────────────"
echo -e "  ${BLD}Leak Prevention:${RST}"
echo -e "    ✔  NetworkManager: dns=none"
echo -e "    ✔  cloud-init: manage_resolv_conf=false"
echo -e "    ✔  dhclient hook: make_resolv_conf disabled"
echo -e "    ✔  nftables: block port 53 outbound/inbound/forward"
echo -e "    ✔  resolv.conf: locked (chattr +i / path guard)"
echo -e "  ══════════════════════════════════════════════════════"
echo ""
echo -e "${BLD}${YEL}  ── ทดสอบ DNS Leak หลัง reboot ──${RST}"
echo -e "  1. reboot"
echo -e "  2. เปิด: https://browserleaks.com/dns"
echo -e "     หรือ: https://1.1.1.1/help"
echo -e "     ควรเห็น Cloudflare เท่านั้น ไม่มี Google/ISP"
echo -e ""
echo -e "  ── Debug commands ──"
echo -e "  resolvectl status"
echo -e "  resolvectl statistics"
echo -e "  nft list table inet dns_privacy"
echo -e "  dig @127.0.0.53 cloudflare.com"
echo -e "  dig @8.8.8.8 test.com   ← ต้องไม่ผ่าน (timeout)"
echo ""
echo -e "${BLD}${RED}  ⚠  reboot แนะนำเพื่อให้ทุก service reload config ใหม่${RST}"
echo ""
