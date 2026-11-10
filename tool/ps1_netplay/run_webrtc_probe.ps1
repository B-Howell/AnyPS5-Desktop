# Requires PowerShell 7.4 for process-scoped environment overrides.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Runner,
    [Parameter(Mandatory)][string]$Data,
    [string]$NativeFixture,
    [switch]$Ordinary,
    [switch]$Lan
)

$ErrorActionPreference = 'Stop'
if ($Lan -and ($Ordinary -or $NativeFixture)) {
    throw 'LAN mode uses its synthetic Ethernet fixture and cannot take a PS1 fixture.'
}
if ($Ordinary -and -not $NativeFixture) {
    throw 'Ordinary mode needs a native fixture.'
}
$runnerPath = (Resolve-Path -LiteralPath $Runner).ProviderPath
$dataPath = (Resolve-Path -LiteralPath $Data).ProviderPath
$fixturePath = if ($NativeFixture) { (Resolve-Path -LiteralPath $NativeFixture).ProviderPath }
$parent = [IO.Path]::TrimEndingDirectorySeparator((Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath)
$scratch = Join-Path $parent ("anyps5-webrtc-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$process = $null
try {
    $stdout = Join-Path $scratch 'stdout.log'
    $stderr = Join-Path $scratch 'stderr.log'
    $process = Start-Process -FilePath $runnerPath -ArgumentList ('"' + $dataPath + '"') `
        -WorkingDirectory (Split-Path -Parent $runnerPath) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -Environment @{
            TEMP = $scratch
            TMP = $scratch
            ANYPS5_PS1_WEBRTC_NATIVE = $fixturePath
            ANYPS5_PS1_WEBRTC_ORDINARY = if ($Ordinary) { '1' } else { $null }
            ANYPS5_PS2_WEBRTC_LAN = if ($Lan) { '1' } else { $null }
        }
    if (-not $process.WaitForExit(75000)) { throw 'The headless WebRTC runner timed out.' }
    Get-Content -LiteralPath $stdout | Where-Object { $_ -notmatch '^The Dart VM service is listening' }
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath $stderr -Tail 12
        throw "The headless WebRTC runner exited with code $($process.ExitCode)."
    }
} finally {
    if ($null -ne $process -and -not $process.HasExited) {
        try {
            $process.Kill($true)
        } catch {
            if (-not $process.HasExited) { throw }
        }
        if (-not $process.WaitForExit(5000)) { throw 'The probe process tree did not stop.' }
    }
    $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ($resolved -ne $scratch -or (Split-Path -Parent $resolved) -ne $parent -or
        ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The scratch directory changed while the probe was running.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
