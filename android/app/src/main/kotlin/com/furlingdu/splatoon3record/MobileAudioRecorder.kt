package com.furlingdu.splatoon3record

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class MobileAudioRecorder(
  private val ContextValue: Context,
  private val Path: String,
  private val DeviceId: String,
  private val Bitrate: Int,
) {
  private val Running = AtomicBoolean(false)
  private var Recorder: AudioRecord? = null
  private var Codec: MediaCodec? = null
  private var Muxer: MediaMuxer? = null
  private var Worker: Thread? = null
  private var Track = -1
  private var MuxerStarted = false
  private var SampleRate = 48000
  private var Channels = 2
  private var LastPtsUs = 0L
  @Volatile private var Monitor = false
  @Volatile private var Player: AudioTrack? = null
  var StartNs = 0L
  var Error: String? = null

  fun Monitor(Value: Boolean): Boolean {
    Monitor = Value
    if (Value) EnsurePlayer() else ReleasePlayer()
    return Value
  }

  private fun EnsurePlayer() {
    if (Player != null || Recorder == null) return
    val ChannelMask = if (Channels == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
    val Minimum = AudioTrack.getMinBufferSize(SampleRate, ChannelMask, AudioFormat.ENCODING_PCM_16BIT)
    if (Minimum <= 0) return
    val Track = try {
      AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
        .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(SampleRate).setChannelMask(ChannelMask).build())
        .setTransferMode(AudioTrack.MODE_STREAM)
        .setBufferSizeInBytes(Minimum * 4)
        .build()
    } catch (_: Exception) {
      null
    }
    if (Track == null) return
    try {
      Track.play()
      Player = Track
    } catch (_: Exception) {
      Track.release()
    }
  }

  private fun ReleasePlayer() {
    val Track = Player
    Player = null
    if (Track != null) {
      try {
        Track.stop()
      } catch (_: Exception) {
      }
      Track.release()
    }
  }

  fun Start(): Long {
    val Target = File(Path)
    Target.parentFile?.mkdirs()
    if (Target.exists()) Target.delete()
    if (!Configure()) throw IllegalStateException(Error ?: "无法初始化音频录制")
    Running.set(true)
    if (Monitor) EnsurePlayer()
    StartNs = System.nanoTime()
    try {
      Recorder?.startRecording()
    } catch (Failure: Exception) {
      Stop()
      throw Failure
    }
    val Routed = Recorder?.routedDevice
    if (Routed != null && !MobileAudioDevices.IsExternal(Routed)) {
      Stop()
      throw IllegalStateException("未能使用采集卡音频")
    }
    Worker = Thread {
      RecordLoop()
    }
    Worker?.start()
    return StartNs
  }

  private fun Configure(): Boolean {
    val Candidates = listOf(48000 to 2, 44100 to 2, 48000 to 1, 44100 to 1)
    for ((Rate, ChannelCount) in Candidates) {
      val ChannelMask = if (ChannelCount == 2) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
      val Minimum = AudioRecord.getMinBufferSize(Rate, ChannelMask, AudioFormat.ENCODING_PCM_16BIT)
      if (Minimum <= 0) continue
      val Record = try {
        AudioRecord(MediaRecorder.AudioSource.MIC, Rate, ChannelMask, AudioFormat.ENCODING_PCM_16BIT, Minimum * 4)
      } catch (Failure: Exception) {
        null
      }
      if (Record == null || Record.state != AudioRecord.STATE_INITIALIZED) {
        Record?.release()
        continue
      }
      val Target = MobileAudioDevices.Find(ContextValue, DeviceId)
      if (Target == null) {
        Record.release()
        Error = "未找到采集卡音频"
        continue
      }
      if (!Record.setPreferredDevice(Target)) {
        Record.release()
        Error = "无法切换到采集卡音频"
        continue
      }
      val CodecRef = try {
        MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
      } catch (Failure: Exception) {
        Record.release()
        Error = Failure.message
        continue
      }
      val Format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, Rate, ChannelCount).apply {
        setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
        setInteger(MediaFormat.KEY_BIT_RATE, Bitrate)
        setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65536)
      }
      try {
        CodecRef.configure(Format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        CodecRef.start()
        Muxer = MediaMuxer(Path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      } catch (Failure: Exception) {
        Error = Failure.message
        try {
          CodecRef.stop()
        } catch (_: Exception) {
        }
        CodecRef.release()
        Record.release()
        continue
      }
      Recorder = Record
      Codec = CodecRef
      SampleRate = Rate
      Channels = ChannelCount
      return true
    }
    return false
  }

  private fun RecordLoop() {
    val CodecRef = Codec ?: return
    val Record = Recorder ?: return
    val Info = MediaCodec.BufferInfo()
    try {
      while (Running.get()) {
        val InputIndex = CodecRef.dequeueInputBuffer(10000)
        if (InputIndex >= 0) {
          val Input = CodecRef.getInputBuffer(InputIndex)
          if (Input == null) {
            CodecRef.queueInputBuffer(InputIndex, 0, 0, LastPtsUs, 0)
          } else {
            Input.clear()
            val Count = Record.read(Input, Input.capacity())
            if (Count > 0) {
              if (Monitor) {
                val Copy = Input.duplicate()
                Copy.position(0)
                Copy.limit(Count)
                try {
                  Player?.write(Copy, Count, AudioTrack.WRITE_NON_BLOCKING)
                } catch (_: Exception) {
                }
              }
              CodecRef.queueInputBuffer(InputIndex, 0, Count, LastPtsUs, 0)
              LastPtsUs += Count * 1_000_000L / (SampleRate.toLong() * Channels.toLong() * 2L)
            } else {
              CodecRef.queueInputBuffer(InputIndex, 0, 0, LastPtsUs, 0)
            }
          }
        }
        Drain(0, Info)
      }
    } catch (Failure: Exception) {
      Error = Failure.message
      Running.set(false)
    }
  }

  private fun Drain(TimeoutUs: Long, Info: MediaCodec.BufferInfo): Boolean {
    val CodecRef = Codec ?: return false
    while (true) {
      val OutputIndex = CodecRef.dequeueOutputBuffer(Info, TimeoutUs)
      if (OutputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        if (!MuxerStarted) {
          val OutputFormat = CodecRef.outputFormat
          Track = Muxer?.addTrack(OutputFormat) ?: -1
          if (Track >= 0) {
            Muxer?.start()
            MuxerStarted = true
          }
        }
        continue
      }
      if (OutputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) return false
      if (OutputIndex < 0) continue
      val Output = CodecRef.getOutputBuffer(OutputIndex)
      if (Output != null && Info.size > 0 && MuxerStarted && (Info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
        Muxer?.writeSampleData(Track, Output, Info)
      }
      val End = (Info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
      CodecRef.releaseOutputBuffer(OutputIndex, false)
      if (End) return true
    }
  }

  fun Stop(): String? {
    Running.set(false)
    try {
      Recorder?.stop()
    } catch (_: Exception) {
    }
    Worker?.join(2000)
    Worker = null
    val CodecRef = Codec
    if (CodecRef != null) {
      try {
        val Info = MediaCodec.BufferInfo()
        val Index = CodecRef.dequeueInputBuffer(100000)
        if (Index >= 0) CodecRef.queueInputBuffer(Index, 0, 0, LastPtsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        for (Attempt in 0 until 200) {
          if (Drain(10000, Info)) break
        }
      } catch (_: Exception) {
      }
    }
    try {
      Recorder?.stop()
    } catch (_: Exception) {
    }
    Recorder?.release()
    Recorder = null
    try {
      Codec?.stop()
    } catch (_: Exception) {
    }
    Codec?.release()
    Codec = null
    if (MuxerStarted) {
      try {
        Muxer?.stop()
      } catch (_: Exception) {
      }
    }
    try {
      Muxer?.release()
    } catch (_: Exception) {
    }
    Muxer = null
    MuxerStarted = false
    Track = -1
    Monitor = false
    ReleasePlayer()
    return if (File(Path).exists() && File(Path).length() > 0) Path else null
  }
}
