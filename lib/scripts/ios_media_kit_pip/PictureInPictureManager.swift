import AVKit
import CoreMedia
import CoreVideo
import Flutter
import QuartzCore
import UIKit

/// Compatibility wrapper: the sample-buffer PiP content source is available on
/// iOS 15 and later, while PiliPlus still supports iOS 14.
public final class PictureInPictureManager: NSObject {
  private let channel: FlutterMethodChannel

  @available(iOS 15.0, *)
  private var implementation: PictureInPictureManagerIOS15?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  public func prepare(handle: Int64) -> Bool {
    guard #available(iOS 15.0, *),
          AVPictureInPictureController.isPictureInPictureSupported()
    else {
      return false
    }

    if implementation == nil {
      implementation = PictureInPictureManagerIOS15(channel: channel)
    }
    return implementation!.prepare(handle: handle)
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
  AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  private let channel: FlutterMethodChannel
  private let stateLock = NSLock()
  private let sourceView = UIView(frame: .zero)
  private let displayLayer = AVSampleBufferDisplayLayer()

  private var controller: AVPictureInPictureController?
  private var activeHandle: Int64?
  private var isPlaying = false
  private var isPictureInPictureActive = false
  private var lastFrameTime: CFTimeInterval = 0
  private var formatDescription: CMVideoFormatDescription?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func prepare(handle: Int64) -> Bool {
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

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: contentSource)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.requiresLinearPlayback = true

    stateLock.lock()
    activeHandle = handle
    isPlaying = false
    isPictureInPictureActive = false
    lastFrameTime = 0
    stateLock.unlock()

    self.controller = controller
    return true
  }

  func setPlaying(handle: Int64, playing: Bool) {
    stateLock.lock()
    guard activeHandle == handle else {
      stateLock.unlock()
      return
    }
    isPlaying = playing
    stateLock.unlock()

    DispatchQueue.main.async { [weak self] in
      self?.controller?.invalidatePlaybackState()
    }
  }

  func needsFrame(handle: Int64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }

    guard activeHandle == handle, isPlaying else { return false }
    let now = CACurrentMediaTime()
    let minimumInterval = isPictureInPictureActive ? (1.0 / 30.0) : (1.0 / 12.0)
    guard now - lastFrameTime >= minimumInterval else { return false }
    lastFrameTime = now
    return true
  }

  func consumeFrame(
    handle: Int64,
    pixelBuffer: CVPixelBuffer,
    size _: CGSize
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCurrentHandle(handle) else { return }

      if self.displayLayer.status == .failed {
        self.displayLayer.flush()
      }
      self.displayLayer.frame = self.sourceView.bounds

      let description: CMVideoFormatDescription
      if let cached = self.formatDescription,
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
          self.sendError("创建 PiP 视频格式失败：\(status)")
          return
        }
        self.formatDescription = created
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
        self.sendError("创建 PiP 视频帧失败：\(status)")
        return
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

      self.displayLayer.enqueue(sampleBuffer)
    }
  }

  func dispose(handle: Int64) {
    guard isCurrentHandle(handle) else { return }
    DispatchQueue.main.async { [weak self] in
      self?.disposeCurrentController()
    }
  }

  private func disposeCurrentController() {
    if controller?.isPictureInPictureActive == true {
      controller?.stopPictureInPicture()
    }
    controller?.delegate = nil
    controller = nil
    displayLayer.flushAndRemoveImage()
    displayLayer.removeFromSuperlayer()
    sourceView.removeFromSuperview()
    formatDescription = nil

    stateLock.lock()
    activeHandle = nil
    isPlaying = false
    isPictureInPictureActive = false
    lastFrameTime = 0
    stateLock.unlock()
  }

  private func isCurrentHandle(_ handle: Int64) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return activeHandle == handle
  }

  private func sendError(_ message: String) {
    channel.invokeMethod(
      "PictureInPicture.Error",
      arguments: ["message": message]
    )
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
    return CMTimeRange(start: .zero, duration: .positiveInfinity)
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
    skipByInterval _: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
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
    stateLock.unlock()
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    stateLock.lock()
    isPictureInPictureActive = false
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
