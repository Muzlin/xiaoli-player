# =====================================================================
#  小李播放器 — Windows 一键安装脚本
#  用法（在 PowerShell 里一行）：
#    irm http://192.168.31.57:8900/dl/install.ps1 | iex
#  逻辑：服务器有编好的应用就秒装；没有就自动装工具链 + 编译 + 安装。
# =====================================================================
$ErrorActionPreference = 'Stop'

$Script:AppName = 'XiaoliPlayer'
$Script:Install = Join-Path $env:LOCALAPPDATA $AppName
$Script:Bases   = @('http://192.168.31.57:8900',
                    'https://shapes-cups-hospital-respected.trycloudflare.com')
$Script:Tmp     = Join-Path $env:TEMP 'xiaoli_setup'

function Say($m){ Write-Host "  $m" -ForegroundColor Cyan }
function Warn($m){ Write-Host "  $m" -ForegroundColor Yellow }
function Die($m){ Write-Host "  $m" -ForegroundColor Red; Read-Host '按回车退出'; exit 1 }

# 在多个服务器地址里挑一个能下到的；都失败返回 $false。
function Fetch($pathOnServer, $outFile){
  foreach($b in $Script:Bases){
    try{
      Invoke-WebRequest "$b$pathOnServer" -OutFile $outFile -TimeoutSec 120 -UseBasicParsing
      return $true
    } catch { }
  }
  return $false
}

# 建桌面快捷方式并启动。
function Finish-Install {
  $exe = Join-Path $Script:Install 'media_client.exe'
  if(-not (Test-Path $exe)){ Die '安装异常：没找到 media_client.exe。' }
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '小李播放器.lnk'
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lnk)
  $sc.TargetPath = $exe
  $sc.WorkingDirectory = $Script:Install
  $sc.Save()
  Write-Host ''
  Write-Host '============================================================'
  Write-Host '  安装完成 ✓  桌面已建「小李播放器」快捷方式' -ForegroundColor Green
  Write-Host "  程序目录: $Script:Install"
  Write-Host '============================================================'
  Start-Process $exe
}

function Main {
  Write-Host ''
  Write-Host '============================================================'
  Write-Host '  小李播放器 Windows 安装器' -ForegroundColor Green
  Write-Host '============================================================'

  New-Item -ItemType Directory -Force -Path $Script:Install | Out-Null
  New-Item -ItemType Directory -Force -Path $Script:Tmp | Out-Null

  # ---------- 快路径：服务器已有编好的应用 ----------
  Say '检查服务器上是否有现成应用…'
  $appZip = Join-Path $Script:Tmp 'xiaoli-win.zip'
  if(Fetch '/dl/xiaoli-win.zip' $appZip){
    Say '发现现成应用，直接安装（无需编译）…'
    Remove-Item "$Script:Install\*" -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Force $appZip $Script:Install
    Finish-Install
    return
  }

  # ---------- 慢路径：自动装工具链 + 编译 ----------
  Warn '服务器暂无现成应用，转为自动编译（第一次较慢，需联网）。'

  if(-not (Get-Command winget -ErrorAction SilentlyContinue)){
    Die '系统没有 winget（应用安装程序）。请到 Microsoft Store 搜「应用安装程序」装一下再重跑。'
  }

  if(-not (Get-Command git -ErrorAction SilentlyContinue)){
    Say '安装 Git…'
    winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements --silent | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
  }

  $flutterBin = Join-Path $env:LOCALAPPDATA 'flutter\bin'
  if(-not (Get-Command flutter -ErrorAction SilentlyContinue)){
    if(-not (Test-Path "$flutterBin\flutter.bat")){
      Say '下载 Flutter SDK（stable，约 1GB，请稍候）…'
      git clone -b stable --depth 1 https://github.com/flutter/flutter.git (Join-Path $env:LOCALAPPDATA 'flutter')
    }
    $env:Path = "$flutterBin;$env:Path"
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if($userPath -notlike "*$flutterBin*"){
      [Environment]::SetEnvironmentVariable('Path', "$userPath;$flutterBin", 'User')
    }
  }

  # Visual Studio C++ 桌面工具（编译 Windows 必需，会弹 UAC 授权）
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  $hasVC = $false
  if(Test-Path $vswhere){
    $vc = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if($vc){ $hasVC = $true }
  }
  if(-not $hasVC){
    Say '安装 Visual Studio 生成工具(C++ 桌面，约 3-5GB，会弹授权请点是)…'
    winget install -e --id Microsoft.VisualStudio.2022.BuildTools --accept-source-agreements --accept-package-agreements `
      --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"
  }

  Say '下载源码…'
  $src = Join-Path $Script:Tmp 'src'
  $srcZip = Join-Path $Script:Tmp 'src.zip'
  if(-not (Fetch '/dl/xiaoli-win-src.zip' $srcZip)){ Die '源码下载失败：服务器连不上（同 WiFi 用局域网地址）。' }
  Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -Force $srcZip $src

  Say '编译中（flutter build windows，首次很慢）…'
  Push-Location $src
  & flutter pub get
  & flutter build windows --release
  $rel = Join-Path $src 'build\windows\x64\runner\Release'
  Pop-Location
  if(-not (Test-Path "$rel\media_client.exe")){ Die '编译失败。把上面的红色报错发我。' }

  Say '安装到本机…'
  Remove-Item "$Script:Install\*" -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item "$rel\*" $Script:Install -Recurse -Force
  Finish-Install
}

Main
