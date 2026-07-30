param(
    [string]$TtwRoot = "",
    [string]$Fallout3Data = "",
    [string]$FalloutNewVegasData = "",
    [string]$JamRoot = "",
    [ValidateSet("Auto", "RequireAll")]
    [string]$DlcPolicy = "Auto",
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
. (Join-Path $PSScriptRoot "OpenNVModManager.ps1")

function Get-OpenNVPropertyValue {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Name,
        $Default = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function Invoke-OpenNVVariantPreflight {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("NewVegas", "Fallout3", "TTW")][string]$Campaign,
        [switch]$EnableJam
    )

    $arguments = @{ DryRun = $true; DlcPolicy = $DlcPolicy }
    switch ($Campaign) {
        "NewVegas" {
            $initializer = Join-Path $PSScriptRoot "Initialize-OpenNVBaseProfile.ps1"
            $arguments.FalloutNewVegasData = $FalloutNewVegasData
            $arguments.JamRoot = $JamRoot
            if ($EnableJam) { $arguments.IncludeJam = $true }
        }
        "Fallout3" {
            $initializer = Join-Path $PSScriptRoot "Initialize-OpenFO3BaseProfile.ps1"
            $arguments.Fallout3Data = $Fallout3Data
        }
        "TTW" {
            $initializer = Join-Path $PSScriptRoot "Initialize-TTWCompatibilityProfile.ps1"
            $arguments.TtwRoot = $TtwRoot
            $arguments.Fallout3Data = $Fallout3Data
            $arguments.FalloutNewVegasData = $FalloutNewVegasData
            $arguments.JamRoot = $JamRoot
            if ($EnableJam) { $arguments.IncludeJam = $true }
            $arguments.Remove("DlcPolicy")
        }
    }

    try {
        # Initializers deliberately narrate interactive preflight.  The
        # control-center API returns only its structured result, so that a
        # caller using -AsJson never has to parse console narration.
        $profile = & $initializer @arguments 3>$null 6>$null
        $profileConfigState = [string](Get-OpenNVPropertyValue -Object $profile -Name "profileConfigState" -Default "unknown")
        $profileReady = [bool](Get-OpenNVPropertyValue -Object $profile -Name "launchable" -Default $false) -and
            $profileConfigState -ne "custom-configuration"
        $message = switch ($profileConfigState) {
            "managed-upgrade-required" { "Ready; launcher-owned profile configuration will be refreshed with a backup before start."; break }
            "missing" { "Ready; launcher will create its generated profile configuration before start."; break }
            "custom-configuration" { "Profile openmw.cfg was customized outside the launcher. Preserve or replace it explicitly with -ForceProfileConfig before launch."; break }
            default { "Ready"; break }
        }
        return [pscustomobject]@{
            ready = $profileReady
            launchMode = [string](Get-OpenNVPropertyValue -Object $profile -Name "launchMode" -Default "unknown")
            installComplete = Get-OpenNVPropertyValue -Object $profile -Name "installComplete" -Default $null
            installReasons = @(Get-OpenNVPropertyValue -Object $profile -Name "installReasons" -Default @())
            availableDlc = @(Get-OpenNVPropertyValue -Object $profile -Name "availableDlc" -Default @())
            unavailableDlc = @(Get-OpenNVPropertyValue -Object $profile -Name "unavailableDlc" -Default @())
            profileDirectory = [string](Get-OpenNVPropertyValue -Object $profile -Name "profileDirectory" -Default "")
            runtimeRoot = [string](Get-OpenNVPropertyValue -Object $profile -Name "runtimeRoot" -Default "")
            resourcesRoot = [string](Get-OpenNVPropertyValue -Object $profile -Name "resourcesRoot" -Default "")
            profileConfigState = $profileConfigState
            message = $message
        }
    }
    catch {
        return [pscustomobject]@{
            ready = $false
            launchMode = "unavailable"
            installComplete = $null
            installReasons = @()
            availableDlc = @()
            unavailableDlc = @()
            profileDirectory = ""
            runtimeRoot = ""
            resourcesRoot = ""
            profileConfigState = "unavailable"
            message = $_.Exception.Message
        }
    }
}

function Get-OpenNVModuleState {
    param(
        [Parameter(Mandatory=$true)]$Catalog,
        [Parameter(Mandatory=$true)][ValidateSet("NewVegas", "Fallout3", "TTW")][string]$Campaign
    )

    $campaignId = $Campaign.ToLowerInvariant()
    $states = [Collections.Generic.List[object]]::new()
    foreach ($module in @($Catalog.modules | Where-Object { @($_.campaigns) -contains $campaignId })) {
        $selection = Resolve-OpenNVModSelection -Catalog $Catalog -Campaign $Campaign -Module @([string]$module.id)
        $block = @($selection.blockedModules | Select-Object -First 1)
        $states.Add([pscustomobject]@{
            id = [string]$module.id
            title = [string]$module.title
            selectable = [bool]$selection.ready
            status = if ($selection.ready) { "ready" } elseif ($block.Count -gt 0) { [string]$block[0].status } else { "unavailable" }
            detail = if ($selection.ready) { "Ready to use from its registered untouched source folder." } elseif ($block.Count -gt 0) { [string]$block[0].detail } else { "Unavailable" }
            managed = @((Get-OpenNVManagedSelection -Campaign $Campaign)) -contains [string]$module.id
            homepage = [string]$module.homepage
        })
    }
    return @($states.ToArray())
}

function Get-OpenNVLayerState {
    param(
        [Parameter(Mandatory=$true)]$Catalog,
        [Parameter(Mandatory=$true)][ValidateSet("NewVegas", "Fallout3", "TTW")][string]$Campaign
    )

    $campaignId = $Campaign.ToLowerInvariant()
    $states = [Collections.Generic.List[object]]::new()
    foreach ($layer in @($Catalog.layers | Where-Object { @($_.campaigns) -contains $campaignId })) {
        $selection = Resolve-OpenNVModSelection -Catalog $Catalog -Campaign $Campaign -Layer @([string]$layer.id)
        $states.Add([pscustomobject]@{
            id = [string]$layer.id
            title = [string]$layer.title
            selectable = [bool]$selection.ready
            modules = @($selection.requestedModuleIds)
            blockedModules = @($selection.blockedModules)
            managed = @((Get-OpenNVManagedSelection -Campaign $Campaign)) | Where-Object { $_ -in @($selection.requestedModuleIds) } | ForEach-Object { [string]$_ }
        })
    }
    return @($states.ToArray())
}

$catalog = Get-OpenNVModCatalog
$installer = @(Get-Process -Name "TTW Install" -ErrorAction SilentlyContinue | Select-Object -First 1)
$variants = [ordered]@{
    newVegasVanilla = Invoke-OpenNVVariantPreflight -Campaign NewVegas
    newVegasJam = Invoke-OpenNVVariantPreflight -Campaign NewVegas -EnableJam
    fallout3Vanilla = Invoke-OpenNVVariantPreflight -Campaign Fallout3
    ttw = Invoke-OpenNVVariantPreflight -Campaign TTW
    ttwJam = Invoke-OpenNVVariantPreflight -Campaign TTW -EnableJam
}

$state = [ordered]@{
    schema = "nikami-open-nv-launcher-state/v1"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    campaignRule = "Choose a campaign before creating a character. New Vegas, standalone Fallout 3, and TTW saves never cross over. JAM can be added later to New Vegas or TTW, but a save made with JAM must continue with JAM enabled."
    campaigns = @(
        [ordered]@{
            id = "NewVegas"
            title = "New Vegas"
            characterCreation = "Standalone Mojave character"
            jam = $true
            variants = [ordered]@{ vanilla = $variants.newVegasVanilla; jam = $variants.newVegasJam }
            modules = Get-OpenNVModuleState -Catalog $catalog -Campaign NewVegas
            layers = Get-OpenNVLayerState -Catalog $catalog -Campaign NewVegas
        },
        [ordered]@{
            id = "Fallout3"
            title = "Fallout 3"
            characterCreation = "Standalone Capital Wasteland character"
            jam = $false
            jamRule = "JAM is available in the Capital Wasteland only through a TTW character."
            variants = [ordered]@{ vanilla = $variants.fallout3Vanilla }
            modules = @()
            layers = @()
        },
        [ordered]@{
            id = "TTW"
            title = "Tale of Two Wastelands"
            characterCreation = "One Capital Wasteland-to-Mojave character; stock TTW begins on the Fallout 3 side"
            jam = $true
            ttwRule = "TTW requires the full official Fallout 3 and Fallout: New Vegas DLC/preorder set."
            variants = [ordered]@{ vanilla = $variants.ttw; jam = $variants.ttwJam }
            modules = Get-OpenNVModuleState -Catalog $catalog -Campaign TTW
            layers = Get-OpenNVLayerState -Catalog $catalog -Campaign TTW
        }
    )
    installer = [ordered]@{
        running = $installer.Count -gt 0
        processId = if ($installer.Count -gt 0) { $installer[0].Id } else { $null }
        cpuSeconds = if ($installer.Count -gt 0) { [math]::Round($installer[0].CPU, 0) } else { $null }
        note = if ($installer.Count -gt 0) { "The official TTW installer is still processing. Do not cancel it." } else { "No TTW installer process is running." }
    }
    actions = [ordered]@{
        showChoices = @(".\\scripts\\Start-OpenNV.ps1", "-ShowChoices")
        launch = @(".\\scripts\\Start-OpenNV.ps1", "-Campaign", "<NewVegas|Fallout3|TTW>", "[-EnableJam]", "[-UseManagedMods]")
        manage = @(".\\scripts\\Manage-OpenNVMods.ps1", "-Action", "<List|Plan|Enable|Disable>")
    }
}

if ($AsJson) {
    $state | ConvertTo-Json -Depth 12
    return
}

Write-Host "OpenNV control center (headless)"
Write-Host ""
$state.campaigns | ForEach-Object {
    $vanilla = $_.variants.vanilla
    $jam = if ($_.variants.Contains("jam")) { $_.variants["jam"] } else { $null }
    [pscustomobject]@{
        Campaign = $_.title
        Vanilla = if ($vanilla.ready) { "ready" } else { $vanilla.message }
        JAM = if ($null -eq $jam) { "not available" } elseif ($jam.ready) { "ready" } else { $jam.message }
        DLC = if (@($vanilla.unavailableDlc).Count -eq 0) { "all detected" } else { "not mounted: $($vanilla.unavailableDlc -join ', ')" }
    }
} | Format-Table -AutoSize

if ($state.installer.running) {
    Write-Host "TTW installer: working (PID $($state.installer.processId), CPU $($state.installer.cpuSeconds)s)."
}
else {
    Write-Host "TTW installer: not running."
}
Write-Host ""
Write-Host "For a UI/client, use: .\\scripts\\Get-OpenNVLauncherState.ps1 -AsJson"
Write-Host "For the character-creation choices, use: .\\scripts\\Start-OpenNV.ps1 -ShowChoices"
