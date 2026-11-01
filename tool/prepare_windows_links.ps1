[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskMetadataPath = Join-Path $taskProjectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $taskMetadataPath)) {
    throw 'Run flutter pub get first so the generated plugin metadata exists.'
}

# Directory junctions provide the same local plugin source paths without
# changing Windows Developer Mode or requiring a privileged symbolic link.
$taskLinkRoot = [System.IO.Path]::GetFullPath((Join-Path $taskProjectRoot 'windows\flutter\ephemeral\.plugin_symlinks'))
$taskExpectedPrefix = $taskProjectRoot.TrimEnd('\') + '\'
if (-not $taskLinkRoot.StartsWith($taskExpectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Plugin link directory escaped the project.'
}
New-Item -ItemType Directory -Path $taskLinkRoot -Force | Out-Null
$taskMetadata = Get-Content -LiteralPath $taskMetadataPath -Raw | ConvertFrom-Json
foreach ($taskPlugin in $taskMetadata.plugins.windows) {
    if ($taskPlugin.name -notmatch '^[a-z0-9_]+$') {
        throw 'Unexpected plugin name in generated metadata.'
    }
    $taskLinkPath = [System.IO.Path]::GetFullPath((Join-Path $taskLinkRoot $taskPlugin.name))
    if (-not $taskLinkPath.StartsWith($taskLinkRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Plugin path escaped the checked link directory.'
    }
    $taskTarget = [System.IO.Path]::GetFullPath($taskPlugin.path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $taskTarget -PathType Container)) {
        throw "Missing plugin package: $($taskPlugin.name)"
    }
    $taskExisting = Get-Item -LiteralPath $taskLinkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $taskExisting) {
        if ($taskExisting.LinkType -notin @('Junction', 'SymbolicLink')) {
            throw "Refusing to replace a regular file or folder: $taskLinkPath"
        }
        $taskExistingTarget = [System.IO.Path]::GetFullPath([string]@($taskExisting.Target)[0]).TrimEnd('\')
        if ($taskExistingTarget -eq $taskTarget) { continue }
        # Remove only the checked link itself. Never recurse into its Pub Cache target.
        Remove-Item -LiteralPath $taskLinkPath -Force
    }
    New-Item -ItemType Junction -Path $taskLinkPath -Target $taskTarget | Out-Null
    Write-Output "Prepared plugin link: $($taskPlugin.name)"
}
