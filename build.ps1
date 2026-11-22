# StarPivot / 星枢 构建脚本
#
# 背景：本机 PATH 里的 java 可能是 JDK8，hvigor 打包阶段（app_packing_tool.jar）会崩(0xC0000409)。
# 这里把 DevEco 自带的 JDK(jbr) 放到 PATH 最前面，hvigor 就会用它来打包。
#
# 用法：
#   $env:DEVECO_HOME = "D:\Program Files\Huawei\DevEco Studio"   # 可选，未设则自动探测
#   .\build.ps1                # debug
#   .\build.ps1 -Release       # release

param(
  [switch]$Release
)

$ErrorActionPreference = "Stop"

# DevEco 安装目录：优先环境变量，其次常见位置
$ide = $env:DEVECO_HOME
if ([string]::IsNullOrWhiteSpace($ide)) {
  $candidates = @(
    "D:\Program Files\Huawei\DevEco Studio",
    "C:\Program Files\Huawei\DevEco Studio",
    "$env:LOCALAPPDATA\Huawei\DevEco Studio"
  )
  foreach ($c in $candidates) {
    if (Test-Path -LiteralPath (Join-Path $c "tools\hvigor\bin\hvigorw.js")) { $ide = $c; break }
  }
}
if ([string]::IsNullOrWhiteSpace($ide) -or -not (Test-Path -LiteralPath (Join-Path $ide "tools\hvigor\bin\hvigorw.js"))) {
  throw "未找到 DevEco Studio。请设置环境变量 DEVECO_HOME 指向安装目录。"
}

$node  = Join-Path $ide "tools\node\node.exe"
$hvigor= Join-Path $ide "tools\hvigor\bin\hvigorw.js"
$proj  = Split-Path -Parent $MyInvocation.MyCommand.Path

$env:PATH = (Join-Path $ide "jbr\bin") + ";" + $env:PATH
$env:DEVECO_SDK_HOME = Join-Path $ide "sdk"
Set-Location -LiteralPath $proj

$modeArgs = @()
if ($Release) { $modeArgs = @("-p", "buildMode=release") }

& $node $hvigor assembleHap --mode module -p product=default -p module=entry@default @modeArgs --no-daemon

$hap = Join-Path $proj "entry\build\default\outputs\default\entry-default-unsigned.hap"
if (Test-Path -LiteralPath $hap) {
  $kb = [math]::Round((Get-Item -LiteralPath $hap).Length / 1KB, 1)
  Write-Host ("`n构建成功 -> " + $hap + " (" + $kb + " KB)") -ForegroundColor Green
} else {
  Write-Host "`n构建失败：未产出 HAP" -ForegroundColor Red
  exit 1
}
