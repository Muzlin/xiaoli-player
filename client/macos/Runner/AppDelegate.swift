import Cocoa
import CryptoKit
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // 后台运行：开启时关掉最后一个窗口不退出（窗口由 windowShouldClose 隐藏而非关闭）。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !UserDefaults.standard.bool(forKey: "backgroundRun")
  }

  // 点 Dock 图标时把隐藏的窗口重新显示出来。
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      for w in sender.windows {
        w.makeKeyAndOrderFront(nil)
      }
    }
    return true
  }

  // Cmd+Q / 菜单退出：开启「禁止退出」则完全拦截；否则弹确认防误退。
  override func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
    if UserDefaults.standard.bool(forKey: "blockQuit") {
      let alert = NSAlert()
      alert.messageText = "已禁止退出"
      alert.informativeText = "如需退出，请到设置里关闭「禁止退出」。"
      alert.addButton(withTitle: "好")
      alert.runModal()
      return .terminateCancel
    }
    let d = UserDefaults.standard
    if d.bool(forKey: "quitNeedsPassword"),
      let hash = d.string(forKey: "appPwdHash"), !hash.isEmpty
    {
      let alert = NSAlert()
      alert.messageText = "退出需要密码"
      let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
      alert.accessoryView = field
      alert.addButton(withTitle: "退出")
      alert.addButton(withTitle: "取消")
      alert.window.initialFirstResponder = field
      if alert.runModal() == .alertFirstButtonReturn {
        let entered = SHA256.hash(data: Data(field.stringValue.utf8))
          .map { String(format: "%02x", $0) }.joined()
        if entered == hash { return .terminateNow }
      }
      return .terminateCancel
    }
    let alert = NSAlert()
    alert.messageText = "确定要退出小李播放器吗？"
    alert.informativeText = "正在播放的内容将停止。"
    alert.addButton(withTitle: "退出")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
      ? .terminateNow : .terminateCancel
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
