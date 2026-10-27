package cn.miodu.splatoon3record

import android.content.Context
import android.graphics.SurfaceTexture
import com.pedro.common.ConnectChecker
import com.pedro.encoder.input.sources.audio.MicrophoneSource
import com.pedro.extrasources.CameraUvcSource
import com.pedro.library.generic.GenericStream

class UvcLive(ContextValue: Context, private val Listener: Listener) {
  interface Listener {
    fun OnState(Value: String)
    fun OnError(Value: String)
  }

  private val Checker = object : ConnectChecker {
    override fun onConnectionStarted(url: String) {
      Listener.OnState("starting")
    }

    override fun onConnectionSuccess() {
      Listener.OnState("live")
    }

    override fun onConnectionFailed(reason: String) {
      Listener.OnError(reason)
    }

    override fun onDisconnect() {
      Listener.OnState("idle")
    }

    override fun onAuthError() {
      Listener.OnError("RTMP 鉴权失败")
    }

    override fun onAuthSuccess() {}

    override fun onNewBitrate(bitrate: Long) {}
  }

  private val Stream = GenericStream(ContextValue, Checker, CameraUvcSource(), MicrophoneSource())
  private var Texture: SurfaceTexture? = null
  private var Active = false

  fun Start(Url: String, Width: Int, Height: Int, Fps: Int, Bitrate: Int): String? {
    if (Active) return null
    return try {
      if (!Stream.prepareVideo(Width, Height, Bitrate, Fps)) return "视频编码器准备失败"
      if (!Stream.prepareAudio(44100, true, 128 * 1024)) return "音频编码器准备失败"
      val Surface = SurfaceTexture(0)
      Surface.setDefaultBufferSize(Width, Height)
      Texture = Surface
      Stream.startPreview(Surface, Width, Height)
      Stream.startStream(Url)
      Active = true
      null
    } catch (Failure: Exception) {
      Active = false
      Failure.message ?: "采集卡推流启动失败"
    }
  }

  fun Stop() {
    if (!Active) return
    Active = false
    try {
      Stream.stopStream()
    } catch (_: Exception) {
    }
    try {
      Stream.stopPreview()
    } catch (_: Exception) {
    }
    Texture?.release()
    Texture = null
  }
}
