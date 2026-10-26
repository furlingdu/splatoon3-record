$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
if (!(Test-Path $Iscc)) { Write-Error 'Inno Setup 6 not installed'; exit 1 }
Push-Location $Root
& $Iscc 'setup\Setup.iss'
$Code = $LASTEXITCODE
Pop-Location
exit $Code
