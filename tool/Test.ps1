$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Flutter = 'D:\Develop\FlutterSdk\flutter\bin\flutter.bat'
if (!(Test-Path $Flutter)) { $Flutter = 'flutter' }
$Tests = Get-ChildItem -Path (Join-Path $Root 'test') -Filter '*Test.dart' -File | Sort-Object Name
if ($Tests.Count -eq 0) { Write-Error 'No tests found'; exit 1 }
Push-Location $Root
$Code = 0
foreach ($Test in $Tests) {
  & $Flutter test --no-pub --concurrency=1 $Test.FullName
  if ($LASTEXITCODE -ne 0) {
    Start-Sleep -Milliseconds 500
    & $Flutter test --no-pub --concurrency=1 $Test.FullName
    if ($LASTEXITCODE -ne 0) { $Code = $LASTEXITCODE; break }
  }
}
Pop-Location
exit $Code
