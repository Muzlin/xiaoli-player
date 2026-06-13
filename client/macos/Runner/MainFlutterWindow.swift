import Carbon
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  var subtitleOverlay: SubtitleOverlay?

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
