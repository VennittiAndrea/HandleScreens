# Unit tests for lib/Logic.ps1. Written for Pester 3.4, the version bundled
# with Windows PowerShell 5.1 (Pester 5 would need BeforeAll and 'Should -Be').

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\Logic.ps1')

function New-TestMonitor($Index, $Model, $Manufacturer, $Serial, $DisplayName) {
    [pscustomobject]@{
        Index = $Index; Model = $Model; Manufacturer = $Manufacturer
        Serial = $Serial; DisplayName = $DisplayName
    }
}

Describe 'ConvertFrom-PercentToken' {
    It 'accepts 0-100 with an optional percent sign' {
        ConvertFrom-PercentToken '0' | Should Be 0
        ConvertFrom-PercentToken '40' | Should Be 40
        ConvertFrom-PercentToken '100%' | Should Be 100
    }
    It 'rejects values outside 0-100 and non-numbers' {
        { ConvertFrom-PercentToken '101' } | Should Throw
        { ConvertFrom-PercentToken '-5' } | Should Throw
        { ConvertFrom-PercentToken '4x' } | Should Throw
        { ConvertFrom-PercentToken '' } | Should Throw
    }
}

Describe 'ConvertFrom-AdjustmentToken' {
    It 'parses signed points' {
        $a = ConvertFrom-AdjustmentToken '-10'
        $a.Mode | Should Be 'Points'
        $a.Amount | Should Be -10
        (ConvertFrom-AdjustmentToken '+5').Amount | Should Be 5
    }
    It 'parses signed proportions' {
        $a = ConvertFrom-AdjustmentToken '-20%'
        $a.Mode | Should Be 'Proportional'
        $a.Amount | Should Be -20
    }
    It 'requires an explicit sign' {
        { ConvertFrom-AdjustmentToken '10' } | Should Throw
        { ConvertFrom-AdjustmentToken '+' } | Should Throw
    }
}

Describe 'Get-AdjustedPercent' {
    It 'adds points' {
        Get-AdjustedPercent -Current 30 -Adjustment (ConvertFrom-AdjustmentToken '-10') | Should Be 20
    }
    It 'scales proportionally, rounding half away from zero' {
        Get-AdjustedPercent -Current 30 -Adjustment (ConvertFrom-AdjustmentToken '-10%') | Should Be 27
        Get-AdjustedPercent -Current 16 -Adjustment (ConvertFrom-AdjustmentToken '-25%') | Should Be 12
        Get-AdjustedPercent -Current 5 -Adjustment (ConvertFrom-AdjustmentToken '-50%') | Should Be 3
    }
    It 'clamps to 0-100' {
        Get-AdjustedPercent -Current 5 -Adjustment (ConvertFrom-AdjustmentToken '-10') | Should Be 0
        Get-AdjustedPercent -Current 95 -Adjustment (ConvertFrom-AdjustmentToken '+10') | Should Be 100
        Get-AdjustedPercent -Current 80 -Adjustment (ConvertFrom-AdjustmentToken '+50%') | Should Be 100
    }
}

Describe 'ConvertTo-RawValue and ConvertTo-Percent' {
    It 'is the identity for a 0-100 monitor' {
        ConvertTo-RawValue -Percent 37 -Maximum 100 | Should Be 37
        ConvertTo-Percent -Raw 37 -Maximum 100 | Should Be 37
    }
    It 'rescales other ranges' {
        ConvertTo-RawValue -Percent 50 -Maximum 255 | Should Be 128
        ConvertTo-Percent -Raw 128 -Maximum 255 | Should Be 50
    }
    It 'rejects a zero maximum' {
        { ConvertTo-Percent -Raw 0 -Maximum 0 } | Should Throw
    }
}

Describe 'Split-MonitorArgument' {
    It 'defaults the selector to all' {
        $r = Split-MonitorArgument @('40')
        $r.Selector | Should Be 'all'
        $r.Value | Should Be '40'
    }
    It 'takes a selector before the value' {
        $r = Split-MonitorArgument @('2', '-10')
        $r.Selector | Should Be '2'
        $r.Value | Should Be '-10'
    }
    It 'rejects no or too many arguments' {
        { Split-MonitorArgument @() } | Should Throw
        { Split-MonitorArgument @('1', '2', '3') } | Should Throw
    }
}

Describe 'Select-Monitor' {
    $monitors = @(
        (New-TestMonitor 1 'MSI MP273A' 'MSI' '' '\\.\DISPLAY5'),
        (New-TestMonitor 2 'HP 23xi' 'HWP' '6CM1234' '\\.\DISPLAY6')
    )
    It 'returns every monitor for all' {
        @(Select-Monitor $monitors 'all').Count | Should Be 2
    }
    It 'selects by number' {
        (Select-Monitor $monitors '2').Model | Should Be 'HP 23xi'
        { Select-Monitor $monitors '3' } | Should Throw
    }
    It 'selects by unique text, case-insensitively' {
        (Select-Monitor $monitors 'msi').Index | Should Be 1
        (Select-Monitor $monitors '6CM').Index | Should Be 2
        (Select-Monitor $monitors 'DISPLAY6').Index | Should Be 2
    }
    It 'rejects unknown or ambiguous text' {
        { Select-Monitor $monitors 'dell' } | Should Throw
        { Select-Monitor $monitors 'DISPLAY' } | Should Throw
    }
    It 'treats wildcard characters literally' {
        { Select-Monitor $monitors '*' } | Should Throw
    }
}

Describe 'Monitor identity strings' {
    It 'reduces a device interface id to the PnP instance path' {
        ConvertFrom-DeviceInterfaceId '\\?\DISPLAY#MSI40B4#5&64f821c&0&UID4613#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}' |
            Should Be 'DISPLAY\MSI40B4\5&64f821c&0&UID4613'
        ConvertFrom-DeviceInterfaceId 'garbage' | Should Be $null
    }
    It 'reduces a WMI instance name to the same path' {
        ConvertFrom-WmiInstanceName 'DISPLAY\MSI40B4\5&64f821c&0&UID4613_0' |
            Should Be 'DISPLAY\MSI40B4\5&64f821c&0&UID4613'
    }
    It 'decodes zero-padded EDID strings' {
        ConvertFrom-EdidString @(72, 80, 32, 50, 51, 120, 105, 0, 0) | Should Be 'HP 23xi'
        ConvertFrom-EdidString $null | Should Be ''
    }
}
