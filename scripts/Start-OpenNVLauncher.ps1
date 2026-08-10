param(
    [ValidateSet("NewVegas", "Fallout3", "TTW")]
    [string]$Campaign = "TTW",
    [switch]$EnableJam,
    [switch]$NewGame,
    # Intended for automated verification and support diagnostics. It runs the
    # same selected launcher profile without opening a Windows form or OpenMW.
    [switch]$Headless,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$stateScript = Join-Path $PSScriptRoot "Get-OpenNVLauncherState.ps1"
$launchScript = Join-Path $PSScriptRoot "Start-OpenNV.ps1"
foreach ($requiredScript in @($stateScript, $launchScript)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Missing OpenNV launcher component: $requiredScript"
    }
}

function Get-OpenNVLauncherViewState {
    $json = & $stateScript -AsJson
    return ($json | ConvertFrom-Json)
}

function Get-OpenNVCampaignRecord {
    param(
        [Parameter(Mandatory=$true)]$State,
        [Parameter(Mandatory=$true)][ValidateSet("NewVegas", "Fallout3", "TTW")][string]$Id
    )

    $record = @($State.campaigns | Where-Object { [string]$_.id -eq $Id })
    if ($record.Count -ne 1) {
        throw "The launcher state did not provide one record for campaign '$Id'."
    }
    return $record[0]
}

function Get-OpenNVVariantRecord {
    param(
        [Parameter(Mandatory=$true)]$CampaignRecord,
        [Parameter(Mandatory=$true)][bool]$Jam
    )

    $name = if ($Jam) { "jam" } else { "vanilla" }
    $property = $CampaignRecord.variants.PSObject.Properties[$name]
    if ($null -eq $property) {
        throw "The $($CampaignRecord.title) launcher profile does not support the requested JAM selection."
    }
    return $property.Value
}

function Get-OpenNVLaunchArguments {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("NewVegas", "Fallout3", "TTW")][string]$SelectedCampaign,
        [Parameter(Mandatory=$true)][bool]$Jam,
        [Parameter(Mandatory=$true)][bool]$StartNewGame,
        [switch]$UseDryRun
    )

    if ($SelectedCampaign -eq "Fallout3" -and $Jam) {
        throw "Standalone Fallout 3 has no JAM variant. Use TTW + JAM for a Capital Wasteland-to-Mojave character."
    }

    $arguments = @{
        Campaign = $SelectedCampaign
    }
    if ($Jam) { $arguments.EnableJam = $true }
    if ($StartNewGame) {
        $arguments.NewGame = $true
        $arguments.SkipMenu = $true
    }
    if ($UseDryRun) { $arguments.DryRun = $true }
    return $arguments
}

if ($Headless -or $DryRun) {
    $arguments = Get-OpenNVLaunchArguments `
        -SelectedCampaign $Campaign `
        -Jam ([bool]$EnableJam) `
        -StartNewGame ([bool]$NewGame) `
        -UseDryRun
    & $launchScript @arguments
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:launcherState = Get-OpenNVLauncherViewState
$script:selectedCampaign = $Campaign
$script:selectedJam = if ($Campaign -eq "Fallout3") { $false } else { [bool]($EnableJam -or $Campaign -eq "TTW") }
$script:selectedVariant = $null

$form = [Windows.Forms.Form]::new()
$form.Text = "OpenNV Launcher"
$form.ClientSize = [Drawing.Size]::new(820, 590)
$form.MinimumSize = [Drawing.Size]::new(820, 590)
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = [Drawing.Color]::FromArgb(20, 24, 20)
$form.ForeColor = [Drawing.Color]::FromArgb(225, 236, 215)
$form.Font = [Drawing.Font]::new("Segoe UI", 9)

$title = [Windows.Forms.Label]::new()
$title.Text = "OpenNV Compatibility Launcher"
$title.Font = [Drawing.Font]::new("Segoe UI", 18, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(135, 220, 120)
$title.AutoSize = $true
$title.Location = [Drawing.Point]::new(22, 17)
$form.Controls.Add($title)

$subtitle = [Windows.Forms.Label]::new()
$subtitle.Text = "Choose one character campaign. The launcher mounts only verified local data and profile-owned fallbacks."
$subtitle.AutoSize = $true
$subtitle.Location = [Drawing.Point]::new(24, 53)
$form.Controls.Add($subtitle)

$campaignGroup = [Windows.Forms.GroupBox]::new()
$campaignGroup.Text = "Campaign"
$campaignGroup.ForeColor = $form.ForeColor
$campaignGroup.Location = [Drawing.Point]::new(22, 84)
$campaignGroup.Size = [Drawing.Size]::new(355, 154)
$form.Controls.Add($campaignGroup)

$nvRadio = [Windows.Forms.RadioButton]::new()
$nvRadio.Text = "Fallout: New Vegas - standalone Mojave character"
$nvRadio.AutoSize = $true
$nvRadio.Location = [Drawing.Point]::new(15, 28)
$campaignGroup.Controls.Add($nvRadio)

$fo3Radio = [Windows.Forms.RadioButton]::new()
$fo3Radio.Text = "Fallout 3 - standalone Capital Wasteland character"
$fo3Radio.AutoSize = $true
$fo3Radio.Location = [Drawing.Point]::new(15, 62)
$campaignGroup.Controls.Add($fo3Radio)

$ttwRadio = [Windows.Forms.RadioButton]::new()
$ttwRadio.Text = "TTW - one Capital Wasteland-to-Mojave character"
$ttwRadio.AutoSize = $true
$ttwRadio.Location = [Drawing.Point]::new(15, 96)
$campaignGroup.Controls.Add($ttwRadio)

$jamCheck = [Windows.Forms.CheckBox]::new()
$jamCheck.Text = "Enable JAM (verified optional layer)"
$jamCheck.AutoSize = $true
$jamCheck.Location = [Drawing.Point]::new(28, 251)
$form.Controls.Add($jamCheck)

$newGameCheck = [Windows.Forms.CheckBox]::new()
$newGameCheck.Text = "Start a new character now (skip the OpenMW title menu)"
$newGameCheck.AutoSize = $true
$newGameCheck.Checked = $true
$newGameCheck.Location = [Drawing.Point]::new(28, 281)
$form.Controls.Add($newGameCheck)

$statusLabel = [Windows.Forms.Label]::new()
$statusLabel.AutoSize = $false
$statusLabel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$statusLabel.Location = [Drawing.Point]::new(22, 322)
$statusLabel.Size = [Drawing.Size]::new(355, 147)
$statusLabel.Padding = [Windows.Forms.Padding]::new(10)
$form.Controls.Add($statusLabel)

$modulesGroup = [Windows.Forms.GroupBox]::new()
$modulesGroup.Text = "Optional mod compatibility"
$modulesGroup.ForeColor = $form.ForeColor
$modulesGroup.Location = [Drawing.Point]::new(397, 84)
$modulesGroup.Size = [Drawing.Size]::new(400, 222)
$form.Controls.Add($modulesGroup)

$modulesBox = [Windows.Forms.TextBox]::new()
$modulesBox.Multiline = $true
$modulesBox.ReadOnly = $true
$modulesBox.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$modulesBox.BackColor = [Drawing.Color]::FromArgb(9, 12, 9)
$modulesBox.ForeColor = [Drawing.Color]::FromArgb(211, 233, 194)
$modulesBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$modulesBox.Location = [Drawing.Point]::new(12, 25)
$modulesBox.Size = [Drawing.Size]::new(376, 184)
$modulesGroup.Controls.Add($modulesBox)

$detailsBox = [Windows.Forms.TextBox]::new()
$detailsBox.Multiline = $true
$detailsBox.ReadOnly = $true
$detailsBox.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
$detailsBox.BackColor = [Drawing.Color]::FromArgb(9, 12, 9)
$detailsBox.ForeColor = [Drawing.Color]::FromArgb(211, 233, 194)
$detailsBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$detailsBox.Location = [Drawing.Point]::new(397, 322)
$detailsBox.Size = [Drawing.Size]::new(400, 147)
$form.Controls.Add($detailsBox)

$refreshButton = [Windows.Forms.Button]::new()
$refreshButton.Text = "Refresh preflight"
$refreshButton.Location = [Drawing.Point]::new(22, 500)
$refreshButton.Size = [Drawing.Size]::new(135, 38)
$form.Controls.Add($refreshButton)

$profileButton = [Windows.Forms.Button]::new()
$profileButton.Text = "Open profile"
$profileButton.Location = [Drawing.Point]::new(169, 500)
$profileButton.Size = [Drawing.Size]::new(112, 38)
$form.Controls.Add($profileButton)

$launchButton = [Windows.Forms.Button]::new()
$launchButton.Text = "Launch selected profile"
$launchButton.Location = [Drawing.Point]::new(592, 500)
$launchButton.Size = [Drawing.Size]::new(205, 38)
$launchButton.BackColor = [Drawing.Color]::FromArgb(45, 104, 47)
$launchButton.ForeColor = [Drawing.Color]::White
$form.Controls.Add($launchButton)

function Set-OpenNVSelectedRadio {
    switch ($script:selectedCampaign) {
        "NewVegas" { $nvRadio.Checked = $true }
        "Fallout3" { $fo3Radio.Checked = $true }
        default { $ttwRadio.Checked = $true }
    }
}

function Update-OpenNVLauncherView {
    $campaignRecord = Get-OpenNVCampaignRecord -State $script:launcherState -Id $script:selectedCampaign
    $jamSupported = [bool]$campaignRecord.jam
    if (-not $jamSupported) {
        $script:selectedJam = $false
    }
    $jamCheck.Enabled = $jamSupported
    $jamCheck.Checked = $script:selectedJam
    $jamCheck.Text = if ($jamSupported) { "Enable JAM (verified optional layer)" } else { "JAM is available for the Capital Wasteland through TTW only" }

    $variant = Get-OpenNVVariantRecord -CampaignRecord $campaignRecord -Jam $script:selectedJam
    $script:selectedVariant = $variant
    $ready = [bool]$variant.ready
    $statusColor = if ($ready) { [Drawing.Color]::FromArgb(136, 224, 128) } else { [Drawing.Color]::FromArgb(244, 158, 102) }
    $statusLabel.ForeColor = $statusColor
    $statusLabel.Text = @(
        "Profile: $($variant.profileDirectory)",
        "Launch mode: $($variant.launchMode)",
        "Configuration: $($variant.profileConfigState)",
        "Status: $($variant.message)",
        "",
        "Saves remain isolated by campaign. TTW and TTW+JAM intentionally share only the TTW campaign save store."
    ) -join [Environment]::NewLine

    $moduleLines = [Collections.Generic.List[string]]::new()
    if ($campaignRecord.id -eq "Fallout3") {
        $moduleLines.Add("Standalone Fallout 3 is deliberately vanilla.")
        $moduleLines.Add("")
        $moduleLines.Add("For a Capital Wasteland character with JAM, choose TTW above.")
    }
    else {
        foreach ($module in @($campaignRecord.modules)) {
            $marker = if ([bool]$module.selectable) { "READY" } else { "GATED" }
            $moduleLines.Add("[$marker] $($module.title)")
            $moduleLines.Add("  $($module.detail)")
            if (-not [string]::IsNullOrWhiteSpace([string]$module.homepage)) {
                $moduleLines.Add("  Source: $($module.homepage)")
            }
            $moduleLines.Add("")
        }
        $moduleLines.Add("The launcher never loads an xNVSE DLL. A mod stays gated until its native compatibility layer has passed validation.")
    }
    $modulesBox.Text = $moduleLines -join [Environment]::NewLine

    $detailsBox.Text = @(
        "Runtime: $($script:selectedVariant.runtimeRoot)",
        "Data policy: no Downloads or lab data layer is accepted.",
        "Required game/TTW assets are resolved by the selected generated profile.",
        "JAM is mounted only from its hash-locked local depot when selected."
    ) -join [Environment]::NewLine
    $launchButton.Enabled = $ready
}

$nvRadio.Add_CheckedChanged({
    if ($nvRadio.Checked) {
        $script:selectedCampaign = "NewVegas"
        Update-OpenNVLauncherView
    }
})
$fo3Radio.Add_CheckedChanged({
    if ($fo3Radio.Checked) {
        $script:selectedCampaign = "Fallout3"
        Update-OpenNVLauncherView
    }
})
$ttwRadio.Add_CheckedChanged({
    if ($ttwRadio.Checked) {
        $script:selectedCampaign = "TTW"
        Update-OpenNVLauncherView
    }
})
$jamCheck.Add_CheckedChanged({
    if ($jamCheck.Enabled) {
        $script:selectedJam = [bool]$jamCheck.Checked
        Update-OpenNVLauncherView
    }
})
$refreshButton.Add_Click({
    try {
        $script:launcherState = Get-OpenNVLauncherViewState
        Update-OpenNVLauncherView
        $detailsBox.AppendText([Environment]::NewLine + "Preflight refreshed at $([DateTime]::Now.ToString('T')).")
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "OpenNV preflight failed", [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})
$profileButton.Add_Click({
    $profilePath = [string]$script:selectedVariant.profileDirectory
    if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
        [Windows.Forms.MessageBox]::Show("Profile directory does not exist: $profilePath", "OpenNV", [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    Start-Process -FilePath "explorer.exe" -ArgumentList @($profilePath)
})
$launchButton.Add_Click({
    try {
        $arguments = Get-OpenNVLaunchArguments `
            -SelectedCampaign $script:selectedCampaign `
            -Jam $script:selectedJam `
            -StartNewGame ([bool]$newGameCheck.Checked)
        $output = (& $launchScript @arguments 6>&1 | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            $detailsBox.Text = $output
        }
        $form.WindowState = [Windows.Forms.FormWindowState]::Minimized
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "OpenNV launch failed", [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

Set-OpenNVSelectedRadio
Update-OpenNVLauncherView
[void]$form.ShowDialog()
