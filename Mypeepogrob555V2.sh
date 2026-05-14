#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#   AIS Setup — Diagnostic Checker v1.0
#   By (IG:peepogrob555  FB:Shogun)
#
#   เช็คทุกอย่างที่ Mypeepogrob555.sh ทำไว้
#   ใช้: sudo bash check-ais-setup.sh
# ═══════════════════════════════════════════════════════════════════════════════

BGRN='\033[1;32m'
BCYN='\033[1;36m'
BYLW='\033[1;33m'
BRED='\033[1;31m'
BMAG='\033[1;35m'
BWHT='\033[1;37m'
RST='\033[0m'

PASS=0
WARN=0
FAIL=0

[ "$EUID" -ne 0 ] && echo -e "${BRED}Run as root: sudo bash $0${RST}" && exit 1

pass() { echo -e "  ${BGRN}[PASS]${RST} $*"; (( PASS++ )); }
warn() { echo -e "  ${BYLW}[WARN]${RST} $*"; (( WARN++ )); }
fail() { echo -e "  ${BRED}[FAIL]${RST} $*"; (( FAIL++ )); }
info() { echo -e "  ${BCYN}[INFO]${RST} $*"; }
section() { echo -e "\n${BMAG}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; \
            echo -e "${BMAG}  $*${RST}"; \
            echo -e "${BMAG}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; }

# ─────────────────────────────────────────────────────────────────────────────
section "1. SYSTEM INFO"
# ─────────────────────────────────────────────────────────────────────────────

VIRT=$(systemd-detect-virt 2>/dev/null || echo "unknown")
RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
CPU=$(nproc)
KERNEL=$(uname -r)
IFACE=$(ip route show default 2>/dev/null | awk 'NR==1{print $5}')
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")

info "Hostname   : $(hostname)"
info "OS         : $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
info "Kernel     : $KERNEL"
info "Virt       : $VIRT"
info "RAM        : ${RAM_MB}MB"
info "CPU        : ${CPU} core(s)"
info "Interface  : ${IFACE:-not detected}"
info "Public IP  : $SERVER_IP"
info "Uptime     : $(uptime -p 2>/dev/null || uptime)"

# ─────────────────────────────────────────────────────────────────────────────
section "2. PACKAGES"
# ─────────────────────────────────────────────────────────────────────────────

for pkg in nftables dnsmasq iproute2 curl wget ca-certificates dnsutils certbot; do
  if dpkg -s "$pkg" &>/dev/null 2>&1; then
    VER=$(dpkg -s "$pkg" 2>/dev/null | awk '/^Version:/{print $2}')
    pass "$pkg installed ($VER)"
  else
    fail "$pkg NOT installed"
  fi
done

MODULES_PKG="linux-modules-extra-${KERNEL}"
if dpkg -s "$MODULES_PKG" &>/dev/null 2>&1; then
  pass "$MODULES_PKG installed"
else
  warn "$MODULES_PKG not installed — CAKE may rely on built-in module"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "3. 3x-ui / XRAY"
# ─────────────────────────────────────────────────────────────────────────────

if command -v x-ui &>/dev/null; then
  pass "x-ui binary found: $(which x-ui)"
  XUI_VER=$(x-ui version 2>/dev/null || echo "unknown")
  info "x-ui version: $XUI_VER"
else
  fail "x-ui binary not found"
fi

XUI_STATUS=$(systemctl is-active x-ui 2>/dev/null || echo "inactive")
XUI_ENABLED=$(systemctl is-enabled x-ui 2>/dev/null || echo "disabled")
if [ "$XUI_STATUS" = "active" ]; then
  pass "x-ui service: $XUI_STATUS (enabled: $XUI_ENABLED)"
else
  fail "x-ui service: $XUI_STATUS (enabled: $XUI_ENABLED)"
fi

XRAY_BIN=$(command -v xray 2>/dev/null \
  || find /usr/local/x-ui /usr/local/bin /root/.config/3x-ui -name "xray" 2>/dev/null | head -1 \
  || echo "")
if [ -n "$XRAY_BIN" ]; then
  pass "xray binary: $XRAY_BIN"
  XRAY_VER=$("$XRAY_BIN" version 2>/dev/null | head -1 || echo "unknown")
  info "xray version: $XRAY_VER"
else
  warn "xray binary not found standalone (may be embedded in x-ui)"
fi

# x-ui panel listening on 2053?
if ss -tlnp 2>/dev/null | grep -q ':2053'; then
  pass "Panel port 2053 is LISTENING"
  ss -tlnp | grep ':2053' | while read -r line; do info "  $line"; done
else
  fail "Panel port 2053 not listening"
fi

# VLESS port 443?
if ss -tlnp 2>/dev/null | grep -q ':443'; then
  pass "Port 443 is LISTENING"
else
  warn "Port 443 not listening — inbound may not be configured yet"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "4. TLS CERTIFICATE"
# ─────────────────────────────────────────────────────────────────────────────

CERT_DIR="/etc/ssl/xray"

for f in fullchain.pem key.pem cert.pem; do
  FPATH="$CERT_DIR/$f"
  if [ -L "$FPATH" ] && [ -f "$FPATH" ]; then
    TARGET=$(readlink -f "$FPATH")
    pass "Symlink OK: $FPATH → $TARGET"
  elif [ -f "$FPATH" ]; then
    pass "File exists: $FPATH"
  else
    fail "Missing: $FPATH"
  fi
done

CERT_FILE="$CERT_DIR/fullchain.pem"
if [ -f "$CERT_FILE" ]; then
  EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
  EXPIRY_EPOCH=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null \
    | cut -d= -f2 | xargs -I{} date -d "{}" +%s 2>/dev/null || echo "0")
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

  if [ "$DAYS_LEFT" -gt 30 ]; then
    pass "Certificate expires: $EXPIRY (${DAYS_LEFT} days left)"
  elif [ "$DAYS_LEFT" -gt 0 ]; then
    warn "Certificate expires SOON: $EXPIRY (${DAYS_LEFT} days left — renew soon)"
  else
    fail "Certificate EXPIRED: $EXPIRY"
  fi

  DOMAIN_IN_CERT=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null \
    | sed 's/.*CN = //' | sed 's/,.*//')
  info "Domain in cert: $DOMAIN_IN_CERT"

  # Check SANs
  SANS=$(openssl x509 -noout -ext subjectAltName -in "$CERT_FILE" 2>/dev/null | grep DNS || echo "none")
  info "SANs: $SANS"
else
  fail "Certificate file not found at $CERT_FILE"
fi

# Certbot auto-renew hook
HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-xui.sh"
if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
  pass "Certbot renew hook: $HOOK (executable)"
else
  warn "Certbot renew hook missing or not executable: $HOOK"
fi

# Test certbot timer/cron
if systemctl list-timers 2>/dev/null | grep -q certbot; then
  pass "certbot systemd timer active"
elif crontab -l 2>/dev/null | grep -qi certbot || ls /etc/cron* 2>/dev/null | grep -qi certbot; then
  pass "certbot cron job found"
else
  warn "certbot timer/cron not detected — renewal may not be automatic"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "5. DNS (dnsmasq)"
# ─────────────────────────────────────────────────────────────────────────────

DNS_STATUS=$(systemctl is-active dnsmasq 2>/dev/null || echo "inactive")
DNS_ENABLED=$(systemctl is-enabled dnsmasq 2>/dev/null || echo "disabled")
if [ "$DNS_STATUS" = "active" ]; then
  pass "dnsmasq: $DNS_STATUS (enabled: $DNS_ENABLED)"
else
  fail "dnsmasq: $DNS_STATUS (enabled: $DNS_ENABLED)"
fi

# resolv.conf locked?
RESOLV_NS=$(grep "^nameserver" /etc/resolv.conf 2>/dev/null | head -1)
if echo "$RESOLV_NS" | grep -q "127.0.0.1"; then
  pass "resolv.conf → nameserver 127.0.0.1"
else
  warn "resolv.conf not pointing to 127.0.0.1 (got: $RESOLV_NS)"
fi

RESOLV_IMMUTABLE=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
if echo "$RESOLV_IMMUTABLE" | grep -q "i"; then
  pass "resolv.conf is immutable (chattr +i)"
else
  warn "resolv.conf is NOT immutable — may get overwritten"
fi

# DNS query tests
for domain in google.com th.speedtest.net; do
  RESULT=$(dig +short +time=3 "$domain" @127.0.0.1 2>/dev/null | head -1)
  if [ -n "$RESULT" ]; then
    pass "DNS resolve $domain → $RESULT"
  else
    fail "DNS resolve $domain FAILED via 127.0.0.1"
  fi
done

# dnsmasq config
if grep -q "listen-address=127.0.0.1" /etc/dnsmasq.conf 2>/dev/null; then
  pass "dnsmasq listen-address=127.0.0.1 configured"
  SERVERS=$(grep "^server=" /etc/dnsmasq.conf 2>/dev/null | head -5)
  info "Upstream servers:"
  echo "$SERVERS" | while read -r s; do info "    $s"; done
else
  warn "dnsmasq.conf may not be configured by setup script"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "6. TCP / BBR / SYSCTL"
# ─────────────────────────────────────────────────────────────────────────────

check_sysctl() {
  local key="$1" expected="$2" label="$3"
  local val
  val=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
  if [ "$val" = "$expected" ]; then
    pass "$label: $val"
  else
    warn "$label: got '$val' (expected '$expected')"
  fi
}

check_sysctl "net.ipv4.tcp_congestion_control"    "bbr"     "TCP CC (BBR)"
check_sysctl "net.core.default_qdisc"             "fq_codel" "Default qdisc"
check_sysctl "net.ipv4.tcp_notsent_lowat"         "16384"   "tcp_notsent_lowat"
check_sysctl "net.ipv4.tcp_slow_start_after_idle" "0"       "tcp_slow_start_after_idle"
check_sysctl "net.ipv4.tcp_ecn"                   "1"       "TCP ECN"
check_sysctl "net.ipv4.tcp_fastopen"              "3"       "TCP Fast Open"
check_sysctl "net.ipv4.tcp_mtu_probing"           "1"       "MTU probing"
check_sysctl "net.ipv4.ip_forward"                "1"       "IP forwarding"
check_sysctl "net.ipv6.conf.all.forwarding"       "1"       "IPv6 forwarding"
check_sysctl "net.ipv4.tcp_limit_output_bytes"    "131072"  "tcp_limit_output_bytes"
check_sysctl "vm.swappiness"                      "10"      "vm.swappiness"

BBR_LOADED=$(lsmod | grep -c tcp_bbr || echo "0")
if [ "$BBR_LOADED" -gt 0 ]; then
  pass "BBR kernel module loaded"
else
  warn "BBR module not in lsmod (may be built-in)"
fi

SYSCTL_FILE="/etc/sysctl.d/99-ais-128k.conf"
if [ -f "$SYSCTL_FILE" ]; then
  pass "sysctl config file exists: $SYSCTL_FILE"
else
  warn "sysctl config file not found: $SYSCTL_FILE"
fi

# conntrack
CT_VAL=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "N/A")
info "nf_conntrack_max: $CT_VAL"

# keepalive
info "tcp_keepalive_time : $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null)"
info "tcp_keepalive_intvl: $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────
section "7. QDISC (CAKE / fq_codel)"
# ─────────────────────────────────────────────────────────────────────────────

if [ -z "$IFACE" ]; then
  fail "Cannot detect default interface — skipping qdisc check"
else
  QDISC_OUT=$(tc qdisc show dev "$IFACE" 2>/dev/null)
  info "qdisc on $IFACE:"
  echo "$QDISC_OUT" | while read -r line; do info "    $line"; done

  if echo "$QDISC_OUT" | grep -q "cake"; then
    pass "CAKE qdisc active on $IFACE"
    BW_IN_USE=$(echo "$QDISC_OUT" | grep -oP 'bandwidth \K[0-9]+[KMGkbitKbit]+' | head -1)
    info "CAKE bandwidth: ${BW_IN_USE:-not shown}"
  elif echo "$QDISC_OUT" | grep -q "fq_codel"; then
    warn "fq_codel active on $IFACE (CAKE fallback — still good)"
  else
    fail "No CAKE or fq_codel found on $IFACE"
  fi

  # IFB ingress
  IFB_DEV="ifb0"
  if ip link show "$IFB_DEV" &>/dev/null 2>&1; then
    IFB_QDISC=$(tc qdisc show dev "$IFB_DEV" 2>/dev/null)
    info "qdisc on $IFB_DEV (ingress IFB):"
    echo "$IFB_QDISC" | while read -r line; do info "    $line"; done
    if echo "$IFB_QDISC" | grep -q "cake"; then
      pass "CAKE ingress shaping active on $IFB_DEV"
    else
      warn "IFB device exists but no CAKE ingress qdisc"
    fi
  else
    warn "IFB device ($IFB_DEV) not present — ingress shaping not active"
  fi

  # ais-qdisc service
  AIS_STATUS=$(systemctl is-active ais-qdisc 2>/dev/null || echo "inactive")
  AIS_ENABLED=$(systemctl is-enabled ais-qdisc 2>/dev/null || echo "disabled")
  if [ "$AIS_STATUS" = "active" ]; then
    pass "ais-qdisc service: $AIS_STATUS (enabled: $AIS_ENABLED)"
  else
    warn "ais-qdisc service: $AIS_STATUS (enabled: $AIS_ENABLED) — qdisc may not persist after reboot"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "8. NFTABLES FIREWALL"
# ─────────────────────────────────────────────────────────────────────────────

NFT_STATUS=$(systemctl is-active nftables 2>/dev/null || echo "inactive")
NFT_ENABLED=$(systemctl is-enabled nftables 2>/dev/null || echo "disabled")
if [ "$NFT_STATUS" = "active" ]; then
  pass "nftables: $NFT_STATUS (enabled: $NFT_ENABLED)"
else
  fail "nftables: $NFT_STATUS (enabled: $NFT_ENABLED)"
fi

# Check key rules exist
NFT_RULES=$(nft list ruleset 2>/dev/null || echo "")

if echo "$NFT_RULES" | grep -q "dport 443"; then
  pass "nftables: port 443 rule present"
else
  fail "nftables: port 443 rule NOT found"
fi

if echo "$NFT_RULES" | grep -q "dport 2053"; then
  pass "nftables: port 2053 rule present"
else
  fail "nftables: port 2053 rule NOT found"
fi

if echo "$NFT_RULES" | grep -q "ssh_blocklist"; then
  pass "nftables: SSH brute-force blocklist present"
else
  warn "nftables: SSH blocklist not found"
fi

if echo "$NFT_RULES" | grep -q "masquerade"; then
  pass "nftables: NAT masquerade rule present"
else
  warn "nftables: NAT masquerade rule not found"
fi

if echo "$NFT_RULES" | grep -q "dscp"; then
  pass "nftables: DSCP QoS marking rules present"
else
  warn "nftables: DSCP marking rules not found"
fi

# Show SSH port in use
SSH_PORT_IN_NFT=$(echo "$NFT_RULES" | grep -oP 'dport \K[0-9]+' | grep -v "^443$" | grep -v "^2053$" | grep -v "^53$" | head -1)
[ -n "$SSH_PORT_IN_NFT" ] && info "SSH port in nftables: $SSH_PORT_IN_NFT"

# ─────────────────────────────────────────────────────────────────────────────
section "9. FILE DESCRIPTORS / LIMITS"
# ─────────────────────────────────────────────────────────────────────────────

LIMITS_CONF="/etc/security/limits.conf"
if grep -q "xray-limits" "$LIMITS_CONF" 2>/dev/null; then
  pass "limits.conf: xray fd limits configured"
  grep -A4 "xray-limits" "$LIMITS_CONF" | while read -r l; do info "    $l"; done
else
  warn "limits.conf: xray fd limits not found"
fi

OVERRIDE_FILE="/etc/systemd/system/x-ui.service.d/override.conf"
if [ -f "$OVERRIDE_FILE" ]; then
  pass "systemd override: $OVERRIDE_FILE exists"
  cat "$OVERRIDE_FILE" | while read -r l; do info "    $l"; done
else
  warn "systemd override not found: $OVERRIDE_FILE"
fi

# Check actual fd limit of x-ui process
XUI_PID=$(pgrep -f "x-ui" | head -1 || echo "")
if [ -n "$XUI_PID" ]; then
  FD_SOFT=$(cat /proc/"$XUI_PID"/limits 2>/dev/null | awk '/open files/{print $4}')
  FD_HARD=$(cat /proc/"$XUI_PID"/limits 2>/dev/null | awk '/open files/{print $5}')
  if [ "${FD_SOFT:-0}" -ge 65535 ] 2>/dev/null; then
    pass "x-ui process fd limit: soft=$FD_SOFT hard=$FD_HARD"
  else
    warn "x-ui process fd limit may be low: soft=${FD_SOFT:-?} hard=${FD_HARD:-?}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
section "10. CONNECTIVITY TEST"
# ─────────────────────────────────────────────────────────────────────────────

# HTTPS to panel
DOMAIN_IN_CERT_CHECK=$(openssl x509 -noout -subject -in "$CERT_DIR/fullchain.pem" 2>/dev/null \
  | sed 's/.*CN = //' | sed 's/,.*//' || echo "")

if [ -n "$DOMAIN_IN_CERT_CHECK" ]; then
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    "https://$DOMAIN_IN_CERT_CHECK:2053/" --connect-timeout 5 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" =~ ^(200|301|302|400|401|403|404)$ ]]; then
    pass "Panel HTTPS reachable: https://$DOMAIN_IN_CERT_CHECK:2053/ (HTTP $HTTP_CODE)"
  else
    warn "Panel HTTPS: https://$DOMAIN_IN_CERT_CHECK:2053/ → HTTP $HTTP_CODE (may need cert config in panel UI)"
  fi
fi

# Outbound internet
OUTBOUND=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
if [ -n "$OUTBOUND" ]; then
  pass "Outbound internet: OK (public IP = $OUTBOUND)"
else
  fail "Outbound internet: FAILED"
fi

# th.speedtest.net reachable (Reality SNI target)
SNI_IP=$(dig +short th.speedtest.net @127.0.0.1 2>/dev/null | tail -1)
if [ -n "$SNI_IP" ]; then
  SNI_REACH=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
    "https://th.speedtest.net" 2>/dev/null || echo "000")
  if [[ "$SNI_REACH" =~ ^(200|301|302|400)$ ]]; then
    pass "th.speedtest.net reachable ($SNI_IP, HTTP $SNI_REACH) — Reality SNI OK"
  else
    warn "th.speedtest.net → $SNI_IP but HTTP $SNI_REACH — Reality may still work"
  fi
else
  fail "th.speedtest.net DNS failed — Reality handshake will fail"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "11. LOG FILE"
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILE="/var/log/3x-ui-ais-setup.log"
if [ -f "$LOG_FILE" ]; then
  LOG_SIZE=$(du -sh "$LOG_FILE" | cut -f1)
  LOG_LINES=$(wc -l < "$LOG_FILE")
  pass "Setup log exists: $LOG_FILE ($LOG_SIZE, $LOG_LINES lines)"
  info "Last 5 lines:"
  tail -5 "$LOG_FILE" | while read -r l; do info "    $l"; done
else
  warn "Setup log not found: $LOG_FILE (setup may not have been run yet)"
fi

HINT_FILE="/root/xray-inbound-settings.txt"
if [ -f "$HINT_FILE" ]; then
  pass "Xray hints file: $HINT_FILE"
else
  warn "Xray hints file not found: $HINT_FILE"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

TOTAL=$(( PASS + WARN + FAIL ))

echo ""
echo -e "${BCYN}╔═════════════════════════════════════════╗${RST}"
echo -e "${BCYN}║           DIAGNOSTIC RESULTS            ║${RST}"
echo -e "${BCYN}╠═════════════════════════════════════════╣${RST}"
printf "${BCYN}║${RST}  ${BGRN}%-6s PASS${RST}  %-26s ${BCYN}║${RST}\n" "$PASS" ""
printf "${BCYN}║${RST}  ${BYLW}%-6s WARN${RST}  %-26s ${BCYN}║${RST}\n" "$WARN" "(non-critical)"
printf "${BCYN}║${RST}  ${BRED}%-6s FAIL${RST}  %-26s ${BCYN}║${RST}\n" "$FAIL" "(needs attention)"
printf "${BCYN}║${RST}  %-6s TOTAL %-26s ${BCYN}║${RST}\n" "$TOTAL" ""
echo -e "${BCYN}╚═════════════════════════════════════════╝${RST}"
echo ""

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo -e "${BGRN}  ✓ Everything looks perfect!${RST}"
elif [ "$FAIL" -eq 0 ]; then
  echo -e "${BYLW}  ⚠ Setup OK but $WARN warning(s) — review above${RST}"
else
  echo -e "${BRED}  ✗ $FAIL failure(s) found — check [FAIL] items above${RST}"
fi

echo ""
