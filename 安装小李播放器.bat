@echo off
chcp 65001 >nul
title 小李播放器 一键安装（加速版）
echo ==========================================
echo   正在下载并安装小李播放器到桌面...
echo   （使用国内加速镜像，下载更快）
echo ==========================================

set URL_GITHUB=https://github.com/Muzlin/xiaoli-player/releases/latest/download/xiaoli-player-windows.zip
set URL_MIRROR1=https://ghfast.top/https://github.com/Muzlin/xiaoli-player/releases/latest/download/xiaoli-player-windows.zip
set URL_MIRROR2=https://ghproxy.net/https://github.com/Muzlin/xiaoli-player/releases/latest/download/xiaoli-player-windows.zip

echo [1/3] 镜像1 下载中...
curl -L --fail --connect-timeout 20 -o "%TEMP%\xiaoli.zip" "%URL_MIRROR1%"
if errorlevel 1 (
    echo      镜像1失败，改用镜像2...
    curl -L --fail --connect-timeout 20 -o "%TEMP%\xiaoli.zip" "%URL_MIRROR2%"
)
if errorlevel 1 (
    echo      镜像2失败，改用 GitHub 直连...
    curl -L --fail --connect-timeout 30 -o "%TEMP%\xiaoli.zip" "%URL_GITHUB%"
)
if errorlevel 1 (
    echo.
    echo [失败] 下载失败，请检查网络后重试
    pause
    exit /b 1
)

echo [2/3] 解压到桌面...
powershell -Command "Expand-Archive '%TEMP%\xiaoli.zip' -DestinationPath '%USERPROFILE%\Desktop\小李播放器' -Force"
if errorlevel 1 (
    powershell -Command "Expand-Archive '%TEMP%\xiaoli.zip' -DestinationPath '%USERPROFILE%\Desktop\小李播放器' -Force"
)

echo [3/3] 重命名并启动...
cd /d "%USERPROFILE%\Desktop\小李播放器"
if exist media_client.exe ( ren media_client.exe 小李播放器.exe )
del "%TEMP%\xiaoli.zip" >nul 2>nul
start "" "%USERPROFILE%\Desktop\小李播放器\小李播放器.exe"
echo.
echo ==========================================
echo   完成！小李播放器已装到桌面并启动。
echo ==========================================
pause
