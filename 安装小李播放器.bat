@echo off
chcp 65001 >nul
title 小李播放器 一键安装
echo ==========================================
echo   正在下载并安装小李播放器到桌面...
echo   请保持网络畅通，约 1-2 分钟
echo ==========================================
powershell -Command "Invoke-WebRequest 'https://github.com/Muzlin/xiaoli-player/releases/latest/download/xiaoli-player-windows.zip' -OutFile \"$env:TEMP\x.zip\"; Expand-Archive \"$env:TEMP\x.zip\" -DestinationPath \"$env:USERPROFILE\Desktop\小李播放器\" -Force; Remove-Item \"$env:TEMP\x.zip\"; Rename-Item \"$env:USERPROFILE\Desktop\小李播放器\media_client.exe\" \"小李播放器.exe\"; Start-Process \"$env:USERPROFILE\Desktop\小李播放器\小李播放器.exe\""
if errorlevel 1 (
    echo.
    echo [失败] 请检查网络后重试，或手动下载:
    echo https://github.com/Muzlin/xiaoli-player/releases/latest
    pause
) else (
    echo.
    echo 完成！小李播放器已安装到桌面并启动。
    pause
)
