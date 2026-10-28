$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Flutter = 'D:\Develop\FlutterSdk\flutter\bin\flutter.bat'
if (!(Test-Path $Flutter)) { $Flutter = 'flutter' }
Push-Location $Root
& $Flutter build windows --release
$Code = $LASTEXITCODE
Pop-Location
exit $Code
