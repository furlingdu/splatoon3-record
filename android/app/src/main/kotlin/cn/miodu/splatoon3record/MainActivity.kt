package cn.miodu.splatoon3record

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
  private var Audio: UsbAudio? = null
  private var Uvc: UvcLive? = null
  private var UvcSink: EventChannel.EventSink? = null

  override fun configureFlutterEngine(Engine: FlutterEngine) {
    super.configureFlutterEngine(Engine)
    MethodChannel(Engine.dartExecutor.binaryMessenger, "splatoon3record/mobile_audio").setMethodCallHandler { Call, Result ->
      when (Call.method) {
        "Devices" -> Result.success(AudioDevices())
        "Start" -> {
          val Path = Call.argument<String>("path") ?: ""
          val Device = Call.argument<String>("device") ?: ""
          try {
            Audio?.Stop()
            Audio = UsbAudio(this, Path, Device)
            Audio?.Start()
            Result.success(null)
          } catch (Failure: Exception) {
            Result.error("audio", Failure.message, null)
          }
        }
        "Stop" -> {
          val Path = Audio?.Stop()
          Audio = null
          Result.success(Path)
        }
        else -> Result.notImplemented()
      }
    }
    EventChannel(Engine.dartExecutor.binaryMessenger, "splatoon3record/uvc_live/events").setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(Arguments: Any?, Events: EventChannel.EventSink) {
        UvcSink = Events
      }

      override fun onCancel(Arguments: Any?) {
        UvcSink = null
      }
    })
    MethodChannel(Engine.dartExecutor.binaryMessenger, "splatoon3record/uvc_live").setMethodCallHandler { Call, Result ->
      when (Call.method) {
        "Start" -> {
          val Url = Call.argument<String>("url") ?: ""
          val Width = Call.argument<Int>("width") ?: 1920
          val Height = Call.argument<Int>("height") ?: 1080
          val Fps = Call.argument<Int>("fps") ?: 30
          val Bitrate = Call.argument<Int>("bitrate") ?: 6000000
          try {
            Uvc?.Stop()
            val Live = UvcLive(this, object : UvcLive.Listener {
              override fun OnState(Value: String) {
                UvcSink?.success(mapOf("type" to "state", "value" to Value))
              }

              override fun OnError(Value: String) {
                UvcSink?.success(mapOf("type" to "error", "value" to Value))
              }
            })
            Uvc = Live
            val Failure = Live.Start(Url, Width, Height, Fps, Bitrate)
            if (Failure != null) {
              Uvc = null
              Result.error("uvc", Failure, null)
            } else {
              Result.success(null)
            }
          } catch (Problem: Exception) {
            Result.error("uvc", Problem.message, null)
          }
        }
        "Stop" -> {
          Uvc?.Stop()
          Uvc = null
          Result.success(null)
        }
        else -> Result.notImplemented()
      }
    }
  }

  private fun AudioDevices(): List<Map<String, Any>> {
    val Manager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val Result = ArrayList<Map<String, Any>>()
    for (Device in Manager.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
      val Name = Device.productName.toString().ifEmpty { DeviceName(Device.type) }
      val External = Device.type == AudioDeviceInfo.TYPE_USB_DEVICE || Device.type == AudioDeviceInfo.TYPE_USB_HEADSET
      Result.add(mapOf("id" to Device.id.toString(), "name" to Name, "kind" to "audio", "external" to External))
    }
    return Result
  }

  private fun DeviceName(Type: Int): String = when (Type) {
    AudioDeviceInfo.TYPE_USB_DEVICE -> "USB 音频"
    AudioDeviceInfo.TYPE_USB_HEADSET -> "USB 耳机"
    AudioDeviceInfo.TYPE_BUILTIN_MIC -> "内置麦克风"
    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "蓝牙麦克风"
    else -> "音频输入"
  }
}

class UsbAudio(private val ContextValue: Context, private val Path: String, private val DeviceId: String) {
  private val Running = AtomicBoolean(false)
  private var Recorder: AudioRecord? = null
  private var Worker: Thread? = null
  private val SampleRate = 48000
  private val Channels = 2
  private val Bits = 16

  fun Start() {
    val Minimum = AudioRecord.getMinBufferSize(SampleRate, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
    val Buffer = if (Minimum > 0) Minimum * 4 else 32768
    val Record = AudioRecord(MediaRecorder.AudioSource.MIC, SampleRate, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT, Buffer)
    if (Record.state != AudioRecord.STATE_INITIALIZED) {
      Record.release()
      throw IllegalStateException("无法打开音频输入")
    }
    val Manager = ContextValue.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val Target = Manager.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id.toString() == DeviceId }
    if (Target != null) Record.setPreferredDevice(Target)
    Recorder = Record
    Running.set(true)
    Record.startRecording()
    Worker = Thread {
      val Output = FileOutputStream(Path, false)
      Output.write(WavHeader(0))
      val Data = ByteArray(Buffer)
      while (Running.get()) {
        val Count = Record.read(Data, 0, Data.size)
        if (Count > 0) Output.write(Data, 0, Count)
      }
      Output.flush()
      Output.close()
      PatchHeader(File(Path))
    }
    Worker?.start()
  }

  fun Stop(): String? {
    Running.set(false)
    Worker?.join(2000)
    Worker = null
    Recorder?.let {
      try {
        it.stop()
      } catch (_: Exception) {
      }
      it.release()
    }
    Recorder = null
    return Path
  }

  private fun WavHeader(Size: Int): ByteArray {
    val Header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
    val ByteRate = SampleRate * Channels * Bits / 8
    val Block = Channels * Bits / 8
    Header.put("RIFF".toByteArray())
    Header.putInt(36 + Size)
    Header.put("WAVE".toByteArray())
    Header.put("fmt ".toByteArray())
    Header.putInt(16)
    Header.putShort(1)
    Header.putShort(Channels.toShort())
    Header.putInt(SampleRate)
    Header.putInt(ByteRate)
    Header.putShort(Block.toShort())
    Header.putShort(Bits.toShort())
    Header.put("data".toByteArray())
    Header.putInt(Size)
    return Header.array()
  }

  private fun PatchHeader(FileValue: File) {
    if (!FileValue.exists()) return
    val Size = (FileValue.length() - 44).toInt()
    RandomAccessFile(FileValue, "rw").use { Handle ->
      Handle.seek(4)
      Handle.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(36 + Size).array())
      Handle.seek(40)
      Handle.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(Size).array())
    }
  }
}
