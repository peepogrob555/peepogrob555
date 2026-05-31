#!/bin/bash
set -e
echo "=== PeepogrobVPN Full Build Script ==="

# ─── Phase 1: System ───────────────────────────────────────────────
echo "[1/6] System setup..."
apt-get update -q && apt-get install -y -q openjdk-17-jdk unzip wget curl zip python3

if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ─── Phase 2: Android SDK ──────────────────────────────────────────
echo "[2/6] Android SDK..."
mkdir -p ~/android-sdk/cmdline-tools
if [ ! -f ~/android-sdk/cmdline-tools/latest/bin/sdkmanager ]; then
  wget -q https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdtools.zip
  unzip -q /tmp/cmdtools.zip -d ~/android-sdk/cmdline-tools
  mv ~/android-sdk/cmdline-tools/cmdline-tools ~/android-sdk/cmdline-tools/latest
fi
export ANDROID_HOME=~/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
yes | sdkmanager --licenses > /dev/null 2>&1
sdkmanager "platforms;android-34" "build-tools;34.0.0" "platform-tools" > /dev/null 2>&1

if [ ! -f /opt/gradle-8.2/bin/gradle ]; then
  wget -q https://services.gradle.org/distributions/gradle-8.2-bin.zip -O /tmp/gradle.zip
  unzip -q /tmp/gradle.zip -d /opt
fi
export PATH=$PATH:/opt/gradle-8.2/bin

# ─── Phase 3: Project ──────────────────────────────────────────────
echo "[3/6] Project structure..."
rm -rf ~/PeepogrobVPN
mkdir -p ~/PeepogrobVPN/app/src/main/{java/com/peepogrob/vpn/{ui,vpn,model,util},res/{layout,values,values-night,mipmap-mdpi,mipmap-hdpi,mipmap-xhdpi,mipmap-xxhdpi,mipmap-xxxhdpi}}
mkdir -p ~/PeepogrobVPN/app/libs
cd ~/PeepogrobVPN

# libv2ray
echo "[4/6] Downloading libv2ray.aar..."
wget -q "https://github.com/2dust/AndroidLibV2rayLite/releases/download/v5.51.2/libv2ray.aar" -O app/libs/libv2ray.aar

# Icons (blue)
for d in mipmap-mdpi mipmap-hdpi mipmap-xhdpi mipmap-xxhdpi mipmap-xxxhdpi; do
python3 -c "
import struct,zlib
def png(w,h,r,g,b):
    def chunk(t,d):
        c=zlib.crc32(t+d)&0xffffffff
        return struct.pack('>I',len(d))+t+d+struct.pack('>I',c)
    raw=b''.join(b'\x00'+bytes([r,g,b])*w for _ in range(h))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
open('app/src/main/res/$d/ic_launcher.png','wb').write(png(48,48,33,150,243))
"
done

# ─── Gradle files ──────────────────────────────────────────────────
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
org.gradle.jvmargs=-Xmx1536m
org.gradle.daemon=false
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
EOF

# ─── Phase 5: Source Code ──────────────────────────────────────────
echo "[5/6] Writing source code..."
python3 << 'PYEOF'
import os
B = '/root/PeepogrobVPN/app/src/main'
J = f'{B}/java/com/peepogrob/vpn'

# ── AndroidManifest ────────────────────────────────────────────────
open(f'{B}/AndroidManifest.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
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
        <activity android:name=".ui.MainActivity" android:exported="true"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <activity android:name=".ui.SettingsActivity" android:exported="false"/>
        <service android:name=".vpn.PeeVpnService" android:exported="false"
            android:permission="android.permission.BIND_VPN_SERVICE"
            android:foregroundServiceType="connectedDevice">
            <intent-filter><action android:name="android.net.VpnService"/></intent-filter>
        </service>
    </application>
</manifest>
''')

# ── VmessConfig ────────────────────────────────────────────────────
open(f'{J}/model/VmessConfig.kt','w').write('''package com.peepogrob.vpn.model
import android.os.Parcelable
import kotlinx.parcelize.Parcelize
@Parcelize
data class VmessConfig(
    val address: String = "",
    val port: Int = 443,
    val uuid: String = "",
    val alterId: Int = 0,
    val security: String = "aes-128-gcm",
    val path: String = "/",
    val host: String = "",
    val remarks: String = "PeepogrobVPN"
) : Parcelable
''')

# ── VmessImport ────────────────────────────────────────────────────
open(f'{J}/util/VmessImport.kt','w').write('''package com.peepogrob.vpn.util
import android.util.Base64
import com.peepogrob.vpn.model.VmessConfig
import org.json.JSONObject
object VmessImport {
    fun parse(link: String): VmessConfig? = try {
        if (!link.trim().startsWith("vmess://")) null
        else {
            val j = JSONObject(String(Base64.decode(link.trim().removePrefix("vmess://"), Base64.DEFAULT)))
            VmessConfig(
                address  = j.optString("add",""),
                port     = j.optString("port","443").toIntOrNull() ?: 443,
                uuid     = j.optString("id",""),
                alterId  = j.optString("aid","0").toIntOrNull() ?: 0,
                security = j.optString("scy","aes-128-gcm").ifEmpty{"aes-128-gcm"},
                path     = j.optString("path","/").ifEmpty{"/"},
                host     = j.optString("host",""),
                remarks  = j.optString("ps","PeepogrobVPN")
            )
        }
    } catch(e:Exception){ null }
}
''')

# ── ConfigGenerator (TUN mode like v2rayNG) ────────────────────────
open(f'{J}/vpn/ConfigGenerator.kt','w').write('''package com.peepogrob.vpn.vpn
import com.peepogrob.vpn.model.VmessConfig
object ConfigGenerator {
    fun generate(cfg: VmessConfig): String {
        val host = cfg.host.ifEmpty { cfg.address }
        return """
{
  "stats":{},
  "log":{"loglevel":"warning"},
  "policy":{
    "levels":{"8":{"handshake":4,"connIdle":300,"uplinkOnly":1,"downlinkOnly":1}},
    "system":{"statsOutboundUplink":true,"statsOutboundDownlink":true}
  },
  "inbounds":[
    {"tag":"socks","port":10808,"protocol":"socks",
     "settings":{"auth":"noauth","udp":true,"userLevel":8},
     "sniffing":{"enabled":true,"destOverride":["http","tls"]}},
    {"tag":"tun","protocol":"tun",
     "settings":{"name":"xray0","MTU":1500,"userLevel":8},
     "sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds":[
    {"tag":"proxy","protocol":"vmess",
     "settings":{"vnext":[{"address":"${cfg.address}","port":${cfg.port},
       "users":[{"id":"${cfg.uuid}","alterId":${cfg.alterId},"security":"${cfg.security}","level":8}]}]},
     "streamSettings":{"network":"ws",
       "wsSettings":{"path":"${cfg.path}","headers":{"Host":"$host"}},
       "sockopt":{"mark":255}},
     "mux":{"enabled":false}},
    {"protocol":"freedom","tag":"direct",
     "streamSettings":{"sockopt":{"domainStrategy":"UseIP"}}},
    {"protocol":"blackhole","tag":"block","settings":{"response":{"type":"http"}}}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","outboundTag":"direct","ip":["geoip:private"]}
  ]},
  "dns":{"hosts":{},"servers":["8.8.8.8","1.1.1.1"]}
}""".trimIndent()
    }
}
''')

# ── PeeVpnService ──────────────────────────────────────────────────
open(f'{J}/vpn/PeeVpnService.kt','w').write('''package com.peepogrob.vpn.vpn
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
        const val ACTION_START = "START"
        const val ACTION_STOP  = "STOP"
        const val CHANNEL_ID   = "peevpn_ch"
        const val NOTIF_ID     = 1
        const val MTU          = 1500
        const val SOCKS_PORT   = 10808
        private const val TAG  = "PeeVpnService"
        var isRunning = false
        var uploadSpeed = 0L
        var downloadSpeed = 0L
    }

    private var core: CoreController? = null
    private var pfd: ParcelFileDescriptor? = null
    private var reconnectCount = 0
    private var currentConfig: VmessConfig? = null
    private val handler = Handler(Looper.getMainLooper())

    private val statsRunnable = object : Runnable {
        var lastUp = 0L; var lastDn = 0L
        override fun run() {
            try {
                val up = core?.queryStats("proxy","uplink") ?: 0L
                val dn = core?.queryStats("proxy","downlink") ?: 0L
                uploadSpeed   = up - lastUp
                downloadSpeed = dn - lastDn
                lastUp = up; lastDn = dn
                sendBroadcast(Intent("com.peepogrob.vpn.SPEED")
                    .putExtra("up", uploadSpeed).putExtra("dn", downloadSpeed))
            } catch(_:Exception){}
            if (isRunning) handler.postDelayed(this, 1000)
        }
    }

    private val cb = object : CoreCallbackHandler {
        override fun onEmitStatus(level: Long, msg: String?): Long { return 0 }
        override fun startup(): Long { return 0 }
        override fun shutdown(): Long { return 0 }
    }

    override fun onCreate() { super.onCreate(); createChannel() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val cfg = if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra("config", VmessConfig::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra("config")
                cfg?.let { currentConfig = it; startVpn(it) }
            }
            ACTION_STOP -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn(cfg: VmessConfig) {
        try {
            pfd = Builder().setMtu(MTU)
                .addAddress("10.10.10.1", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("1.1.1.1")
                .setSession("PeepogrobVPN")
                .setBlocking(false)
                .establish() ?: return
            core = CoreController(cb)
            core!!.startLoop(ConfigGenerator.generate(cfg))
            isRunning = true; reconnectCount = 0
            startForeground(NOTIF_ID, buildNotif("Connected"))
            broadcast(true)
            handler.post(statsRunnable)
        } catch (e: Exception) { Log.e(TAG,"start:${e.message}"); handleReconnect() }
    }

    private fun stopVpn() {
        handler.removeCallbacks(statsRunnable)
        try { core?.stopLoop() } catch(_:Exception){}
        try { pfd?.close() } catch(_:Exception){}
        pfd = null; core = null; isRunning = false
        uploadSpeed = 0; downloadSpeed = 0
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        broadcast(false)
    }

    private fun handleReconnect() {
        if (reconnectCount < 3) {
            reconnectCount++
            updateNotif("Reconnecting ($reconnectCount/3)...")
            handler.postDelayed({ currentConfig?.let { startVpn(it) } }, 3000)
        } else {
            updateNotif("Connection failed"); isRunning = false; broadcast(false)
        }
    }

    private fun broadcast(running: Boolean) =
        sendBroadcast(Intent("com.peepogrob.vpn.STATUS").putExtra("running", running))

    private fun createChannel() {
        val ch = NotificationChannel(CHANNEL_ID,"VPN",NotificationManager.IMPORTANCE_LOW)
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
    }
    private fun buildNotif(text: String): Notification {
        val pi = PendingIntent.getActivity(this,0,
            Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this,CHANNEL_ID)
            .setContentTitle("PeepogrobVPN").setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi).setOngoing(true).build()
    }
    private fun updateNotif(text: String) =
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(NOTIF_ID,buildNotif(text))

    override fun onDestroy() { super.onDestroy(); stopVpn() }
}
''')

# ── ThemeManager ───────────────────────────────────────────────────
open(f'{J}/util/ThemeManager.kt','w').write('''package com.peepogrob.vpn.util
import android.content.Context
import androidx.appcompat.app.AppCompatDelegate

object ThemeManager {
    const val PREF = "theme_pref"
    const val KEY_MODE = "mode"
    const val MODE_DARK  = 0
    const val MODE_LIGHT = 1

    fun apply(ctx: Context) {
        val mode = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getInt(KEY_MODE, MODE_DARK)
        AppCompatDelegate.setDefaultNightMode(
            if (mode == MODE_DARK) AppCompatDelegate.MODE_NIGHT_YES
            else AppCompatDelegate.MODE_NIGHT_NO
        )
    }

    fun toggle(ctx: Context) {
        val prefs = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val cur = prefs.getInt(KEY_MODE, MODE_DARK)
        val next = if (cur == MODE_DARK) MODE_LIGHT else MODE_DARK
        prefs.edit().putInt(KEY_MODE, next).apply()
        apply(ctx)
    }

    fun isDark(ctx: Context) = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        .getInt(KEY_MODE, MODE_DARK) == MODE_DARK
}
''')

# ── SpeedFormatter ─────────────────────────────────────────────────
open(f'{J}/util/SpeedFormatter.kt','w').write('''package com.peepogrob.vpn.util
object SpeedFormatter {
    fun format(bps: Long): String = when {
        bps >= 1_000_000 -> "%.1f MB/s".format(bps / 1_000_000.0)
        bps >= 1_000     -> "%.1f KB/s".format(bps / 1_000.0)
        else             -> "$bps B/s"
    }
}
''')

# ── MainActivity ───────────────────────────────────────────────────
open(f'{J}/ui/MainActivity.kt','w').write('''package com.peepogrob.vpn.ui
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
    private lateinit var tvStatus: TextView
    private lateinit var tvUp: TextView
    private lateinit var tvDn: TextView
    private lateinit var tvServer: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var btnTheme: ImageButton
    private var isConnected = false

    private val vpnLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { if (it.resultCode == RESULT_OK) doConnect() }

    private val statusRx = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) =
            updateUI(i?.getBooleanExtra("running", false) ?: false)
    }
    private val speedRx = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val up = i?.getLongExtra("up", 0) ?: 0
            val dn = i?.getLongExtra("dn", 0) ?: 0
            tvUp.text = "↑ ${SpeedFormatter.format(up)}"
            tvDn.text = "↓ ${SpeedFormatter.format(dn)}"
        }
    }

    override fun onCreate(s: Bundle?) {
        ThemeManager.apply(this)
        super.onCreate(s)
        setContentView(R.layout.activity_main)
        btnConnect  = findViewById(R.id.btnConnect)
        tvStatus    = findViewById(R.id.tvStatus)
        tvUp        = findViewById(R.id.tvUp)
        tvDn        = findViewById(R.id.tvDn)
        tvServer    = findViewById(R.id.tvServer)
        progressBar = findViewById(R.id.progressBar)
        btnTheme    = findViewById(R.id.btnTheme)

        btnConnect.setOnClickListener { if (isConnected) stopVpn() else requestVpnPermission() }
        btnTheme.setOnClickListener { ThemeManager.toggle(this); recreate() }
        findViewById<ImageButton>(R.id.btnImport).setOnClickListener { importFromClipboard() }
        findViewById<ImageButton>(R.id.btnSettings).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }

        val f = IntentFilter("com.peepogrob.vpn.STATUS")
        val fs = IntentFilter("com.peepogrob.vpn.SPEED")
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(statusRx, f, RECEIVER_NOT_EXPORTED)
            registerReceiver(speedRx, fs, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(statusRx, f)
            registerReceiver(speedRx, fs)
        }
        updateUI(PeeVpnService.isRunning)
        updateServerLabel()
    }

    private fun requestVpnPermission() {
        val i = VpnService.prepare(this)
        if (i != null) vpnLauncher.launch(i) else doConnect()
    }

    private fun doConnect() {
        val p = getSharedPreferences("peevpn", MODE_PRIVATE)
        val cfg = VmessConfig(
            address  = p.getString("address","") ?: "",
            port     = p.getInt("port",443),
            uuid     = p.getString("uuid","") ?: "",
            alterId  = p.getInt("alterId",0),
            security = p.getString("security","aes-128-gcm") ?: "aes-128-gcm",
            path     = p.getString("path","/") ?: "/",
            host     = p.getString("host","") ?: ""
        )
        if (cfg.address.isEmpty() || cfg.uuid.isEmpty()) {
            Toast.makeText(this,"Configure server first",Toast.LENGTH_SHORT).show()
            startActivity(Intent(this,SettingsActivity::class.java)); return
        }
        progressBar.visibility = View.VISIBLE
        startService(Intent(this,PeeVpnService::class.java).apply {
            action = PeeVpnService.ACTION_START; putExtra("config",cfg)
        })
    }

    private fun stopVpn() = startService(
        Intent(this,PeeVpnService::class.java).apply { action = PeeVpnService.ACTION_STOP })

    private fun importFromClipboard() {
        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val text = cm.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
        val cfg = VmessImport.parse(text)
        if (cfg != null) {
            saveCfg(cfg)
            updateServerLabel()
            Toast.makeText(this,"Imported: ${cfg.remarks}",Toast.LENGTH_SHORT).show()
        } else Toast.makeText(this,"No valid vmess:// in clipboard",Toast.LENGTH_SHORT).show()
    }

    private fun saveCfg(cfg: VmessConfig) = getSharedPreferences("peevpn",MODE_PRIVATE).edit().apply {
        putString("address",cfg.address); putInt("port",cfg.port)
        putString("uuid",cfg.uuid); putInt("alterId",cfg.alterId)
        putString("security",cfg.security); putString("path",cfg.path)
        putString("host",cfg.host); apply()
    }

    private fun updateServerLabel() {
        val p = getSharedPreferences("peevpn",MODE_PRIVATE)
        val addr = p.getString("address","") ?: ""
        tvServer.text = if (addr.isEmpty()) "No server configured" else addr
    }

    private fun updateUI(running: Boolean) {
        isConnected = running
        progressBar.visibility = View.GONE
        if (running) {
            btnConnect.text = "DISCONNECT"
            tvStatus.text = "● Connected"
            tvStatus.setTextColor(getColor(R.color.accent_pink))
        } else {
            btnConnect.text = "CONNECT"
            tvStatus.text = "● Disconnected"
            tvStatus.setTextColor(getColor(R.color.text_secondary))
            tvUp.text = ""; tvDn.text = ""
        }
    }

    override fun onResume() { super.onResume(); updateServerLabel() }
    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(statusRx)
        unregisterReceiver(speedRx)
    }
}
''')

# ── SettingsActivity ────────────────────────────────────────────────
open(f'{J}/ui/SettingsActivity.kt','w').write('''package com.peepogrob.vpn.ui
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
        val p = getSharedPreferences("peevpn",MODE_PRIVATE)
        val etAddr = findViewById<EditText>(R.id.etAddress)
        val etPort = findViewById<EditText>(R.id.etPort)
        val etUuid = findViewById<EditText>(R.id.etUuid)
        val etPath = findViewById<EditText>(R.id.etPath)
        val etHost = findViewById<EditText>(R.id.etHost)
        val spin   = findViewById<Spinner>(R.id.spinSecurity)
        val btnSave= findViewById<Button>(R.id.btnSave)
        val secs   = arrayOf("aes-128-gcm","chacha20-poly1305","none","auto")
        spin.adapter = ArrayAdapter(this,android.R.layout.simple_spinner_item,secs)
            .also{it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)}
        etAddr.setText(p.getString("address",""))
        etPort.setText(p.getInt("port",443).toString())
        etUuid.setText(p.getString("uuid",""))
        etPath.setText(p.getString("path","/"))
        etHost.setText(p.getString("host",""))
        val idx = secs.indexOf(p.getString("security","aes-128-gcm"))
        if(idx>=0) spin.setSelection(idx)
        btnSave.setOnClickListener {
            p.edit().apply {
                putString("address",etAddr.text.toString().trim())
                putInt("port",etPort.text.toString().toIntOrNull()?:443)
                putString("uuid",etUuid.text.toString().trim())
                putString("security",spin.selectedItem.toString())
                putString("path",etPath.text.toString().trim().ifEmpty{"/"})
                putString("host",etHost.text.toString().trim())
                apply()
            }
            Toast.makeText(this,"Saved",Toast.LENGTH_SHORT).show(); finish()
        }
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
    }
    override fun onSupportNavigateUp(): Boolean { finish(); return true }
}
''')

# ── Layouts ────────────────────────────────────────────────────────
open(f'{B}/res/layout/activity_main.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:background="?attr/colorBackground"
    android:padding="0dp">

    <!-- Top bar -->
    <LinearLayout android:orientation="horizontal"
        android:layout_width="match_parent" android:layout_height="56dp"
        android:paddingHorizontal="16dp" android:gravity="center_vertical"
        android:background="?attr/colorSurface">
        <TextView android:text="PeepogrobVPN"
            android:textSize="18sp" android:textStyle="bold"
            android:textColor="?attr/colorOnSurface"
            android:layout_width="0dp" android:layout_height="wrap_content"
            android:layout_weight="1"/>
        <ImageButton android:id="@+id/btnTheme"
            android:src="@android:drawable/ic_menu_manage"
            android:background="?attr/selectableItemBackgroundBorderless"
            android:layout_width="40dp" android:layout_height="40dp"
            android:layout_marginEnd="8dp"/>
        <ImageButton android:id="@+id/btnSettings"
            android:src="@android:drawable/ic_menu_preferences"
            android:background="?attr/selectableItemBackgroundBorderless"
            android:layout_width="40dp" android:layout_height="40dp"/>
    </LinearLayout>

    <!-- Server label -->
    <TextView android:id="@+id/tvServer"
        android:text="No server configured"
        android:textSize="12sp" android:textColor="?attr/colorControlNormal"
        android:gravity="center" android:padding="8dp"
        android:layout_width="match_parent" android:layout_height="wrap_content"/>

    <!-- Center content -->
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
            android:textSize="16sp" android:letterSpacing="0.1"
            android:stateListAnimator="@null"
            android:layout_width="180dp" android:layout_height="180dp"/>

        <!-- Speed -->
        <LinearLayout android:orientation="horizontal"
            android:layout_marginTop="28dp" android:gravity="center"
            android:layout_width="wrap_content" android:layout_height="wrap_content">
            <TextView android:id="@+id/tvUp" android:text=""
                android:textSize="13sp" android:textColor="@color/accent_blue"
                android:layout_marginEnd="16dp"
                android:layout_width="wrap_content" android:layout_height="wrap_content"/>
            <TextView android:id="@+id/tvDn" android:text=""
                android:textSize="13sp" android:textColor="@color/accent_pink"
                android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        </LinearLayout>
    </LinearLayout>

    <!-- Bottom bar -->
    <LinearLayout android:orientation="horizontal" android:gravity="center"
        android:padding="16dp" android:background="?attr/colorSurface"
        android:layout_width="match_parent" android:layout_height="wrap_content">
        <ImageButton android:id="@+id/btnImport"
            android:src="@android:drawable/ic_menu_add"
            android:background="?attr/selectableItemBackgroundBorderless"
            android:layout_width="48dp" android:layout_height="48dp"/>
    </LinearLayout>
</LinearLayout>
''')

open(f'{B}/res/layout/activity_settings.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<ScrollView xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:background="?attr/colorBackground">
    <LinearLayout android:orientation="vertical"
        android:layout_width="match_parent" android:layout_height="wrap_content"
        android:padding="20dp">
        <TextView android:text="Server Address" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:textAllCaps="true"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etAddress" android:hint="example.com"
            android:textColor="?attr/colorOnBackground"
            android:inputType="textUri" android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
        <TextView android:text="Port" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:textAllCaps="true"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etPort" android:hint="443"
            android:textColor="?attr/colorOnBackground"
            android:inputType="number" android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
        <TextView android:text="UUID" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:textAllCaps="true"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etUuid" android:hint="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
            android:textColor="?attr/colorOnBackground"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
        <TextView android:text="WebSocket Path" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:textAllCaps="true"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etPath" android:hint="/"
            android:textColor="?attr/colorOnBackground"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
        <TextView android:text="Host / SNI" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:textAllCaps="true"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etHost" android:hint="(blank = same as address)"
            android:textColor="?attr/colorOnBackground"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
        <TextView android:text="Encryption" android:textColor="?attr/colorControlNormal"
            android:textSize="11sp" android:textAllCaps="true"
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

# ── Colors & Themes ────────────────────────────────────────────────
# Light mode colors
open(f'{B}/res/values/colors.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Light mode -->
    <color name="accent_blue">#2196F3</color>
    <color name="accent_pink">#E91E8C</color>
    <color name="bg_light">#FFFFFF</color>
    <color name="surface_light">#F5F5F5</color>
    <color name="text_primary_light">#1A1A1A</color>
    <color name="text_secondary">#888888</color>
    <!-- Dark mode -->
    <color name="accent_blue_dark">#1565C0</color>
    <color name="accent_pink_dark">#AD1457</color>
    <color name="bg_dark">#0D0D0D</color>
    <color name="surface_dark">#1A1A1A</color>
    <color name="text_primary_dark">#F0F0F0</color>
</resources>
''')

open(f'{B}/res/values/styles.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Light theme: white bg, blue+pink accents -->
    <style name="AppTheme" parent="Theme.MaterialComponents.DayNight.NoActionBar">
        <item name="colorPrimary">@color/accent_blue</item>
        <item name="colorSecondary">@color/accent_pink</item>
        <item name="colorBackground">@color/bg_light</item>
        <item name="colorSurface">@color/surface_light</item>
        <item name="colorOnBackground">@color/text_primary_light</item>
        <item name="colorOnSurface">@color/text_primary_light</item>
        <item name="android:windowAnimationStyle">@null</item>
        <item name="android:windowNoTitle">true</item>
    </style>
</resources>
''')

# Dark mode override
open(f'{B}/res/values-night/styles.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Dark theme: black bg, dark blue+dark pink accents -->
    <style name="AppTheme" parent="Theme.MaterialComponents.DayNight.NoActionBar">
        <item name="colorPrimary">@color/accent_blue_dark</item>
        <item name="colorSecondary">@color/accent_pink_dark</item>
        <item name="colorBackground">@color/bg_dark</item>
        <item name="colorSurface">@color/surface_dark</item>
        <item name="colorOnBackground">@color/text_primary_dark</item>
        <item name="colorOnSurface">@color/text_primary_dark</item>
        <item name="android:windowAnimationStyle">@null</item>
        <item name="android:windowNoTitle">true</item>
    </style>
</resources>
''')

open(f'{B}/res/values-night/colors.xml','w').write('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="accent_blue">#1565C0</color>
    <color name="accent_pink">#AD1457</color>
    <color name="text_secondary">#555555</color>
</resources>
''')

print("ALL SOURCE OK")
PYEOF

# ─── Phase 6: Build ────────────────────────────────────────────────
echo "[6/6] Building APK..."
cd ~/PeepogrobVPN
export ANDROID_HOME=~/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:/opt/gradle-8.2/bin

gradle assembleDebug 2>&1 | grep -E "^e:|BUILD"

APK=$(find ~/PeepogrobVPN -name "app-debug.apk" | head -1)
if [ -n "$APK" ]; then
    echo ""
    echo "╔══════════════════════════════╗"
    echo "║     BUILD SUCCESSFUL ✓       ║"
    echo "╚══════════════════════════════╝"
    IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    echo "Download: http://$IP:8080/app-debug.apk"
    python3 -m http.server 8080 --directory "$(dirname $APK)"
else
    echo "BUILD FAILED — errors above"
fi
