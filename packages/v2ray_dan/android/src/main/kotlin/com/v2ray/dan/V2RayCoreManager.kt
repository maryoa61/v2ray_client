package com.v2ray.dan

import android.app.Service
import android.util.Log
import libv2ray.CoreCallbackHandler
import libv2ray.CoreController
import libv2ray.Libv2ray
import libv2ray.V2RayProtector
import java.util.concurrent.atomic.AtomicBoolean

object V2RayCoreManager {
    private const val TAG = "V2RayCoreManager"
    private var coreController: CoreController? = null
    var listener: V2RayServicesListener? = null
    var isInitialized = false

    // AtomicBoolean به‌جای var ساده، چون این فلگ از چند thread (main + core callback thread) خونده/نوشته می‌شه
    private val _isCoreRunning = AtomicBoolean(false)
    val isCoreRunning: Boolean get() = _isCoreRunning.get()

    fun setUpListener(service: Service) {
        if (service is V2RayServicesListener) {
            listener = service

            // اگه قبلاً initialize شده، دوباره انجام نده (جلوگیری از re-register پروتکتور/کنترلر روی هر start)
            if (isInitialized) {
                Log.d(TAG, "Already initialized, skipping re-init")
                return
            }

            Libv2ray.initCoreEnv(service.applicationContext.filesDir.absolutePath, "")

            Libv2ray.useProtector(object : V2RayProtector {
                override fun protect(fd: Long): Boolean {
                    return listener?.onProtect(fd.toInt()) ?: true
                }
            })

            coreController = Libv2ray.newCoreController(object : CoreCallbackHandler {
                override fun onEmitStatus(p0: Long, p1: String?): Long {
                    if (p1 != null) {
                        Utilities.broadcastLog(service.applicationContext, p1, "INFO")
                    }
                    return 0
                }

                override fun shutdown(): Long {
                    Utilities.broadcastLog(service.applicationContext, "Core: shutdown() callback received", "INFO")
                    // نکته‌ی حیاتی: قبلاً این فلگ اینجا ریست نمی‌شد، در نتیجه startCore()
                    // در تلاش بعدی فکر می‌کرد Core هنوز در حال اجراست و کاری نمی‌کرد.
                    _isCoreRunning.set(false)
                    if (listener is Service) {
                        try {
                            (listener as Service).stopSelf()
                        } catch (e: Exception) {
                            Log.e(TAG, "stopSelf failed in shutdown callback: ${e.message}")
                        }
                    }
                    listener?.stopService()
                    return 0
                }

                override fun startup(): Long {
                    Utilities.broadcastLog(service.applicationContext, "Core: startup() callback received", "INFO")
                    _isCoreRunning.set(true)
                    listener?.startService()
                    return 0
                }
            })

            isInitialized = true
        }
    }

    fun startCore(config: V2rayConfig): Boolean {
        // compareAndSet به‌جای if/set جدا، تا بین چک و ست شدن race condition نباشه
        if (!_isCoreRunning.compareAndSet(false, true)) {
            Log.w(TAG, "Core already running")
            return true
        }

        if (!isInitialized || coreController == null) {
            Log.e(TAG, "Core not initialized")
            _isCoreRunning.set(false)
            return false
        }

        return try {
            coreController?.startLoop(config.V2RAY_FULL_JSON_CONFIG)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start core: ${e.message}")
            // اگه استارت واقعاً fail شد، فلگ رو برگردون به false وگرنه سیستم فکر می‌کنه در حال اجراست
            _isCoreRunning.set(false)
            false
        }
    }

    fun stopCore() {
        try {
            coreController?.stopLoop()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop core: ${e.message}")
        } finally {
            // finally: مطمئن می‌شه صرف‌نظر از موفقیت stopLoop، فلگ همیشه ریست می‌شه
            _isCoreRunning.set(false)
        }
    }
}
