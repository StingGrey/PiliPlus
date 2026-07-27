param(
    [string] $MediaKitVideoRoot = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Replace-Exact {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $OldText,
        [Parameter(Mandatory = $true)] [string] $NewText
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $count = [regex]::Matches($content, [regex]::Escape($OldText)).Count
    if ($count -ne 1) {
        throw "Expected exactly one source block in '$Path', found $count."
    }

    $updated = $content.Replace($OldText, $NewText)
    Set-Content -LiteralPath $Path -Value $updated -Encoding utf8NoBOM -NoNewline
}

$workspace = if ($env:GITHUB_WORKSPACE) {
    $env:GITHUB_WORKSPACE
}
else {
    $parent = Join-Path $PSScriptRoot '..'
    (Resolve-Path -LiteralPath (Join-Path $parent '..')).Path
}

$mediaKitVideoPath = if ([string]::IsNullOrWhiteSpace($MediaKitVideoRoot)) {
    $packageConfigPath = Join-Path (Join-Path $workspace '.dart_tool') 'package_config.json'
    $packageConfigFile = Get-Item -LiteralPath $packageConfigPath
    $packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $mediaKitPackage = $packageConfig.packages |
        Where-Object { $_.name -eq 'media_kit_video' } |
        Select-Object -First 1
    if ($null -eq $mediaKitPackage) {
        throw 'media_kit_video was not found in package_config.json.'
    }

    $packageUri = [Uri]::new(
        [string] $mediaKitPackage.rootUri,
        [UriKind]::RelativeOrAbsolute
    )
    if ($packageUri.IsAbsoluteUri) {
        if ($packageUri.Scheme -ne [Uri]::UriSchemeFile) {
            throw "Unsupported media_kit_video root URI: $packageUri"
        }
        $packageUri.LocalPath.TrimEnd([IO.Path]::DirectorySeparatorChar)
    }
    else {
        $relativeRoot = [Uri]::UnescapeDataString($packageUri.OriginalString)
        $relativeRoot = $relativeRoot.Replace(
            '/',
            [IO.Path]::DirectorySeparatorChar
        )
        [IO.Path]::GetFullPath(
            [IO.Path]::Combine(
                $packageConfigFile.Directory.FullName,
                $relativeRoot
            )
        ).TrimEnd([IO.Path]::DirectorySeparatorChar)
    }
}
else {
    (Resolve-Path -LiteralPath $MediaKitVideoRoot).Path
}
$mediaKitRepoPath = Split-Path -Parent $mediaKitVideoPath
$pluginPath = Join-Path (Join-Path (Join-Path (Join-Path $mediaKitVideoPath 'ios') 'Classes') 'plugin') 'common'

$managerTemplate = Join-Path (Join-Path (Join-Path (Join-Path $workspace 'lib') 'scripts') 'ios_media_kit_pip') 'PictureInPictureManager.swift'
$managerTarget = Join-Path $pluginPath 'PictureInPictureManager.swift'
Copy-Item -LiteralPath $managerTemplate -Destination $managerTarget -Force

$pluginFile = Join-Path $pluginPath 'MediaKitVideoPlugin.swift'
Replace-Exact -Path $pluginFile -OldText @'
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"
'@ -NewText @'
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"
  private static let PIP_CHANNEL_NAME = "com.piliplus/ios_picture_in_picture"
'@

Replace-Exact -Path $pluginFile -OldText @'
    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
'@ -NewText @'
    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let pipChannel = FlutterMethodChannel(
      name: PIP_CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      pipChannel: pipChannel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addMethodCallDelegate(instance, channel: pipChannel)
'@

Replace-Exact -Path $pluginFile -OldText @'
  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let utils: UtilsProtocol?

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    videoOutputManager = VideoOutputManager(
      registry: registry
    )
    self.utils = utils
  }
'@ -NewText @'
  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let pictureInPictureManager: PictureInPictureManager
  private let utils: UtilsProtocol?

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    pipChannel: FlutterMethodChannel,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    videoOutputManager = VideoOutputManager(
      registry: registry
    )
    pictureInPictureManager = PictureInPictureManager(channel: pipChannel)
    self.utils = utils
    super.init()

    videoOutputManager.shouldOutputFrame = { [weak self] handle in
      return self?.pictureInPictureManager.needsFrame(handle: handle) ?? false
    }
    videoOutputManager.frameOutputCallback = {
      [weak self] handle, pixelBuffer, size in
      self?.pictureInPictureManager.consumeFrame(
        handle: handle,
        pixelBuffer: pixelBuffer,
        size: size
      )
    }
  }
'@

Replace-Exact -Path $pluginFile -OldText @'
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    default:
'@ -NewText @'
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    case "PictureInPicture.Prepare":
      let args = call.arguments as? [String: Any]
      let handle = Int64(args?["handle"] as? String ?? "")
      guard let handle else {
        return result(FlutterError(
          code: "invalid_handle",
          message: "PictureInPicture.Prepare requires a valid handle.",
          details: nil
        ))
      }
      result(pictureInPictureManager.prepare(handle: handle))
    case "PictureInPicture.SetPlaying":
      let args = call.arguments as? [String: Any]
      let handle = Int64(args?["handle"] as? String ?? "")
      let playing = args?["playing"] as? Bool
      guard let handle, let playing else {
        return result(FlutterError(
          code: "invalid_arguments",
          message: "PictureInPicture.SetPlaying requires handle and playing.",
          details: nil
        ))
      }
      pictureInPictureManager.setPlaying(handle: handle, playing: playing)
      result(nil)
    case "PictureInPicture.Dispose":
      let args = call.arguments as? [String: Any]
      let handle = Int64(args?["handle"] as? String ?? "")
      guard let handle else {
        return result(FlutterError(
          code: "invalid_handle",
          message: "PictureInPicture.Dispose requires a valid handle.",
          details: nil
        ))
      }
      pictureInPictureManager.dispose(handle: handle)
      result(nil)
    default:
'@

$outputFile = Join-Path $pluginPath 'VideoOutput.swift'
Replace-Exact -Path $outputFile -OldText @'
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void
'@ -NewText @'
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void
  public typealias ShouldOutputFrame = (Int64) -> Bool
  public typealias FrameOutputCallback = (Int64, CVPixelBuffer, CGSize) -> Void
'@

Replace-Exact -Path $outputFile -OldText @'
  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
'@ -NewText @'
  private let handle: OpaquePointer
  private let handleValue: Int64
  private let enableHardwareAcceleration: Bool
  private let shouldOutputFrame: ShouldOutputFrame?
  private let frameOutputCallback: FrameOutputCallback?
'@

Replace-Exact -Path $outputFile -OldText @'
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
'@ -NewText @'
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback,
    shouldOutputFrame: ShouldOutputFrame?,
    frameOutputCallback: FrameOutputCallback?
'@

Replace-Exact -Path $outputFile -OldText @'
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")
'@ -NewText @'
    handleValue = handle
    let opaqueHandle = OpaquePointer(bitPattern: Int(handle))
    assert(opaqueHandle != nil, "handle casting")
'@

Replace-Exact -Path $outputFile -OldText @'
    self.handle = handle!
    width = configuration.width
'@ -NewText @'
    self.handle = opaqueHandle!
    self.shouldOutputFrame = shouldOutputFrame
    self.frameOutputCallback = frameOutputCallback
    width = configuration.width
'@

Replace-Exact -Path $outputFile -OldText @'
    texture.render(size)
    DispatchQueue.main.sync { [weak self] in
'@ -NewText @'
    texture.render(size)
    if shouldOutputFrame?(handleValue) == true,
       let pixelBuffer = texture.copyPixelBuffer()?.takeRetainedValue()
    {
      frameOutputCallback?(handleValue, pixelBuffer, size)
    }
    DispatchQueue.main.sync { [weak self] in
'@

$managerFile = Join-Path $pluginPath 'VideoOutputManager.swift'
Replace-Exact -Path $managerFile -OldText @'
  private let registry: FlutterTextureRegistry
  private var videoOutputs = [Int64: VideoOutput]()
'@ -NewText @'
  private let registry: FlutterTextureRegistry
  private var videoOutputs = [Int64: VideoOutput]()
  public var shouldOutputFrame: VideoOutput.ShouldOutputFrame?
  public var frameOutputCallback: VideoOutput.FrameOutputCallback?
'@

Replace-Exact -Path $managerFile -OldText @'
      configuration: configuration,
      registry: self.registry,
      textureUpdateCallback: textureUpdateCallback
'@ -NewText @'
      configuration: configuration,
      registry: self.registry,
      textureUpdateCallback: textureUpdateCallback,
      shouldOutputFrame: shouldOutputFrame,
      frameOutputCallback: frameOutputCallback
'@

Write-Host "Patched media-kit iOS PiP sources in $mediaKitRepoPath"
