@echo off
REM ============================================================
REM  小李播放器 — Windows 构建脚本
REM  前置：1) 安装 Flutter（已加入 PATH）
REM        2) 安装 Visual Studio 2022，勾选「使用 C++ 的桌面开发」工作负载
REM           （含 MSVC v143 + Windows 10/11 SDK + CMake）
REM  用法：双击本文件，或在本目录开 cmd 运行 build_windows.bat
REM ============================================================
setlocal
cd /d "%~dp0"

echo [1/3] flutter pub get ...
call flutter pub get || goto :err

echo [2/3] 确认 Windows 桌面已启用 ...
call flutter config --enable-windows-desktop >nul 2>&1

echo [3/3] flutter build windows --release ...
call flutter build windows --release || goto :err

echo.
echo ============================================================
echo  构建成功！可分发的整个文件夹（exe + dll + data 都在里面）：
echo    build\windows\x64\runner\Release\
echo  直接双击其中的 media_client.exe 运行；
echo  分发时请把整个 Release 文件夹一起拷给别人（缺 dll/data 会打不开）。
echo ============================================================
pause
exit /b 0

:err
echo.
echo *** 构建失败。常见原因：
echo   - 没装 Visual Studio 的「使用 C++ 的桌面开发」工作负载
echo   - Flutter 没加进 PATH（先跑 flutter doctor 检查）
echo 把上面的红色报错发我，我来修。
pause
exit /b 1
