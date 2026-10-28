$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Flutter = 'D:\Develop\FlutterSdk\flutter\bin\flutter.bat'
if (!(Test-Path $Flutter)) { $Flutter = 'flutter' }
& (Join-Path $Root 'tool\checkComments.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Push-Location $Root
& $Flutter analyze --no-fatal-infos --no-fatal-warnings
$Code = $LASTEXITCODE
Pop-Location
exit $Code
