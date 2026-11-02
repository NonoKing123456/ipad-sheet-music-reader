[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ReleaseDirectory,
  [switch]$InstallLauncher,
  [ValidateSet('legacy', 'share-v1')][string]$LayoutProfile = 'legacy',
  [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
$appId = 'SheetMusicReader.Desktop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$release = (Resolve-Path -LiteralPath $ReleaseDirectory).Path.TrimEnd('\')
$name = Split-Path $release -Leaf
if ($name -notmatch '^reader-update-(\d+\.\d+\.\d+\+\d+)-win-x64$') { throw 'Expected a versioned reader-update-x.y.z+N-win-x64 directory.' }
$version = $Matches[1]
if ($LayoutProfile -eq 'legacy' -and [Version]($version.Replace('+', '.')) -ge [Version]'0.8.10.31') { throw 'Release 0.8.10+31 and later requires -LayoutProfile share-v1.' }
$members = @(
  'dartjni.dll', 'file_selector_windows_plugin.dll', 'flutter_windows.dll',
  'native_assets.json', 'pdfium.dll', 'pdfrx_pdfium_gate.dll', 'score_reader.exe',
  'url_launcher_windows_plugin.dll', 'data\app.so', 'data\icudtl.dat',
  'data\flutter_assets\AssetManifest.bin', 'data\flutter_assets\FontManifest.json',
  'data\flutter_assets\NativeAssetsManifest.json', 'data\flutter_assets\NOTICES.Z',
  'data\flutter_assets\fonts\MaterialIcons-Regular.otf',
  'data\flutter_assets\packages\material_ui\shaders\ink_sparkle.frag',
  'data\flutter_assets\shaders\ink_sparkle.frag',
  'data\flutter_assets\shaders\stretch_effect.frag'
)
if ($LayoutProfile -eq 'share-v1') { $members += 'share_plus_plugin.dll' }
if ((Get-Item -LiteralPath $release).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release cannot be a reparse point.' }
$items = @(Get-ChildItem -LiteralPath $release -Recurse -Force)
if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Release contains a reparse point.' }
$files = @($items | Where-Object { -not $_.PSIsContainer })
if ($files.Count -ne $members.Count) { throw "Expected $($members.Count) release files for $LayoutProfile; found $($files.Count)." }
$hashes = [ordered]@{}
foreach ($member in $members) {
  $path = Join-Path $release $member
  if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw "Missing or empty release member: $member" }
  $hashes[$member] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$exeVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $release 'score_reader.exe'))
if ($exeVersion.ProductVersion -ne $version) { throw "Executable product version $($exeVersion.ProductVersion) does not match $version." }
if ($ValidateOnly) {
  [ordered]@{ ok = $true; version = $version; layoutProfile = $LayoutProfile; members = $members; sha256 = $hashes; releaseDirectory = $release } | ConvertTo-Json -Depth 4
  return
}
$install = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\SheetMusicReader'
[IO.Directory]::CreateDirectory($install) | Out-Null
$launcher = Join-Path $install '曲谱阅读器.exe'
$icon = Join-Path $install 'app_icon.ico'
$utf8 = New-Object Text.UTF8Encoding($false)
if ($InstallLauncher -or -not (Test-Path -LiteralPath $launcher)) {
  $build = Join-Path $repo 'artifacts\stable-launcher-build'
  [IO.Directory]::CreateDirectory($build) | Out-Null
  Copy-Item -LiteralPath (Join-Path $repo 'windows\runner\resources\app_icon.ico') -Destination (Join-Path $build 'app_icon.ico') -Force
  $rc = Get-ChildItem -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter rc.exe -Recurse |
    Where-Object { $_.FullName -match '\\x64\\rc.exe$' } | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $rc) { throw 'Windows SDK rc.exe was not found.' }
  Push-Location $build
  try {
    & $rc.FullName /nologo /fo launcher.res (Join-Path $PSScriptRoot 'launcher.rc')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher resource compilation failed.' }
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:winexe /platform:x64 /optimize+ /win32res:launcher.res /out:StableLauncher.exe /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll (Join-Path $PSScriptRoot 'StableLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
  } finally { Pop-Location }
  # Only explicit launcher upgrades replace this fixed executable; normal releases update the pointer.
  Copy-Item -LiteralPath (Join-Path $build 'StableLauncher.exe') -Destination ($launcher + '.new') -Force
  if (Test-Path -LiteralPath $launcher) { [IO.File]::Replace($launcher + '.new', $launcher, [NullString]::Value) }
  else { [IO.File]::Move($launcher + '.new', $launcher) }
  Copy-Item -LiteralPath (Join-Path $build 'app_icon.ico') -Destination $icon -Force
}
$pointer = Join-Path $install 'deployment.json'
$candidate = Join-Path $install ('deployment.' + [Guid]::NewGuid().ToString('N') + '.tmp')
$verification = $candidate + '.verification.json'
try {
  $json = [ordered]@{ appId = $appId; version = $version; releaseDirectory = $release; members = $members; layoutProfile = $LayoutProfile; sha256 = $hashes } | ConvertTo-Json -Depth 4
  [IO.File]::WriteAllText($candidate, $json, $utf8)
  $process = Start-Process -FilePath $launcher -ArgumentList @('--verify', '--pointer', ('"' + $candidate + '"'), '--output', ('"' + $verification + '"')) -WindowStyle Hidden -PassThru -Wait
  if ($process.ExitCode -ne 0) { throw "Launcher rejected deployment: $([IO.File]::ReadAllText($verification))" }
  if (Test-Path -LiteralPath $pointer) { [IO.File]::Replace($candidate, $pointer, [NullString]::Value) }
  else { [IO.File]::Move($candidate, $pointer) }
} finally {
  if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate }
  if (Test-Path -LiteralPath $verification) { Remove-Item -LiteralPath $verification }
}
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) '曲谱阅读器.lnk'
if ($InstallLauncher -or -not (Test-Path -LiteralPath $shortcut)) {
  Add-Type -Path (Join-Path $PSScriptRoot 'ShortcutIdentity.cs')
  [ShortcutIdentity]::Create($shortcut, $launcher, $icon)
  $identity = [ShortcutIdentity]::Inspect($shortcut)
  if ($identity[0] -ne $launcher -or $identity[1] -ne $appId) { throw 'Start shortcut identity verification failed.' }
}
[ordered]@{ version = $version; layoutProfile = $LayoutProfile; pointer = $pointer; launcher = $launcher; shortcut = $shortcut; appId = $appId;
  executableSha256 = (Get-FileHash -LiteralPath (Join-Path $release 'score_reader.exe') -Algorithm SHA256).Hash;
  launcherSha256 = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash } | ConvertTo-Json
