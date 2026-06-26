import AVFoundation
import ScreenCaptureKit
import Carbon
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  var subtitleOverlay: SubtitleOverlay?
  var screenRecorder: ScreenRecorder?
  var desktopGrabber: AnyObject?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    let overlay = SubtitleOverlay()
    self.subtitleOverlay = overlay
    let channel = FlutterMethodChannel(
      name: "xiaoli/desktop_subtitle",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "show":
        overlay.show()
        result(nil)
      case "hide":
        overlay.hide()
        result(nil)
      case "update":
        if let args = call.arguments as? [String: Any],
          let text = args["text"] as? String
        {
          overlay.update(text)
        }
        result(nil)
      case "setOpacity":
        if let args = call.arguments as? [String: Any],
          let a = args["opacity"] as? Double
        {
          overlay.setOpacity(a)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let winChannel = FlutterMethodChannel(
      name: "xiaoli/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    winChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "setMini":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        self?.setMini(on)
        result(nil)
      case "setBackgroundRun":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        UserDefaults.standard.set(on, forKey: "backgroundRun")
        result(nil)
      case "backgroundRunEnabled":
        result(UserDefaults.standard.bool(forKey: "backgroundRun"))
      case "setHotkey":
        let a = call.arguments as? [String: Any]
        let on = a?["on"] as? Bool ?? false
        let code = UInt32((a?["code"] as? Int) ?? Int(kVK_ANSI_P))
        let mods = UInt32((a?["mods"] as? Int) ?? Int(cmdKey | optionKey))
        self?.setHotkey(on, code, mods)
        result(nil)
      case "hotkeyEnabled":
        result(UserDefaults.standard.bool(forKey: "hotkeyEnabled"))
      case "setHideHotkey":
        let a = call.arguments as? [String: Any]
        let on = a?["on"] as? Bool ?? false
        let code = UInt32((a?["code"] as? Int) ?? Int(kVK_ANSI_H))
        let mods = UInt32((a?["mods"] as? Int) ?? Int(cmdKey | optionKey))
        self?.setHideHotkey(on, code, mods)
        result(nil)
      case "hideHotkeyEnabled":
        result(UserDefaults.standard.bool(forKey: "hideHotkeyEnabled"))
      case "setBlockQuit":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        UserDefaults.standard.set(on, forKey: "blockQuit")
        result(nil)
      case "blockQuitEnabled":
        result(UserDefaults.standard.bool(forKey: "blockQuit"))
      case "setQuitPassword":
        let a = call.arguments as? [String: Any]
        UserDefaults.standard.set(a?["on"] as? Bool ?? false, forKey: "quitNeedsPassword")
        UserDefaults.standard.set(a?["hash"] as? String ?? "", forKey: "appPwdHash")
        result(nil)
      case "setAlwaysOnTop":
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        self?.level = on ? .floating : .normal
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // 「打开方式」：把双击/打开的文件路径交给 Dart 播放（getPending 拉启动时缓存的）。
    let openCh = FlutterMethodChannel(
      name: "xiaoli/openfile",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    openCh.setMethodCallHandler { (call, result) in
      if call.method == "getPending" {
        let f = AppDelegate.pendingFiles
        AppDelegate.pendingFiles = []
        result(f)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    AppDelegate.openChannel = openCh

    // 系统级录屏：start 开始录短片段(回调 "clip" 把路径给 Dart 上传)，stop 停止。
    let recCh = FlutterMethodChannel(
      name: "xiaoli/screenrec",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    recCh.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "start":
        if self?.screenRecorder == nil { self?.screenRecorder = ScreenRecorder() }
        self?.screenRecorder?.onClip = { path in
          DispatchQueue.main.async { recCh.invokeMethod("clip", arguments: path) }
        }
        let ok = self?.screenRecorder?.start() ?? false
        result(ok)
      case "stop":
        self?.screenRecorder?.stop()
        self?.screenRecorder = nil
        result(nil)
      case "startDesktop":
        if #available(macOS 13.0, *) {
          let g = SCKFrameGrabber()
          g.onFrame = { data in
            DispatchQueue.main.async {
              recCh.invokeMethod("frame", arguments: FlutterStandardTypedData(bytes: data))
            }
          }
          g.start()
          self?.desktopGrabber = g
          result(true)
        } else {
          result(false)
        }
      case "stopDesktop":
        if #available(macOS 13.0, *) { (self?.desktopGrabber as? SCKFrameGrabber)?.stop() }
        self?.desktopGrabber = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    if UserDefaults.standard.bool(forKey: "hotkeyEnabled") {
      let d = UserDefaults.standard
      let code = d.integer(forKey: "hotkeyCode")
      let mods = d.integer(forKey: "hotkeyMods")
      setHotkey(
        true,
        UInt32(code == 0 ? Int(kVK_ANSI_P) : code),
        UInt32(mods == 0 ? Int(cmdKey | optionKey) : mods))
    }
    if UserDefaults.standard.bool(forKey: "hideHotkeyEnabled") {
      let d = UserDefaults.standard
      let code = d.integer(forKey: "hideHotkeyCode")
      let mods = d.integer(forKey: "hideHotkeyMods")
      setHideHotkey(
        true,
        UInt32(code == 0 ? Int(kVK_ANSI_H) : code),
        UInt32(mods == 0 ? Int(cmdKey | optionKey) : mods))
    }

    super.awakeFromNib()
  }

  // 全局快捷键：唤起(id=1) / 隐藏(id=2)。Carbon 热键无需辅助功能权限，组合可自定义。
  private var hotKeyRef: EventHotKeyRef?
  private var hideHotKeyRef: EventHotKeyRef?
  private var hotkeyHandlerInstalled = false

  private func installHotkeyHandler() {
    if hotkeyHandlerInstalled { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { (_, event, _) -> OSStatus in
        var hk = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &hk)
        let id = hk.id
        DispatchQueue.main.async {
          if id == 2 {
            // 退出原生全屏（若有），再强制隐藏。orderOut 忽略 canHide，
            // 修复播视频时 media_kit 把窗口设为不可隐藏导致 NSApp.hide 失效。
            for w in NSApp.windows where w.styleMask.contains(.fullScreen) {
              w.toggleFullScreen(nil)
            }
            for w in NSApp.windows {
              w.canHide = true
              w.orderOut(nil)
            }
            NSApp.hide(nil)
          } else {
            NSApp.activate(ignoringOtherApps: true)
            for w in NSApp.windows {
              w.makeKeyAndOrderFront(nil)
            }
          }
        }
        return noErr
      }, 1, &spec, nil, nil)
    hotkeyHandlerInstalled = true
  }

  func setHotkey(_ on: Bool, _ keyCode: UInt32, _ modifiers: UInt32) {
    let d = UserDefaults.standard
    d.set(on, forKey: "hotkeyEnabled")
    d.set(Int(keyCode), forKey: "hotkeyCode")
    d.set(Int(modifiers), forKey: "hotkeyMods")
    if let r = hotKeyRef {
      UnregisterEventHotKey(r)
      hotKeyRef = nil
    }
    if on {
      installHotkeyHandler()
      let id = EventHotKeyID(signature: OSType(0x584C_5059), id: 1)
      RegisterEventHotKey(
        keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
  }

  func setHideHotkey(_ on: Bool, _ keyCode: UInt32, _ modifiers: UInt32) {
    let d = UserDefaults.standard
    d.set(on, forKey: "hideHotkeyEnabled")
    d.set(Int(keyCode), forKey: "hideHotkeyCode")
    d.set(Int(modifiers), forKey: "hideHotkeyMods")
    if let r = hideHotKeyRef {
      UnregisterEventHotKey(r)
      hideHotKeyRef = nil
    }
    if on {
      installHotkeyHandler()
      let id = EventHotKeyID(signature: OSType(0x584C_5059), id: 2)
      RegisterEventHotKey(
        keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hideHotKeyRef)
    }
  }

  // 后台运行开启时，点关闭按钮只隐藏窗口（app 留在后台，Dock 点击可重开）。
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if UserDefaults.standard.bool(forKey: "backgroundRun") {
      self.orderOut(nil)
      return false
    }
    return true
  }

  // 小窗播放：把主窗缩成置顶悬浮小窗，浮在所有应用之上。
  private var savedFrame: NSRect?
  func setMini(_ on: Bool) {
    if on {
      if savedFrame == nil { savedFrame = self.frame }
      self.level = .floating
      self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      let w: CGFloat = 480
      let h: CGFloat = 300
      if let scr = NSScreen.main?.visibleFrame {
        self.setFrame(
          NSRect(x: scr.maxX - w - 24, y: scr.minY + 24, width: w, height: h),
          display: true, animate: true)
      }
    } else {
      self.level = .normal
      self.collectionBehavior = [.fullScreenPrimary]
      if let f = savedFrame {
        self.setFrame(f, display: true, animate: true)
        savedFrame = nil
      }
    }
  }
}

/// 桌面悬浮字幕：贴屏幕顶部、置顶、半透明、可整窗拖动。
class SubtitleOverlay {
  private var panel: NSPanel?
  private var label: NSTextField?

  func show() {
    if let p = panel {
      p.orderFrontRegardless()
      return
    }
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let w: CGFloat = 920
    let h: CGFloat = 72
    let x = screen.midX - w / 2
    let y = screen.maxY - h - 70
    let p = NSPanel(
      contentRect: NSRect(x: x, y: y, width: w, height: h),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    p.level = .statusBar
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false
    p.isMovableByWindowBackground = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let lbl = NSTextField(labelWithString: "")
    lbl.frame = NSRect(x: 0, y: 0, width: w, height: h)
    lbl.autoresizingMask = [.width, .height]
    lbl.alignment = .center
    lbl.font = NSFont.boldSystemFont(ofSize: 30)
    lbl.textColor = .white
    lbl.backgroundColor = NSColor.black.withAlphaComponent(0.5)
    lbl.drawsBackground = true
    lbl.isBezeled = false
    lbl.isEditable = false
    lbl.isSelectable = false
    lbl.lineBreakMode = .byWordWrapping
    lbl.maximumNumberOfLines = 2
    lbl.wantsLayer = true
    lbl.layer?.cornerRadius = 10
    lbl.isHidden = true
    let sh = NSShadow()
    sh.shadowColor = .black
    sh.shadowBlurRadius = 4
    sh.shadowOffset = NSSize(width: 0, height: -1)
    lbl.shadow = sh
    p.contentView?.addSubview(lbl)
    p.orderFrontRegardless()
    self.panel = p
    self.label = lbl
  }

  func update(_ text: String) {
    label?.stringValue = text
    label?.isHidden = text.isEmpty
  }

  /// 背景框透明度（0=只剩文字，1=纯黑底）；文字始终不透明保证可读。
  private var bgAlpha: CGFloat = 0.5
  func setOpacity(_ a: Double) {
    bgAlpha = CGFloat(max(0.0, min(1.0, a)))
    label?.backgroundColor = NSColor.black.withAlphaComponent(bgAlpha)
  }

  func hide() {
    panel?.orderOut(nil)
    panel = nil
    label = nil
  }
}

/// 系统级录屏：用 AVFoundation 抓主显示器，录成短 H.264 片段(.mov)。
/// 每段 ~3s，录完回调路径给 Dart 上传，立刻接着录下一段(近连续)。
/// 首次启动会触发 macOS「屏幕录制」授权——用户须到 系统设置>隐私与安全性>屏幕录制
/// 勾选本 App 并重启，之后才真正录到画面(系统强制，绕不过=天然的知情同意)。
// 系统级录屏调度：macOS 13+ 走 ScreenCaptureKit(屏幕+系统内音)，否则旧法(只视频)。
class ScreenRecorder: NSObject {
  private var running = false
  private let dir = NSTemporaryDirectory() + "xiaoli_screenrec/"
  var onClip: ((String) -> Void)?
  var clipSeconds: Double = 3.0
  private var sck: AnyObject?
  private var legacy: LegacyScreenRecorder?

  func start() -> Bool {
    if running { return true }
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)
    running = true
    if #available(macOS 13.0, *) {
      let r = SCKRecorder(dir: dir, clipSeconds: clipSeconds)
      r.onClip = { [weak self] p in self?.onClip?(p) }
      r.start()
      sck = r
    } else {
      let l = LegacyScreenRecorder(dir: dir, clipSeconds: clipSeconds)
      l.onClip = { [weak self] p in self?.onClip?(p) }
      _ = l.start()
      legacy = l
    }
    return true
  }

  func stop() {
    running = false
    if #available(macOS 13.0, *) { (sck as? SCKRecorder)?.stop() }
    legacy?.stop()
    sck = nil
    legacy = nil
    if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
      for f in files { try? FileManager.default.removeItem(atPath: dir + f) }
    }
  }
}

/// 旧法(只视频)：AVCaptureScreenInput，macOS <13 兜底。
class LegacyScreenRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
  private var session: AVCaptureSession?
  private var output: AVCaptureMovieFileOutput?
  private var running = false
  private let dir: String
  private let clipSeconds: Double
  var onClip: ((String) -> Void)?
  init(dir: String, clipSeconds: Double) {
    self.dir = dir
    self.clipSeconds = clipSeconds
  }

  func start() -> Bool {
    if running { return true }
    let s = AVCaptureSession()
    s.sessionPreset = .high
    guard let input = AVCaptureScreenInput(displayID: CGMainDisplayID()) else {
      return false
    }
    input.minFrameDuration = CMTime(value: 1, timescale: 15)
    input.scaleFactor = 0.5
    input.capturesCursor = true
    if s.canAddInput(input) { s.addInput(input) }
    let out = AVCaptureMovieFileOutput()
    out.movieFragmentInterval = .invalid
    if s.canAddOutput(out) { s.addOutput(out) }
    self.session = s
    self.output = out
    s.startRunning()
    running = true
    startClip()
    return true
  }

  private func startClip() {
    guard running, let out = output, !out.isRecording else { return }
    let path = dir + "clip_\(Int(Date().timeIntervalSince1970 * 1000)).mov"
    out.startRecording(to: URL(fileURLWithPath: path), recordingDelegate: self)
    DispatchQueue.main.asyncAfter(deadline: .now() + clipSeconds) { [weak self] in
      guard let self = self, self.running, out.isRecording else { return }
      out.stopRecording()
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    let ok =
      (error == nil)
      || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey]
        as? Bool ?? false)
    if ok,
      let sz = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[
        .size] as? Int, sz > 1000
    {
      onClip?(outputFileURL.path)
    } else {
      try? FileManager.default.removeItem(at: outputFileURL)
    }
    if running { startClip() }
  }

  func stop() {
    running = false
    if let o = output, o.isRecording { o.stopRecording() }
    session?.stopRunning()
    session = nil
    output = nil
  }
}

/// 新法：ScreenCaptureKit(macOS 13+) 抓屏幕 + 系统内音 → AVAssetWriter MP4 分段。
@available(macOS 13.0, *)
class SCKRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
  private let dir: String
  private let clipSeconds: Double
  var onClip: ((String) -> Void)?
  private var stream: SCStream?
  private let q = DispatchQueue(label: "xiaoli.sck")
  private var writer: AVAssetWriter?
  private var vIn: AVAssetWriterInput?
  private var aIn: AVAssetWriterInput?
  private var sessionStarted = false
  private var clipStart = CMTime.zero
  private var curPath = ""
  private var W = 1280
  private var H = 800
  private var running = false

  init(dir: String, clipSeconds: Double) {
    self.dir = dir
    self.clipSeconds = clipSeconds
  }

  func start() {
    running = true
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
      [weak self] content, _ in
      guard let self = self, self.running, let display = content?.displays.first
      else { return }
      self.W = Int(Double(display.width) * 0.5)
      self.H = Int(Double(display.height) * 0.5)
      let filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
      let cfg = SCStreamConfiguration()
      cfg.width = self.W
      cfg.height = self.H
      cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
      cfg.capturesAudio = true
      cfg.sampleRate = 48000
      cfg.channelCount = 2
      cfg.showsCursor = true
      cfg.pixelFormat = kCVPixelFormatType_32BGRA
      let s = SCStream(filter: filter, configuration: cfg, delegate: self)
      do {
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.q)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.q)
      } catch { return }
      s.startCapture { _ in }
      self.stream = s
      self.q.async { self.openWriter() }
    }
  }

  private func openWriter() {
    let path = dir + "clip_\(Int(Date().timeIntervalSince1970 * 1000)).mp4"
    guard let w = try? AVAssetWriter(
      outputURL: URL(fileURLWithPath: path), fileType: .mp4) else { return }
    let vi = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: W, AVVideoHeightKey: H,
      ])
    vi.expectsMediaDataInRealTime = true
    let ai = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000,
        AVEncoderBitRateKey: 128000,
      ])
    ai.expectsMediaDataInRealTime = true
    if w.canAdd(vi) { w.add(vi) }
    if w.canAdd(ai) { w.add(ai) }
    w.startWriting()
    writer = w
    vIn = vi
    aIn = ai
    sessionStarted = false
    curPath = path
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard running, CMSampleBufferDataIsReady(sb), writer != nil else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
    if type == .screen {
      if !sessionStarted {
        writer?.startSession(atSourceTime: pts)
        sessionStarted = true
        clipStart = pts
      }
      if vIn?.isReadyForMoreMediaData == true { vIn?.append(sb) }
      if CMTimeGetSeconds(CMTimeSubtract(pts, clipStart)) >= clipSeconds {
        rotate(at: pts)
      }
    } else if type == .audio {
      if sessionStarted, aIn?.isReadyForMoreMediaData == true { aIn?.append(sb) }
    }
  }

  private func rotate(at pts: CMTime) {
    guard let w = writer else { return }
    let path = curPath
    writer = nil
    vIn?.markAsFinished()
    aIn?.markAsFinished()
    vIn = nil
    aIn = nil
    sessionStarted = false
    w.endSession(atSourceTime: pts)
    w.finishWriting {
      if w.status == .completed,
        let sz = try? FileManager.default.attributesOfItem(atPath: path)[.size]
          as? Int, sz > 2000
      {
        self.onClip?(path)
      } else {
        try? FileManager.default.removeItem(atPath: path)
      }
    }
    if running { openWriter() }
  }

  func stop() {
    running = false
    stream?.stopCapture { _ in }
    stream = nil
    if let w = writer {
      vIn?.markAsFinished()
      aIn?.markAsFinished()
      w.finishWriting {}
    }
    writer = nil
    vIn = nil
    aIn = nil
  }
}

/// 桌面取帧器(macOS 13+)：ScreenCaptureKit 抓整个桌面，节流成 ~1.5fps JPEG 帧回调。
@available(macOS 13.0, *)
class SCKFrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
  var onFrame: ((Data) -> Void)?
  var fps: Double = 1.5
  private var stream: SCStream?
  private let q = DispatchQueue(label: "xiaoli.grab")
  private let ciContext = CIContext()
  private var lastEmit = Date(timeIntervalSince1970: 0)
  private var running = false

  func start() {
    running = true
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
      [weak self] content, _ in
      guard let self = self, self.running, let display = content?.displays.first
      else { return }
      let filter = SCContentFilter(
        display: display, excludingApplications: [], exceptingWindows: [])
      let cfg = SCStreamConfiguration()
      cfg.width = Int(Double(display.width) * 0.5)
      cfg.height = Int(Double(display.height) * 0.5)
      cfg.minimumFrameInterval = CMTime(value: 1, timescale: 5)
      cfg.showsCursor = true
      cfg.pixelFormat = kCVPixelFormatType_32BGRA
      let s = SCStream(filter: filter, configuration: cfg, delegate: self)
      try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.q)
      s.startCapture { _ in }
      self.stream = s
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard running, type == .screen, CMSampleBufferDataIsReady(sb) else { return }
    let now = Date()
    if now.timeIntervalSince(lastEmit) < (1.0 / fps) { return }
    guard let px = CMSampleBufferGetImageBuffer(sb) else { return }
    let ci = CIImage(cvImageBuffer: px)
    let opts: [CIImageRepresentationOption: Any] = [
      CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5
    ]
    guard let jpg = ciContext.jpegRepresentation(
      of: ci, colorSpace: CGColorSpaceCreateDeviceRGB(), options: opts) else { return }
    lastEmit = now
    onFrame?(jpg)
  }

  func stop() {
    running = false
    stream?.stopCapture { _ in }
    stream = nil
  }
}
