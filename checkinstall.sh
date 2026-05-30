cat > ~/PeepogrobVPN/app/src/main/java/com/peepogrob/vpn/vpn/PeeVpnService.kt << 'EOF'
package com.peepogrob.vpn.vpn

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
        const val CHANNEL_ID   = "peevpn_channel"
        const val NOTIF_ID     = 1
        const val MTU          = 1500
        private const val TAG  = "PeeVpnService"
        var isRunning = false
    }

    private var coreController: CoreController? = null
    private var pfd: ParcelFileDescriptor? = null
    private var reconnectCount = 0
    private val handler = Handler(Looper.getMainLooper())
    private var currentConfig: VmessConfig? = null

    private val callbackHandler = object : CoreCallbackHandler {
        override fun onEmitStatus(level: Long, msg: String?): Long {
            Log.d(TAG, "v2ray [$level]: $msg")
            if (msg?.contains("failed") == true || msg?.contains("error") == true) {
                handler.post { handleReconnect() }
            }
            return 0
        }
        override fun shutdown(): Long {
            handler.post { stopVpn() }
            return 0
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val cfg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
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
            val builder = Builder()
                .setMtu(MTU)
                .addAddress("10.10.10.1", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("8.8.8.8")
                .addDnsServer("1.1.1.1")
                .setSession("PeepogrobVPN")
                .setBlocking(false)
            pfd = builder.establish() ?: run { Log.e(TAG, "establish null"); return }

            val configJson = ConfigGenerator.generate(cfg)
            coreController = CoreController(callbackHandler)
            coreController!!.startLoop(configJson)

            isRunning = true
            reconnectCount = 0
            startForeground(NOTIF_ID, buildNotification("Connected"))
            sendBroadcast(Intent("com.peepogrob.vpn.STATUS").putExtra("running", true))
        } catch (e: Exception) {
            Log.e(TAG, "startVpn: ${e.message}")
            handleReconnect()
        }
    }

    private fun stopVpn() {
        try { coreController?.stopLoop() } catch (e: Exception) { Log.e(TAG, "stop: ${e.message}") }
        try { pfd?.close() } catch (e: Exception) {}
        pfd = null
        coreController = null
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        sendBroadcast(Intent("com.peepogrob.vpn.STATUS").putExtra("running", false))
    }

    private fun handleReconnect() {
        if (reconnectCount < 3) {
            reconnectCount++
            updateNotification("Reconnecting ($reconnectCount/3)...")
            handler.postDelayed({ currentConfig?.let { startVpn(it) } }, 3000)
        } else {
            updateNotification("Failed")
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
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIF_ID, buildNotification(text))
    }

    override fun onDestroy() {
        super.onDestroy()
        stopVpn()
    }
}
EOF

cat > ~/PeepogrobVPN/app/src/main/java/com/peepogrob/vpn/ui/MainActivity.kt << 'EOF'
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
            startActivity(Intent(this, SettingsActivity::class.java))
            return
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
            Toast.makeText(this, "Imported: ${cfg.remarks}", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(this, "No valid vmess:// in clipboard", Toast.LENGTH_SHORT).show()
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

gradle assembleDebug 2>&1 | grep -E "error:|e:|BUILD" | head -20
