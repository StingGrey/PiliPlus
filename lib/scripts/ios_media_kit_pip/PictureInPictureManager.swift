import AVKit
import CoreMedia
import CoreVideo
import Flutter
import QuartzCore
import UIKit

private protocol PictureInPictureManaging: AnyObject {
  func prepare(handle: Int64, isLive: Bool) -> Bool
  func updatePlaybackState(
    handle: Int64,
    isLive: Bool,
    duration: TimeInterval,
    position: TimeInterval
  )
  func setPlaying(handle: Int64, playing: Bool)
  func needsFrame(handle: Int64) -> Bool
  func consumeFrame(handle: Int64, pixelBuffer: CVPixelBuffer, size: CGSize)
  func dispose(handle: Int64)
}

/// Compatibility wrapper: the sample-buffer PiP content source is available on
/// iOS 15 and later, while PiliPlus still supports iOS 14.
public final class PictureInPictureManager: NSObject {
  private let channel: FlutterMethodChannel
  private var implementation: PictureInPictureManaging?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  public func prepare(handle: Int64, isLive: Bool) -> Bool {
    guard #available(iOS 15.0, *),
          AVPictureInPictureController.isPictureInPictureSupported()
    else {
      return false
    }

    if implementation == nil {
      implementation = PictureInPictureManagerIOS15(channel: channel)
    }
    return implementation!.prepare(handle: handle, isLive: isLive)
  }

  public func updatePlaybackState(
    handle: Int64,
    isLive: Bool,
    duration: TimeInterval,
    position: TimeInterval
  ) {
    guard #available(iOS 15.0, *) else { return }
    implementation?.updatePlaybackState(
      handle: handle,
      isLive: isLive,
      duration: duration,
      position: position
    )
  }

  public func setPlaying(handle: Int64, playing: Bool) {
    guard #available(iOS 15.0, *) else { return }
    implementation?.setPlaying(handle: handle, playing: playing)
  }

  public func needsFrame(handle: Int64) -> Bool {
    guard #available(iOS 15.0, *) else { return false }
    return implementation?.needsFrame(handle: handle) ?? false
  }

  public func consumeFrame(
    handle: Int64,
    pixelBuffer: CVPixelBuffer,
    size: CGSize
  ) {
    guard #available(iOS 15.0, *) else { return }
    implementation?.consumeFrame(
      handle: handle,
      pixelBuffer: pixelBuffer,
      size: size
    )
  }

  public func dispose(handle: Int64) {
    guard #available(iOS 15.0, *) else { return }
    implementation?.dispose(handle: handle)
  }
}

@available(iOS 15.0, *)
private final class PictureInPictureManagerIOS15: NSObject,
  PictureInPictureManaging,
  AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  private struct PendingFrame {
    let handle: Int64
    let pixelBuffer: CVPixelBuffer
  }

  private let channel: FlutterMethodChannel
  private let stateLock = NSLock()
  private let frameLock = NSLock()
  private let frameQueue = DispatchQueue(
    label: "com.piliplus.ios_picture_in_picture.frames",
    qos: .userInteractive
  )
  private let sourceView = UIView(frame: .zero)
  private let displayLayer = AVSampleBufferDisplayLayer()

  private var controller: AVPictureInPictureController?
  private var timebase: CMTimebase?
  private var activeHandle: Int64?
  private var isPlaying = false
  private var isLive = false
  private var duration: TimeInterval = 0
  private var isPictureInPictureActive = false
  private var hasPrimingFrame = false
  private var pendingFrame: PendingFrame?
  private var frameDrainScheduled = false
  private var formatDescription: CMVideoFormatDescription?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func prepare(handle: Int64, isLive: Bool) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))

    if activeHandle == handle, controller != nil {
      return true
    }
    disposeCurrentController()

    guard let window = Self.activeWindow() else {
      sendError("找不到可用的 iOS 窗口")
      return false
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
    } catch {
      sendError("配置后台音频失败：\(error.localizedDescription)")
    }

    sourceView.frame = window.bounds
    sourceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sourceView.isUserInteractionEnabled = false
    sourceView.backgroundColor = .clear
    window.insertSubview(sourceView, at: 0)

    displayLayer.frame = sourceView.bounds
    displayLayer.videoGravity = .resizeAspect
    if displayLayer.superlayer == nil {
      sourceView.layer.addSublayer(displayLayer)
    }

    var timebase: CMTimebase?
    let timebaseStatus = CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase
    )
    if timebaseStatus == noErr, let timebase {
      CMTimebaseSetTime(timebase, time: .zero)
      CMTimebaseSetRate(timebase, rate: 0)
      displayLayer.controlTimebase = timebase
      self.timebase = timebase
    } else {
      sendError("创建 PiP 时间基准失败：\(timebaseStatus)")
    }

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.requiresLinearPlayback = isLive

    stateLock.lock()
    activeHandle = handle
    isPlaying = false
    self.isLive = isLive
    duration = 0
    isPictureInPictureActive = false
    hasPrimingFrame = false
    stateLock.unlock()

    self.controller = controller
    return true
  }

  func updatePlaybackState(
    handle: Int64,
    isLive: Bool,
    duration: TimeInterval,
    position: TimeInterval
  ) {
    stateLock.lock()
    guard activeHandle == handle else {
      stateLock.unlock()
      return
    }
    self.isLive = isLive
    self.duration = max(0, duration)
    let safePosition = max(0, min(position, duration > 0 ? duration : position))
    let playing = isPlaying
    stateLock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrentHandle(handle) else { return }
      self.controller?.requiresLinearPlayback = isLive
      if let timebase = self.timebase {
        CMTimebaseSetTime(
          timebase,
          time: CMTime(seconds: safePosition, preferredTimescale: 1000)
        )
        CMTimebaseSetRate(timebase, rate: playing ? 1 : 0)
      }
      self.controller?.invalidatePlaybackState()
    }
  }

  func setPlaying(handle: Int64, playing: Bool) {
    stateLock.lock()
    guard activeHandle == handle else {
      stateLock.unlock()
      return
    }
    if playing, !isPlaying, !isPictureInPictureActive {
      hasPrimingFrame = false
    }
    isPlaying = playing
    stateLock.unlock()

    if !playing {
      clearPendingFrame()
    }

    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrentHandle(handle) else { return }
      if let timebase = self.timebase {
        CMTimebaseSetRate(timebase, rate: playing ? 1 : 0)
      }
      self.controller?.invalidatePlaybackState()
    }
  }

  func needsFrame(handle: Int64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }

    guard activeHandle == handle, isPlaying else { return false }

    // Do not impose an artificial frame-rate cap while PiP is active. Before
    // PiP starts, one frame is enough to prime AVSampleBufferDisplayLayer.
    return isPictureInPictureActive || !hasPrimingFrame
  }

  func consumeFrame(
    handle: Int64,
    pixelBuffer: CVPixelBuffer,
    size _: CGSize
  ) {
    stateLock.lock()
    guard activeHandle == handle else {
      stateLock.unlock()
      return
    }
    stateLock.unlock()

    var shouldScheduleDrain = false
    frameLock.lock()
    pendingFrame = PendingFrame(handle: handle, pixelBuffer: pixelBuffer)
    if !frameDrainScheduled {
      frameDrainScheduled = true
      shouldScheduleDrain = true
    }
    frameLock.unlock()

    if shouldScheduleDrain {
      frameQueue.async { [weak self] in
        self?.drainPendingFrames()
      }
    }
  }

  func dispose(handle: Int64) {
    guard isCurrentHandle(handle) else { return }
    DispatchQueue.main.async { [weak self] in
      self?.disposeCurrentController()
    }
  }

  private func disposeCurrentController() {
    stateLock.lock()
    activeHandle = nil
    isPlaying = false
    isLive = false
    duration = 0
    isPictureInPictureActive = false
    hasPrimingFrame = false
    stateLock.unlock()

    if controller?.isPictureInPictureActive == true {
      controller?.stopPictureInPicture()
    }
    controller?.delegate = nil
    controller = nil

    frameQueue.sync {
      frameLock.lock()
      pendingFrame = nil
      frameDrainScheduled = false
      frameLock.unlock()
      formatDescription = nil
      displayLayer.flushAndRemoveImage()
    }

    displayLayer.controlTimebase = nil
    displayLayer.removeFromSuperlayer()
    sourceView.removeFromSuperview()
    timebase = nil
  }

  private func clearPendingFrame() {
    frameLock.lock()
    pendingFrame = nil
    frameLock.unlock()
  }

  private func drainPendingFrames() {
    guard displayLayer.isReadyForMoreMediaData else {
      finishFrameDrain()
      return
    }

    frameLock.lock()
    guard let frame = pendingFrame else {
      frameDrainScheduled = false
      frameLock.unlock()
      return
    }
    pendingFrame = nil
    frameLock.unlock()

    if isCurrentHandle(frame.handle) {
      autoreleasepool {
        if displayLayer.status == .failed {
          displayLayer.flush()
          formatDescription = nil
        }
        if let sampleBuffer = makeSampleBuffer(
          pixelBuffer: frame.pixelBuffer
        ) {
          displayLayer.enqueue(sampleBuffer)
          markPrimingFrameEnqueued(handle: frame.handle)
        }
      }
    }

    finishFrameDrain()
  }

  private func finishFrameDrain() {
    frameLock.lock()
    frameDrainScheduled = false
    let shouldRetry = pendingFrame != nil
    frameLock.unlock()

    // The next decoded frame normally retries the drain. Handle the narrow
    // race where the display layer became ready while the drain was stopping.
    if shouldRetry, displayLayer.isReadyForMoreMediaData {
      scheduleFrameDrain()
    }
  }

  private func scheduleFrameDrain() {
    frameLock.lock()
    guard pendingFrame != nil, !frameDrainScheduled else {
      frameLock.unlock()
      return
    }
    frameDrainScheduled = true
    frameLock.unlock()

    frameQueue.async { [weak self] in
      self?.drainPendingFrames()
    }
  }

  private func makeSampleBuffer(
    pixelBuffer: CVPixelBuffer
  ) -> CMSampleBuffer? {
    let description: CMVideoFormatDescription
    if let cached = formatDescription,
       CMVideoFormatDescriptionMatchesImageBuffer(
         cached,
         imageBuffer: pixelBuffer
       )
    {
      description = cached
    } else {
      var created: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &created
      )
      guard status == noErr, let created else {
        sendError("创建 PiP 视频格式失败：\(status)")
        return nil
      }
      formatDescription = created
      description = created
    }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: description,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else {
      sendError("创建 PiP 视频帧失败：\(status)")
      return nil
    }

    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: true
    ), CFArrayGetCount(attachments) > 0 {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(
          kCMSampleAttachmentKey_DisplayImmediately
        ).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }

    return sampleBuffer
  }

  private func markPrimingFrameEnqueued(handle: Int64) {
    stateLock.lock()
    if activeHandle == handle, !isPictureInPictureActive {
      hasPrimingFrame = true
    }
    stateLock.unlock()
  }

  private func isCurrentHandle(_ handle: Int64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return activeHandle == handle
  }

  private func sendError(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod(
        "PictureInPicture.Error",
        arguments: ["message": message]
      )
    }
  }

  private static func activeWindow() -> UIWindow? {
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    stateLock.lock()
    isPlaying = playing
    stateLock.unlock()
    channel.invokeMethod(
      "PictureInPicture.SetPlaying",
      arguments: ["playing": playing]
    )
    pictureInPictureController.invalidatePlaybackState()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _: AVPictureInPictureController
  ) -> CMTimeRange {
    stateLock.lock()
    let isLive = self.isLive
    let duration = self.duration
    stateLock.unlock()

    if isLive {
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    // Keep the range finite even before media-kit reports metadata; otherwise
    // iOS labels ordinary on-demand videos as live streams.
    let finiteDuration = duration > 0 ? duration : 3600
    return CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: finiteDuration, preferredTimescale: 1000)
    )
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _: AVPictureInPictureController
  ) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return !isPlaying
  }

  func pictureInPictureController(
    _: AVPictureInPictureController,
    didTransitionToRenderSize _: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _: AVPictureInPictureController,
    skipByInterval interval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let seconds = CMTimeGetSeconds(interval)
    if seconds.isFinite {
      channel.invokeMethod(
        "PictureInPicture.SkipByInterval",
        arguments: ["seconds": seconds]
      )
    }
    completionHandler()
  }

  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
    _: AVPictureInPictureController
  ) -> Bool {
    return false
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    stateLock.lock()
    isPictureInPictureActive = true
    hasPrimingFrame = false
    stateLock.unlock()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    stateLock.lock()
    isPictureInPictureActive = false
    hasPrimingFrame = true
    stateLock.unlock()
  }

  func pictureInPictureController(
    _: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    sendError("启动系统画中画失败：\(error.localizedDescription)")
  }

  func pictureInPictureController(
    _: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
      completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
