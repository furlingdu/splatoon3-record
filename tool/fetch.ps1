$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Required = @(
  (Join-Path $Root 'assets\tools\ffmpeg.exe'),
  (Join-Path $Root 'assets\tools\ffplay.exe'),
  (Join-Path $Root 'assets\models\splatoonNickname.onnx'),
  (Join-Path $Root 'assets\images\appIcon.ico')
)
foreach ($Item in $Required) {
  if (!(Test-Path $Item)) { Write-Error "Missing $Item"; exit 1 }
  Write-Host "OK $Item"
}



