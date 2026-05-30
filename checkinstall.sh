mkdir -p ~/PeepogrobVPN/app/src/main/{java/com/peepogrob/vpn/{ui,vpn,model,util},res/{layout,values,drawable,xml}} && cd ~/PeepogrobVPN && cat > settings.gradle << 'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url 'https://jitpack.io' }
    }
}
rootProject.name = "PeepogrobVPN"
include ':app'
EOF

cat > build.gradle << 'EOF'
buildscript {
    dependencies {
        classpath 'com.android.tools.build:gradle:8.2.2'
        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.22"
    }
}
EOF

cat > gradle/wrapper/gradle-wrapper.properties << 'EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.2-bin.zip
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
EOF

mkdir -p gradle/wrapper && wget -q https://raw.githubusercontent.com/gradle/gradle/v8.2.0/gradle/wrapper/gradle-wrapper.jar -O gradle/wrapper/gradle-wrapper.jar

cat > gradlew << 'EOF'
#!/bin/sh
exec java -jar "$(dirname "$0")/gradle/wrapper/gradle-wrapper.jar" "$@"
EOF
chmod +x gradlew

cat > app/build.gradle << 'EOF'
plugins {
    id 'com.android.application'
    id 'org.jetbrains.kotlin.android'
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
        ndk { abiFilters 'arm64-v8a', 'armeabi-v7a' }
    }
    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = '17' }
}
dependencies {
    implementation 'androidx.appcompat:appcompat:1.6.1'
    implementation 'androidx.core:core-ktx:1.12.0'
    implementation 'com.google.android.material:material:1.11.0'
    implementation 'com.github.2dust:AndroidLibV2rayLite:2.2.2'
}
EOF

cat > app/proguard-rules.pro << 'EOF'
-keep class com.peepogrob.vpn.** { *; }
-keep class go.** { *; }
-keep class libv2ray.** { *; }
-dontwarn go.**
-dontwarn libv2ray.**
EOF

cat > app/src/main/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
    <application
        android:allowBackup="false"
        android:icon="@mipmap/ic_launcher"
        android:label="PeepogrobVPN"
        android:theme="@style/AppTheme">
        <activity android:name=".ui.MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity>
        <activity android:name=".ui.SettingsActivity" android:exported="false"/>
        <service
            android:name=".vpn.PeeVpnService"
            android:exported="false"
            android:permission="android.permission.BIND_VPN_SERVICE">
            <intent-filter>
                <action android:name="android.net.VpnService"/>
            </intent-filter>
        </service>
    </application>
</manifest>
EOF

cat > app/src/main/java/com/peepogrob/vpn/model/VmessConfig.kt << 'EOF'
package com.peepogrob.vpn.model

data class VmessConfig(
    val address: String = "",
    val port: Int = 443,
    val uuid: String = "",
    val alterId: Int = 0,
    val security: String = "aes-128-gcm",
    val path: String = "/",
    val host: String = "",
    val remarks: String = "PeepogrobVPN"
)
EOF

cat > app/src/main/java/com/peepogrob/vpn/util/VmessImport.kt << 'EOF'
package com.peepogrob.vpn.util

import android.util.Base64
import com.peepogrob.vpn.model.VmessConfig
import org.json.JSONObject

object VmessImport {
    fun parse(link: String): VmessConfig? {
        return try {
            if (!link.startsWith("vmess://")) return null
            val decoded = String(Base64.decode(link.removePrefix("vmess://"), Base64.DEFAULT))
            val json = JSONObject(decoded)
            VmessConfig(
                address  = json.optString("add", ""),
                port     = json.optString("port", "443").toIntOrNull() ?: 443,
                uuid     = json.optString("id", ""),
                alterId  = json.optString("aid", "0").toIntOrNull() ?: 0,
                security = json.optString("scy", "aes-128-gcm").ifEmpty { "aes-128-gcm" },
                path     = json.optString("path", "/").ifEmpty { "/" },
                host     = json.optString("host", ""),
                remarks  = json.optString("ps", "PeepogrobVPN")
            )
        } catch (e: Exception) { null }
    }
}
EOF

cat > app/src/main/java/com/peepogrob/vpn/vpn/ConfigGenerator.kt << 'EOF'
package com.peepogrob.vpn.vpn

import com.peepogrob.vpn.model.VmessConfig

object ConfigGenerator {
    fun generate(cfg: VmessConfig, socksPort: Int = 10808): String = """
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $socksPort,
    "protocol": "socks",
    "settings": {"auth": "noauth", "udp": true},
    "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
  }],
  "outbounds": [{
    "protocol": "vmess",
    "settings": {
      "vnext": [{
        "address": "${cfg.address}",
        "port": ${cfg.port},
        "users": [{"id": "${cfg.uuid}", "alterId": ${cfg.alterId}, "security": "${cfg.security}"}]
      }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "${cfg.path}",
        "headers": {"Host": "${cfg.host.ifEmpty { cfg.address }}"}
      },
      "sockopt": {"mark": 255}
    }
  },{
    "protocol": "freedom",
    "tag": "direct",
    "settings": {}
  }],
  "routing": {
    "rules": [{"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]}]
  }
}""".trimIndent()
}
EOF

cat > app/src/main/java/com/peepogrob/vpn/vpn/PeeVpnService.kt << 'EOF'
package com.peepogrob.vpn.vpn

import android.app.*
import android.content.*
import android.net.VpnService
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import com.peepogrob.vpn.model.VmessConfig
import com.peepogrob.vpn.ui.MainActivity
import libv2ray.Libv2ray
import libv2ray.V2RayPoint
import libv2ray.V2RayVPNServiceSupportsSet
import java.io.File

class PeeVpnService : VpnService(), V2RayVPNServiceSupportsSet {

    companion object {
        const val ACTION_START = "START"
        const val ACTION_STOP  = "STOP"
        const val CHANNEL_ID   = "peevpn_channel"
        const val NOTIF_ID     = 1
        const val SOCKS_PORT   = 10808
        const val MTU          = 1500
        private const val TAG  = "PeeVpnService"

        var isRunning = false
    }

    private lateinit var v2rayPoint: V2RayPoint
    private var pfd: ParcelFileDescriptor? = null
    private var reconnectCount = 0
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        v2rayPoint = Libv2ray.newV2RayPoint(this, false)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val cfg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra("config", VmessConfig::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra("config")
                cfg?.let { startVpn(it) }
            }
            ACTION_STOP -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn(cfg: VmessConfig) {
        try {
            val configJson = ConfigGenerator.generate(cfg, SOCKS_PORT)
            val configFile = File(filesDir, "config.json")
            configFile.writeText(configJson)

            val builder = Builder()
                .setMtu(MTU)
                .addAddress("10.10.10.1", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("1.1.1.1")
                .setSession("PeepogrobVPN")
                .setBlocking(false)

            pfd = builder.establish() ?: run {
                Log.e(TAG, "establish() returned null"); return
            }

            v2rayPoint.configureFileContent = configJson
            v2rayPoint.domainName = "${cfg.address}:${cfg.port}"
            v2rayPoint.runLoop(false)

            isRunning = true
            reconnectCount = 0
            startForeground(NOTIF_ID, buildNotification("Connected"))
            sendBroadcast(Intent("com.peepogrob.vpn.STATUS").putExtra("running", true))
        } catch (e: Exception) {
            Log.e(TAG, "startVpn error: ${e.message}")
            handleReconnect()
        }
    }

    private fun stopVpn() {
        try {
            v2rayPoint.stopLoop()
            pfd?.close()
            pfd = null
        } catch (e: Exception) { Log.e(TAG, "stopVpn: ${e.message}") }
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        sendBroadcast(Intent("com.peepogrob.vpn.STATUS").putExtra("running", false))
    }

    private fun handleReconnect() {
        if (reconnectCount < 3) {
            reconnectCount++
            updateNotification("Reconnecting ($reconnectCount/3)...")
            handler.postDelayed({
                val prefs = getSharedPreferences("peevpn", MODE_PRIVATE)
                val cfg = VmessConfig(
                    address  = prefs.getString("address", "") ?: "",
                    port     = prefs.getInt("port", 443),
                    uuid     = prefs.getString("uuid", "") ?: "",
                    alterId  = prefs.getInt("alterId", 0),
                    security = prefs.getString("security", "aes-128-gcm") ?: "aes-128-gcm",
                    path     = prefs.getString("path", "/") ?: "/",
                    host     = prefs.getString("host", "") ?: ""
                )
                startVpn(cfg)
            }, 3000)
        } else {
            updateNotification("Failed — tap to retry")
            isRunning = false
            sendBroadcast(Intent("com.peepogrob.vpn.STATUS").putExtra("running", false))
        }
    }

    private fun createNotificationChannel() {
        val ch = NotificationChannel(CHANNEL_ID, "VPN Status", NotificationManager.IMPORTANCE_LOW)
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(ch)
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("PeepogrobVPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    // V2RayVPNServiceSupportsSet
    override fun getVpnService() = this
    override fun newBuilder() = Builder()
    override fun shutdown() { stopVpn() }
    override fun prepare() = VpnService.prepare(this)
    override fun protect(socket: Long) = protect(socket.toInt())
}
EOF

cat > app/src/main/java/com/peepogrob/vpn/ui/MainActivity.kt << 'EOF'
package com.peepogrob.vpn.ui

import android.content.*
import android.net.VpnService
import android.os.Bundle
import android.view.View
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.peepogrob.vpn.R
import com.peepogrob.vpn.model.VmessConfig
import com.peepogrob.vpn.util.VmessImport
import com.peepogrob.vpn.vpn.PeeVpnService

class MainActivity : AppCompatActivity() {

    private lateinit var btnConnect: Button
    private lateinit var tvStatus: TextView
    private lateinit var tvSpeed: TextView
    private lateinit var progressBar: ProgressBar

    private var isConnected = false

    private val vpnLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { if (it.resultCode == RESULT_OK) doConnect() }

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val running = intent?.getBooleanExtra("running", false) ?: false
            updateUI(running)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        btnConnect  = findViewById(R.id.btnConnect)
        tvStatus    = findViewById(R.id.tvStatus)
        tvSpeed     = findViewById(R.id.tvSpeed)
        progressBar = findViewById(R.id.progressBar)

        btnConnect.setOnClickListener {
            if (isConnected) stopVpn() else requestVpnPermission()
        }

        findViewById<ImageButton>(R.id.btnImport).setOnClickListener { importFromClipboard() }
        findViewById<ImageButton>(R.id.btnSettings).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }

        registerReceiver(statusReceiver, IntentFilter("com.peepogrob.vpn.STATUS"),
            RECEIVER_NOT_EXPORTED)
        updateUI(PeeVpnService.isRunning)
    }

    private fun requestVpnPermission() {
        val intent = VpnService.prepare(this)
        if (intent != null) vpnLauncher.launch(intent) else doConnect()
    }

    private fun doConnect() {
        val prefs = getSharedPreferences("peevpn", MODE_PRIVATE)
        val cfg = VmessConfig(
            address  = prefs.getString("address", "") ?: "",
            port     = prefs.getInt("port", 443),
            uuid     = prefs.getString("uuid", "") ?: "",
            alterId  = prefs.getInt("alterId", 0),
            security = prefs.getString("security", "aes-128-gcm") ?: "aes-128-gcm",
            path     = prefs.getString("path", "/") ?: "/",
            host     = prefs.getString("host", "") ?: ""
        )
        if (cfg.address.isEmpty() || cfg.uuid.isEmpty()) {
            Toast.makeText(this, "Please configure server first", Toast.LENGTH_SHORT).show()
            startActivity(Intent(this, SettingsActivity::class.java)); return
        }
        progressBar.visibility = View.VISIBLE
        startService(Intent(this, PeeVpnService::class.java).apply {
            action = PeeVpnService.ACTION_START
            putExtra("config", cfg)
        })
    }

    private fun stopVpn() {
        startService(Intent(this, PeeVpnService::class.java).apply {
            action = PeeVpnService.ACTION_STOP
        })
    }

    private fun importFromClipboard() {
        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val text = cm.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
        val cfg = VmessImport.parse(text)
        if (cfg != null) {
            saveConfig(cfg)
            Toast.makeText(this, "Imported: ${cfg.remarks}", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "No valid vmess:// link in clipboard", Toast.LENGTH_SHORT).show()
        }
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

    private fun updateUI(running: Boolean) {
        isConnected = running
        progressBar.visibility = View.GONE
        if (running) {
            btnConnect.text = "DISCONNECT"
            btnConnect.setBackgroundColor(0xFFE53935.toInt())
            tvStatus.text = "Connected"
            tvStatus.setTextColor(0xFF4CAF50.toInt())
        } else {
            btnConnect.text = "CONNECT"
            btnConnect.setBackgroundColor(0xFF1976D2.toInt())
            tvStatus.text = "Disconnected"
            tvStatus.setTextColor(0xFF9E9E9E.toInt())
            tvSpeed.text = ""
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(statusReceiver)
    }
}
EOF

cat > app/src/main/java/com/peepogrob/vpn/ui/SettingsActivity.kt << 'EOF'
package com.peepogrob.vpn.ui

import android.os.Bundle
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import com.peepogrob.vpn.R

class SettingsActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_settings)

        val prefs = getSharedPreferences("peevpn", MODE_PRIVATE)

        val etAddress  = findViewById<EditText>(R.id.etAddress)
        val etPort     = findViewById<EditText>(R.id.etPort)
        val etUuid     = findViewById<EditText>(R.id.etUuid)
        val etPath     = findViewById<EditText>(R.id.etPath)
        val etHost     = findViewById<EditText>(R.id.etHost)
        val spinSec    = findViewById<Spinner>(R.id.spinSecurity)
        val btnSave    = findViewById<Button>(R.id.btnSave)

        val securities = arrayOf("aes-128-gcm", "chacha20-poly1305", "none", "auto")
        spinSec.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_item, securities)
            .also { it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }

        etAddress.setText(prefs.getString("address", ""))
        etPort.setText(prefs.getInt("port", 443).toString())
        etUuid.setText(prefs.getString("uuid", ""))
        etPath.setText(prefs.getString("path", "/"))
        etHost.setText(prefs.getString("host", ""))
        val secIdx = securities.indexOf(prefs.getString("security", "aes-128-gcm"))
        if (secIdx >= 0) spinSec.setSelection(secIdx)

        btnSave.setOnClickListener {
            prefs.edit().apply {
                putString("address",  etAddress.text.toString().trim())
                putInt   ("port",     etPort.text.toString().toIntOrNull() ?: 443)
                putString("uuid",     etUuid.text.toString().trim())
                putString("security", spinSec.selectedItem.toString())
                putString("path",     etPath.text.toString().trim().ifEmpty { "/" })
                putString("host",     etHost.text.toString().trim())
                apply()
            }
            Toast.makeText(this, "Saved", Toast.LENGTH_SHORT).show()
            finish()
        }

        supportActionBar?.setDisplayHomeAsUpEnabled(true)
    }

    override fun onSupportNavigateUp(): Boolean { finish(); return true }
}
EOF

cat > app/src/main/res/layout/activity_main.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:orientation="vertical" android:gravity="center"
    android:background="#121212" android:padding="24dp">

    <TextView android:text="PeepogrobVPN"
        android:textSize="24sp" android:textColor="#FFFFFF"
        android:textStyle="bold" android:layout_marginBottom="8dp"
        android:layout_width="wrap_content" android:layout_height="wrap_content"/>

    <TextView android:id="@+id/tvStatus" android:text="Disconnected"
        android:textSize="14sp" android:textColor="#9E9E9E"
        android:layout_marginBottom="40dp"
        android:layout_width="wrap_content" android:layout_height="wrap_content"/>

    <ProgressBar android:id="@+id/progressBar"
        android:visibility="gone"
        android:layout_marginBottom="16dp"
        android:layout_width="wrap_content" android:layout_height="wrap_content"/>

    <Button android:id="@+id/btnConnect" android:text="CONNECT"
        android:textColor="#FFFFFF" android:backgroundTint="#1976D2"
        android:textSize="18sp" android:paddingHorizontal="48dp"
        android:layout_width="200dp" android:layout_height="200dp"
        android:layout_marginBottom="24dp"/>

    <TextView android:id="@+id/tvSpeed" android:text=""
        android:textSize="13sp" android:textColor="#757575"
        android:layout_marginBottom="32dp"
        android:layout_width="wrap_content" android:layout_height="wrap_content"/>

    <LinearLayout android:orientation="horizontal" android:gravity="center"
        android:layout_width="wrap_content" android:layout_height="wrap_content">

        <ImageButton android:id="@+id/btnImport"
            android:src="@android:drawable/ic_menu_add"
            android:backgroundTint="#1E1E1E" android:layout_marginEnd="24dp"
            android:layout_width="48dp" android:layout_height="48dp"/>

        <ImageButton android:id="@+id/btnSettings"
            android:src="@android:drawable/ic_menu_preferences"
            android:backgroundTint="#1E1E1E"
            android:layout_width="48dp" android:layout_height="48dp"/>
    </LinearLayout>
</LinearLayout>
EOF

cat > app/src/main/res/layout/activity_settings.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<ScrollView xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="match_parent"
    android:background="#121212">
    <LinearLayout android:orientation="vertical"
        android:layout_width="match_parent" android:layout_height="wrap_content"
        android:padding="20dp">

        <TextView android:text="Server Address"
            android:textColor="#9E9E9E" android:textSize="12sp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etAddress" android:hint="example.com"
            android:textColor="#FFFFFF" android:textColorHint="#555"
            android:inputType="textUri" android:background="#1E1E1E"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="Port"
            android:textColor="#9E9E9E" android:textSize="12sp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etPort" android:hint="443"
            android:textColor="#FFFFFF" android:textColorHint="#555"
            android:inputType="number" android:background="#1E1E1E"
            android:padding="12dp" android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="UUID"
            android:textColor="#9E9E9E" android:textSize="12sp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etUuid" android:hint="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
            android:textColor="#FFFFFF" android:textColorHint="#555"
            android:background="#1E1E1E" android:padding="12dp"
            android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="WebSocket Path"
            android:textColor="#9E9E9E" android:textSize="12sp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etPath" android:hint="/"
            android:textColor="#FFFFFF" android:textColorHint="#555"
            android:background="#1E1E1E" android:padding="12dp"
            android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="Host (SNI)"
            android:textColor="#9E9E9E" android:textSize="12sp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <EditText android:id="@+id/etHost" android:hint="leave blank = same as address"
            android:textColor="#FFFFFF" android:textColorHint="#555"
            android:background="#1E1E1E" android:padding="12dp"
            android:layout_marginBottom="16dp"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>

        <TextView android:text="Encryption"
            android:textColor="#9E9E9E" android:textSize="12sp"
            android:layout_width="wrap_content" android:layout_height="wrap_content"/>
        <Spinner android:id="@+id/spinSecurity"
            android:background="#1E1E1E" android:layout_marginBottom="32dp"
            android:layout_width="match_parent" android:layout_height="48dp"/>

        <Button android:id="@+id/btnSave" android:text="SAVE"
            android:textColor="#FFFFFF" android:backgroundTint="#1976D2"
            android:layout_width="match_parent" android:layout_height="wrap_content"/>
    </LinearLayout>
</ScrollView>
EOF

cat > app/src/main/res/values/styles.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="AppTheme" parent="Theme.AppCompat.DayNight.NoActionBar">
        <item name="colorPrimary">#1976D2</item>
        <item name="colorPrimaryDark">#0D47A1</item>
        <item name="colorAccent">#4CAF50</item>
    </style>
</resources>
EOF

cat > app/src/main/res/values/colors.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="blue">#1976D2</color>
    <color name="red">#E53935</color>
    <color name="green">#4CAF50</color>
    <color name="bg">#121212</color>
</resources>
EOF

mkdir -p app/src/main/res/mipmap-hdpi
cd app/src/main/res && for d in mipmap-mdpi mipmap-hdpi mipmap-xhdpi mipmap-xxhdpi mipmap-xxxhdpi; do mkdir -p $d; cp mipmap-hdpi/../../../.. /dev/null 2>/dev/null || true; done; cd ~/PeepogrobVPN

echo "=== SOURCE CODE READY ==="
find app/src -name "*.kt" | wc -l
