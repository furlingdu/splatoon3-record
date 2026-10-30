import AVFoundation
import Foundation

final class MacRecorder {
  private struct Pending {
    let Sample: CMSampleBuffer
    let Video: Bool
    let Time: CMTime
  }

  private let Directory: String
  private let Width: Int
  private let Height: Int
  private let Fps: Int
  private let Quality: Int
  private let SegmentSeconds: Int
  private let HasAudio: Bool
  private let QueueLock = NSCondition()
  private let StatsLock = NSLock()
  private var PendingSamples: [Pending] = []
  private var Worker: Thread?
  private var Writer: AVAssetWriter?
  private var VideoInput: AVAssetWriterInput?
  private var AudioInput: AVAssetWriterInput?
  private var CurrentURL: URL?
  private var Started = false
  private var Stopping = false
  private var Active = false
  private var SegmentWritten = false
  private var SegmentStart = CMTime.zero
  private var WrittenFrames = 0
  private var DroppedFrames = 0
  private let MaxPending = 18
  var OnError: ((String) -> Void)?

  init(Directory: String, Width: Int, Height: Int, Fps: Int, Quality: Int, SegmentSeconds: Int, Audio: Bool) {
    self.Directory = Directory
    self.Width = Width
    self.Height = Height
    self.Fps = max(1, Fps)
    self.Quality = Quality
    self.SegmentSeconds = max(1, SegmentSeconds)
    self.HasAudio = Audio
  }

  deinit {
    Stop()
  }

  @discardableResult
  func Start() -> Bool {
    QueueLock.lock()
    if Active {
      QueueLock.unlock()
      return true
    }
    PendingSamples.removeAll()
    Stopping = false
    Active = true
    WrittenFrames = 0
    DroppedFrames = 0
    SegmentWritten = false
    QueueLock.unlock()
    guard CreateWriter() else {
      QueueLock.lock()
      Active = false
      QueueLock.unlock()
      return false
    }
    let Task = Thread { [weak self] in
      self?.Run()
    }
    Task.name = "splatoon3record.mac.record"
    Task.qualityOfService = .userInitiated
    QueueLock.lock()
    Worker = Task
    QueueLock.unlock()
    Task.start()
    return true
  }

  func AppendVideo(_ Sample: CMSampleBuffer) {
    Enqueue(Sample, Video: true)
  }

  func AppendAudio(_ Sample: CMSampleBuffer) {
    Enqueue(Sample, Video: false)
  }

  func Stop() {
    QueueLock.lock()
    if !Active {
      QueueLock.unlock()
      return
    }
    Stopping = true
    let Task = Worker
    QueueLock.broadcast()
    QueueLock.unlock()
    let Deadline = Date().addingTimeInterval(8)
    while Task?.isExecuting == true && Date() < Deadline {
      Thread.sleep(forTimeInterval: 0.002)
    }
  }

  var Written: Int {
    StatsLock.lock()
    let Value = WrittenFrames
    StatsLock.unlock()
    return Value
  }

  var Dropped: Int {
    StatsLock.lock()
    let Value = DroppedFrames
    StatsLock.unlock()
    return Value
  }

  private func Enqueue(_ Sample: CMSampleBuffer, Video: Bool) {
    let Time = CMSampleBufferGetPresentationTimeStamp(Sample)
    if !Time.isValid {
      return
    }
    QueueLock.lock()
    guard Active, !Stopping else {
      QueueLock.unlock()
      return
    }
    if PendingSamples.count >= MaxPending {
      PendingSamples.removeFirst()
      StatsLock.lock()
      DroppedFrames += 1
      StatsLock.unlock()
    }
    PendingSamples.append(Pending(Sample: Sample, Video: Video, Time: Time))
    QueueLock.signal()
    QueueLock.unlock()
  }

  private func Run() {
    while true {
      QueueLock.lock()
      while PendingSamples.isEmpty && !Stopping {
        QueueLock.wait(until: Date().addingTimeInterval(0.1))
      }
      if PendingSamples.isEmpty && Stopping {
        QueueLock.unlock()
        break
      }
      let Item = PendingSamples.removeFirst()
      QueueLock.unlock()
      Write(Item)
    }
    Finish()
    QueueLock.lock()
    Active = false
    Worker = nil
    QueueLock.broadcast()
    QueueLock.unlock()
  }

  private func Write(_ Item: Pending) {
    guard let AssetWriter = Writer else {
      return
    }
    if !Started {
      guard Item.Video else {
        return
      }
      guard AssetWriter.startWriting() else {
        OnError?("无法启动视频编码：\(AssetWriter.error?.localizedDescription ?? "未知")")
        StopWriter()
        return
      }
      AssetWriter.startSession(atSourceTime: Item.Time)
      SegmentStart = Item.Time
      Started = true
    }
    guard let Input = Item.Video ? VideoInput : AudioInput else {
      return
    }
    var Waited = 0.0
    while !Input.isReadyForMoreMediaData {
      if IsStopping() || AssetWriter.status == .failed || AssetWriter.status == .cancelled {
        return
      }
      Thread.sleep(forTimeInterval: 0.001)
      Waited += 0.001
      if Waited > 2.0 {
        OnError?("视频编码器长时间未就绪")
        return
      }
    }
    if !Input.append(Item.Sample) {
      OnError?("写入录制数据失败：\(AssetWriter.error?.localizedDescription ?? "未知")")
      return
    }
    if Item.Video {
      StatsLock.lock()
      WrittenFrames += 1
      StatsLock.unlock()
      SegmentWritten = true
      if CMTimeGetSeconds(CMTimeSubtract(Item.Time, SegmentStart)) >= Double(SegmentSeconds) {
        Finish()
        if !CreateWriter() {
          StopWriter()
        }
      }
    }
  }

  private func Finish() {
    VideoInput?.markAsFinished()
    AudioInput?.markAsFinished()
    guard let AssetWriter = Writer else {
      Reset()
      return
    }
    let Semaphore = DispatchSemaphore(value: 0)
    AssetWriter.finishWriting {
      Semaphore.signal()
    }
    _ = Semaphore.wait(timeout: .now() + 8)
    if !SegmentWritten, let Target = CurrentURL {
      try? FileManager.default.removeItem(at: Target)
    }
    Reset()
  }

  private func Reset() {
    Writer = nil
    VideoInput = nil
    AudioInput = nil
    CurrentURL = nil
    Started = false
    SegmentWritten = false
    SegmentStart = .zero
  }

  private func CreateWriter() -> Bool {
    Reset()
    let Folder = URL(fileURLWithPath: Directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: Folder, withIntermediateDirectories: true, attributes: nil)
    let Target = Folder.appendingPathComponent(FileName())
    try? FileManager.default.removeItem(at: Target)
    guard let AssetWriter = try? AVAssetWriter(outputURL: Target, fileType: .mp4) else {
      OnError?("无法创建录制文件：\(Target.path)")
      return false
    }
    let VideoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Width,
      AVVideoHeightKey: Height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Bitrate(),
        AVVideoMaxKeyFrameIntervalKey: Fps * 2,
        AVVideoExpectedSourceFrameRateKey: Fps,
        AVVideoAllowFrameReorderingKey: false,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    let Video = AVAssetWriterInput(mediaType: .video, outputSettings: VideoSettings)
    Video.expectsMediaDataInRealTime = true
    guard AssetWriter.canAdd(Video) else {
      OnError?("无法创建视频编码通道")
      return false
    }
    AssetWriter.add(Video)
    var Audio: AVAssetWriterInput?
    if HasAudio {
      let AudioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192000,
      ]
      let Input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioSettings)
      Input.expectsMediaDataInRealTime = true
      if AssetWriter.canAdd(Input) {
        AssetWriter.add(Input)
        Audio = Input
      }
    }
    Writer = AssetWriter
    VideoInput = Video
    AudioInput = Audio
    CurrentURL = Target
    return true
  }

  private func StopWriter() {
    QueueLock.lock()
    Stopping = true
    PendingSamples.removeAll()
    QueueLock.broadcast()
    QueueLock.unlock()
  }

  private func IsStopping() -> Bool {
    QueueLock.lock()
    let Value = Stopping
    QueueLock.unlock()
    return Value
  }

  private func Bitrate() -> Int {
    let Pixels = Double(Width) * Double(Height) * Double(Fps)
    let Ratio = min(0.18, max(0.05, 0.20 - Double(Quality) * 0.0045))
    return min(80000000, max(6000000, Int(Pixels * Ratio)))
  }

  private func FileName() -> String {
    let Formatter = DateFormatter()
    Formatter.locale = Locale(identifier: "en_US_POSIX")
    Formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "Cache-\(Formatter.string(from: Date())).mp4"
  }
}
