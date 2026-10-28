param(
  [string]$Target = 'windows-x64'
)

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Tools = Join-Path $Root 'assets\tools'
New-Item -ItemType Directory -Force -Path $Tools | Out-Null

if ($Target -ne 'windows-x64') {
  Write-Error "unknown target: $Target"
  exit 1
}

$Url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
$Zip = Join-Path $env:TEMP 'ffmpeg-win64.zip'
$Dir = Join-Path $env:TEMP 'ffmpeg-win64'
if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing
Expand-Archive -Path $Zip -DestinationPath $Dir -Force
$Ffmpeg = Get-ChildItem $Dir -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
$Ffplay = Get-ChildItem $Dir -Recurse -Filter 'ffplay.exe' | Select-Object -First 1
Copy-Item $Ffmpeg.FullName (Join-Path $Tools 'ffmpeg.exe') -Force
Copy-Item $Ffplay.FullName (Join-Path $Tools 'ffplay.exe') -Force
& (Join-Path $Tools 'ffmpeg.exe') -version | Select-Object -First 1
