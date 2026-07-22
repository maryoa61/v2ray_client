package com.v2ray.dan

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import android.app.Notification
import android.os.PowerManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import androidx.core.app.NotificationCompat
import java.util.concurrent.atomic.AtomicBoolean

class V2RayVPNService : VpnService(), V2RayServicesListener {
    private val TAG = "V2RayVPNService"
    private var mInterface: ParcelFileDescriptor? = null
    private var process: Process? = null

    @Volatile
    private var isRunning = false

    // فلگ جدید: تضمین می‌کنه setup() دقیقاً یک‌بار در هر چرخه‌ی اتصال اجرا بشه
    // (جلوگیری از double-establish وقتی هم core callback و هم فالبک تایم‌اوت هم‌زمان بشن)
    private val setupCalled = AtomicBoolean(false)

    private var wakeLock: PowerManager.WakeLock? = null
    private var setupTimeoutHandler: android.os.Handler? = null
    private var setupTimeoutRunnable: Runnable? = null

    companion object {
        const val ACTION_STOP_VPN = "com.v2ray.dan.action.STOP_VPN"
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val command = intent?.getIntExtra("COMMAND", 0)
        Log.i(TAG, "onStartCommand: command=$command action=${intent?.action}")
        Utilities.broadcastLog(this, "Service: onStartCommand (cmd: $command)", "INFO")

        if (intent?.action == ACTION_STOP_VPN || command == AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE) {
            Utilities.broadcastLog(this, "Service: Stopping service command received", "INFO")
            Utilities.broadcastStatus(this, "disconnecting")
            isRunning = false
            stopAllProcess()
            Utilities.broadcastStatus(this, "disconnected")
            stopSelf()
            return Service.START_NOT_STICKY
        }
        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
            // هر شروع جدید یعنی چرخه‌ی جدید — فلگ setup رو ریست کن
            setupCalled.set(false)

            Utilities.copyAssets(this)
            V2RayCoreManager.setUpListener(this)
            val config = AppConfigs.V2RAY_CONFIG
            if (config != null) {
                Utilities.broadcastStatus(this, "connecting")
                Utilities.broadcastLog(this, "Service: Starting V2Ray Core", "INFO")
                Utilities.broadcastLog(this, "Service: Using config for server '${config.REMARK}'", "DEBUG")

                val started = V2RayCoreManager.startCore(config)
                if (!started) {
                    // اگه startCore واقعاً fail بشه، منتظر callback بی‌فایده نمون؛ فوراً error بده
                    Utilities.broadcastLog(this, "Service: startCore failed immediately", "ERROR")
                    Utilities.broadcastStatus(this, "error")
                    stopSelf()
                    return Service.START_NOT_STICKY
                }

                // فالبک: اگه ظرف ۵ ثانیه startup() صدا زده نشد، خودمون setup رو صدا بزن
                setupTimeoutRunnable = Runnable {
                    if (!isRunning) {
                        Utilities.broadcastLog(this, "Service: Core callback timeout - triggering setup fallback", "WARN")
                        setup()
                    }
                }
                setupTimeoutHandler = android.os.Handler(android.os.Looper.getMainLooper())
                setupTimeoutHandler?.postDelayed(setupTimeoutRunnable!!, 5000)

            } else {
                Utilities.broadcastLog(this, "Service: Config is null, cannot start", "ERROR")
                Utilities.broadcastStatus(this, "error")
                stopSelf()
                return Service.START_NOT_STICKY
            }
        }
        return Service.START_STICKY
    }

    override fun onProtect(socket: Int): Boolean = protect(socket)
    override fun getService(): Service = this
    override fun startService() = setup()
    override fun stopService() = stopAllProcess()

    private fun createNotification(): Notification {
        val channelId = "V2RAY_VPN_CHANNEL"
        val channelName = "V2Ray VPN Service"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }

        val disconnectIntent = Intent(this, V2RayVPNService::class.java)
        disconnectIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getService(this, 0, disconnectIntent, flags)

        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Flaming Cherubim: ${AppConfigs.V2RAY_CONFIG?.REMARK ?: "Connected"}")
            .setContentText("Connected to ${AppConfigs.V2RAY_CONFIG?.REMARK ?: "secure server"}")
            .setSmallIcon(AppConfigs.APPLICATION_ICON)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "DISCONNECT", pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun setup() {
        // تضمین اجرای دقیقاً یک‌باره، حتی اگه هم core callback و هم فالبک تایم‌اوت هم‌زمان صدا بزنن
        if (!setupCalled.compareAndSet(false, true)) {
            Utilities.broadcastLog(this, "Service: setup() already called for this cycle, skipping", "WARN")
            return
        }

        Utilities.broadcastLog(this, "Service: setup() starting", "INFO")
        val config = AppConfigs.V2RAY_CONFIG
        if (config == null) {
            Utilities.broadcastLog(this, "Service: setup failed - config is null", "ERROR")
            stopSelf()
            return
        }

        try {
            startForeground(1, createNotification())
            Utilities.broadcastLog(this, "Service: startForeground called", "INFO")
            broadcastWidgetState(true)
        } catch (e: Exception) {
            Utilities.broadcastLog(this, "Service: startForeground failed: ${e.message}", "ERROR")
        }

        Utilities.broadcastLog(this, "Service: Establishing Optimized VPN Interface...", "INFO")
        val builder = Builder()
        builder.setSession(config.REMARK)
        builder.setMtu(config.MTU)

        builder.addAddress("172.19.0.1", 30)
        builder.addRoute("0.0.0.0", 0)

        if (config.USE_SYSTEM_DNS) {
            // با LinkedHashSet از تکرار DNS جلوگیری می‌کنیم (ترتیب هم حفظ می‌شه)
            val dnsSet = LinkedHashSet<String>()
            dnsSet.add("1.1.1.1")
            dnsSet.add("8.8.8.8")

            val systemDnsChannels = Utilities.getSystemDnsServers(this)
            if (systemDnsChannels.isNotEmpty()) {
                systemDnsChannels.forEach { dns ->
                    if (!dns.contains(":")) {
                        dnsSet.add(dns)
                    }
                }
            } else {
                Utilities.broadcastLog(this, "Service: No System DNS found, using Fallback (Cloudflare/Google)", "WARN")
            }

            dnsSet.forEach { dns ->
                try {
                    builder.addDnsServer(dns)
                    Utilities.broadcastLog(this, "Service: Added DNS: $dns", "DEBUG")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to add DNS: $dns — ${e.message}")
                }
            }
        } else {
            try {
                builder.addDnsServer("1.1.1.1")
                builder.addDnsServer("8.8.8.8")
                Utilities.broadcastLog(this, "Service: Custom DNS servers added", "DEBUG")
            } catch (e: Exception) {
                Utilities.broadcastLog(this, "Service: addDnsServer error: ${e.message}", "WARN")
            }
        }

        try {
            mInterface = builder.establish()
            if (mInterface == null) {
                // establish() می‌تونه null برگردونه (نه فقط exception بزنه) — مثلاً وقتی
                // یه VPN دیگه هم‌زمان در حال آماده‌سازیه. این حالت قبلاً چک نمی‌شد.
                Utilities.broadcastLog(this, "Service: builder.establish() returned null", "ERROR")
                Utilities.broadcastStatus(this, "error")
                stopAllProcess()
                return
            }
            isRunning = true
            Utilities.broadcastStatus(this, "connected")
            Utilities.broadcastLog(this, "Service: VPN Interface established successfully", "INFO")

            // TODO: اینجا دقیقاً همون‌جاییه که باید FD رو از طریق LocalSocket
            // به سوپروایزر tun2socks پاس بدی و اون پروسه رو استارت کنی.
            // منتظر فایل بعدی‌ت هستم تا این بخش رو هم بهینه کنیم.

        } catch (e: Exception) {
            Utilities.broadcastLog(this, "Service: vpn builder establish failed: ${e.message}", "ERROR")
            Utilities.broadcastStatus(this, "error")
            stopAllProcess()
        }
    }

    private fun stopAllProcess() {
        isRunning = false
        setupCalled.set(false) // ریست برای چرخه‌ی اتصال بعدی

        if (setupTimeoutHandler != null && setupTimeoutRunnable != null) {
            setupTimeoutHandler?.removeCallbacks(setupTimeoutRunnable!!)
        }
        setupTimeoutHandler = null
        setupTimeoutRunnable = null

        V2RayCoreManager.stopCore()
        try {
            mInterface?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to close mInterface: ${e.message}")
        } finally {
            mInterface = null
        }
        broadcastWidgetState(false)
        stopForeground(true)
    }

    private fun broadcastWidgetState(isExpanded: Boolean) {
        // Implementation for widget broadcast state
    }
}
