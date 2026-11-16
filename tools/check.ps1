[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Fix
)

# Windows PowerShell 5.1: save this file as UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$taskRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskLogs = Join-Path ([IO.Path]::GetTempPath()) ('score-reader-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskLogs | Out-Null
$taskResults = New-Object 'System.Collections.Generic.List[object]'
$taskUtf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-LoggedCommand {
    param([string]$Executable, [string[]]$CommandArgs, [string]$Directory, [string]$Log)
    # Arguments here are fixed flags or filesystem paths; reject embedded quotes.
    foreach ($argument in (@($Executable) + $CommandArgs)) {
        if ($argument.Contains('"')) { throw 'Command paths/arguments must not contain a double quote.' }
    }
    $quoted = @(@($Executable) + $CommandArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c "' + $quoted + '"'
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $taskUtf8
    $info.StandardErrorEncoding = $taskUtf8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $outputFile = [IO.File]::Create($Log)
        $errorFile = [IO.File]::Create($Log + '.stderr.log')
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync($outputFile)
        $stderr = $process.StandardError.BaseStream.CopyToAsync($errorFile)
        $process.WaitForExit()
        [void]$stdout.GetAwaiter().GetResult()
        [void]$stderr.GetAwaiter().GetResult()
        return $process.ExitCode
    } finally {
        if ($null -ne $outputFile) { $outputFile.Dispose() }
        if ($null -ne $errorFile) { $errorFile.Dispose() }
        $process.Dispose()
    }
}

function Write-FailingTests {
    param([string]$Log)
    $names = @{}
    $failed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in [IO.File]::ReadLines($Log)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($event.type -eq 'testStart') { $names[$event.test.id] = $event.test.name }
        if (($event.type -eq 'testDone' -and $event.result -in @('failure', 'error')) -or
            $event.type -eq 'error') {
            $name = $null
            if ($null -ne $event.testID) { $name = $names[$event.testID] }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = '测试加载或执行失败，见日志' }
            [void]$failed.Add($name)
        }
    }
    if ($failed.Count -eq 0) { Write-Output '  未取得失败测试名称，请查看日志。' }
    foreach ($name in $failed) { Write-Output ('  失败测试：' + $name) }
}

function Invoke-CheckStep {
    param([string]$Name, [string]$Executable, [string[]]$CommandArgs,
        [string]$Directory = $taskRepo, [switch]$Tests)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $log = Join-Path $taskLogs ('{0:D2}.log' -f ($taskResults.Count + 1))
    $code = 1
    try {
        $code = Invoke-LoggedCommand $Executable $CommandArgs $Directory $log
    } catch {
        [IO.File]::WriteAllText($log, ($_ | Out-String), $taskUtf8)
    }
    $watch.Stop()
    $result = [PSCustomObject]@{ Name = $Name; Passed = ($code -eq 0); Seconds = $watch.Elapsed.TotalSeconds; Log = $log }
    $taskResults.Add($result)
    $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
    Write-Output ('{0} {1} ({2:F1}秒)' -f $status, $Name, $result.Seconds)
    if (-not $result.Passed) {
        Write-Output ('  日志：' + $log)
        if ($Tests) { Write-FailingTests $log }
    }
}

function Get-WorktreeState {
    # Do not stash, reset, clean, or otherwise alter the caller's pending work.
    $status = & git -C $taskRepo status --porcelain=v1 --untracked-files=all
    if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
    $diff = & git -C $taskRepo diff --no-ext-diff --binary HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git diff failed.' }
    return (@($status) + @($diff)) -join "`n"
}

Write-Output ('完整日志：' + $taskLogs)
try {
    $taskSdk = $env:FLUTTER_ROOT
    if ([string]::IsNullOrWhiteSpace($taskSdk)) {
        $command = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            $taskSdk = Split-Path -Parent (Split-Path -Parent $command.Source)
        } else {
            $taskSdk = 'D:/WorkSpace/.tools/flutter'
        }
    }
    $taskSdk = (Resolve-Path -LiteralPath $taskSdk).Path
    $taskFlutter = Join-Path $taskSdk 'bin/flutter.bat'
    $taskDart = Join-Path $taskSdk 'bin/dart.bat'
    foreach ($launcher in @($taskFlutter, $taskDart)) {
        if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "SDK launcher missing: $launcher" }
    }
    $packages = @(Get-ChildItem -LiteralPath (Join-Path $taskRepo 'packages') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pubspec.yaml') } | Sort-Object Name)
    $formatPaths = @('lib', 'test', 'tool', 'flutter_test_config.dart')
    foreach ($package in $packages) {
        foreach ($directory in @('lib', 'test')) {
            $path = Join-Path $package.FullName $directory
            if (Test-Path -LiteralPath $path) { $formatPaths += $path }
        }
    }
    if ($Fix) {
        Invoke-CheckStep -Name '格式修复' -Executable $taskDart -CommandArgs (@('format') + $formatPaths)
    }
    $taskBefore = Get-WorktreeState
    Invoke-CheckStep -Name '格式检查' -Executable $taskDart -CommandArgs (@('format', '--output=none', '--set-exit-if-changed') + $formatPaths)
    # Flutter makes infos fatal by default. Warnings and errors remain fatal.
    Invoke-CheckStep -Name '静态分析 app' -Executable $taskFlutter -CommandArgs @('analyze', '--no-pub', '--no-fatal-infos')
    foreach ($package in $packages) {
        Invoke-CheckStep -Name ('静态分析 ' + $package.Name) -Executable $taskDart -CommandArgs @('analyze') -Directory $package.FullName
    }
    foreach ($package in $packages) {
        Invoke-CheckStep -Name ('测试 ' + $package.Name) -Executable $taskDart -CommandArgs @('test', '--reporter=json') -Directory $package.FullName -Tests
    }
    if ($Fast) {
        Write-Output 'SKIP 测试 app（-Fast）'
    } else {
        Invoke-CheckStep -Name '测试 app' -Executable $taskFlutter -CommandArgs @('test', '--no-pub', '--concurrency=1', '--no-enable-dart-profiling', '--reporter=json') -Tests
    }
    if ((Get-WorktreeState) -cne $taskBefore) {
        throw '检查期间 Git 工作区发生变化；请检查 git status / git diff。脚本未自动还原文件。'
    }
    $failed = @($taskResults | Where-Object { -not $_.Passed }).Count
    $taskResults | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $taskLogs 'summary.json') -Encoding UTF8
    if ($failed -gt 0) { Write-Output ('FAIL 总计：' + $failed + ' 项失败'); exit 1 }
    Write-Output 'PASS 全部检查通过，Git 工作区无新增改动。'
    exit 0
} catch {
    [IO.File]::WriteAllText((Join-Path $taskLogs 'runner-error.log'), ($_ | Out-String), $taskUtf8)
    Write-Output ('FAIL 检查入口：' + $_.Exception.Message)
    Write-Output ('完整日志：' + $taskLogs)
    exit 1
}
