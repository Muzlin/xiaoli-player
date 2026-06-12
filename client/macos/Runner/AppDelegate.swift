import Cocoa
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

  // Cmd+Q / 菜单退出时弹确认，防误退。
  override func applicationShouldTerminate(_ sender: NSApplication)
    -> NSApplication.TerminateReply
  {
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
