# Shows each monitor's number from 'list' on its own screen, so the numbers
# can be matched to the physical monitors on the desk.

Set-StrictMode -Version 3.0

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:OverlayWidth = 560
$script:OverlayHeight = 320
$script:CaptionHeight = 60
$script:NumberFontSize = 120
$script:CaptionFontSize = 16
$script:OverlayPollMs = 50

function New-OverlayLabel {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][float]$FontSize,
        [Parameter(Mandatory)][System.Windows.Forms.DockStyle]$Dock
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Dock = $Dock
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $FontSize, [System.Drawing.FontStyle]::Bold)
    $label
}

function New-OverlayForm {
    param([Parameter(Mandatory)][object]$Monitor)

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = [System.Drawing.Color]::Black
    $form.Bounds = New-Object System.Drawing.Rectangle(
        ($Monitor.Left + [int](($Monitor.Width - $script:OverlayWidth) / 2)),
        ($Monitor.Top + [int](($Monitor.Height - $script:OverlayHeight) / 2)),
        $script:OverlayWidth,
        $script:OverlayHeight)

    # WinForms docks the last-added control first, so the caption claims the
    # bottom strip before the number fills the rest.
    $form.Controls.Add((New-OverlayLabel -Text "$($Monitor.Index)" -FontSize $script:NumberFontSize -Dock Fill))
    $caption = New-OverlayLabel -Text "$($Monitor.Model)   $($Monitor.DisplayName)" `
        -FontSize $script:CaptionFontSize -Dock Bottom
    $caption.Height = $script:CaptionHeight
    $form.Controls.Add($caption)
    $form
}

function Show-MonitorNumber {
    <#
    .SYNOPSIS
        Displays each monitor's number centred on its screen for a few seconds.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Monitors,
        [Parameter(Mandatory)][int]$Seconds
    )

    $forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    try {
        foreach ($monitor in $Monitors) {
            $form = New-OverlayForm -Monitor $monitor
            $forms.Add($form)
            $form.Show()
        }
        # No message loop runs in a script, so pump events to keep the windows painted.
        $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds $script:OverlayPollMs
        }
    }
    finally {
        foreach ($form in $forms) {
            $form.Close()
            $form.Dispose()
        }
    }
}
