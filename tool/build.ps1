$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Flutter = $env:FLUTTER_ROOT
if ($Flutter) { $Flutter = Join-Path $Flutter 'bin\flutter.bat' } else { $Flutter = 'flutter' }
Push-Location $Root
& $Flutter build windows --release
$Code = $LASTEXITCODE
Pop-Location
exit $Code
