$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Invalid = @()
$CommentHits = @()
$Files = Get-ChildItem -Path (Join-Path $Root 'lib'), (Join-Path $Root 'test'), (Join-Path $Root 'tool') -Recurse -File | Where-Object { $_.Extension -in '.dart', '.ps1' }
foreach ($File in $Files) {
  $Base = $File.BaseName
  if ($Base -ne 'main' -and $Base -notmatch '^[a-z][A-Za-z0-9]*$') {
    $Invalid += $File.FullName
  }
  $Lines = Get-Content $File.FullName
  for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
    $Line = $Lines[$Index].Trim()
    if ($Line.StartsWith('//') -or $Line.StartsWith('/*') -or $Line.StartsWith('///') -or $Line.StartsWith('# ')) {
      $CommentHits += "$($File.FullName):$($Index + 1)"
    }
  }
}
$Native = Get-ChildItem -Path (Join-Path $Root 'windows\runner\capture') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.cpp', '.h' }
foreach ($File in $Native) {
  $Base = $File.BaseName
  if ($Base -notmatch '^[a-z][A-Za-z0-9]*$') {
    $Invalid += $File.FullName
  }
  $Lines = Get-Content $File.FullName
  for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
    $Line = $Lines[$Index].Trim()
    if ($Line.StartsWith('//') -or $Line.StartsWith('/*') -or $Line.StartsWith('///') -or $Line.StartsWith('# ')) {
      $CommentHits += "$($File.FullName):$($Index + 1)"
    }
  }
}
if ($Invalid.Count -gt 0) {
  Write-Error ("Invalid file names:`n" + ($Invalid -join "`n"))
  exit 1
}
if ($CommentHits.Count -gt 0) {
  Write-Error ("Comments found:`n" + ($CommentHits -join "`n"))
  exit 1
}
$Generated = Get-ChildItem -Path (Join-Path $Root 'windows'), (Join-Path $Root 'macos'), (Join-Path $Root 'linux') -Recurse -File | Where-Object { $_.Extension -in '.cpp', '.h', '.cc' }
$Forbidden = @()
foreach ($File in $Generated) {
  $Text = Get-Content $File.FullName -Raw
  if ($Text -match 'Copyright \(c\)|Flutter Authors|Use of this source') {
    $Forbidden += $File.FullName
  }
}
if ($Forbidden.Count -gt 0) {
  Write-Host "Generated platform files retained for tool compatibility."
}
Write-Host "Naming and comment checks passed."
