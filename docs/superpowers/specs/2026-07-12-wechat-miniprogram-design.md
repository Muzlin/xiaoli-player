# 小李播放器 · 微信小程序原型设计

## 背景

小李播放器目前有 Flutter 桌面/移动客户端(`client/`)和 Python 后端(`backend/` 是本地媒体库后端；线上共享平台是独立仓库 `~/xiaoli-platform/server.py`，端口 8900)。用户想要一个微信小程序版本。

**硬约束(已跟用户确认)**：
- 用户目前没有微信小程序 AppID，也没有固定域名，且明确表示暂时不想去注册/购买域名。
- 微信小程序的网络请求要求 HTTPS + 在小程序后台白名单登记的固定域名（大陆备案域名优先）。没有固定域名，就没法通过正式的域名校验。
- 结论：这一期做的是**只能在开发者用自己电脑的微信开发者工具里预览的原型**，不能真机扫码分享、不能提交审核发布。以后如果用户拿到 AppID + 固定域名，把网络地址常量换掉就能升级成可发布版本，代码结构不用大改。

## 目标 / 非目标

**目标**
- 原生微信小程序（不引入 Taro/uni-app 等框架，零额外工具链，开发者工具直接打开目录能跑）。
- 复用 `xiaoli-platform/server.py` 现成的只读接口：`GET /list?cat=`、`GET /search?q=`、`GET /video/<id>`，服务端不改代码。
- 三个能力：首页浏览（音乐/视频分类）、搜索、播放（音频用 `wx.createInnerAudioContext()` 自建播放条，视频用小程序原生 `<video>` 组件）。
- 请求失败（最常见原因：本机没跑 server.py，或开发者工具没勾选跳过域名校验）要有清晰提示 + 重试，不能白屏/崩溃。

**非目标（本期不做）**
- 不做钱包/经济系统、评论、社交（私信/动态/红包）、B站搜索、收藏、下载缓存——这些依赖账号体系或涉及微信小程序对虚拟货币/UGC 内容的合规限制，且不是"核心播放体验"的一部分。
- 不做正式发布所需的域名/AppID 配置、不做小程序审核材料准备——这些需要用户自己的账号和域名，不在本次范围内。
- 不改动 `xiaoli-platform/server.py` 的任何接口。

## 架构

```
miniprogram/                       # 新增目录，media-player 仓库下，和 client/ backend/ 平级
  app.js / app.json / app.wxss     # 小程序入口配置
  config.js                        # BASE_URL 常量，写死 http://localhost:8900
  pages/
    index/                        # 首页：分类切换 + 搜索框 + 列表
      index.wxml / .wxss / .js / .json
    player/                       # 播放页：音频/视频播放
      player.wxml / .wxss / .js / .json
  utils/
    api.js                        # 封装 wx.request 调 /list /search，统一错误处理
```

- **数据层**（`utils/api.js`）：包一层 `wx.request` 的 Promise 封装，调 `${BASE_URL}/list?cat=xxx` 和 `${BASE_URL}/search?q=xxx`，服务端返回的字段（`id/title/uploader/ext/views/likes/favs`）和 Flutter 端解析的是同一套，直接透传给页面渲染。
- **首页**（`pages/index`）：`onLoad`/下拉刷新时调 `/list?cat=音乐` 或 `/list?cat=视频`（顶部 tab 切换分类），搜索框输入触发 `/search?q=`（结果里按 `ext` 过滤成当前分类，因为 `/search` 不分类）。列表项点击 `wx.navigateTo` 到播放页，带上 `id`、`title`、`ext`。
- **播放页**（`pages/player`）：根据传入的 `ext` 判断音频/视频：
  - 音频：`wx.createInnerAudioContext()` 设 `src = ${BASE_URL}/video/${id}`，自己画播放/暂停按钮、进度条（监听 `onTimeUpdate`/`onPlay`/`onPause`/`onEnded`）。
  - 视频：原生 `<video>` 组件，`src` 同上，用组件自带的控制栏。
- **网络地址**：`config.js` 里的 `BASE_URL = 'http://localhost:8900'`，顶部写清楚使用前提（本机要跑着 server.py；开发者工具项目设置里要勾选「不校验合法域名」）。

## 错误处理

- `wx.request` 失败（fail 回调）：列表页/播放页显示"加载失败，请确认本机服务已启动、且开发者工具已关闭域名校验"文案 + 「重试」按钮，不留白屏。
- 列表为空（分类下没有内容）：显示"暂无内容"占位，不是空白页。
- 播放出错（`InnerAudioContext.onError` / `<video>` 的 `binderror`）：toast 提示"播放失败"，不影响返回上一页。

## 测试计划

- 这台机器上没有微信开发者工具（CLI 环境），没法自动化跑小程序真机预览。
- 代码写完后，我会提醒你在微信开发者工具里「导入项目」选这个 `miniprogram/` 目录、不填 AppID 用"测试号"、项目设置里勾选跳过域名校验，然后手动验证：首页列表加载、分类切换、搜索、点进播放页音频/视频都能放出来。
- server.py 本身不改，不需要额外测试。

## 文件位置

新目录 `~/media-player/miniprogram/`，和现有 `client/`（Flutter）、`backend/`（本地媒体库后端）平级。
