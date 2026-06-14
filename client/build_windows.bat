@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================================
echo  XiaoLi Player - Windows build  (小李播放器 Windows 构建)
echo  Need: Flutter in PATH  +  Visual Studio 2022 (Desktop C++)
echo ============================================================
echo.

where flutter >nul 2>&1
if errorlevel 1 (
  echo [X] 找不到 flutter 命令。请先装 Flutter 并把它加进 PATH。
  echo     装好后命令行跑一下 flutter doctor 确认。
  echo.
  pause
  exit /b 1
)

echo [1/3] flutter pub get ...
call flutter pub get
if errorlevel 1 goto fail

echo [2/3] enable windows desktop ...
call flutter config --enable-windows-desktop >nul 2>&1

echo [3/3] flutter build windows --release ...
call flutter build windows --release
if errorlevel 1 goto fail

echo.
echo ============================================================
echo  构建成功 OK!
echo  产物文件夹（exe + dll + data 都在里面）:
echo    build\windows\x64\runner\Release\
echo  双击其中的 media_client.exe 即可运行。
echo  分发请把整个 Release 文件夹一起拷。
echo ============================================================
echo.
pause
exit /b 0

:fail
echo.
echo ============================================================
echo  构建失败 FAILED.
echo  常见原因:
echo   - 没装 Visual Studio 2022 的「使用 C++ 的桌面开发」工作负载
echo   - Flutter 没装好 / 没联网拉依赖
echo  先跑一下:  flutter doctor
echo  把上面的红色报错发我，我来修。
echo ============================================================
echo.
pause
exit /b 1
