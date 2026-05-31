# 跨平台媒体平台 — 设计文档 (v1)

**日期:** 2026-05-31
**状态:** 已批准，待写实现计划

## 目标

一个媒体平台，由**后端服务**和**跨平台客户端**组成：

- 用户**登录账号**后才能使用
- 用户可**上传**媒体文件
- 客户端可**播放所有格式**的媒体（音频 + 视频）
- **管理员**可以看到**所有人**上传的文件并下载
- 客户端需在 **macOS / Windows / Android** 三端原生安装

核心设计决策：
1. **"支持所有格式"** 的现实做法是内嵌成熟媒体引擎 **libmpv**（封装 FFmpeg，负责解复用/解码/同步/渲染），不自己写编解码器。
2. **三端单一代码库** 用 **Flutter + media_kit**（media_kit 底层即 libmpv，官方支持 Windows/macOS/Android）。因需支持 Android，原 PyQt6 方案不适用。
3. **播放来源** 以"流式播放平台上已上传的文件"为系统主播放方式（带鉴权的 HTTP 流，libmpv 直接拉流，不下整文件）；同时保留"打开本地文件"。

## 技术栈

**后端:** Python 3.11+ · FastAPI · SQLAlchemy/SQLModel · SQLite（开发）/ PostgreSQL（生产）· 本地文件存储 · JWT 认证 · Uvicorn

**客户端:** Flutter · media_kit（libmpv 绑定）· 三端：macOS / Windows / Android

## 系统架构

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  客户端 (Flutter+media_kit)  │  HTTP   │   后端 (FastAPI)             │
│  Mac / Windows / Android     │ ◄─────► │   auth / storage / media /   │
│  登录·媒体库·上传·播放器      │   API   │   admin  + DB + 文件存储     │
└─────────────────────────────┘         └──────────────────────────────┘
```

两部分通过下文的 **API 契约** 解耦：可独立开发与测试。

---

## A. 后端平台

### 模块边界

| 模块 | 职责 | 依赖 |
|------|------|------|
| `auth` | 注册 / 登录；签发并校验 JWT；角色判定（user / admin）| DB |
| `storage` | 接收上传文件，落盘；在 DB 写入元数据（属主、文件名、大小、格式、创建时间）| DB、文件系统 |
| `media` | 按权限列出文件；提供带鉴权的流式/下载响应（支持 HTTP Range，便于 seek）| DB、storage |
| `admin` | 管理员专用：列出所有用户的文件、下载任意文件 | DB、storage、auth |

每个模块职责单一、通过函数/路由接口对外，内部实现可替换而不影响调用方。

### 数据模型

- `User`: id, email, password_hash, role(`user`|`admin`), created_at
- `MediaFile`: id, owner_id, original_name, stored_path, size_bytes, container_format, created_at

### 权限规则

- 普通用户：只能列出 / 播放 / 下载**自己上传**的文件。
- 管理员：可列出 / 播放 / 下载**所有人**的文件。
- 所有 `/media` 与 `/admin` 接口都要求有效 JWT。

### 角色分配

- 开放自助注册 + 登录。
- 管理员由配置指定：启动配置里给出管理员邮箱（或首个注册账号自动为 admin）。具体取首个注册账号为 admin，其余为 user；配置可覆盖。

### 错误处理

- 鉴权失败 → 401；越权访问他人文件 → 403。
- 上传格式不被支持 / 文件损坏 → 不阻止上传（存储层不做解码），播放时由客户端 libmpv 处理；真正无法播放时客户端给出提示。
- 上传体积超限 → 413，配置可调上限。
- 找不到文件 → 404。

---

## B. 客户端 (Flutter + media_kit)

一套代码出 macOS / Windows / Android 三端原生安装包。

### 界面 / 模块

| 界面 | 职责 |
|------|------|
| 登录页 | 登录 / 注册；成功后安全存储 JWT（各平台安全存储）|
| 媒体库 | 调 `GET /media` 列出文件；管理员额外有"全部文件"视图并可下载 |
| 上传 | 选择本地文件 → `POST /media/upload`，显示上传进度 |
| 播放器 | media_kit/libmpv 播放（**所有格式**）：播放/暂停、可拖动进度条、时间、音量、全屏、快捷键；播放来源为后端流 URL；也支持打开本地文件 |

### 客户端服务层

- `ApiClient`：封装 HTTP + 自动附带 JWT；登录、列表、上传、获取流 URL、下载。
- `PlayerController`：封装 media_kit player，统一播放控制与状态。

### 错误处理

- 网络失败 / 401 → 引导重新登录。
- 流播放失败 → 播放器区域给出可读提示，不崩溃。

---

## C. API 契约（连接前后端）

| 方法 | 路径 | 说明 | 权限 |
|------|------|------|------|
| POST | `/auth/register` | 注册，返回 token | 公开 |
| POST | `/auth/login` | 登录，返回 token | 公开 |
| GET  | `/auth/me` | 当前用户信息 + 角色 | 已登录 |
| POST | `/media/upload` | 上传文件（multipart）| 已登录 |
| GET  | `/media` | 列出文件（user=自己，admin=全部）| 已登录 |
| GET  | `/media/{id}/stream` | 流式播放，支持 Range | 属主或 admin |
| GET  | `/media/{id}/download` | 下载文件 | 属主或 admin |
| GET  | `/admin/media` | 列出所有文件（含属主信息）| admin |

认证：除注册/登录外，所有请求带 `Authorization: Bearer <JWT>`。

---

## 范围 (v1)

**做：** 上述全部 —— 登录/注册、上传、按角色列出、流式播放所有格式、管理员看全部并下载、三端客户端、打开本地文件。

**不做 (YAGNI)：** 文件夹/标签整理、分享链接、转码/导出、评论、在线直播、多管理员细粒度权限、找回密码 / 邮件验证（v1 不做）、iOS/Web 端。

## 测试策略

**后端:**
- 单元测试：auth（注册/登录/JWT/角色）、权限规则（属主 vs admin vs 越权）、storage 元数据。
- 接口测试：用 FastAPI TestClient 跑完整 API，含 401/403/404/Range。

**客户端:**
- `ApiClient` 用 mock HTTP 单测。
- `PlayerController` 用 fake player 单测状态机。
- Widget 冒烟测试：登录页、媒体库、上传、播放器控件存在且信号连通。
- 手动验证清单：三端各跑一遍登录→上传→播放（多种格式 mp4/mkv/flac/mp3/avi）→管理员看全部并下载。

## 项目结构（初步）

```
media-player/
  backend/
    app/
      main.py
      auth.py
      storage.py
      media.py
      admin.py
      models.py
      db.py
    tests/
    pyproject.toml
  client/                 # Flutter 工程
    lib/
      api/api_client.dart
      player/player_controller.dart
      screens/login_screen.dart
      screens/library_screen.dart
      screens/upload_screen.dart
      screens/player_screen.dart
      main.dart
    test/
    pubspec.yaml
  docs/superpowers/specs/
  README.md
```

## 实现顺序（两子系统一起做，但有依赖序）

1. 后端先立起 API 契约（auth → storage/media → admin），随时可用 TestClient 验证。
2. 客户端按契约对接：登录 → 媒体库/上传 → 播放器。
3. 三端打包与手动验证。
