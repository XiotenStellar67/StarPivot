# 星枢 StarPivot 构建脚本
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#
# 说明：本机 PATH 上的 Oracle JDK 8 会让 hvigor 的打包阶段（app_packing_tool.jar）崩溃（0xC0000409）。
# 这里把 DevEco 自带的 JDK（jbr）放到 PATH 最前面，hvigor 就会用它来打包。

$ErrorActionPreference = "Stop"

# DevEco Studio 安装目录：优先取环境变量，否则按常见位置探测
$ide = $env:DEVECO_HOME
if (-not $ide) {
    foreach ($p in @("D:\Program Files\Huawei\DevEco Studio", "C:\Program Files\Huawei\DevEco Studio")) {
        if (Test-Path -LiteralPath $p) { $ide = $p; break }
    }
}
if (-not $ide) {
    throw "未找到 DevEco Studio，请设置环境变量 DEVECO_HOME 指向安装目录"
}

$node = Join-Path $ide "tools\node\node.exe"
$hvigor = Join-Path $ide "tools\hvigor\bin\hvigorw.js"
$proj = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path -LiteralPath $node)) { throw "找不到 node：$node" }
if (-not (Test-Path -LiteralPath $hvigor)) { throw "找不到 hvigorw.js：$hvigor" }

$env:PATH = (Join-Path $ide "jbr\bin") + ";$env:PATH"
$env:DEVECO_SDK_HOME = Join-Path $ide "sdk"
Set-Location -LiteralPath $proj

& $node $hvigor assembleHap --mode module -p product=default -p module=entry@default --no-daemon

$hap = Join-Path $proj "entry\build\default\outputs\default\entry-default-unsigned.hap"
if (Test-Path -LiteralPath $hap) {
    Write-Host ("`n构建成功 -> " + $hap) -ForegroundColor Green
    Write-Host "该 HAP 未签名，请用本机签名工具（如 HoKit）签名后再安装。" -ForegroundColor Yellow
} else {
    Write-Host "`n构建失败：未产出 HAP" -ForegroundColor Red
    exit 1
}
