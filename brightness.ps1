# brightness - list external monitors and read or change their brightness over
# DDC/CI. Runs in Windows PowerShell 5.1; see README.md. Arguments are parsed
# from $args (no param block) so tokens such as "-10" reach the parser as text
# instead of being taken for PowerShell parameter names.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\Logic.ps1')
. (Join-Path $PSScriptRoot 'lib\Display.ps1')
. (Join-Path $PSScriptRoot 'lib\Overlay.ps1')

$script:VcpBrightness = [byte]0x10          # MCCS feature "Luminance"
$script:WriteSettleMs = 300                 # pause before reading back a write (check --write)
$script:IdentifyDefaultSeconds = 3
$script:IdentifyMaxSeconds = 30
$script:ExitOk = 0
$script:ExitFailure = 1
$script:ExitUsage = 2
$script:HadFailure = $false

$script:Usage = @'
Usage: brightness <command> [arguments]

  list                        Monitors left to right: identity, DDC/CI state, brightness
  identify [seconds]          Show each monitor's number on its screen (default 3 s)
  get [monitor]               Current brightness
  set [monitor] <0-100>       Set brightness
  adjust [monitor] <+N|-N>    Change by N percentage points (30% -10 -> 20%)
  adjust [monitor] <+N%|-N%>  Change by N percent of the current value (30% -10% -> 27%)
  check [monitor] [--write]   Verify DDC/CI answers; --write also proves a write
                              is applied (changes brightness by one step, then restores)
  help                        This text

[monitor] is the number shown by 'list', 'all' (the default), or part of a
monitor's model, manufacturer, serial or \\.\DISPLAYn name.
With no command, 'list' runs.
Exit status: 0 success, 1 a monitor operation failed, 2 usage error.
'@

function Write-Diagnostic {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("brightness: $Message")
}

function Write-Failure {
    param([Parameter(Mandatory)][string]$Message)
    Write-Diagnostic $Message
    $script:HadFailure = $true
}

function Format-MonitorLabel {
    param([Parameter(Mandatory)][object]$Monitor)
    "#$($Monitor.Index) $($Monitor.Model)"
}

function Assert-NoExtraArgument {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments, [int]$Allowed)
    if ($Arguments.Count -gt $Allowed) {
        throw [System.ArgumentException]::new("unexpected argument '$($Arguments[$Allowed])'")
    }
}

function Get-Brightness {
    param([Parameter(Mandatory)][object]$Monitor)

    if ($Monitor.Handle -eq [IntPtr]::Zero) {
        throw [System.IO.IOException]::new('Windows exposes no DDC/CI handle for this display')
    }
    $reply = Read-VcpFeature -Handle $Monitor.Handle -Code $script:VcpBrightness
    [pscustomobject]@{
        Raw     = $reply.Current
        Maximum = $reply.Maximum
        Percent = ConvertTo-Percent -Raw $reply.Current -Maximum $reply.Maximum
    }
}

function Format-Brightness {
    param([Parameter(Mandatory)][object]$Brightness)
    $text = "$($Brightness.Percent)%"
    if ($Brightness.Maximum -ne 100) {
        $text += " (raw $($Brightness.Raw)/$($Brightness.Maximum))"
    }
    $text
}

function Invoke-ForEachMonitor {
    # Runs $Action per monitor; one monitor failing does not stop the others.
    param([Parameter(Mandatory)][object[]]$Monitors, [Parameter(Mandatory)][scriptblock]$Action)

    foreach ($monitor in $Monitors) {
        try {
            & $Action $monitor
        }
        catch [System.ArgumentException] {
            throw
        }
        catch {
            Write-Failure "$(Format-MonitorLabel $monitor): $($_.Exception.Message)"
        }
    }
}

function Set-MonitorPercent {
    param([Parameter(Mandatory)][object]$Monitor, [Parameter(Mandatory)][object]$Current, [int]$Percent)

    $raw = ConvertTo-RawValue -Percent $Percent -Maximum $Current.Maximum
    Write-VcpFeature -Handle $Monitor.Handle -Code $script:VcpBrightness -Value $raw
    "$(Format-MonitorLabel $Monitor): $($Current.Percent)% -> $Percent%"
}

function Invoke-List {
    param([object[]]$Monitors, [string[]]$Arguments)

    Assert-NoExtraArgument $Arguments 0
    $row = '{0,-4}{1,-20}{2,-5}{3,-16}{4,-14}{5,-11}{6,-11}{7}'
    $row -f '#', 'Model', 'Mfr', 'Serial', 'Display', 'Resolution', 'Position', 'Brightness'
    foreach ($monitor in $Monitors) {
        $brightness = try {
            Format-Brightness (Get-Brightness $monitor)
        }
        catch {
            'no DDC/CI reply (run: brightness check)'
        }
        $row -f "$($monitor.Index)$(if ($monitor.IsPrimary) { '*' })", $monitor.Model,
            $monitor.Manufacturer, $monitor.Serial, $monitor.DisplayName,
            "$($monitor.Width)x$($monitor.Height)", "$($monitor.Left),$($monitor.Top)", $brightness
    }
    '* primary display.  Run "brightness identify" to see the numbers on the screens.'
}

function Invoke-Identify {
    param([object[]]$Monitors, [string[]]$Arguments)

    Assert-NoExtraArgument $Arguments 1
    $seconds = $script:IdentifyDefaultSeconds
    if ($Arguments.Count -eq 1) {
        if ($Arguments[0] -notmatch '^\d+$' -or [int]$Arguments[0] -lt 1 -or [int]$Arguments[0] -gt $script:IdentifyMaxSeconds) {
            throw [System.ArgumentException]::new("invalid duration '$($Arguments[0])': expected 1-$script:IdentifyMaxSeconds seconds")
        }
        $seconds = [int]$Arguments[0]
    }
    Show-MonitorNumber -Monitors $Monitors -Seconds $seconds
}

function Invoke-Get {
    param([object[]]$Monitors, [string[]]$Arguments)

    Assert-NoExtraArgument $Arguments 1
    $selector = if ($Arguments.Count -eq 1) { $Arguments[0] } else { 'all' }
    Invoke-ForEachMonitor (Select-Monitor $Monitors $selector) {
        param($monitor)
        "$(Format-MonitorLabel $monitor): $(Format-Brightness (Get-Brightness $monitor))"
    }
}

function Invoke-Set {
    param([object[]]$Monitors, [string[]]$Arguments)

    $request = Split-MonitorArgument $Arguments
    $percent = ConvertFrom-PercentToken $request.Value
    Invoke-ForEachMonitor (Select-Monitor $Monitors $request.Selector) {
        param($monitor)
        Set-MonitorPercent -Monitor $monitor -Current (Get-Brightness $monitor) -Percent $percent
    }
}

function Invoke-Adjust {
    param([object[]]$Monitors, [string[]]$Arguments)

    $request = Split-MonitorArgument $Arguments
    $adjustment = ConvertFrom-AdjustmentToken $request.Value
    Invoke-ForEachMonitor (Select-Monitor $Monitors $request.Selector) {
        param($monitor)
        $current = Get-Brightness $monitor
        $target = Get-AdjustedPercent -Current $current.Percent -Adjustment $adjustment
        Set-MonitorPercent -Monitor $monitor -Current $current -Percent $target
    }
}

function Test-BrightnessWrite {
    # Moves brightness one raw step, reads it back, and always restores it.
    param([Parameter(Mandatory)][object]$Monitor, [Parameter(Mandatory)][object]$Current)

    $probe = if ($Current.Raw -gt 0) { $Current.Raw - 1 } else { 1 }
    try {
        Write-VcpFeature -Handle $Monitor.Handle -Code $script:VcpBrightness -Value $probe
        Start-Sleep -Milliseconds $script:WriteSettleMs
        $seen = (Read-VcpFeature -Handle $Monitor.Handle -Code $script:VcpBrightness).Current
    }
    finally {
        Write-VcpFeature -Handle $Monitor.Handle -Code $script:VcpBrightness -Value $Current.Raw
    }
    Start-Sleep -Milliseconds $script:WriteSettleMs
    $restored = (Read-VcpFeature -Handle $Monitor.Handle -Code $script:VcpBrightness).Current

    $label = Format-MonitorLabel $Monitor
    if ($restored -ne $Current.Raw) {
        Write-Failure "${label}: brightness not restored (raw $restored, was $($Current.Raw)); set it again with 'brightness set'"
    }
    elseif ($seen -ne $probe) {
        Write-Failure "${label}: monitor accepted the write but kept raw $seen instead of $probe (writes are ignored)"
    }
    else {
        "${label}: write OK (raw $($Current.Raw) -> $probe read back, restored to $restored)"
    }
}

function Invoke-Check {
    param([object[]]$Monitors, [string[]]$Arguments)

    $withWrite = $Arguments -contains '--write'
    $rest = @($Arguments | Where-Object { $_ -ne '--write' })
    Assert-NoExtraArgument $rest 1
    $selector = if ($rest.Count -eq 1) { $rest[0] } else { 'all' }

    foreach ($monitor in (Select-Monitor $Monitors $selector)) {
        $label = Format-MonitorLabel $monitor
        if ($monitor.Handle -eq [IntPtr]::Zero) {
            Write-Failure "${label}: no DDC/CI handle - Windows does not offer DDC/CI on this output (typical of DisplayLink and some docks)"
            continue
        }
        try {
            $current = Get-Brightness $monitor
        }
        catch {
            Write-Failure ("${label}: DDC/CI not answering ($($_.Exception.Message)). " +
                "Enable DDC/CI in the monitor's on-screen menu; if it is on, the cable, dock or adapter does not carry DDC.")
            continue
        }
        "${label}: DDC/CI OK, brightness $(Format-Brightness $current) (VCP 0x10 range 0-$($current.Maximum))"
        if ($withWrite) {
            try {
                Test-BrightnessWrite -Monitor $monitor -Current $current
            }
            catch {
                Write-Failure "${label}: write test failed: $($_.Exception.Message)"
            }
        }
    }
}

$commands = @{
    list     = ${function:Invoke-List}
    identify = ${function:Invoke-Identify}
    get      = ${function:Invoke-Get}
    set      = ${function:Invoke-Set}
    adjust   = ${function:Invoke-Adjust}
    check    = ${function:Invoke-Check}
}

$cliArgs = [string[]]@($args)
$commandName = if ($cliArgs.Count -gt 0) { $cliArgs[0].ToLowerInvariant() } else { 'list' }
$commandArgs = [string[]]@($cliArgs | Select-Object -Skip 1)

if ($commandName -in 'help', '-h', '--help', '/?') {
    $script:Usage
    exit $script:ExitOk
}
if (-not $commands.ContainsKey($commandName)) {
    Write-Diagnostic "unknown command '$commandName'"
    [Console]::Error.WriteLine($script:Usage)
    exit $script:ExitUsage
}

$identities = try {
    Get-MonitorIdentityTable
}
catch {
    Write-Diagnostic "monitor names unavailable, using driver names (WMI: $($_.Exception.Message))"
    @{}
}

$exitCode = $script:ExitOk
$monitors = @()
try {
    $monitors = Open-Monitor -Identities $identities
    if ($monitors.Count -eq 0) {
        throw [System.IO.IOException]::new('no displays found')
    }
    & $commands[$commandName] $monitors $commandArgs
    if ($script:HadFailure) {
        $exitCode = $script:ExitFailure
    }
}
catch [System.ArgumentException] {
    Write-Diagnostic "$($_.Exception.Message) (see: brightness help)"
    $exitCode = $script:ExitUsage
}
catch {
    Write-Diagnostic $_.Exception.Message
    $exitCode = $script:ExitFailure
}
finally {
    Close-Monitor $monitors
}
exit $exitCode
