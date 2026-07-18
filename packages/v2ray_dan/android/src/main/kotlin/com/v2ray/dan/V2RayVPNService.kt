package com.v2ray.dan

import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.util.Log
import java.io.File
import java.io.FileDescriptor
import java.util.ArrayList
import java.util.Arrays
import android.app.Notification
import android.content.Context
import android.os.PowerManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import androidx.core.app.NotificationCompat
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import java.net.InetAddress
import java.net.Inet4Address

class V2RayVPNService : VpnService(), V2RayServicesListener {
    private val TAG = "V2RayVPNService"
    private var mInterface: ParcelFileDescriptor? = null
    private var process: Process? = null
    @Volatile
    private var isRunning = false
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
            isRunning = false // Stop supervisor loops first
            stopAllProcess()
            Utilities.broadcastStatus(this, "disconnected")
            stopSelf()
            return Service.START_NOT_STICKY
        }
        if (command == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
            Utilities.copyAssets(this)
            V2RayCoreManager.setUpListener(this)
            val config = AppConfigs.V2RAY_CONFIG
            if (config != null) {
                Utilities.broadcastStatus(this, "connecting")
                Utilities.broadcastLog(this, "Service: Starting V2Ray Core", "INFO")
                
                // Log parameters for verification
                android.util.Log.d("V2RayDAN", "Service: Start core - Remark: ${config.REMARK}, Config Length: ${config.V2RAY_FULL_JSON_CONFIG.length}")
                Utilities.broadcastLog(this, "Service: Using config for server '${config.REMARK}'", "DEBUG")
                
                V2RayCoreManager.startCore(config)
                
                // FALLBACK: If core doesn't call startup() within 5 seconds, try to setup anyway
                // This ensures VPN interface is established even if core lifecycle is weird
                // CRITICAL: Store handler reference so we can cancel it on disconnect
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
            }
        }
        return Service.START_STICKY
    }
    
    // V2RayServicesListener implementation
    override fun onProtect(socket: Int): Boolean {
        return protect(socket)
    }
    
    override fun getService(): Service {
        return this
    }
    
    override fun startService() {
        setup()
    }
    
    override fun stopService() {
        stopAllProcess()
    }

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
        Utilities.broadcastLog(this, "Service: setup() starting", "INFO")
        val config = AppConfigs.V2RAY_CONFIG
        if (config == null) {
            Utilities.broadcastLog(this, "Service: setup failed - config is null", "ERROR")
            stopSelf()
            return
        }

        // CRITICAL: Must be called within 5 seconds of startForegroundService
        try {
            startForeground(1, createNotification())
            Utilities.broadcastLog(this, "Service: startForeground called", "INFO")
            broadcastWidgetState(true) // Notify widget
        } catch (e: Exception) {
            Utilities.broadcastLog(this, "Service: startForeground failed: ${e.message}", "ERROR")
        }

        // Prepare VPN - Optimized for Iran Network
        Utilities.broadcastLog(this, "Service: Establishing Optimized VPN Interface...", "INFO")
        val builder = Builder()
        builder.setSession(config.REMARK)
        
        // تنظیم خودکار مقدار MTU بهینه‌سازی شده از آبجکت کانفیگ (پیش‌فرض ۱۳۵۰)
        builder.setMtu(config.MTU)
        
        builder.addAddress("172.19.0.1", 30)
        builder.addRoute("0.0.0.0", 0)
        
        /* IPv6 disabled to prevent leaks/resets on dual-stack networks for now */
        // builder.addAddress("fd00:1::1", 128)
        // builder.addRoute("::", 0)

        // Optimized DNS Resolving Layer
        if (config.USE_SYSTEM_DNS) {
            // اضافه کردن دی‌ان‌اس‌های پرسرعت به صورت موازی برای کاهش ریسک منقضی شدن آدرس‌ها
            builder.addDnsServer("1.1.1.1")
            builder.addDnsServer("8.8.8.8")
            
            val systemDnsChannels = Utilities.getSystemDnsServers(this)
            if (systemDnsChannels.isNotEmpty()) {
                systemDnsChannels.forEach { dns ->
                    try {
                        // فقط رکوردهای IPv4 سیستم‌عامل اد شوند تا نشت یا کندی در شبکه‌های هایبرید پیش نیاید
                        if (!dns.contains(":")) {
                            builder.addDnsServer(dns)
                            Utilities.broadcastLog(this, "Service: Added System DNS: $dns", "DEBUG")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to add system DNS: $dns")
                    }
                }
            } else {
                Utilities.broadcastLog(this, "Service: No System DNS found, using Fallback (Cloudflare/Google)", "WARN")
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

        // بقیه کدهای متد متناسب با بقیه پیاده‌سازی‌های سیستم شما ادامه می‌یابد...
        try {
            mInterface = builder.establish()
            isRunning = true
            Utilities.broadcastStatus(this, "connected")
            Utilities.broadcastLog(this, "Service: VPN Interface established successfully", "INFO")
        } catch (e: Exception) {
            Utilities.broadcastLog(this, "Service: vpn builder establish failed: ${e.message}", "ERROR")
            Utilities.broadcastStatus(this, "error")
            stopAllProcess()
        }
    }

    private fun stopAllProcess() {
        isRunning = false
        if (setupTimeoutHandler != null && setupTimeoutRunnable != null) {
            setupTimeoutHandler?.removeCallbacks(setupTimeoutRunnable!!)
        }
        V2RayCoreManager.stopCore()
        try {
            mInterface?.close()
            mInterface = null
        } catch (e: Exception) {
            Log.e(TAG, "Failed to close mInterface: ${e.message}")
        }
        broadcastWidgetState(false)
        stopForeground(true)
    }

    private fun broadcastWidgetState(isExpanded: Boolean) {
        // Implementation for widget broadcast state
    }
}
