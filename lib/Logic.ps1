# Pure helpers for brightness.ps1: argument parsing, value arithmetic and
# monitor-identity string handling. Free of Win32 calls and I/O so they can be
# unit tested without monitors (tests/Logic.Tests.ps1).

Set-StrictMode -Version 3.0

$script:MaxPercent = 100

function ConvertFrom-PercentToken {
    <#
    .SYNOPSIS
        Parses an absolute brightness such as "40" or "40%" into an integer 0-100.
    #>
    param([Parameter(Mandatory)][string]$Token)

    if ($Token -notmatch '^(\d{1,3})%?$' -or [int]$Matches[1] -gt $script:MaxPercent) {
        throw [System.ArgumentException]::new("invalid brightness '$Token': expected 0-$script:MaxPercent")
    }
    [int]$Matches[1]
}

function ConvertFrom-AdjustmentToken {
    <#
    .SYNOPSIS
        Parses a signed change: "+10"/"-10" are percentage points, "+10%"/"-10%"
        are a proportion of the current value.
    #>
    param([Parameter(Mandatory)][string]$Token)

    if ($Token -notmatch '^([+-])(\d{1,3})(%?)$') {
        throw [System.ArgumentException]::new(
            "invalid change '$Token': expected +N or -N (points) or +N% or -N% (proportional)")
    }
    $amount = [int]$Matches[2]
    if ($Matches[1] -eq '-') { $amount = -$amount }
    [pscustomobject]@{
        Mode   = if ($Matches[3]) { 'Proportional' } else { 'Points' }
        Amount = $amount
    }
}

function Get-AdjustedPercent {
    <#
    .SYNOPSIS
        Applies an adjustment from ConvertFrom-AdjustmentToken to a brightness,
        clamping the result to 0-100.
    #>
    param(
        [Parameter(Mandatory)][int]$Current,
        [Parameter(Mandatory)][object]$Adjustment
    )

    $target = switch ($Adjustment.Mode) {
        'Points'       { $Current + $Adjustment.Amount }
        'Proportional' { $Current * (100 + $Adjustment.Amount) / 100 }
        default        { throw [System.ArgumentException]::new("unknown adjustment mode '$($Adjustment.Mode)'") }
    }
    $rounded = [int][Math]::Round($target, [MidpointRounding]::AwayFromZero)
    [Math]::Min($script:MaxPercent, [Math]::Max(0, $rounded))
}

function ConvertTo-RawValue {
    <#
    .SYNOPSIS
        Maps a percentage onto the monitor's own VCP range 0..Maximum.
    #>
    param(
        [Parameter(Mandatory)][int]$Percent,
        [Parameter(Mandatory)][int]$Maximum
    )

    [int][Math]::Round($Percent * $Maximum / $script:MaxPercent, [MidpointRounding]::AwayFromZero)
}

function ConvertTo-Percent {
    <#
    .SYNOPSIS
        Maps a raw VCP value in 0..Maximum onto 0-100.
    #>
    param(
        [Parameter(Mandatory)][int]$Raw,
        [Parameter(Mandatory)][int]$Maximum
    )

    if ($Maximum -le 0) {
        throw [System.ArgumentOutOfRangeException]::new('Maximum', "monitor reports a range maximum of $Maximum")
    }
    [int][Math]::Round($Raw * $script:MaxPercent / $Maximum, [MidpointRounding]::AwayFromZero)
}

function Split-MonitorArgument {
    <#
    .SYNOPSIS
        Splits "[monitor] <value>" into a selector (default 'all') and a value.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)

    switch ($Arguments.Count) {
        1       { return [pscustomobject]@{ Selector = 'all'; Value = $Arguments[0] } }
        2       { return [pscustomobject]@{ Selector = $Arguments[0]; Value = $Arguments[1] } }
        default { throw [System.ArgumentException]::new('expected [monitor] <value>') }
    }
}

function Select-Monitor {
    <#
    .SYNOPSIS
        Resolves a selector to monitors: 'all', a number from 'list', or text
        matching exactly one monitor's model, manufacturer, serial or display name.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Monitors,
        [Parameter(Mandatory)][string]$Selector
    )

    if ($Selector -eq 'all') {
        return $Monitors
    }
    if ($Selector -match '^\d+$') {
        $found = @($Monitors | Where-Object { $_.Index -eq [int]$Selector })
        if ($found.Count -eq 0) {
            throw [System.ArgumentException]::new("no monitor #$Selector (have 1-$($Monitors.Count))")
        }
        return $found
    }

    $pattern = "*$([System.Management.Automation.WildcardPattern]::Escape($Selector))*"
    $found = @($Monitors | Where-Object {
            $_.Model -like $pattern -or $_.Manufacturer -like $pattern -or
            $_.Serial -like $pattern -or $_.DisplayName -like $pattern
        })
    if ($found.Count -eq 1) {
        return $found
    }
    if ($found.Count -eq 0) {
        throw [System.ArgumentException]::new("no monitor matches '$Selector'")
    }
    $names = ($found | ForEach-Object { "#$($_.Index) $($_.Model)" }) -join ', '
    throw [System.ArgumentException]::new("'$Selector' matches several monitors ($names); use the number")
}

function ConvertFrom-DeviceInterfaceId {
    <#
    .SYNOPSIS
        Turns a monitor device interface path into its PnP instance path:
        \\?\DISPLAY#MSI40B4#5&64f821c&0&UID4613#{e6f07b5f-...} -> DISPLAY\MSI40B4\5&64f821c&0&UID4613
        Returns $null when the input does not have that shape.
    #>
    param([AllowEmptyString()][string]$InterfaceId)

    if ($InterfaceId -match '^\\\\\?\\([^#]+)#([^#]+)#([^#]+)#\{[0-9A-Fa-f-]+\}$') {
        return "$($Matches[1])\$($Matches[2])\$($Matches[3])"
    }
    $null
}

function ConvertFrom-WmiInstanceName {
    <#
    .SYNOPSIS
        Turns a WmiMonitorID instance name into its PnP instance path:
        DISPLAY\MSI40B4\5&64f821c&0&UID4613_0 -> DISPLAY\MSI40B4\5&64f821c&0&UID4613
    #>
    param([AllowEmptyString()][string]$InstanceName)

    $InstanceName -replace '_\d+$', ''
}

function ConvertFrom-EdidString {
    <#
    .SYNOPSIS
        Decodes a WmiMonitorID field (UInt16 character codes, zero padded).
    #>
    param([AllowNull()][object[]]$Codes)

    if (-not $Codes) {
        return ''
    }
    (-join ($Codes | Where-Object { $_ -ne 0 } | ForEach-Object { [char][int]$_ })).Trim()
}
