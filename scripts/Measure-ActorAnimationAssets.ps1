param(
    [string]$ActorRuntimeLedgerPath = "run/audit/actor-runtime-warnings.jsonl",
    [string]$PolicyPath = "catalog/actor-animation-policy.json",
    [string]$OutputPath = "run/audit/actor-animation-assets.jsonl",
    [string]$BsaTool = "",
    [switch]$NoWrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToForwardSlash([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Convert-ResourcePath([string]$Path) {
    return ([string]$Path -replace "\\", "/").Trim().TrimStart("/").ToLowerInvariant()
}

function Resolve-RepoRelativePath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
}

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-TextArray($Value) {
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }
    return @($text)
}

function Resolve-BsaTool([string]$Candidate) {
    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        $resolved = Resolve-RepoRelativePath $Candidate
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
        throw "bsatool.exe not found: $Candidate"
    }

    $default = Resolve-RepoRelativePath "local/openmw-fo4guard/bsatool.exe"
    if (Test-Path -LiteralPath $default -PathType Leaf) {
        return $default
    }

    throw "bsatool.exe not found. Expected repo-local tool at local/openmw-fo4guard/bsatool.exe or pass -BsaTool."
}

function Get-OpenMwCfgValue {
    param(
        [string]$Line,
        [string]$Key
    )

    if ($Line -notmatch "^\s*$([regex]::Escape($Key))\s*=\s*(?<value>.+?)\s*$") {
        return $null
    }
    return $Matches["value"]
}

function Get-ProfileAssetScope([string]$ProfileDirectory) {
    if ([string]::IsNullOrWhiteSpace($ProfileDirectory)) {
        throw "Manifest has no profileDirectory."
    }
    $cfgPath = Join-Path $ProfileDirectory "openmw.cfg"
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        throw "Profile openmw.cfg not found: $cfgPath"
    }

    $dataDirs = New-Object System.Collections.Generic.List[string]
    $archives = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-Content -LiteralPath $cfgPath) {
        $dataValue = Get-OpenMwCfgValue -Line $line -Key "data"
        if (-not [string]::IsNullOrWhiteSpace($dataValue)) {
            $dataDirs.Add($dataValue) | Out-Null
            continue
        }
        $dataLocalValue = Get-OpenMwCfgValue -Line $line -Key "data-local"
        if (-not [string]::IsNullOrWhiteSpace($dataLocalValue)) {
            $dataDirs.Add($dataLocalValue) | Out-Null
            continue
        }
        $archiveValue = Get-OpenMwCfgValue -Line $line -Key "fallback-archive"
        if (-not [string]::IsNullOrWhiteSpace($archiveValue)) {
            $archives.Add($archiveValue) | Out-Null
        }
    }

    $resolvedArchives = New-Object System.Collections.Generic.List[string]
    foreach ($archive in @($archives.ToArray())) {
        if ([System.IO.Path]::IsPathRooted($archive)) {
            if (Test-Path -LiteralPath $archive -PathType Leaf) {
                $resolvedArchives.Add([System.IO.Path]::GetFullPath($archive)) | Out-Null
            }
            continue
        }

        foreach ($dataDir in @($dataDirs.ToArray())) {
            $candidate = Join-Path $dataDir $archive
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $resolvedArchives.Add([System.IO.Path]::GetFullPath($candidate)) | Out-Null
                break
            }
        }
    }

    return [pscustomobject][ordered]@{
        cfg = Convert-ToForwardSlash $cfgPath
        dataDirs = @($dataDirs.ToArray() | Select-Object -Unique)
        archives = @($resolvedArchives.ToArray() | Select-Object -Unique)
    }
}

$script:ArchiveEntryCache = @{}

function Get-ArchiveEntries {
    param(
        [string]$ArchivePath,
        [string]$BsaToolPath
    )

    $key = [System.IO.Path]::GetFullPath($ArchivePath).ToLowerInvariant()
    if ($script:ArchiveEntryCache.ContainsKey($key)) {
        return $script:ArchiveEntryCache[$key]
    }

    $entries = @{}
    if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
        $listed = & $BsaToolPath list $ArchivePath 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in @($listed)) {
                $resource = Convert-ResourcePath $line
                if (-not [string]::IsNullOrWhiteSpace($resource) -and -not $entries.ContainsKey($resource)) {
                    $entries[$resource] = $true
                }
            }
        }
    }

    $script:ArchiveEntryCache[$key] = $entries
    return $entries
}

function Resolve-ProfileAsset {
    param(
        $Scope,
        [string]$ResourcePath,
        [string]$BsaToolPath
    )

    $resource = Convert-ResourcePath $ResourcePath
    foreach ($dataDir in @($Scope.dataDirs)) {
        $loosePath = Join-Path $dataDir ($resource -replace "/", [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $loosePath -PathType Leaf) {
            return [pscustomobject][ordered]@{
                resolved = $true
                source = "loose"
                path = Convert-ToForwardSlash $loosePath
                archive = $null
            }
        }
    }

    foreach ($archivePath in @($Scope.archives)) {
        $entries = Get-ArchiveEntries -ArchivePath $archivePath -BsaToolPath $BsaToolPath
        if ($entries.ContainsKey($resource)) {
            return [pscustomobject][ordered]@{
                resolved = $true
                source = "archive"
                path = $resource
                archive = Convert-ToForwardSlash $archivePath
            }
        }
    }

    return [pscustomobject][ordered]@{
        resolved = $false
        source = $null
        path = $resource
        archive = $null
    }
}

function Test-PolicyMatch {
    param(
        $Actor,
        $Rule
    )

    $match = Get-PropertyValue $Rule "match"
    if ($null -eq $match) {
        return $true
    }

    foreach ($name in @("actorType", "actorName", "race", "traits", "modelRecord")) {
        $expected = [string](Get-PropertyValue $match $name)
        if (-not [string]::IsNullOrWhiteSpace($expected) -and [string](Get-PropertyValue $Actor $name) -ne $expected) {
            return $false
        }

        $pattern = [string](Get-PropertyValue $match "$($name)Pattern")
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and [string](Get-PropertyValue $Actor $name) -notmatch $pattern) {
            return $false
        }
    }

    return $true
}

function Get-WorldAnimationRules {
    param(
        $Policy,
        [string]$WorldId
    )

    $worlds = Get-PropertyValue $Policy "worlds"
    if ($null -eq $worlds) {
        return @()
    }
    $world = Get-PropertyValue $worlds $WorldId
    if ($null -eq $world) {
        return @()
    }
    return @((Get-PropertyValue $world "rules"))
}

function Add-AssetRowsForSource {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        $Actor,
        $Rule,
        $Scope,
        [string]$BsaToolPath,
        [string]$Kind,
        [string]$Role,
        [string]$Path,
        [string]$FailureClass = "",
        [string]$WarningClass = ""
    )

    $resolution = Resolve-ProfileAsset -Scope $Scope -ResourcePath $Path -BsaToolPath $BsaToolPath
    $required = [string]::Equals($Kind, "required", [StringComparison]::OrdinalIgnoreCase)
    $failureClasses = @()
    $warningClasses = @()
    $status = "pass"
    if (-not $resolution.resolved) {
        if ($required) {
            $status = "fail"
            $failureClasses = @($(if ($FailureClass) { $FailureClass } else { "missing-content" }))
        }
        else {
            $status = "questionable"
            $warningClasses = @($(if ($WarningClass) { $WarningClass } else { "animation-asset-optional-missing" }))
        }
    }

    $Rows.Add([pscustomobject][ordered]@{
        schemaVersion = 1
        assessedAt = (Get-Date).ToString("o")
        worldId = [string](Get-PropertyValue $Actor "worldId")
        evidenceKind = "actor-animation-asset"
        status = $status
        failureClasses = @($failureClasses)
        warningClasses = @($warningClasses)
        manifest = Get-PropertyValue $Actor "manifest"
        actorRuntimeLog = Get-PropertyValue $Actor "log"
        actorRuntimeStatus = Get-PropertyValue $Actor "status"
        formId = Get-PropertyValue $Actor "formId"
        actorName = Get-PropertyValue $Actor "actorName"
        actorType = Get-PropertyValue $Actor "actorType"
        race = Get-PropertyValue $Actor "race"
        modelRecord = Get-PropertyValue $Actor "modelRecord"
        ruleId = Get-PropertyValue $Rule "id"
        assetKind = $Kind
        assetRole = $Role
        resource = Convert-ResourcePath $Path
        resolved = [bool]$resolution.resolved
        resolvedSource = $resolution.source
        resolvedPath = $resolution.path
        archive = $resolution.archive
        profileConfig = $Scope.cfg
    }) | Out-Null
}

$resolvedActorRuntimeLedger = Resolve-RepoRelativePath $ActorRuntimeLedgerPath
if (-not (Test-Path -LiteralPath $resolvedActorRuntimeLedger)) {
    throw "Actor runtime ledger not found: $ActorRuntimeLedgerPath"
}

$resolvedPolicyPath = Resolve-RepoRelativePath $PolicyPath
if (-not (Test-Path -LiteralPath $resolvedPolicyPath)) {
    throw "Actor animation policy not found: $PolicyPath"
}

$bsaToolPath = Resolve-BsaTool -Candidate $BsaTool
$policy = Get-Content -LiteralPath $resolvedPolicyPath -Raw | ConvertFrom-Json
$actors = Get-Content -LiteralPath $resolvedActorRuntimeLedger |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_ | ConvertFrom-Json }

$manifestCache = @{}
$scopeCache = @{}
$rows = New-Object System.Collections.Generic.List[object]

foreach ($actor in @($actors)) {
    $worldId = [string](Get-PropertyValue $actor "worldId")
    $rules = @(Get-WorldAnimationRules -Policy $policy -WorldId $worldId | Where-Object { Test-PolicyMatch -Actor $actor -Rule $_ })
    if ($rules.Count -eq 0) {
        continue
    }

    $manifestPath = [string](Get-PropertyValue $actor "manifest")
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        continue
    }
    $manifestKey = (Resolve-RepoRelativePath $manifestPath).ToLowerInvariant()
    if (-not $manifestCache.ContainsKey($manifestKey)) {
        $manifestCache[$manifestKey] = Get-Content -LiteralPath (Resolve-RepoRelativePath $manifestPath) -Raw | ConvertFrom-Json
    }
    $manifest = $manifestCache[$manifestKey]
    $profileDirectory = [string](Get-PropertyValue $manifest "profileDirectory")
    if ([string]::IsNullOrWhiteSpace($profileDirectory)) {
        continue
    }
    $scopeKey = (Resolve-RepoRelativePath $profileDirectory).ToLowerInvariant()
    if (-not $scopeCache.ContainsKey($scopeKey)) {
        $scopeCache[$scopeKey] = Get-ProfileAssetScope -ProfileDirectory (Resolve-RepoRelativePath $profileDirectory)
    }
    $scope = $scopeCache[$scopeKey]

    foreach ($rule in $rules) {
        $skeleton = [string](Get-PropertyValue $rule "skeleton")
        if (-not [string]::IsNullOrWhiteSpace($skeleton)) {
            Add-AssetRowsForSource -Rows $rows -Actor $actor -Rule $rule -Scope $scope -BsaToolPath $bsaToolPath `
                -Kind "required" -Role "skeleton" -Path $skeleton -FailureClass "actor-root-missing"
        }

        foreach ($source in @((Get-PropertyValue $rule "requiredSources"))) {
            Add-AssetRowsForSource -Rows $rows -Actor $actor -Rule $rule -Scope $scope -BsaToolPath $bsaToolPath `
                -Kind "required" `
                -Role ([string](Get-PropertyValue $source "role")) `
                -Path ([string](Get-PropertyValue $source "path")) `
                -FailureClass ([string](Get-PropertyValue $source "failureClass"))
        }

        foreach ($source in @((Get-PropertyValue $rule "optionalSources"))) {
            Add-AssetRowsForSource -Rows $rows -Actor $actor -Rule $rule -Scope $scope -BsaToolPath $bsaToolPath `
                -Kind "optional" `
                -Role ([string](Get-PropertyValue $source "role")) `
                -Path ([string](Get-PropertyValue $source "path")) `
                -WarningClass ([string](Get-PropertyValue $source "warningClass"))
        }
    }
}

if (-not $NoWrite) {
    $resolvedOutput = Resolve-RepoRelativePath $OutputPath
    $outputDir = Split-Path -Parent $resolvedOutput
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    if (Test-Path -LiteralPath $resolvedOutput) {
        Remove-Item -LiteralPath $resolvedOutput -Force
    }
    foreach ($row in @($rows.ToArray())) {
        ($row | ConvertTo-Json -Depth 8 -Compress) | Add-Content -LiteralPath $resolvedOutput -Encoding ASCII
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No actor animation asset rows found."
}
else {
    @($rows.ToArray()) |
        Select-Object worldId, status, actorName, assetKind, assetRole, resource, resolved, resolvedSource, archive |
        Format-Table -AutoSize
}

if (-not $NoWrite) {
    Write-Host "Wrote actor animation asset ledger: $OutputPath"
}
