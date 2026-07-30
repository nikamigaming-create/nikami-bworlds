param(
    [ValidateSet("List", "Plan", "Enable", "Disable")]
    [string]$Action = "List",
    [ValidateSet("NewVegas", "Fallout3", "TTW")]
    [string]$Campaign = "TTW",
    [string[]]$Module = @(),
    [string[]]$Layer = @(),
    [string]$StatePath = "",
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
. (Join-Path $PSScriptRoot "OpenNVModManager.ps1")

$repoRoot = Split-Path -Parent $PSScriptRoot
$catalog = Get-OpenNVModCatalog
if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $repoRoot "local/open-nv-mod-manager.json"
}

if ($Action -eq "List") {
    $list = @($catalog.modules | ForEach-Object {
        [pscustomobject]@{
            Id = $_.id
            Module = $_.title
            Campaigns = (@($_.campaigns) -join ", ")
            OpenNV = $_.openNvSupport
            Native = $_.nativeSupport
            Input = if ($_.PSObject.Properties.Name -contains "depotId") { "hash-locked-depot:$($_.depotId)" } else { "local-config:$($_.sourceConfigKey)" }
            Capabilities = if ($_.PSObject.Properties.Name -contains "requiredCapabilities") { @($_.requiredCapabilities) -join ", " } else { "" }
        }
    })
    if ($AsJson) {
        [pscustomobject]@{
            schema = "nikami-open-nv-mod-manager-status/v1"
            modules = $list
            layers = @($catalog.layers)
        } | ConvertTo-Json -Depth 8
    }
    else {
        $list | Format-Table -AutoSize
        Write-Host "Layers: $(@($catalog.layers.id) -join ', ')"
    }
    return
}

$selection = Resolve-OpenNVModSelection -Catalog $catalog -Campaign $Campaign -Module $Module -Layer $Layer
if ($Action -eq "Plan") {
    if ($AsJson) {
        $selection | ConvertTo-Json -Depth 8
    }
    else {
        $selection | Select-Object campaign, requestedModuleIds, ready, validatedModules, blockedModules | Format-List
    }
    return
}
if ($Action -ne "Disable" -and -not $selection.ready) {
    $details = @($selection.blockedModules | ForEach-Object { "$($_.id): $($_.status) ($($_.detail))" }) -join "; "
    throw "Cannot change the managed layer until every requested module is ready: $details"
}

$state = if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
    Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
}
else {
    [pscustomobject]@{
        schema = "nikami-open-nv-mod-manager/v1"
        campaigns = [pscustomobject]@{}
    }
}
if ([string]$state.schema -cne "nikami-open-nv-mod-manager/v1") {
    throw "Unsupported OpenNV mod manager state schema: $($state.schema)"
}
$campaignKey = $Campaign.ToLowerInvariant()
$existingProperty = $state.campaigns.PSObject.Properties[$campaignKey]
$existing = if ($null -eq $existingProperty) { @() } else { @($existingProperty.Value.modules | ForEach-Object { [string]$_ }) }
$next = [Collections.Generic.List[string]]::new()
foreach ($id in $existing) { $next.Add($id) }
if ($Action -eq "Enable") {
    foreach ($id in $selection.requestedModuleIds) {
        if (-not $next.Contains($id)) { $next.Add($id) }
    }
}
else {
    foreach ($id in $selection.requestedModuleIds) {
        [void]$next.Remove($id)
    }
}
$record = [pscustomobject]@{ modules = @($next.ToArray()) }
if ($null -eq $existingProperty) {
    $state.campaigns | Add-Member -MemberType NoteProperty -Name $campaignKey -Value $record
}
else {
    $existingProperty.Value = $record
}
$stateDirectory = Split-Path -Parent $StatePath
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
[IO.File]::WriteAllText($StatePath, (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
if ($AsJson) {
    [pscustomobject]@{
        campaign = $Campaign
        modules = @($next.ToArray())
        statePath = $StatePath
    } | ConvertTo-Json -Depth 4
}
else {
    Write-Host "Managed $Campaign modules: $($next -join ', ')"
}
