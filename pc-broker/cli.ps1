# 星zuku 电脑侧命令行（不需要装 App 也能用全部能力）
#
# 前提：broker 已在运行（start-starzuku.bat）
#
# 用法示例：
#   .\cli.ps1 shot                    截屏存到当前目录 screen.jpg
#   .\cli.ps1 tap 400 1200            点击
#   .\cli.ps1 swipe 400 1400 400 600  滑动
#   .\cli.ps1 key Back                按键 (Back/Home/Power)
#   .\cli.ps1 ps                      进程列表
#   .\cli.ps1 kill 1234               杀进程
#   .\cli.ps1 ls /data/local/tmp      列目录
#   .\cli.ps1 cat /proc/version       读文件
#   .\cli.ps1 install D:\a.hap        安装 HAP
#   .\cli.ps1 uninstall com.xx.yy     卸载
#   .\cli.ps1 start com.xx.yy         启动
#   .\cli.ps1 shell "getprop | head"  任意命令

param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Cmd,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Args
)

$base = "http://127.0.0.1:18791"

function Post($path, $obj) {
  return (Invoke-WebRequest -Uri ($base + $path) -Method POST -Body ($obj | ConvertTo-Json -Compress) `
    -ContentType "application/json" -UseBasicParsing -TimeoutSec 120).Content
}

function Exec($cmd, $timeout = 30000) {
  $r = Post "/exec" @{ cmd = $cmd; timeout = $timeout } | ConvertFrom-Json
  if ($r.out) { Write-Output $r.out.TrimEnd() }
  if ($r.err) { Write-Output $r.err.TrimEnd() }
  if (-not $r.ok) { Write-Warning "exit=$($r.code)" }
  return $r
}

switch ($Cmd.ToLower()) {
  "health"    { (Invoke-WebRequest -Uri "$base/health" -UseBasicParsing -TimeoutSec 10).Content }
  "shot" {
    Exec "rm -f /data/local/tmp/.sz_shot.jpeg; snapshot_display -f /data/local/tmp/.sz_shot.jpeg >/dev/null 2>&1; ls -l /data/local/tmp/.sz_shot.jpeg" 30000 | Out-Null
    $r = Post "/pull" @{ path = "/data/local/tmp/.sz_shot.jpeg" } | ConvertFrom-Json
    $out = Join-Path (Get-Location) "screen.jpg"
    [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String($r.base64))
    Write-Host ("截屏 -> " + $out + "  (" + [Math]::Round($r.size / 1024) + " KB)")
  }
  "tap"       { Exec ("uitest uiInput click " + $Args[0] + " " + $Args[1]) | Out-Null; Write-Host "已点击 $($Args[0]),$($Args[1])" }
  "swipe"     { Exec ("uitest uiInput swipe " + ($Args -join " ")) | Out-Null; Write-Host "已滑动 $($Args -join ' ')" }
  "key"       { Exec ("uitest uiInput keyEvent " + $Args[0]) | Out-Null; Write-Host "已按键 $($Args[0])" }
  "ps"        { Exec "ps -ef" 20000 }
  "kill"      { Exec ("kill -9 " + $Args[0]) | Out-Null; Write-Host "已发送 kill -9 $($Args[0])" }
  "ls"        { Exec ("ls -lA `"" + $Args[0] + "`"") }
  "cat"       { Exec ("cat `"" + $Args[0] + "`"") }
  "install" {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Args[0]))
    $r = Post "/push" @{ path = ("/data/local/tmp/" + (Split-Path $Args[0] -Leaf)); base64 = $b64 } | ConvertFrom-Json
    Exec ("bm install -p /data/local/tmp/" + (Split-Path $Args[0] -Leaf) + " -u 100") 60000
  }
  "uninstall" { Exec ("bm uninstall -n " + $Args[0]) }
  "start"     { Exec ("aa start -b `"" + $Args[0] + "`" -a EntryAbility 2>&1 || aa start -b `"" + $Args[0] + "`"") }
  "shell"     { Exec ($Args -join " ") }
  default     { Write-Host "未知命令: $Cmd  (可用: health shot tap swipe key ps kill ls cat install uninstall start shell)" -ForegroundColor Red }
}
