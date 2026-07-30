Set-StrictMode -Version Latest

function Get-OpenNVModDepotLock {
    param([string]$LockPath = "")

    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($LockPath)) {
        $LockPath = Join-Path $repoRoot "catalog/open-nv-mod-depot.lock.json"
    }
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        throw "Missing OpenNV mod-depot lock: $LockPath"
    }
    $lock = Get-Content -LiteralPath $LockPath -Raw | ConvertFrom-Json
    if ([string]$lock.schema -cne "nikami-open-nv-mod-depot-lock/v1") {
        throw "Unsupported OpenNV mod-depot lock schema: $($lock.schema)"
    }
    return $lock
}

function Get-OpenNVCapabilityRegistry {
    param([string]$RegistryPath = "")

    $repoRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Join-Path $repoRoot "catalog/open-nv-capability-registry.json"
    }
    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        throw "Missing OpenNV capability registry: $RegistryPath"
    }
    $registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
    if ([string]$registry.schema -cne "nikami-open-nv-capability-registry/v1") {
        throw "Unsupported OpenNV capability registry schema: $($registry.schema)"
    }
    return $registry
}

function Get-OpenNVModDepotEntry {
    param(
        [Parameter(Mandatory=$true)]$Lock,
        [Parameter(Mandatory=$true)][string]$Id
    )

    $match = @($Lock.modules | Where-Object { [string]$_.id -ieq $Id })
    if ($match.Count -ne 1) {
        throw "Unknown OpenNV mod-depot module '$Id'."
    }
    return $match[0]
}

function Get-OpenNVCapability {
    param(
        [Parameter(Mandatory=$true)]$Registry,
        [Parameter(Mandatory=$true)][string]$Id
    )

    $match = @($Registry.capabilities | Where-Object { [string]$_.id -ieq $Id })
    if ($match.Count -ne 1) {
        throw "Unknown OpenNV compatibility capability '$Id'."
    }
    return $match[0]
}

function Resolve-OpenNVModDepotPath {
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$AllowedRoot
    )

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "A mod-depot path must be repository-relative: $RelativePath"
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $RepoRoot $RelativePath))
    $allowed = [IO.Path]::GetFullPath((Join-Path $RepoRoot $AllowedRoot)).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $allowed + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing mod-depot path outside ${AllowedRoot}: $RelativePath"
    }
    return $resolved
}

function Get-OpenNVModDepotState {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [string]$RepoRoot = "",
        [string]$LockPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $PSScriptRoot
    }
    $RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
    $lock = Get-OpenNVModDepotLock -LockPath $LockPath
    $entry = Get-OpenNVModDepotEntry -Lock $lock -Id $Id
    $archivePath = Resolve-OpenNVModDepotPath -RepoRoot $RepoRoot `
        -RelativePath ([string]$entry.archive.relativePath) -AllowedRoot ([string]$lock.depotPolicy.archiveRoot)
    $installPath = Resolve-OpenNVModDepotPath -RepoRoot $RepoRoot `
        -RelativePath ([string]$entry.install.relativePath) -AllowedRoot ([string]$lock.depotPolicy.installRoot)
    $checks = [Collections.Generic.List[object]]::new()

    $archiveExists = Test-Path -LiteralPath $archivePath -PathType Leaf
    $archiveHash = $null
    $archiveBytes = $null
    if ($archiveExists) {
        $archiveItem = Get-Item -LiteralPath $archivePath
        $archiveBytes = [long]$archiveItem.Length
        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    $archiveValid = $archiveExists -and $archiveBytes -eq [long]$entry.archive.bytes `
        -and $archiveHash -ceq ([string]$entry.archive.sha256).ToUpperInvariant()
    $checks.Add([pscustomobject]@{
        kind = "archive"; path = $archivePath; exists = $archiveExists; bytes = $archiveBytes; sha256 = $archiveHash
        expectedBytes = [long]$entry.archive.bytes; expectedSha256 = ([string]$entry.archive.sha256).ToUpperInvariant(); valid = $archiveValid
    })

    $installExists = Test-Path -LiteralPath $installPath -PathType Container
    $installValid = $installExists
    foreach ($file in @($entry.install.files)) {
        $relativePath = [string]$file.relativePath
        $filePath = Join-Path $installPath ($relativePath -replace '/', '\\')
        $exists = Test-Path -LiteralPath $filePath -PathType Leaf
        $bytes = $null
        $hash = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $filePath
            $bytes = [long]$item.Length
            $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToUpperInvariant()
        }
        $valid = $exists -and $bytes -eq [long]$file.bytes -and $hash -ceq ([string]$file.sha256).ToUpperInvariant()
        if (-not $valid) { $installValid = $false }
        $checks.Add([pscustomobject]@{
            kind = "installed-file"; path = $filePath; exists = $exists; bytes = $bytes; sha256 = $hash
            expectedBytes = [long]$file.bytes; expectedSha256 = ([string]$file.sha256).ToUpperInvariant(); valid = $valid
        })
    }

    [pscustomobject]@{
        id = [string]$entry.id
        title = [string]$entry.title
        archivePath = $archivePath
        installPath = $installPath
        archiveValid = $archiveValid
        installValid = $installValid
        ready = $archiveValid -and $installValid
        status = if (-not $archiveExists) { "archive-missing" } elseif (-not $archiveValid) { "archive-mismatch" } elseif (-not $installExists) { "install-missing" } elseif (-not $installValid) { "install-mismatch" } else { "ready" }
        checks = @($checks.ToArray())
    }
}

function Get-OpenNVRequiredCapabilityState {
    param(
        [string[]]$RequiredCapability = @(),
        [string]$RegistryPath = ""
    )

    $registry = Get-OpenNVCapabilityRegistry -RegistryPath $RegistryPath
    $states = [Collections.Generic.List[object]]::new()
    foreach ($id in @($RequiredCapability | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $capability = Get-OpenNVCapability -Registry $registry -Id ([string]$id)
        $states.Add([pscustomobject]@{
            id = [string]$capability.id
            title = [string]$capability.title
            status = [string]$capability.status
            implementation = [string]$capability.implementation
            verification = [string]$capability.verification
            validated = [string]$capability.status -ceq "validated"
        })
    }
    return @($states.ToArray())
}
