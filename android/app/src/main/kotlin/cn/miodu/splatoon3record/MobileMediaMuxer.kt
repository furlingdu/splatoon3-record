package cn.miodu.splatoon3record

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

object MobileMediaMuxer {
  fun Mux(VideoPath: String, AudioPath: String, OutputPath: String, AudioOffsetUs: Long): Boolean {
    if (!File(VideoPath).exists() || !File(AudioPath).exists()) return false
    val Target = File(OutputPath)
    Target.parentFile?.mkdirs()
    if (Target.exists()) Target.delete()
    var Video: MediaExtractor? = null
    var Audio: MediaExtractor? = null
    var Muxer: MediaMuxer? = null
    var Started = false
    return try {
      val VideoExtractor = MediaExtractor().apply { setDataSource(VideoPath) }
      Video = VideoExtractor
      val AudioExtractor = MediaExtractor().apply { setDataSource(AudioPath) }
      Audio = AudioExtractor
      val VideoTrack = FindTrack(VideoExtractor, "video/")
      val AudioTrack = FindTrack(AudioExtractor, "audio/")
      if (VideoTrack < 0 || AudioTrack < 0) return false
      VideoExtractor.selectTrack(VideoTrack)
      AudioExtractor.selectTrack(AudioTrack)
      val VideoFormat = VideoExtractor.getTrackFormat(VideoTrack)
      val AudioFormat = AudioExtractor.getTrackFormat(AudioTrack)
      val MuxerValue = MediaMuxer(OutputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      Muxer = MuxerValue
      val OutputVideo = MuxerValue.addTrack(VideoFormat)
      val OutputAudio = MuxerValue.addTrack(AudioFormat)
      MuxerValue.start()
      Started = true
      val Buffer = ByteBuffer.allocateDirect(BufferSize(VideoFormat, AudioFormat))
      val VideoDuration = Duration(VideoFormat)
      val AudioLimit = if (VideoDuration > 0) VideoDuration else Duration(AudioFormat)
      CopyTrack(VideoExtractor, OutputVideo, MuxerValue, Buffer, 0, VideoDuration)
      CopyTrack(AudioExtractor, OutputAudio, MuxerValue, Buffer, AudioOffsetUs, AudioLimit)
      MuxerValue.stop()
      Started = false
      true
    } catch (_: Exception) {
      false
    } finally {
      if (Started) {
        try {
          Muxer?.stop()
        } catch (_: Exception) {
        }
      }
      try {
        Muxer?.release()
      } catch (_: Exception) {
      }
      Video?.release()
      Audio?.release()
      if (!File(OutputPath).exists() || File(OutputPath).length() == 0L) {
        try {
          File(OutputPath).delete()
        } catch (_: Exception) {
        }
      }
    }
  }

  private fun FindTrack(Extractor: MediaExtractor, Prefix: String): Int {
    for (Index in 0 until Extractor.trackCount) {
      val Format = Extractor.getTrackFormat(Index)
      val Mime = Format.getString(MediaFormat.KEY_MIME) ?: ""
      if (Mime.startsWith(Prefix)) return Index
    }
    return -1
  }

  private fun BufferSize(First: MediaFormat, Second: MediaFormat): Int {
    val FirstSize = if (First.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) First.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0
    val SecondSize = if (Second.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) Second.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0
    return maxOf(4 * 1024 * 1024, FirstSize, SecondSize)
  }

  private fun Duration(Format: MediaFormat): Long {
    return if (Format.containsKey(MediaFormat.KEY_DURATION)) Format.getLong(MediaFormat.KEY_DURATION) else -1L
  }

  private fun CopyTrack(Extractor: MediaExtractor, OutputTrack: Int, Muxer: MediaMuxer, Buffer: ByteBuffer, OffsetUs: Long, LimitUs: Long) {
    val Info = MediaCodec.BufferInfo()
    val TrimUs = if (OffsetUs < 0) -OffsetUs else 0L
    val ShiftUs = if (OffsetUs > 0) OffsetUs else 0L
    while (true) {
      Buffer.clear()
      val Size = Extractor.readSampleData(Buffer, 0)
      if (Size < 0) break
      Buffer.position(0)
      Buffer.limit(Size)
      val Time = Extractor.sampleTime
      if (Time < 0) break
      if (Time < TrimUs) {
        Extractor.advance()
        continue
      }
      val Shifted = Time - TrimUs + ShiftUs
      if (LimitUs > 0 && Shifted >= LimitUs) {
        Extractor.advance()
        continue
      }
      Info.set(0, Size, if (Shifted < 0) 0 else Shifted, Extractor.sampleFlags)
      Muxer.writeSampleData(OutputTrack, Buffer, Info)
      Extractor.advance()
    }
  }
}
