package com.furlingdu.splatoon3record

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
  private var Audio: MobileAudioRecorder? = null
  private var PendingPermission: MethodChannel.Result? = null
  private var PendingGallery: Pair<MethodChannel.Result, String>? = null
  private val Worker: ExecutorService = Executors.newSingleThreadExecutor()

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    ApplyRefreshRate()
  }

  override fun onPostResume() {
    super.onPostResume()
    ApplyRefreshRate()
  }

  override fun configureFlutterEngine(Engine: FlutterEngine) {
    super.configureFlutterEngine(Engine)
    MethodChannel(Engine.dartExecutor.binaryMessenger, "splatoon3record/mobile_audio").setMethodCallHandler { Call, Result ->
      when (Call.method) {
        "Devices" -> Result.success(MobileAudioDevices.List(this))
        "EnsurePermission" -> EnsurePermission(Result)
        "MonotonicNs" -> Result.success(System.nanoTime())
        "Start" -> {
          val Path = Call.argument<String>("path") ?: ""
          val Device = Call.argument<String>("device") ?: ""
          val Bitrate = Call.argument<Int>("bitrate") ?: 192000
          if (Path.isEmpty()) {
            Result.error("audio", "path is required", null)
          } else {
            Worker.execute {
              try {
                Audio?.Stop()
                val New = MobileAudioRecorder(this, Path, Device, Bitrate)
                val StartNs = New.Start()
                Audio = New
                runOnUiThread { Result.success(mapOf("path" to Path, "startNs" to StartNs)) }
              } catch (Failure: Exception) {
                runOnUiThread { Result.error("audio", Failure.message, null) }
              }
            }
          }
        }
        "Stop" -> {
          val Current = Audio
          Audio = null
          if (Current == null) {
            Result.success(null)
          } else {
            Worker.execute {
              val Path = try {
                Current.Stop()
              } catch (Failure: Exception) {
                null
              }
              runOnUiThread { Result.success(Path) }
            }
          }
        }
        "SetMonitor" -> {
          val Enabled = Call.argument<Boolean>("enabled") ?: false
          Result.success(Audio?.Monitor(Enabled) ?: false)
        }
        "Mux" -> {
          val Video = Call.argument<String>("video") ?: ""
          val AudioPath = Call.argument<String>("audio") ?: ""
          val Output = Call.argument<String>("output") ?: ""
          val Offset = Call.argument<Number>("audioOffsetUs")?.toLong() ?: 0L
          Worker.execute {
            val Ok = MobileMediaMuxer.Mux(Video, AudioPath, Output, Offset)
            runOnUiThread { Result.success(Ok) }
          }
        }
        else -> Result.notImplemented()
      }
    }
    MethodChannel(Engine.dartExecutor.binaryMessenger, "splatoon3record/mobile_media").setMethodCallHandler { Call, Result ->
      when (Call.method) {
        "SaveVideo" -> {
          val Path = Call.argument<String>("path") ?: ""
          if (Path.isEmpty()) {
            Result.error("media", "path is required", null)
          } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            PendingGallery?.first?.success(false)
            PendingGallery = Result to Path
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), GalleryPermissionRequest)
          } else {
            Worker.execute {
              val Ok = MobileMediaStore.SaveVideo(this, Path)
              runOnUiThread { Result.success(Ok) }
            }
          }
        }
        else -> Result.notImplemented()
      }
    }
  }

  private fun EnsurePermission(Result: MethodChannel.Result) {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
      Result.success(true)
      return
    }
    PendingPermission?.success(false)
    PendingPermission = Result
    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), AudioPermissionRequest)
  }

  override fun onRequestPermissionsResult(RequestCode: Int, Permissions: Array<out String>, GrantResults: IntArray) {
    super.onRequestPermissionsResult(RequestCode, Permissions, GrantResults)
    val Granted = GrantResults.isNotEmpty() && GrantResults[0] == PackageManager.PERMISSION_GRANTED
    if (RequestCode == GalleryPermissionRequest) {
      val Pending = PendingGallery
      PendingGallery = null
      if (Pending == null) return
      if (!Granted) {
        Pending.first.success(false)
        return
      }
      val Path = Pending.second
      Worker.execute {
        val Ok = MobileMediaStore.SaveVideo(this, Path)
        runOnUiThread { Pending.first.success(Ok) }
      }
      return
    }
    if (RequestCode != AudioPermissionRequest) return
    val Result = PendingPermission
    PendingPermission = null
    Result?.success(Granted)
  }

  private fun ApplyRefreshRate() {
    val CurrentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay
    if (CurrentDisplay == null) return
    val Modes = CurrentDisplay.supportedModes
    if (Modes.isEmpty()) return
    val Best = Modes.maxByOrNull { it.refreshRate } ?: return
    val Attributes = window.attributes
    Attributes.preferredRefreshRate = Best.refreshRate
    window.attributes = Attributes
  }

  override fun onDestroy() {
    try {
      Audio?.Stop()
    } catch (_: Exception) {
    }
    Audio = null
    Worker.shutdown()
    super.onDestroy()
  }

  companion object {
    private const val AudioPermissionRequest = 9002
    private const val GalleryPermissionRequest = 9003
  }
}
