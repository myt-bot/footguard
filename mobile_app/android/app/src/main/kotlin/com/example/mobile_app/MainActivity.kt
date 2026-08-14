package com.example.mobile_app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.speech.tts.TextToSpeech
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "footguard/notifications"
    private val ttsChannelName = "footguard/tts"
    private val notificationChannelId = "footguard_risk_alerts_silent_v2"
    private var textToSpeech: TextToSpeech? = null
    private var chineseSpeechReady = false
    private var initializingSpeech = false
    private val pendingSpeechInitializations = mutableListOf<MethodChannel.Result>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        createNotificationChannel()
                        if (Build.VERSION.SDK_INT >= 33 &&
                            ActivityCompat.checkSelfPermission(
                                this,
                                Manifest.permission.POST_NOTIFICATIONS,
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                701,
                            )
                        }
                        result.success(null)
                    }
                    "show" -> {
                        showNotification(
                            call.argument<String>("title") ?: "FootGuard 风险提醒",
                            call.argument<String>("body") ?: "请查看当前监测状态",
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> initializeChineseSpeech(result)
                    "speak" -> {
                        val text = call.argument<String>("text")?.trim().orEmpty()
                        if (!chineseSpeechReady || text.isEmpty()) {
                            result.success(false)
                        } else {
                            val status = textToSpeech?.speak(
                                text,
                                TextToSpeech.QUEUE_ADD,
                                null,
                                "footguard-${System.currentTimeMillis()}",
                            )
                            result.success(status == TextToSpeech.SUCCESS)
                        }
                    }
                    "stop" -> {
                        textToSpeech?.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun initializeChineseSpeech(result: MethodChannel.Result) {
        if (chineseSpeechReady) {
            result.success(true)
            return
        }
        pendingSpeechInitializations.add(result)
        if (initializingSpeech) return
        initializingSpeech = true
        textToSpeech = TextToSpeech(applicationContext) { status ->
            val engine = textToSpeech
            chineseSpeechReady = if (status == TextToSpeech.SUCCESS && engine != null) {
                val availability = engine.isLanguageAvailable(Locale.SIMPLIFIED_CHINESE)
                availability >= TextToSpeech.LANG_AVAILABLE &&
                    engine.setLanguage(Locale.SIMPLIFIED_CHINESE) >= TextToSpeech.LANG_AVAILABLE
            } else {
                false
            }
            initializingSpeech = false
            pendingSpeechInitializations.forEach { it.success(chineseSpeechReady) }
            pendingSpeechInitializations.clear()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    notificationChannelId,
                    "风险与干预提醒",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "FootGuard 持续风险和干预观察结果"
                    enableVibration(false)
                },
            )
        }
    }

    private fun showNotification(title: String, body: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ActivityCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) return
        createNotificationChannel()
        val notification = NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setSilent(true)
            .setAutoCancel(true)
            .build()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(System.currentTimeMillis().toInt(), notification)
    }

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }
}
