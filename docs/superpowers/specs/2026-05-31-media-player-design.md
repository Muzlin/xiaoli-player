# 跨平台媒体播放器 — 设计文档 (v1)

**日期:** 2026-05-31
**状态:** 已批准，待实现

## 目标

做一个跨平台（macOS / Windows）的图形界面媒体播放器，**支持所有格式**，音频和视频都能播。

核心设计决策：**支持"所有格式"的现实做法是内嵌一个成熟的媒体引擎**（libmpv，底层封装 FFmpeg，负责解复用、解码、A/V 同步和渲染），而不是自己实现编解码器。本应用是"一个 GUI 外壳承载 libmpv"。

## 技术栈

- Python 3.11+
- PyQt6（GUI）
- python-mpv（libmpv 的 Python 绑定）
- PyInstaller（打包发布）

跨平台：PyQt6 与 libmpv 在 macOS 和 Windows 均可用。mpv 通过宿主窗口的 window-id（`wid`）嵌入 Qt 控件进行渲染——这是成熟且文档完善的路径。

## 架构 / 模块边界

四个职责清晰、相互隔离的单元，各管一件事：

| 模块 | 职责 | 依赖 |
|------|------|------|
| `PlayerEngine` | 封装 python-mpv：play/pause/stop/seek/volume/load；对外发出 position / duration / state / track 变化信号 | python-mpv |
| `VideoWidget` | 一个 QWidget，把它的 window-id (`wid`) 交给 mpv 作渲染表面；处理鼠标单击/双击 | PyQt6 |
| `ControlBar` | 进度条、时间显示、播放/暂停、停止、音量、全屏按钮；纯 UI，只发信号 | PyQt6 |
| `MainWindow` | 组装上述三者 + 菜单栏 + 拖拽 + 快捷键；做 UI ↔ Engine 的信号桥接 | 以上全部 |

每个单元都能独立回答：它做什么、怎么用、依赖什么。可以替换某个单元内部实现而不破坏其使用方。

### 数据流

```
UI 操作 → Qt 信号 → PlayerEngine 调用 mpv
mpv 事件（mpv 线程）→ 经 Qt 信号切回主线程 → 更新 UI
```

**所有 UI 更新只在主线程。** mpv 的回调发生在 mpv 自己的线程，必须通过 Qt 信号/槽（队列连接）切回主线程后再触碰任何 widget。

## v1 功能范围

- 打开文件：菜单/文件对话框 + 把文件拖拽到窗口
- 音频 + 视频，**所有 mpv/FFmpeg 支持的格式**
- 播放 / 暂停 / 停止
- 可拖动进度条，显示当前时间 / 总时长
- 音量调节 + 静音
- 全屏切换（双击画面或按钮）
- 简单播放列表：加入多个文件、上一个/下一个、播完自动连播
- 字幕轨 / 音轨切换：mpv 已解析，在菜单里列出供选择
- 键盘快捷键：
  - 空格 = 播放/暂停
  - ← / → = 快退 / 快进
  - ↑ / ↓ = 音量
  - F = 全屏
  - M = 静音

## 明确不做 (YAGNI)

以下 v1 一律不做，以后需要再加：

- 流媒体 URL / 在线源
- 转码 / 导出
- 均衡器 / 视频滤镜
- 皮肤 / 主题
- 网络串流（DLNA 等）

## 错误处理

- 文件打不开 / 格式确实不支持 → 状态栏提示，绝不崩溃
- libmpv 没装 / 找不到动态库 → 启动时给出友好报错，并说明安装方法
- mpv 抛出的错误 → 统一在 `PlayerEngine` 层捕获，转成信号上报 UI

## 测试策略

- `PlayerEngine`：用一个 fake-mpv（替身对象）做单元测试，覆盖状态机与信号发射，不依赖真实播放
- UI：用 pytest-qt 做冒烟测试（控件存在、信号连通）
- 手动验证清单：用若干不同格式的样本文件（如 mp4 / mkv / flac / mp3 / avi）实际播放确认

## 项目结构（初步）

```
media-player/
  player/
    __init__.py
    engine.py        # PlayerEngine
    video_widget.py  # VideoWidget
    control_bar.py   # ControlBar
    main_window.py   # MainWindow
    app.py           # 入口：构建 QApplication
  tests/
    test_engine.py
    test_ui_smoke.py
  pyproject.toml
  README.md
```
