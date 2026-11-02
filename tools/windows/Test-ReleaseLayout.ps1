[CmdletBinding()]
param([string]$EvidenceDirectory = (Join-Path $PSScriptRoot '../../artifacts/qa/pm31-r1/windows-layout'))
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
if (-not $evidence.StartsWith((Join-Path $repo 'artifacts') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must remain inside project artifacts.' }
if (Test-Path -LiteralPath $evidence) { throw 'Evidence exists; refusing to overwrite.' }
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$install = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\SheetMusicReader'
$productionPaths = @((Join-Path $install 'deployment.json'), (Join-Path $install '曲谱阅读器.exe'), (Join-Path ([Environment]::GetFolderPath('Programs')) '曲谱阅读器.lnk'))
function Get-ProductionHashes {
  foreach ($path in $productionPaths) { if (Test-Path -LiteralPath $path) { [ordered]@{ path = $path; sha256 = (Get-FileHash -LiteralPath $path).Hash } } }
}
$before = @(Get-ProductionHashes)
$results = [Collections.Generic.List[object]]::new()
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$checker = Join-Path $evidence 'ContractLauncher.exe'
& $csc /nologo /target:exe /platform:x64 "/out:$checker" /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'StableLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Contract checker compilation failed.' }
$legacy = Join-Path $repo 'artifacts\reader-update-0.8.10+30-win-x64'
$publish = Join-Path $PSScriptRoot 'Publish-Reader.ps1'
$legacyReport = & $publish -ReleaseDirectory $legacy -ValidateOnly | ConvertFrom-Json
if ($legacyReport.members.Count -ne 18) { throw 'Legacy fixture must contain 18 members.' }
$candidate = Join-Path $evidence 'reader-update-0.8.10+31-win-x64'
[IO.Directory]::CreateDirectory($candidate) | Out-Null
foreach ($member in $legacyReport.members) {
  $destination = Join-Path $candidate $member
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
  [IO.File]::Copy((Join-Path $legacy $member), $destination)
}
$stubSource = Join-Path $evidence 'NeverStarted.cs'
@'
using System.Reflection;
[assembly: AssemblyVersion("0.8.10.31")]
[assembly: AssemblyFileVersion("0.8.10.31")]
[assembly: AssemblyInformationalVersion("0.8.10+31")]
class NeverStarted { static int Main() { return 91; } }
'@ | Set-Content -LiteralPath $stubSource -Encoding utf8
& $csc /nologo /target:exe /platform:x64 "/out:$(Join-Path $candidate 'score_reader.exe')" $stubSource
if ($LASTEXITCODE -ne 0) { throw 'Version-only fixture compilation failed.' }
$share = Join-Path $candidate 'share_plus_plugin.dll'
[IO.File]::WriteAllText($share, 'Layout fixture, not a loadable plugin.')
$candidateReport = & $publish -ReleaseDirectory $candidate -LayoutProfile share-v1 -ValidateOnly | ConvertFrom-Json
if ($candidateReport.members.Count -ne 19) { throw 'Share fixture must contain 19 members.' }
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Pointer([string]$Name, $Report, [string]$Profile, [string]$Directory) {
  $path = Join-Path $evidence "$Name.pointer.json"
  $data = [ordered]@{ appId = 'SheetMusicReader.Desktop'; version = $Report.version; releaseDirectory = $Directory; members = $Report.members; sha256 = $Report.sha256 }
  if ($Profile) { $data.layoutProfile = $Profile }
  [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 5), $utf8)
  return $path
}
function Check-Launcher([string]$Name, [string]$Pointer, [bool]$Expected) {
  $output = Join-Path $evidence "$Name.launcher.json"
  $process = Start-Process -FilePath $checker -ArgumentList @('--verify', '--pointer', ('"' + $Pointer + '"'), '--output', ('"' + $output + '"')) -WindowStyle Hidden -PassThru -Wait
  $result = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
  if (($process.ExitCode -eq 0 -and $result.ok) -ne $Expected) { throw "Unexpected launcher result: $Name" }
  $results.Add([ordered]@{ check = $Name; validator = 'launcher --verify'; accepted = [bool]$result.ok; expected = $Expected; detail = $result })
}
function Check-Publish([string]$Name, [string]$Directory, [string]$Profile, [bool]$Expected) {
  $accepted = $false; $detail = $null
  try { $detail = & $publish -ReleaseDirectory $Directory -LayoutProfile $Profile -ValidateOnly | ConvertFrom-Json; $accepted = $true } catch { $detail = $_.Exception.Message }
  if ($accepted -ne $Expected) { throw "Unexpected publisher validation result: $Name ($detail)" }
  $results.Add([ordered]@{ check = $Name; validator = 'Publish -ValidateOnly'; accepted = $accepted; expected = $Expected; detail = $detail })
}
try {
  # Missing layoutProfile is deliberately accepted for already-installed legacy30 pointers.
  $oldPointer = Write-Pointer 'legacy30' $legacyReport '' $legacy
  $newPointer = Write-Pointer 'share31' $candidateReport 'share-v1' $candidate
  Check-Launcher 'legacy30-18' $oldPointer $true
  Check-Publish 'legacy30-18' $legacy 'legacy' $true
  Check-Launcher 'share31-19' $newPointer $true
  Check-Publish 'share31-19' $candidate 'share-v1' $true
  $shareBytes = [IO.File]::ReadAllBytes($share)
  Remove-Item -LiteralPath $share
  Check-Launcher 'missing-share-dll' $newPointer $false
  Check-Publish 'missing-share-dll' $candidate 'share-v1' $false
  [IO.File]::WriteAllBytes($share, $shareBytes)
  $extra = Join-Path $candidate 'unexpected.dll'
  [IO.File]::WriteAllText($extra, 'unexpected')
  Check-Launcher 'extra-dll' $newPointer $false
  Check-Publish 'extra-dll' $candidate 'share-v1' $false
  Remove-Item -LiteralPath $extra
  $wrongProfile = Write-Pointer 'unknown-profile' $candidateReport 'unknown' $candidate
  Check-Launcher 'unknown-profile' $wrongProfile $false
  Check-Publish 'unknown-profile' $candidate 'unknown' $false
  $wrongLegacy = Write-Pointer 'legacy31' $candidateReport 'legacy' $candidate
  Check-Launcher '31-requires-share-profile' $wrongLegacy $false
  Check-Publish '31-requires-share-profile' $candidate 'legacy' $false
  [IO.File]::AppendAllText($share, 'corrupted')
  Check-Launcher 'sha-mismatch' $newPointer $false
  [IO.File]::WriteAllBytes($share, $shareBytes)
  $relative = Write-Pointer 'relative-path' $candidateReport 'share-v1' 'relative\reader-update-0.8.10+31-win-x64'
  Check-Launcher 'relative-path' $relative $false
  $junction = Join-Path $evidence 'linked-release'
  New-Item -ItemType Junction -Path $junction -Target $candidate | Out-Null
  $linkedPointer = Write-Pointer 'linked-root' $candidateReport 'share-v1' $junction
  Check-Launcher 'linked-root' $linkedPointer $false
  # A correctly named nested junction must also be rejected, without following it.
  $nested = Join-Path $candidate 'linked-assets'
  New-Item -ItemType Junction -Path $nested -Target (Join-Path $candidate 'data') | Out-Null
  Check-Launcher 'nested-reparse-point' $newPointer $false
  Check-Publish 'nested-reparse-point' $candidate 'share-v1' $false
} finally {
  $after = @(Get-ProductionHashes)
  if (($before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) { throw 'Production pointer, launcher or Start shortcut changed.' }
}
$report = [ordered]@{ ok = $true; readerStarted = $false; productionUnchanged = $true; checks = @($results); productionBefore = $before; productionAfter = $after; caveat = 'Only layout/version/hash validation. The synthetic31 exe and DLL were never executed as a reader and are not a release build.' }
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'report.json') -Encoding utf8
Write-Output "PASS: $($results.Count) non-starting layout contract checks; production unchanged. $evidence"
