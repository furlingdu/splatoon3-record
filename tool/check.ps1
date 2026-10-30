$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Flutter = $env:FLUTTER_ROOT
if ($Flutter) { $Flutter = Join-Path $Flutter 'bin\flutter.bat' } else { $Flutter = 'flutter' }
& (Join-Path $Root 'tool\checkComments.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Push-Location $Root
& $Flutter analyze --no-fatal-infos --no-fatal-warnings
$Code = $LASTEXITCODE
Pop-Location
exit $Code
