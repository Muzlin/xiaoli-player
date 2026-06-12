import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  var subtitleOverlay: SubtitleOverlay?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

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
      if call.method == "setMini" {
        let on = (call.arguments as? [String: Any])?["on"] as? Bool ?? false
        self?.setMini(on)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
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
