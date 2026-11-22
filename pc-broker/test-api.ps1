$ErrorActionPreference = "Stop"
$base = "http://127.0.0.1:18791"

function Post($path, $obj) {
  $body = $obj | ConvertTo-Json -Compress
  return (Invoke-WebRequest -Uri ($base + $path) -Method POST -Body $body `
    -ContentType "application/json" -UseBasicParsing -TimeoutSec 60).Content
}

Write-Host "== health ==" -ForegroundColor Cyan
(Invoke-WebRequest -Uri "$base/health" -UseBasicParsing -TimeoutSec 10).Content

Write-Host "`n== exec: id ==" -ForegroundColor Cyan
Post "/exec" @{ cmd = "id; echo ---; param get const.product.model"; timeout = 15000 }

Write-Host "`n== exec: ps (前 5 行) ==" -ForegroundColor Cyan
$ps = Post "/exec" @{ cmd = "ps -ef | head -5"; timeout = 15000 }
$ps

Write-Host "`n== 截屏 ==" -ForegroundColor Cyan
Post "/exec" @{ cmd = "snapshot_display -f /data/local/tmp/.sz_check.jpeg"; timeout = 30000 } | Out-Null
$r = Post "/pull" @{ path = "/data/local/tmp/.sz_check.jpeg" } | ConvertFrom-Json
if ($r.ok) {
  $out = Join-Path $PSScriptRoot "screen-check.jpg"
  [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String($r.base64))
  Write-Host ("截屏已保存: " + $out + "  (" + [Math]::Round($r.size / 1024) + " KB)")
} else {
  Write-Host ("截屏失败: " + $r.err) -ForegroundColor Red
}
