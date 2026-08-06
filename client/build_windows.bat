@echo off
chcp 65001 >nul
title 小李播放器 Windows 构建
echo ==========================================
echo   小李播放器 - Windows 11 一键构建
echo ==========================================
echo.

REM 检查 Flutter
where flutter >nul 2>nul
if %errorlevel% neq 0 (
    echo [错误] 未找到 Flutter，请先安装并加入 PATH
    echo 安装: https://docs.flutter.dev/get-started/install/windows
    pause
    exit /b 1
)
echo [1/3] Flutter: %flutter --version 2>nul | findstr "Flutter"%

REM 检查 Visual Studio
where msbuild >nul 2>nul
if %errorlevel% neq 0 (
    echo [提示] 请确认已安装 Visual Studio 2022 并勾选"C++ 桌面开发"
)

echo [2/3] 拉取依赖...
call flutter pub get
if %errorlevel% neq 0 (
    echo [错误] 依赖拉取失败
    pause
    exit /b 1
)

echo [3/3] 构建 Release 版（首次约 5-15 分钟）...
call flutter build windows --release
if %errorlevel% neq 0 (
    echo [错误] 构建失败，请查看上方错误信息
    pause
    exit /b 1
)

echo.
echo ==========================================
echo   ✅ 构建成功！
echo   应用位置: build\windows\x64\runner\Release\
echo ==========================================
explorer build\windows\x64\runner\Release
pause
