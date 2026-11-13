# Requires PowerShell 7.4 for process-scoped environment overrides.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Runner,
    [Parameter(Mandatory)][string]$Data,
    [string]$NativeFixture,
    [string]$RaceTrace,
    [ValidateRange(1024, 65535)][int]$TurnPort,
    [string]$TurnAddress = '127.0.0.1',
    [switch]$Ordinary,
    [switch]$DualShock,
    [switch]$Lan
)

$ErrorActionPreference = 'Stop'
if ($RaceTrace -and -not $DualShock) {
    throw 'Race traces require DualShock mode.'
}
if ($TurnPort -and -not ($DualShock -or $Lan)) {
    throw 'The local TURN fixture requires DualShock or LAN mode.'
}
if ($PSBoundParameters.ContainsKey('TurnAddress') -and -not $TurnPort) {
    throw 'A TURN address requires a TURN port.'
}
if ($TurnPort -and $TurnAddress -ne '127.0.0.1') {
    $adapter = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.IPAddress -eq $TurnAddress -and $_.InterfaceAlias -like 'vEthernet (WSL*' -and $_.AddressState -eq 'Preferred'
    }
    if (-not $adapter) { throw 'The TURN fixture must use loopback or the local WSL virtual adapter.' }
}
if ($Lan -and ($Ordinary -or $DualShock -or $NativeFixture)) {
    throw 'LAN mode uses its synthetic Ethernet fixture and cannot take a PS1 fixture.'
}
if ($Ordinary -and $DualShock) {
    throw 'Ordinary and DualShock modes are mutually exclusive.'
}
if (($Ordinary -or $DualShock) -and -not $NativeFixture) {
    throw 'This mode needs a native fixture.'
}
$runnerPath = (Resolve-Path -LiteralPath $Runner).ProviderPath
$dataPath = (Resolve-Path -LiteralPath $Data).ProviderPath
$fixturePath = if ($NativeFixture) { (Resolve-Path -LiteralPath $NativeFixture).ProviderPath }
$tracePath = if ($RaceTrace) { (Resolve-Path -LiteralPath $RaceTrace).ProviderPath }
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
            ANYPS5_PS1_WEBRTC_RACE_TRACE = $tracePath
            ANYPS5_TEST_TURN_PORT = if ($TurnPort) { [string]$TurnPort } else { $null }
            ANYPS5_TEST_TURN_ADDRESS = if ($TurnPort) { $TurnAddress } else { $null }
            ANYPS5_PS1_WEBRTC_DUALSHOCK = if ($DualShock) { '1' } else { $null }
            ANYPS5_PS2_WEBRTC_LAN = if ($Lan) { '1' } else { $null }
        }
    $timeoutMs = if ($RaceTrace) { 430000 } else { 75000 }
    if (-not $process.WaitForExit($timeoutMs)) { throw 'The headless WebRTC runner timed out.' }
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
