@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ============================================================
echo  小李播放器 - 打 MSIX 安装包
echo  建议「以管理员身份运行」本脚本（证书需写入系统信任区）
echo  需要: Flutter + Visual Studio 2022 (Desktop C++)
echo ============================================================
echo.

where flutter >nul 2>&1
if errorlevel 1 (
  echo [X] 找不到 flutter，请先装 Flutter 并加进 PATH。
  echo.
  pause
  exit /b 1
)

echo [1/3] flutter pub get ...
call flutter pub get
if errorlevel 1 goto fail

echo [2/3] flutter build windows --release ...
call flutter build windows --release
if errorlevel 1 goto fail

echo [3/3] dart run msix:create  (打 MSIX 并用测试证书签名) ...
call dart run msix:create
if errorlevel 1 goto fail

echo.
echo ============================================================
echo  打包成功 OK!  .msix 在:
echo    build\windows\x64\runner\Release\
echo  （文件名形如 小李播放器.msix 或 media_client.msix）
echo.
echo  安装方法:
echo   - 本机(已用管理员跑过本脚本)：双击 .msix → 安装
echo   - 别的电脑：先信任证书再装。把 .msix 改名为 .zip 解压，
echo     里面有签名证书；右键证书 → 安装证书 → 本地计算机 →
echo     「受信任人(Trusted People)」，再双击 .msix 安装。
echo ============================================================
echo.
pause
exit /b 0

:fail
echo.
echo ============================================================
echo  失败 FAILED。常见原因:
echo   - 没装 Visual Studio 的「使用 C++ 的桌面开发」工作负载
echo   - msix 依赖没拉到(检查联网)；先跑 flutter pub get
echo   - 证书写系统区被拒：用「以管理员身份运行」再试
echo  把红色报错发我。
echo ============================================================
echo.
pause
exit /b 1
