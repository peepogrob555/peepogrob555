#!/usr/bin/env bash
# =============================================================================
# PeepogrobVPN — Production Build Script
# Target: Ubuntu 22.04 LTS / ARM64 VPS
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/var/log/peepogrobvpn_build.log"
readonly WORK_DIR="$HOME/PeepogrobVPN"
readonly SDK_DIR="$HOME/android-sdk"
readonly GRADLE_DIR="/opt/gradle-8.2"
readonly GRADLE_URL="https://services.gradle.org/distributions/gradle-8.2-bin.zip"
readonly GRADLE_SHA256="1b91265e65b73b016a3f1a88c6c7ec4e1e8f4ce7a43413f86d4c048c4c71a4e9"
readonly SDK_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
readonly AAR_URL="https://github.com/2dust/AndroidLibV2rayLite/releases/download/v5.51.2/libv2ray.aar"
readonly AAR_SHA256="skip"   # computed at runtime first download
readonly MIN_RAM_MB=1500
readonly MIN_DISK_MB=5000
readonly ANDROID_API=34
readonly BUILD_TOOLS_VER="34.0.0"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
log_ok()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $*"; }
log_err() { echo -e "${RED}[$(date '+%H:%M:%S')] ✗ ERROR:${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $*"; }
die()     { log_err "$*"; exit 1; }

# ── Cleanup trap ──────────────────────────────────────────────────────────────
CLEANUP_NEEDED=false
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 && "$CLEANUP_NEEDED" == "true" ]]; then
    log_warn "Build failed (exit $exit_code). Partial files kept for debug."
    log_warn "Log: $LOG_FILE"
    log_warn "Work dir: $WORK_DIR"
  fi
  # Kill background http server if running
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
cat << 'BANNER'
 ____                                       _    ___   ____  _   _
|  _ \ ___  ___ _ __   ___   __ _ _ __ ___| |__/ _ \ / ___|| \ | |
| |_) / _ \/ _ \ '_ \ / _ \ / _` | '__/ _ \ '_ \  / /_____/ | \| |
|  __/  __/  __/ |_) | (_) | (_| | | |  __/ |_) ) /|______|  |\  |
|_|   \___|\___| .__/ \___/ \__, |_|  \___|_.__/_/        |_| \_|
               |_|          |___/
BANNER
echo -e "${NC}"
log "PeepogrobVPN Build Script v${SCRIPT_VERSION}"
log "Log: $LOG_FILE"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 0: PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[0/7] Pre-flight checks...${NC}"

# Root check
[[ $EUID -eq 0 ]] || die "Must run as root. Use: sudo bash $0"
log_ok "Running as root"

# OS check
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  log_ok "OS: $PRETTY_NAME"
  [[ "$ID" == "ubuntu" || "$ID" == "debian" ]] || log_warn "Untested OS: $ID"
fi

# Architecture check
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" || "$ARCH" == "aarch64" ]] || die "Unsupported arch: $ARCH"
log_ok "Architecture: $ARCH"

# RAM check
RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
log "RAM: ${RAM_MB}MB"
(( RAM_MB >= MIN_RAM_MB )) || die "Insufficient RAM: ${RAM_MB}MB < ${MIN_RAM_MB}MB required"
log_ok "RAM sufficient"

# Disk check
DISK_MB=$(df -m "$HOME" | awk 'NR==2{print $4}')
log "Disk free: ${DISK_MB}MB"
(( DISK_MB >= MIN_DISK_MB )) || die "Insufficient disk: ${DISK_MB}MB < ${MIN_DISK_MB}MB required"
log_ok "Disk sufficient"

# Network check
log "Checking network..."
curl -sf --max-time 5 https://google.com > /dev/null || die "No internet connection"
log_ok "Network OK"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: SYSTEM DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[1/7] System dependencies...${NC}"

PKGS=(openjdk-17-jdk unzip wget curl zip python3 ca-certificates)
MISSING=()
for pkg in "${PKGS[@]}"; do
  dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log "Installing: ${MISSING[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
  log_ok "Packages installed"
else
  log_ok "All packages already installed"
fi

# Java version verify
JAVA_VER=$(java -version 2>&1 | head -1 | grep -oP '"\K[^"]+' | cut -d. -f1)
[[ "$JAVA_VER" -ge 17 ]] || die "Java 17+ required, got $JAVA_VER"
log_ok "Java $JAVA_VER"

# Swap — only if not enough free RAM
FREE_RAM=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if (( FREE_RAM < 1200 )); then
  if [[ ! -f /swapfile ]]; then
    log "Low RAM (${FREE_RAM}MB free), creating 2GB swap..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log_ok "Swap created"
  else
    swapon /swapfile 2>/dev/null || true
    log_ok "Swap already exists"
  fi
else
  log_ok "RAM sufficient (${FREE_RAM}MB free), skip swap"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: ANDROID SDK
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[2/7] Android SDK...${NC}"

export ANDROID_HOME="$SDK_DIR"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"

if [[ ! -f "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
  log "Downloading Android SDK command-line tools..."
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  wget -q "$SDK_URL" -O /tmp/cmdtools.zip
  unzip -q /tmp/cmdtools.zip -d "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm /tmp/cmdtools.zip
  log_ok "SDK tools downloaded"
else
  log_ok "SDK tools already installed"
fi

log "Accepting licenses..."
yes | sdkmanager --licenses > /dev/null 2>&1 || true

COMPONENTS_NEEDED=false
[[ -d "$ANDROID_HOME/platforms/android-${ANDROID_API}" ]] || COMPONENTS_NEEDED=true
[[ -d "$ANDROID_HOME/build-tools/${BUILD_TOOLS_VER}" ]] || COMPONENTS_NEEDED=true

if [[ "$COMPONENTS_NEEDED" == "true" ]]; then
  log "Installing SDK components..."
  sdkmanager \
    "platforms;android-${ANDROID_API}" \
    "build-tools;${BUILD_TOOLS_VER}" \
    "platform-tools" > /dev/null 2>&1
  log_ok "SDK components installed"
else
  log_ok "SDK components already installed"
fi

# Gradle
export PATH="$PATH:$GRADLE_DIR/bin"
if [[ ! -f "$GRADLE_DIR/bin/gradle" ]]; then
  log "Downloading Gradle 8.2..."
  wget -q "$GRADLE_URL" -O /tmp/gradle.zip
  # Verify gradle zip is valid
  unzip -t /tmp/gradle.zip > /dev/null 2>&1 || die "Gradle zip corrupted"
  unzip -q /tmp/gradle.zip -d /opt
  rm /tmp/gradle.zip
  log_ok "Gradle installed"
else
  log_ok "Gradle already installed"
fi

GRADLE_VER=$(gradle --version 2>/dev/null | grep "^Gradle" | awk '{print $2}')
log_ok "Gradle $GRADLE_VER"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: PROJECT STRUCTURE
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[3/7] Project structure...${NC}"
CLEANUP_NEEDED=true

[[ -d "$WORK_DIR" ]] && { log_warn "Removing existing project..."; rm -rf "$WORK_DIR"; }

mkdir -p "$WORK_DIR"/app/src/main/{java/com/peepogrob/vpn/{ui,vpn,model,util},res/{layout,values,values-night,mipmap-mdpi,mipmap-hdpi,mipmap-xhdpi,mipmap-xxhdpi,mipmap-xxxhdpi}}
mkdir -p "$WORK_DIR/app/libs"

log_ok "Directory structure created"

# ── Download libv2ray.aar ──────────────────────────────────────────────────────
AAR_PATH="$WORK_DIR/app/libs/libv2ray.aar"
log "Downloading libv2ray.aar v5.51.2..."
wget -q --show-progress "$AAR_URL" -O "$AAR_PATH" 2>&1 | tail -1 || die "Failed to download libv2ray.aar"

# Verify AAR is valid zip
unzip -t "$AAR_PATH" > /dev/null 2>&1 || die "libv2ray.aar is corrupted"
# Verify it contains the expected .so
unzip -l "$AAR_PATH" | grep -q "libgojni.so" || die "libv2ray.aar missing libgojni.so"
AAR_SIZE=$(stat -c%s "$AAR_PATH")
(( AAR_SIZE > 30000000 )) || die "libv2ray.aar too small (${AAR_SIZE} bytes) — likely incomplete"
log_ok "libv2ray.aar verified ($(( AAR_SIZE / 1024 / 1024 ))MB)"

# ── Generate placeholder icons ────────────────────────────────────────────────
log "Generating icons..."
python3 - << 'PYICON'
import struct, zlib, os

def make_png(w, h, r, g, b):
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    raw = b''.join(b'\x00' + bytes([r, g, b]) * w for _ in range(h))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw))
            + chunk(b'IEND', b''))

base = '/root/PeepogrobVPN/app/src/main/res'
sizes = {'mipmap-mdpi':48,'mipmap-hdpi':72,'mipmap-xhdpi':96,'mipmap-xxhdpi':144,'mipmap-xxxhdpi':192}
for folder, size in sizes.items():
    path = f'{base}/{folder}/ic_launcher.png'
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(make_png(size, size, 33, 150, 243))
print("Icons OK")
PYICON
log_ok "Icons generated"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: GRADLE BUILD FILES
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[4/7] Build configuration...${NC}"
cd "$WORK_DIR"

cat > settings.gradle << 'EOF'
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "PeepogrobVPN"
include ':app'
EOF

cat > build.gradle << 'EOF'
buildscript {
    repositories { google(); mavenCentral() }
    dependencies {
        classpath 'com.android.tools.build:gradle:8.2.2'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22"
    }
}
EOF

cat > gradle.properties << 'EOF'
android.useAndroidX=true
android.enableJetifier=true
org.gradle.jvmargs=-Xmx1536m -XX:+UseG1GC
org.gradle.daemon=false
org.gradle.parallel=false
kotlin.incremental=false
EOF

cat > app/build.gradle << 'EOF'
plugins {
    id 'com.android.application'
    id 'org.jetbrains.kotlin.android'
    id 'kotlin-parcelize'
}
android {
    namespace 'com.peepogrob.vpn'
    compileSdk 34
    defaultConfig {
        applicationId "com.peepogrob.vpn"
        minSdk 21
        targetSdk 34
        versionCode 1
        versionName "1.0"
        ndk { abiFilters 'arm64-v8a' }
    }
    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
        debug { minifyEnabled false }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = '17' }
    buildFeatures { viewBinding true }
    packagingOptions {
        jniLibs { useLegacyPackaging = true }
    }
}
dependencies {
    implementation 'androidx.appcompat:appcompat:1.6.1'
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'com.google.android.material:material:1.11.0'
    implementation 'androidx.lifecycle:lifecycle-runtime-ktx:2.7.0'
    implementation fileTree(dir: 'libs', include: ['*.aar','*.jar'])
}
EOF

cat > app/proguard-rules.pro << 'EOF'
-keep class com.peepogrob.vpn.** { *; }
-keep class go.** { *; }
-keep class libv2ray.** { *; }
-dontwarn go.**
-dontwarn libv2ray.**
-keepattributes *Annotation*
EOF

log_ok "Build files written"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: SOURCE CODE
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[5/7] Writing source code...${NC}"

python3 << 'PYEOF'
import os, sys

B  = '/root/PeepogrobVPN/app/src/main'
J  = f'{B}/java/com/peepogrob/vpn'
RES= f'{B}/res'

def w(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path,'w') as f: f.write(content)
    print(f"  wrote {path.split('PeepogrobVPN/')[-1]}")

# ── AndroidManifest ──────────────────────────────────────────────────────────
w(f'{B}/AndroidManifest.xml', '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <application
        android:allowBackup="false"
        android:icon="@mipmap/ic_launcher"
        android:label="PeepogrobVPN"
        android:theme="@style/AppTheme">
        <activity
            android:name=".ui.MainActivity"
            android:exported="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <activity android:name=".ui.SettingsActivity" android:exported="false"/>
        <service
            android:name=".vpn.PeeVpnService"
            android:exported="false"
            android:permission="android.permission.BIND_VPN_SERVICE"
            android:foregroundServiceType="connectedDevice">
            <intent-filter>
                <action android:name="android.net.VpnService"/>
            </intent-filter>
        </service>
    </application>
</manifest>
''')

# ── VmessConfig ──────────────────────────────────────────────────────────────
w(f'{J}/model/VmessConfig.kt', '''package com.peepogrob.vpn.model

import android.os.Parcelable
import kotlinx.parcelize.Parcelize

@Parcelize
data class VmessConfig(
    val address:  String = "",
    val port:     Int    = 443,
    val uuid:     String = "",
    val alterId:  Int    = 0,
    val security: String = "aes-128-gcm",
    val path:     String = "/",
    val host:     String = "",
    val remarks:  String = "PeepogrobVPN"
) : Parcelable
''')

# ── VmessImport ──────────────────────────────────────────────────────────────
w(f'{J}/util/VmessImport.kt', '''package com.peepogrob.vpn.util

import android.util.Base64
import com.peepogrob.vpn.model.VmessConfig
import org.json.JSONObject

object VmessImport {
    fun parse(raw: String): VmessConfig? = runCatching {
        val link = raw.trim()
        require(link.startsWith("vmess://")) { "not vmess link" }
        val json = JSONObject(String(Base64.decode(
            link.removePrefix("vmess://"), Base64.DEFAULT)))
        VmessConfig(
            address  = json.optString("add", "").trim(),
            port     = json.optString("port", "443").toIntOrNull() ?: 443,
            uuid     = json.optString("id",  "").trim(),
            alterId  = json.optString("aid", "0").toIntOrNull() ?: 0,
            security = json.optString("scy", "aes-128-gcm").ifEmpty { "aes-128-gcm" },
            path     = json.optString("path","/").ifEmpty { "/" },
            host     = json.optString("host","").trim(),
            remarks  = json.optString("ps",  "PeepogrobVPN")
        ).also { cfg ->
            require(cfg.address.isNotEmpty()) { "empty address" }
            require(cfg.uuid.isNotEmpty())    { "empty uuid" }
        }
    }.getOrNull()
}
''')

# ── ConfigGenerator ──────────────────────────────────────────────────────────
w(f'{J}/vpn/ConfigGenerator.kt', '''package com.peepogrob.vpn.vpn

import com.peepogrob.vpn.model.VmessConfig

object ConfigGenerator {
    fun generate(cfg: VmessConfig, socksPort: Int = 10808): String {
        val sniHost = cfg.host.ifEmpty { cfg.address }
        return """
{
  "stats": {},
  "log": { "loglevel": "warning" },
  "policy": {
    "levels": { "8": { "handshake": 4, "connIdle": 300, "uplinkOnly": 1, "downlinkOnly": 1 } },
    "system": { "statsOutboundUplink": true, "statsOutboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": $socksPort,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true, "userLevel": 8 },
      "sniffing":  { "enabled": true, "destOverride": ["http","tls"] }
    },
    {
      "tag": "tun",
      "protocol": "tun",
      "settings": { "name": "xray0", "MTU": 1500, "userLevel": 8 },
      "sniffing":  { "enabled": true, "destOverride": ["http","tls"] }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [{ "address": "${cfg.address}", "port": ${cfg.port},
          "users": [{ "id": "${cfg.uuid}", "alterId": ${cfg.alterId},
                      "security": "${cfg.security}", "level": 8 }] }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${cfg.path}", "headers": { "Host": "$sniHost" } },
        "sockopt":  { "mark": 255 }
      },
      "mux": { "enabled": false }
    },
    {
      "protocol": "freedom", "tag": "direct",
      "streamSettings": { "sockopt": { "domainStrategy": "UseIP" } }
    },
    {
      "protocol": "blackhole", "tag": "block",
      "settings": { "response": { "type": "http" } }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "outboundTag": "direct", "ip":     ["geoip:private"] },
      { "type": "field", "outboundTag": "block",  "domain": ["geosite:category-ads-all"] }
    ]
  },
  "dns": { "hosts": {}, "servers": ["8.8.8.8","1.1.1.1","localhost"] }
}""".trimIndent()
    }
}
''')

# ── PeeVpnService ────────────────────────────────────────────────────────────
w(f'{J}/vpn/PeeVpnService.kt', '''package com.peepogrob.vpn.vpn

import android.app.*
import android.content.*
import android.net.VpnService
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import com.peepogrob.vpn.model.VmessConfig
import com.peepogrob.vpn.ui.MainActivity
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController

class PeeVpnService : VpnService() {

    companion object {
        const val ACTION_START  = "com.peepogrob.vpn.START"
        const val ACTION_STOP   = "com.peepogrob.vpn.STOP"
        const val BROADCAST_STATUS = "com.peepogrob.vpn.STATUS"
        const val BROADCAST_SPEED  = "com.peepogrob.vpn.SPEED"
        const val EXTRA_CONFIG  = "config"
        const val EXTRA_RUNNING = "running"
        const val CHANNEL_ID    = "peevpn_ch"
        const val NOTIF_ID      = 1
        const val MTU           = 1500
        const val SOCKS_PORT    = 10808
        private const val TAG   = "PeeVpnService"
        private const val MAX_RECONNECT = 3
        private const val RECONNECT_DELAY_MS = 3_000L
        private const val STATS_INTERVAL_MS  = 1_000L

        @Volatile var isRunning = false
        @Volatile var uploadSpeed   = 0L
        @Volatile var downloadSpeed = 0L
    }

    private var core: CoreController? = null
    private var pfd: ParcelFileDescriptor? = null
    private var reconnectCount = 0
    private var currentConfig: VmessConfig? = null
    private val handler = Handler(Looper.getMainLooper())
    private val notifManager by lazy {
        getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    }

    // ── Stats polling ──────────────────────────────────────────────
    private val statsRunnable = object : Runnable {
        private var lastUp = 0L
        private var lastDn = 0L
        override fun run() {
            runCatching {
                val up = core?.queryStats("proxy","uplink")   ?: 0L
                val dn = core?.queryStats("proxy","downlink") ?: 0L
                uploadSpeed   = (up - lastUp).coerceAtLeast(0L)
                downloadSpeed = (dn - lastDn).coerceAtLeast(0L)
                lastUp = up; lastDn = dn
                sendBroadcast(Intent(BROADCAST_SPEED)
                    .putExtra("up", uploadSpeed)
                    .putExtra("dn", downloadSpeed))
            }
            if (isRunning) handler.postDelayed(this, STATS_INTERVAL_MS)
        }
    }

    // ── Core callback ──────────────────────────────────────────────
    private val coreCallback = object : CoreCallbackHandler {
        override fun onEmitStatus(level: Long, msg: String?): Long {
            Log.d(TAG, "core[$level]: $msg")
            return 0
        }
        override fun startup():  Long { return 0 }
        override fun shutdown(): Long { return 0 }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val cfg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra(EXTRA_CONFIG, VmessConfig::class.java)
                else
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(EXTRA_CONFIG)
                if (cfg != null) { currentConfig = cfg; startVpn(cfg) }
                else stopSelf()
            }
            ACTION_STOP -> stopVpn()
            else        -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startVpn(cfg: VmessConfig) {
        runCatching {
            // Establish TUN interface
            pfd = Builder()
                .setMtu(MTU)
                .addAddress("10.10.10.1", 32)
                .addRoute("0.0.0.0", 0)
                .addRoute("::", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("1.1.1.1")
                .setSession("PeepogrobVPN")
                .setBlocking(false)
                .establish()
                ?: throw IllegalStateException("VPN establish() returned null")

            // Start xray core
            core = CoreController(coreCallback)
            core!!.startLoop(ConfigGenerator.generate(cfg, SOCKS_PORT))

            isRunning      = true
            reconnectCount = 0
            startForeground(NOTIF_ID, buildNotification("Connected ✓"))
            broadcastStatus(true)
            handler.post(statsRunnable)
            Log.i(TAG, "VPN started — ${cfg.address}:${cfg.port}")
        }.onFailure { e ->
            Log.e(TAG, "startVpn failed: ${e.message}", e)
            cleanupCore()
            handleReconnect()
        }
    }

    private fun stopVpn() {
        handler.removeCallbacks(statsRunnable)
        cleanupCore()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        broadcastStatus(false)
        Log.i(TAG, "VPN stopped")
    }

    private fun cleanupCore() {
        runCatching { core?.stopLoop() }
        runCatching { pfd?.close() }
        core = null; pfd = null
        isRunning = false
        uploadSpeed = 0; downloadSpeed = 0
    }

    private fun handleReconnect() {
        if (reconnectCount < MAX_RECONNECT) {
            reconnectCount++
            Log.w(TAG, "Reconnect attempt $reconnectCount/$MAX_RECONNECT")
            updateNotification("Reconnecting ($reconnectCount/$MAX_RECONNECT)…")
            handler.postDelayed({
                currentConfig?.let { startVpn(it) }
            }, RECONNECT_DELAY_MS)
        } else {
            Log.e(TAG, "Max reconnects reached")
            updateNotification("Connection failed")
            broadcastStatus(false)
            stopSelf()
        }
    }

    private fun broadcastStatus(running: Boolean) =
        sendBroadcast(Intent(BROADCAST_STATUS).putExtra(EXTRA_RUNNING, running))

    private fun createNotificationChannel() {
        val ch = NotificationChannel(CHANNEL_ID, "VPN Status", NotificationManager.IMPORTANCE_LOW)
        ch.setShowBadge(false)
        notifManager.createNotificationChannel(ch)
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stopPi = PendingIntent.getService(
            this, 1, Intent(this, PeeVpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PeepogrobVPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .addAction(android.R.drawable.ic_delete, "Stop", stopPi)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) =
        notifManager.notify(NOTIF_ID, buildNotification(text))

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        cleanupCore()
        super.onDestroy()
    }
}
''')

# ── ThemeManager ─────────────────────────────────────────────────────────────
w(f'{J}/util/ThemeManager.kt', '''package com.peepogrob.vpn.util

import android.content.Context
import androidx.appcompat.app.AppCompatDelegate

object ThemeManager {
    private const val PREFS  = "peevpn_theme"
    private const val KEY    = "dark_mode"

    fun isDark(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, true)

    fun apply(ctx: Context) {
        AppCompatDelegate.setDefaultNightMode(
            if (isDark(ctx)) AppCompatDelegate.MODE_NIGHT_YES
            else             AppCompatDelegate.MODE_NIGHT_NO
        )
    }

    fun toggle(ctx: Context) {
        val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        sp.edit().putBoolean(KEY, !isDark(ctx)).apply()
        apply(ctx)
    }
}
''')

# ── SpeedFormatter ────────────────────────────────────────────────────────────
w(f'{J}/util/SpeedFormatter.kt', '''package com.peepogrob.vpn.util

object SpeedFormatter {
    fun format(bytesPerSec: Long): String = when {
        bytesPerSec >= 1_048_576 -> "%.1f MB/s".format(bytesPerSec / 1_048_576.0)
        bytesPerSec >= 1_024     -> "%.1f KB/s".format(bytesPerSec / 1_024.0)
        bytesPerSec > 0          -> "${bytesPerSec} B/s"
        else                     -> "—"
    }
}
''')

# ── MainActivity ──────────────────────────────────────────────────────────────
w(f'{J}/ui/MainActivity.kt', '''package com.peepogrob.vpn.ui

import android.content.*
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.peepogrob.vpn.R
import com.peepogrob.vpn.model.VmessConfig
import com.peepogrob.vpn.util.SpeedFormatter
import com.peepogrob.vpn.util.ThemeManager
import com.peepogrob.vpn.util.VmessImport
import com.peepogrob.vpn.vpn.PeeVpnService

class MainActivity : AppCompatActivity() {

    private lateinit var btnConnect: Button
    private lateinit var tvStatus:   TextView
    private lateinit var tvUp:       TextView
    private lateinit var tvDn:       TextView
    private lateinit var tvServer:   TextView
    private lateinit var progress:   ProgressBar
    private lateinit var btnTheme:   ImageButton

    private var isConnected = false

    private val vpnLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result -> if (result.resultCode == RESULT_OK) doConnect() }

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) =
            updateUI(intent?.getBooleanExtra(PeeVpnService.EXTRA_RUNNING, false) ?: false)
    }

    private val speedReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            tvUp.text = "↑ ${SpeedFormatter.format(intent?.getLongExtra("up",0) ?: 0)}"
            tvDn.text = "↓ ${SpeedFormatter.format(intent?.getLongExtra("dn",0) ?: 0)}"
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        ThemeManager.apply(this)
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        btnConnect = findViewById(R.id.btnConnect)
        tvStatus   = findViewById(R.id.tvStatus)
        tvUp       = findViewById(R.id.tvUp)
        tvDn       = findViewById(R.id.tvDn)
        tvServer   = findViewById(R.id.tvServer)
        progress   = findViewById(R.id.progressBar)
        btnTheme   = findViewById(R.id.btnTheme)

        btnConnect.setOnClickListener {
            if (isConnected) stopVpn() else requestVpnPermission()
        }
        btnTheme.setOnClickListener { ThemeManager.toggle(this); recreate() }
        findViewById<ImageButton>(R.id.btnImport).setOnClickListener { importFromClipboard() }
        findViewById<ImageButton>(R.id.btnSettings).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }

        registerReceivers()
        updateUI(PeeVpnService.isRunning)
        refreshServerLabel()
    }

    private fun registerReceivers() {
        val statusFilter = IntentFilter(PeeVpnService.BROADCAST_STATUS)
        val speedFilter  = IntentFilter(PeeVpnService.BROADCAST_SPEED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(statusReceiver, statusFilter, RECEIVER_NOT_EXPORTED)
            registerReceiver(speedReceiver,  speedFilter,  RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusReceiver, statusFilter)
            registerReceiver(speedReceiver,  speedFilter)
        }
    }

    private fun requestVpnPermission() {
        val intent = VpnService.prepare(this)
        if (intent != null) vpnLauncher.launch(intent) else doConnect()
    }

    private fun doConnect() {
        val cfg = loadConfig()
        if (cfg.address.isEmpty() || cfg.uuid.isEmpty()) {
            Toast.makeText(this, "Configure server first", Toast.LENGTH_SHORT).show()
            startActivity(Intent(this, SettingsActivity::class.java))
            return
        }
        progress.visibility = View.VISIBLE
        startService(Intent(this, PeeVpnService::class.java).apply {
            action = PeeVpnService.ACTION_START
            putExtra(PeeVpnService.EXTRA_CONFIG, cfg)
        })
    }

    private fun stopVpn() {
        startService(Intent(this, PeeVpnService::class.java).apply {
            action = PeeVpnService.ACTION_STOP
        })
    }

    private fun importFromClipboard() {
        val cm   = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val text = cm.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
        val cfg  = VmessImport.parse(text)
        if (cfg != null) {
            saveConfig(cfg)
            refreshServerLabel()
            Toast.makeText(this, "✓ Imported: ${cfg.remarks}", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "No valid vmess:// in clipboard", Toast.LENGTH_SHORT).show()
        }
    }

    private fun loadConfig(): VmessConfig {
        val p = getSharedPreferences("peevpn", MODE_PRIVATE)
        return VmessConfig(
            address  = p.getString("address","")        ?: "",
            port     = p.getInt("port",443),
            uuid     = p.getString("uuid","")           ?: "",
            alterId  = p.getInt("alterId",0),
            security = p.getString("security","aes-128-gcm") ?: "aes-128-gcm",
            path     = p.getString("path","/")          ?: "/",
            host     = p.getString("host","")           ?: ""
        )
    }

    private fun saveConfig(cfg: VmessConfig) {
        getSharedPreferences("peevpn", MODE_PRIVATE).edit().apply {
            putString("address",  cfg.address)
            putInt   ("port",     cfg.port)
            putString("uuid",     cfg.uuid)
            putInt   ("alterId",  cfg.alterId)
            putString("security", cfg.security)
            putString("path",     cfg.path)
            putString("host",     cfg.host)
            apply()
        }
    }

    private fun refreshServerLabel() {
        val addr = getSharedPreferences("peevpn", MODE_PRIVATE).getString("address","") ?: ""
        tvServer.text = addr.ifEmpty { "No server configured" }
    }

    private fun updateUI(running: Boolean) {
        isConnected         = running
        progress.visibility = View.GONE
        if (running) {
            btnConnect.text = "DISCONNECT"
            btnConnect.setBackgroundColor(getColor(R.color.accent_pink))
            tvStatus.text   = "● Connected"
            tvStatus.setTextColor(getColor(R.color.accent_pink))
        } else {
            btnConnect.text = "CONNECT"
            btnConnect.setBackgroundColor(getColor(R.color.accent_blue))
            tvStatus.text   = "● Disconnected"
            tvStatus.setTextColor(getColor(R.color.text_secondary))
            tvUp.text = ""; tvDn.text = ""
        }
    }

    override fun onResume()  { super.onResume();  refreshServerLabel() }
    override fun onDestroy() {
        runCatching { unregisterReceiver(statusReceiver) }
        runCatching { unregisterReceiver(speedReceiver) }
        super.onDestroy()
    }
}
''')

# ── SettingsActivity ──────────────────────────────────────────────────────────
w(f'{J}/ui/SettingsActivity.kt', '''package com.peepogrob.vpn.ui

import android.os.Bundle
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import com.peepogrob.vpn.R
import com.peepogrob.vpn.util.ThemeManager

class SettingsActivity : AppCompatActivity() {
    override fun onCreate(s: Bundle?) {
        ThemeManager.apply(this)
        super.onCreate(s)
        setContentView(R.layout.activity_settings)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        val p       = getSharedPreferences("peevpn", MODE_PRIVATE)
        val etAddr  = findViewById<EditText>(R.id.etAddress)
        val etPort  = findViewById<EditText>(R.id.etPort)
        val etUuid  = findViewById<EditText>(R.id.etUuid)
        val etPath  = findViewById<EditText>(R.id.etPath)
        val etHost  = findViewById<EditText>(R.id.etHost)
        val spin    = findViewById<Spinner>(R.id.spinSecurity)
        val btnSave = findViewById<Button>(R.id.btnSave)

        val secs = arrayOf("aes-128-gcm","chacha20-poly1305","none","auto")
        spin.adapter = ArrayAdapter(this,
            android.R.layout.simple_spinner_item, secs).also {
            it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }

        etAddr.setText(p.getString("address",""))
        etPort.setText(p.getInt("port",443).toString())
        etUuid.setText(p.getString("uuid",""))
        etPath.setText(p.getString("path","/"))
        etHost.setText(p.getString("host",""))
        val idx = secs.indexOf(p.getString("security","aes-128-gcm"))
        if (idx >= 0) spin.setSelection(idx)

        btnSave.setOnClickListener {
            val addr = etAddr.text.toString().trim()
            val uuid = etUuid.text.toString().trim()
            if (addr.isEmpty() || uuid.isEmpty()) {
                Toast.makeText(this,"Address and UUID are required",Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            p.edit().apply {
                putString("address",  addr)
                putInt   ("port",     etPort.text.toString().toIntOrNull() ?: 443)
                putString("uuid",     uuid)
                putString("security", spin.selectedItem.toString())
                putString("path",     etPath.text.toString().trim().ifEmpty{"/"})
                putString("host",     etHost.text.toString().trim())
                apply()
            }
            Toast.makeText(this,"Saved ✓",Toast.LENGTH_SHORT).show()
            finish()
        }
    }
    override fun onSupportNavigateUp(): Boolean { finish(); return true }
}
''')

# ── Layouts ───────────────────────────────────────────────────────────────────
w(f'{RES}/layout/activity_main.xml', '''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:background="?attr/colorBackground">

    <LinearLayout android:orientation="horizontal"
        android:layout_width="match_parent" android:layout_height="56dp"
        android:paddingHorizontal="16dp" android:gravity="center_vertical"
        android:background="?attr/colorSurface" android:elevation="2dp">
        <TextView android:text="PeepogrobVPN"
            android:textSize="18sp" android:textStyle="bold"
            android:textColor="?attr/colorOnSurface"
            android:layout_width="0dp" android:layout_height="wrap_content"
            android:layout_weight="1"/>
        <ImageButton android:id="@+id/btnTheme"
            android:src="@android:drawable/ic_menu_manage"
            android:background="?attr/selectableItemBackgroundBorderless"
            android:contentDescription="Toggle theme"
            android:layout_width="40dp" android:layout_height="40dp"
            android:layout_marginEnd="8dp"/>
        <ImageButton android:id="@+id/btnSettings"
            android:src="@android:drawable/ic_menu_preferences"
            android:background="?attr/selectableItemBackgroundBorderless"
            android:contentDescription="Settings"
            android:layout_width="40dp" android:layout_height="40dp"/>
    </LinearLayout>

    <TextView android:id="@+id/tvServer"
        android:text="No server configured"
        android:textSize="12sp" android:textColor="?attr/colorControlNormal"
        android:gravity="center" android:padding="8dp"
        android:layout_width="match_parent" android:layout_height="wrap_content"/>

    <LinearLayout android:orientation="vertical"
        android:layout_width="match_parent" android:layout_height="0dp"
        android:layout_weight="1" android:gravity="center">

        <TextView android:id="@+id/tvStatus" android:text="● Disconnected"
            android:textSize="14sp" android:textColor="@color/text_secondary"
            android:gravity="center" android:layout_marginBottom="32dp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>

        <ProgressBar android:id="@+id/progressBar" android:visibility="gone"
            android:layout_marginBottom="16dp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>

        <Button android:id="@+id/btnConnect" android:text="CONNECT"
            android:textColor="@android:color/white"
            android:backgroundTint="@color/accent_blue"
            android:textSize="16sp" android:letterSpacing="0.08"
            android:stateListAnimator="@null"
            android:layout_width="180dp" android:layout_height="180dp"/>

        <LinearLayout android:orientation="horizontal"
            android:layout_marginTop="24dp" android:gravity="center"
            android:layout_width="wrap_content" android:layout_height="wrap_content">
            <TextView android:id="@+id/tvUp" android:text=""
                android:textSize="13sp" android:textColor="@color/accent_blue"
                android:layout_marginEnd="20dp"
                android:layout_width="wrap_content" android:layout_height="wrap_content"/>
            <TextView android:id="@+id/tvDn" android:text=""
                android:textSize="13sp" android:textColor="@color/accent_pink"
                android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        </LinearLayout>
    </LinearLayout>

    <LinearLayout android:orientation="horizontal" android:gravity="center"
        android:padding="16dp" android:background="?attr/colorSurface"
        android:elevation="2dp"
        android:layout_width="match_parent" android:layout_height="wrap_content">
        <ImageButton android:id="@+id/btnImport"
            android:src="@android:drawable/ic_menu_add"
            android:background="?attr/selectableItemBackgroundBorderless"
            android:contentDescription="Import vmess link"
            android:layout_width="48dp" android:layout_height="48dp"/>
    </LinearLayout>
</LinearLayout>
''')

w(f'{RES}/layout/activity_settings.xml', '''<?xml version="1.0" encoding="utf-8"?>
<ScrollView xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:background="?attr/colorBackground">
    <LinearLayout android:orientation="vertical"
        android:layout_width="match_parent" android:layout_height="wrap_content"
        android:padding="20dp">

        <TextView android:text="SERVER ADDRESS" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:letterSpacing="0.08"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etAddress" android:hint="example.com"
            android:inputType="textUri" android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="PORT" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:letterSpacing="0.08"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etPort" android:hint="443"
            android:inputType="number" android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="UUID" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:letterSpacing="0.08"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etUuid" android:hint="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="WEBSOCKET PATH" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:letterSpacing="0.08"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etPath" android:hint="/"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="HOST / SNI" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:letterSpacing="0.08"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etHost" android:hint="(blank = same as address)"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="ENCRYPTION" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:letterSpacing="0.08"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <Spinner android:id="@+id/spinSecurity"
            android:layout_marginBottom="32dp"
            android:layout_width="match_parent" android:layout_height="48dp"/>

        <Button android:id="@+id/btnSave" android:text="SAVE"
            android:textColor="@android:color/white"
            android:backgroundTint="@color/accent_blue"
            android:stateListAnimator="@null"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
    </LinearLayout>
</ScrollView>
''')

# ── Colors ────────────────────────────────────────────────────────────────────
w(f'{RES}/values/colors.xml', '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="accent_blue">#2196F3</color>
    <color name="accent_pink">#E91E8C</color>
    <color name="text_secondary">#888888</color>
</resources>
''')

w(f'{RES}/values-night/colors.xml', '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="accent_blue">#1565C0</color>
    <color name="accent_pink">#AD1457</color>
    <color name="text_secondary">#444444</color>
</resources>
''')

# ── Themes (no animation) ─────────────────────────────────────────────────────
THEME = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="AppTheme" parent="Theme.MaterialComponents.DayNight.NoActionBar">
        <item name="colorPrimary">@color/accent_blue</item>
        <item name="colorSecondary">@color/accent_pink</item>
        <item name="android:windowAnimationStyle">@null</item>
        <item name="android:windowNoTitle">true</item>
        <item name="android:windowContentTransitions">false</item>
    </style>
</resources>
'''
w(f'{RES}/values/styles.xml',       THEME)
w(f'{RES}/values-night/styles.xml', THEME)

print("\nAll source files written OK")
PYEOF

log_ok "Source code written"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: BUILD
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[6/7] Building APK...${NC}"
cd "$WORK_DIR"

export ANDROID_HOME="$SDK_DIR"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$GRADLE_DIR/bin"

BUILD_START=$(date +%s)
if gradle assembleDebug 2>&1 | tee -a "$LOG_FILE" | grep -E "^e:|BUILD (SUCCESSFUL|FAILED)"; then
  :
fi
BUILD_END=$(date +%s)
BUILD_TIME=$(( BUILD_END - BUILD_START ))

APK_PATH=$(find "$WORK_DIR" -name "app-debug.apk" 2>/dev/null | head -1)
[[ -n "$APK_PATH" ]] || die "APK not found — check build log: $LOG_FILE"

APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
log_ok "APK built in ${BUILD_TIME}s — size: $APK_SIZE"
log_ok "APK: $APK_PATH"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 7: VERIFY & SERVE
# ═══════════════════════════════════════════════════════════════════════════════
log "${BOLD}[7/7] Verification & download server...${NC}"

# Verify APK integrity
python3 - << PYVERIFY
import zipfile, sys
apk = "$APK_PATH"
try:
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        checks = {
            "classes.dex":              any("classes.dex" in n for n in names),
            "AndroidManifest.xml":      "AndroidManifest.xml" in names,
            "libgojni.so (arm64)":      "lib/arm64-v8a/libgojni.so" in names,
        }
        all_ok = True
        for item, ok in checks.items():
            status = "✓" if ok else "✗"
            print(f"  [{status}] {item}")
            if not ok: all_ok = False
        sys.exit(0 if all_ok else 1)
except Exception as e:
    print(f"APK verify error: {e}")
    sys.exit(1)
PYVERIFY

log_ok "APK integrity verified"

IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
PORT=8080

echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════╗"
echo "║         BUILD SUCCESSFUL ✓                   ║"
echo "╠══════════════════════════════════════════════╣"
printf  "║  APK size : %-31s║\n" "$APK_SIZE"
printf  "║  Build    : %-31s║\n" "${BUILD_TIME}s"
printf  "║  Log      : %-31s║\n" "$LOG_FILE"
echo "╠══════════════════════════════════════════════╣"
printf  "║  Download : http://%-25s║\n" "${IP}:${PORT}/app-debug.apk"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo "Press Ctrl+C to stop the download server"
echo ""

CLEANUP_NEEDED=false
python3 -m http.server "$PORT" --directory "$(dirname "$APK_PATH")"
