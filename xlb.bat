@echo off
REM ============================================
REM  小李播放器 Windows 启动命令（xlb）
REM  用法: xlb          启动小李播放器
REM        xlb build    重新构建
REM        xlb where    显示程序位置
REM  放到 PATH 目录后，任意位置输入 xlb 即可
REM ============================================
chcp 65001 >nul
setlocal

REM 查找已构建的 exe（优先当前目录，再找常见位置）
set APP=
for %%D in ("%CD%\build\windows\x64\runner\Release\小李播放器.exe"
           "%USERPROFILE%\xiaoli-player\client\build\windows\x64\runner\Release\小李播放器.exe"
           "%USERPROFILE%\Desktop\小李播放器\小李播放器.exe"
           "%~dp0Release\小李播放器.exe") do (
    if exist %%D set "APP=%%~fD"
)

if "%APP%"=="" (
    echo [xlb] 未找到 小李播放器.exe，尝试自动构建...
    if exist "%CD%\pubspec.yaml" goto :build
    if exist "%USERPROFILE%\xiaoli-player\client\pubspec.yaml" (
        cd /d "%USERPROFILE%\xiaoli-player\client"
        goto :build
    )
    echo [xlb] 找不到项目源码，请先 git clone https://github.com/Muzlin/xiaoli-player.git
    pause
    exit /b 1
)

if /i "%~1"=="where" (
    echo %APP%
    exit /b 0
)

if /i "%~1"=="build" (
    cd /d "%~dp0"
    call :build
    exit /b 0
)

echo [xlb] 启动: %APP%
start "" "%APP%"
exit /b 0

:build
echo [xlb] 开始构建（首次 5-15 分钟）...
call flutter pub get
if errorlevel 1 ( echo [xlb] 依赖拉取失败 & pause & exit /b 1 )
call flutter build windows --release
if errorlevel 1 ( echo [xlb] 构建失败 & pause & exit /b 1 )
set "APP=%CD%\build\windows\x64\runner\Release\小李播放器.exe"
echo [xlb] 构建完成 ✓
start "" "%APP%"
exit /b 0
