Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "WorldViewerPaths.ps1")
. (Join-Path $PSScriptRoot "OpenNVModDepot.ps1")

function Get-OpenNVModCatalog {
    param([string]$CatalogPath = "")

    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
        $CatalogPath = Join-Path $repoRoot "catalog/open-nv-modules.json"
    }
    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "Missing OpenNV mod catalog: $CatalogPath"
    }
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    if ([string]$catalog.schema -cne "nikami-open-nv-modules/v1") {
        throw "Unsupported OpenNV mod catalog schema: $($catalog.schema)"
    }
    return $catalog
}

function Get-OpenNVModule {
    param(
        [Parameter(Mandatory=$true)]$Catalog,
        [Parameter(Mandatory=$true)][string]$Id
    )

    $match = @($Catalog.modules | Where-Object { [string]$_.id -ieq $Id })
    if ($match.Count -ne 1) {
        throw "Unknown OpenNV module '$Id'."
    }
    return $match[0]
}

function Get-OpenNVModLayer {
    param(
        [Parameter(Mandatory=$true)]$Catalog,
        [Parameter(Mandatory=$true)][string]$Id
    )

    $match = @($Catalog.layers | Where-Object { [string]$_.id -ieq $Id })
    if ($match.Count -ne 1) {
        throw "Unknown OpenNV mod layer '$Id'."
    }
    return $match[0]
}

function Get-OpenNVManagedSelection {
    param(
        [Parameter(Mandatory=$true)][string]$Campaign,
        [string]$StatePath = ""
    )

    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Join-Path $repoRoot "local/open-nv-mod-manager.json"
    }
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return @()
    }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ([string]$state.schema -cne "nikami-open-nv-mod-manager/v1") {
        throw "Unsupported OpenNV mod manager state schema: $($state.schema)"
    }
    $property = $state.campaigns.PSObject.Properties[$Campaign.ToLowerInvariant()]
    if ($null -eq $property) {
        return @()
    }
    return @($property.Value.modules | ForEach-Object { [string]$_ })
}

function Resolve-OpenNVModSelection {
    param(
        [Parameter(Mandatory=$true)]$Catalog,
        [Parameter(Mandatory=$true)][ValidateSet("NewVegas", "Fallout3", "TTW")][string]$Campaign,
        [string[]]$Module = @(),
        [string[]]$Layer = @()
    )

    # This resolver is also called by the launcher control-center in its own
    # script scope.  Resolve the repository locally instead of depending on a
    # caller-owned $repoRoot variable, otherwise the control-center crashes
    # under StrictMode before it can report which launch profiles are ready.
    $repoRoot = Split-Path -Parent $PSScriptRoot

    $campaignId = switch ($Campaign) {
        "NewVegas" { "newvegas" }
        "Fallout3" { "fallout3" }
        "TTW" { "ttw" }
    }
    $requestedIds = [Collections.Generic.List[string]]::new()
    foreach ($layerId in $Layer) {
        if ([string]::IsNullOrWhiteSpace($layerId)) { continue }
        $layerRecord = Get-OpenNVModLayer -Catalog $Catalog -Id $layerId
        if (@($layerRecord.campaigns) -notcontains $campaignId) {
            throw "Layer '$($layerRecord.id)' does not apply to $Campaign."
        }
        foreach ($moduleId in @($layerRecord.modules)) {
            if (-not $requestedIds.Contains([string]$moduleId)) {
                $requestedIds.Add([string]$moduleId)
            }
        }
    }
    foreach ($moduleId in $Module) {
        if (-not [string]::IsNullOrWhiteSpace($moduleId) -and -not $requestedIds.Contains($moduleId)) {
            $requestedIds.Add($moduleId)
        }
    }

    $localConfig = $null
    $validated = [Collections.Generic.List[object]]::new()
    $blocked = [Collections.Generic.List[object]]::new()
    foreach ($moduleId in $requestedIds) {
        $record = Get-OpenNVModule -Catalog $Catalog -Id $moduleId
        if (@($record.campaigns) -notcontains $campaignId) {
            throw "Module '$($record.id)' does not apply to $Campaign."
        }
        $requiredCapabilities = if ($record.PSObject.Properties.Name -contains "requiredCapabilities") {
            @($record.requiredCapabilities | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        else {
            @()
        }
        $capabilityStates = @(Get-OpenNVRequiredCapabilityState -RequiredCapability $requiredCapabilities)

        $sourcePath = ""
        $sourceKind = ""
        $depotId = if ($record.PSObject.Properties.Name -contains "depotId") { [string]$record.depotId } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($depotId)) {
            $depotState = Get-OpenNVModDepotState -Id $depotId -RepoRoot $repoRoot
            if (-not $depotState.ready) {
                $blocked.Add([pscustomobject]@{
                    id = [string]$record.id
                    title = [string]$record.title
                    status = [string]$depotState.status
                    detail = "The hash-locked depot input is not ready: $($depotState.installPath)"
                })
                continue
            }
            $sourcePath = [string]$depotState.installPath
            $sourceKind = "hash-locked-depot"
        }
        else {
            if ($null -eq $localConfig) {
                $localConfig = Get-NikamiLocalConfig
            }
            $sourceKey = [string]$record.sourceConfigKey
            $sourcePath = if ([string]::IsNullOrWhiteSpace($sourceKey)) { "" } else { [string](Get-NikamiConfigValue -Config $localConfig -Name $sourceKey) }
            $sourceKind = "local-config"
            if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
                $blocked.Add([pscustomobject]@{
                    id = [string]$record.id
                    title = [string]$record.title
                    status = "source-not-registered"
                    detail = "Set local/paths.json:$sourceKey to the untouched mod directory."
                })
                continue
            }
        }

        $requiredFiles = if ($record.PSObject.Properties.Name -contains "requiredFiles") { @($record.requiredFiles) } else { @() }
        $missingFiles = @($requiredFiles | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $sourcePath ([string]$_)) -PathType Leaf)
        })
        if ($missingFiles.Count -gt 0) {
            $blocked.Add([pscustomobject]@{
                id = [string]$record.id
                title = [string]$record.title
                status = "source-incomplete"
                detail = "Missing: $($missingFiles -join ', ')"
            })
            continue
        }

        $unvalidatedCapabilities = @($capabilityStates | Where-Object { -not $_.validated })
        if ($unvalidatedCapabilities.Count -gt 0) {
            $blocked.Add([pscustomobject]@{
                id = [string]$record.id
                title = [string]$record.title
                status = "native-capability-pending"
                detail = "Required native compatibility capabilities are not validated: $((@($unvalidatedCapabilities | ForEach-Object { "$($_.id) [$($_.status)]" }) -join ', '))."
            })
            continue
        }

        $status = [string]$record.openNvSupport
        if ($status -cne "validated") {
            $blocked.Add([pscustomobject]@{
                id = [string]$record.id
                title = [string]$record.title
                status = $status
                detail = [string]$record.notes
            })
            continue
        }
        $validated.Add([pscustomobject]@{
            id = [string]$record.id
            title = [string]$record.title
            sourcePath = (Resolve-Path -LiteralPath $sourcePath).Path
            sourceKind = $sourceKind
            depotId = $depotId
            integration = [string]$record.integration
            content = if ($record.PSObject.Properties.Name -contains "content") { @($record.content | ForEach-Object { [string]$_ }) } else { @() }
            capabilities = @($capabilityStates)
        })
    }

    return [pscustomobject]@{
        campaign = $Campaign
        requestedModuleIds = @($requestedIds.ToArray())
        validatedModules = @($validated.ToArray())
        blockedModules = @($blocked.ToArray())
        includeJam = @($validated | Where-Object { $_.id -eq "jam" }).Count -gt 0
        ready = ($blocked.Count -eq 0)
    }
}
