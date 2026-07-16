[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,
    [string]$OutputRoot = 'run/fnv-actor-parity-sidecar',
    [ValidateSet('Both', 'Retail', 'OpenMW')]
    [string]$Engine = 'Both',
    [ValidateSet('Parallel', 'Sequential')]
    [string]$ExecutionMode = 'Parallel',
    [Alias('DryRun', 'NoLaunch')]
    [switch]$ValidateOnly,
    [string]$GameRoot = 'D:\SteamLibrary\steamapps\common\Fallout New Vegas',
    [string]$RetailRuntimeRoot = 'local/xnvse-retail-oracle',
    [string]$RetailPluginDll = 'local/xnvse-retail-oracle/plugins/nvse_retail_oracle.dll',
    [string]$RetailSaveFixture = '',
    [string]$OpenMwRosterPath = 'run/openmw-fnv-representative-visible-20260715/loaded-actor-roster-20260715-193048.json',
    [switch]$VisibleRetail,
    [switch]$BackgroundOpenMW,
    [switch]$AllowStaticRetailProof,
    [string]$ChannelId = '',
    [ValidateRange(1000, 300000)]
    [int]$BarrierTimeoutMilliseconds = 30000,
    [ValidateRange(1, 600)]
    [int]$RetailBatchSettleFrames = 30,
    [ValidateRange(1, 60)]
    [int]$RetailBatchAdvanceFrames = 3,
    [ValidateRange(1, 600)]
    [int]$RetailWeaponProbeFrames = 12,
    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 720
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$retailRunner = Join-Path $PSScriptRoot 'Invoke-FNVRetailOracle.ps1'
$openMwRunner = Join-Path $PSScriptRoot 'Invoke-OpenMWFNVLoadedActorSweep.ps1'

function Resolve-RepoPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Get-OptionalProperty([object]$Object, [string]$Name, [object]$Default = $null) {
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-RequiredProperty([object]$Object, [string]$Name, [string]$Context) {
    if ($null -eq $Object) { throw "$Context must be an object." }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Context is missing required property '$Name'." }
    return $property.Value
}

function Assert-ObjectProperties(
    [object]$Object,
    [string[]]$Allowed,
    [string[]]$Required,
    [string]$Context
) {
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType] -or
        $Object -is [System.Array] -or $Object -is [System.Collections.IList]) {
        throw "$Context must be an object."
    }
    $allowedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Allowed) { $allowedSet.Add($name) | Out-Null }
    foreach ($property in $Object.PSObject.Properties) {
        if (-not $allowedSet.Contains([string]$property.Name)) {
            throw "$Context contains unsupported property '$($property.Name)'."
        }
    }
    foreach ($name in $Required) {
        if ($null -eq $Object.PSObject.Properties[$name]) {
            throw "$Context is missing required property '$name'."
        }
    }
}

function Get-JsonString([object]$Value, [string]$Context) {
    if ($Value -isnot [string]) { throw "$Context must be a JSON string." }
    return [string]$Value
}

function Get-JsonInteger([object]$Value, [string]$Context, [long]$Minimum, [long]$Maximum) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "$Context must be a JSON integer."
    }
    try { $number = [double]$Value }
    catch { throw "$Context must be a JSON integer." }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        [Math]::Truncate($number) -ne $number -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Context must be an integer in [$Minimum, $Maximum]."
    }
    return [long]$number
}

function Get-JsonBoolean([object]$Value, [string]$Context) {
    if ($Value -isnot [bool]) { throw "$Context must be a JSON boolean." }
    return [bool]$Value
}

function Get-ValidatedFileEvidence(
    [object]$PathValue,
    [object]$SizeValue,
    [string]$Context,
    [string[]]$AllowedRoots,
    [string]$RelativeRoot = '',
    [string[]]$FallbackPaths = @()
) {
    $path = Get-JsonString $PathValue "$Context.path"
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "$Context.path must be a nonempty path."
    }
    $claimedSize = Get-JsonInteger $SizeValue "$Context.size" 1 ([long]::MaxValue)
    $primaryPath = if ([IO.Path]::IsPathRooted($path)) {
        [IO.Path]::GetFullPath($path)
    } else {
        if ([string]::IsNullOrWhiteSpace($RelativeRoot)) {
            throw "$Context.path is relative but no endpoint working root was approved."
        }
        [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($RelativeRoot)) $path))
    }
    $candidates = @($primaryPath) + @($FallbackPaths | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { [IO.Path]::GetFullPath($_) })
    $fullPath = $null
    foreach ($candidate in $candidates) {
        $underAllowedRoot = $false
        foreach ($root in @($AllowedRoots)) {
            if ([string]::IsNullOrWhiteSpace($root)) { continue }
            $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if ($candidate.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $underAllowedRoot = $true
                break
            }
        }
        if (-not $underAllowedRoot) {
            throw "$Context.path candidate is outside every coordinator-approved evidence root."
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $fullPath = $candidate
            break
        }
    }
    if ($null -eq $fullPath) {
        throw "$Context.path does not exist at its published path or exact runner relocation path."
    }
    $actualSize = [IO.FileInfo]::new($fullPath).Length
    if ($actualSize -ne $claimedSize) {
        throw "$Context.size mismatch: claimed=$claimedSize actual=$actualSize."
    }
    return [pscustomobject][ordered]@{
        path = $fullPath
        bytes = $actualSize
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Format-RetailFormId([object]$Value, [string]$Context, [switch]$AllowZero) {
    $text = Get-JsonString $Value $Context
    if ($text -notmatch '^0[xX][0-9a-fA-F]{1,8}$') {
        throw "$Context must be a 0x-prefixed 32-bit FormID; got '$text'."
    }
    $number = [Convert]::ToUInt32($text.Substring(2), 16)
    if (-not $AllowZero -and $number -eq 0) { throw "$Context must be nonzero." }
    return ('0x{0:x8}' -f $number)
}

function Format-OpenMwFormId([object]$Value, [string]$Context) {
    $text = Get-JsonString $Value $Context
    if ($text -notmatch '^(?i:FormId):0[xX][0-9a-fA-F]{1,8}$') {
        throw "$Context must use OpenMW's FormId:0x######## representation; got '$text'."
    }
    $number = [Convert]::ToUInt32(($text -replace '^(?i:FormId):0[xX]', ''), 16)
    if ($number -eq 0) { throw "$Context must be nonzero." }
    return ('FormId:0x{0:x}' -f $number)
}

function Get-FiniteNumber([object]$Value, [string]$Context) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "$Context must be a JSON number."
    }
    try { $number = [double]$Value }
    catch { throw "$Context must be numeric." }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "$Context must be finite."
    }
    return $number
}

function Get-Vector3([object]$Value, [string]$Context) {
    $items = @($Value)
    if ($items.Count -ne 3) { throw "$Context must contain exactly three numbers." }
    return @(
        Get-FiniteNumber $items[0] "$Context[0]"
        Get-FiniteNumber $items[1] "$Context[1]"
        Get-FiniteNumber $items[2] "$Context[2]"
    )
}

function Get-SafeToken([string]$Value) {
    $token = $Value -replace '[^A-Za-z0-9._-]+', '-'
    $token = $token.Trim('-')
    if ([string]::IsNullOrWhiteSpace($token)) { return 'capture' }
    return $token
}

function Get-Invariant([double]$Value) {
    return $Value.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
}

function New-SidecarChannelContract([string]$SequenceId, [string]$RequestedChannelId) {
    $mappingPrefix = 'Local\NikamiFNVSidecar-'
    $id = if ([string]::IsNullOrWhiteSpace($RequestedChannelId)) {
        $suffix = '-' + [Guid]::NewGuid().ToString('N')
        $maximumSequenceCharacters = 180 - $mappingPrefix.Length - $suffix.Length
        $sequenceToken = Get-SafeToken $SequenceId
        if ($sequenceToken.Length -gt $maximumSequenceCharacters) {
            $sequenceToken = $sequenceToken.Substring(0, $maximumSequenceCharacters).TrimEnd('-')
        }
        $sequenceToken + $suffix
    } else {
        if ($RequestedChannelId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') {
            throw 'ChannelId must be a filesystem/object-name-safe token no longer than 96 characters.'
        }
        $RequestedChannelId
    }
    $mappingName = $mappingPrefix + $id
    if ($mappingName.Length -gt 180 -or
        $mappingName -notmatch '^Local\\[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'Generated NKSC mapping name violates the retail endpoint 180-character object-name contract.'
    }
    return [pscustomobject][ordered]@{
        schema = 'NikamiFNVSidecar/v1'
        channelId = $id
        mappingName = $mappingName
        capacity = 65536
        headerBytes = 512
        payloadBytesPerEngine = 32512
        events = [pscustomobject][ordered]@{
            retailReady = "$mappingName.retail-ready"
            openMwReady = "$mappingName.openmw-ready"
            captureAck = "$mappingName.capture-ack"
            error = "$mappingName.error"
        }
        headerLayout = [pscustomobject][ordered]@{
            magic = '0x43534B4E (NKSC little-endian)'
            magicOffset = 0
            versionOffset = 4
            headerBytesOffset = 6
            totalBytesOffset = 8
            mutexOffset = 12
            stateOffset = 16
            flagsOffset = 20
            errorCodeOffset = 24
            actorIndexOffset = 28
            actionIndexOffset = 32
            actionCountOffset = 36
            generationOffset = 48
            retailFrameOffset = 56
            openMwFrameOffset = 64
            captureOrdinalOffset = 72
            deadlineTickMsOffset = 80
            retailPayloadLengthOffset = 88
            retailPayloadCrc32Offset = 92
            openMwPayloadLengthOffset = 96
            openMwPayloadCrc32Offset = 100
            sequenceIdOffset = 104
            errorMessageOffset = 232
            retailPayloadOffset = 512
            openMwPayloadOffset = 33024
        }
        negotiation = [pscustomobject][ordered]@{
            readyEventsRequired = @('retailReady', 'openMwReady')
            captureAckEvent = 'captureAck'
            errorEvent = 'error'
            filePollingPermitted = $false
        }
    }
}

function Get-SidecarChannelEnvironment([object]$Channel, [string]$PlanPath, [int]$BarrierTimeoutMilliseconds) {
    return @{
        NIKAMI_ORACLE_PLAN_PATH = $PlanPath
        NIKAMI_ORACLE_SHARED_MEMORY_NAME = [string]$Channel.mappingName
        NIKAMI_ORACLE_BARRIER_TIMEOUT_MS = [string]$BarrierTimeoutMilliseconds
        OPENMW_FNV_SIDECAR_SHARED_MEMORY_NAME = [string]$Channel.mappingName
    }
}

function Assert-SidecarProtocolSourceContract {
    $retailHeader = Join-Path $repoRoot 'oracles/xnvse/nvse_retail_oracle/sidecar_protocol.h'
    $openMwHeader = 'D:\code\nikami-openmw-lab\apps\openmw\fnvsidecaripc.hpp'
    foreach ($path in @($retailHeader, $openMwHeader)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Missing authoritative sidecar protocol header: $path"
        }
        $text = Get-Content -LiteralPath $path -Raw
        foreach ($required in @(
            '0x43534B4E', 'SharedBlockBytes = 65536', 'SharedHeaderBytes = 512',
            'PayloadBytes = (SharedBlockBytes - SharedHeaderBytes) / 2',
            'SharedHeader) == SharedHeaderBytes', 'SharedBlock) == SharedBlockBytes'
        )) {
            if (-not $text.Contains($required)) {
                throw "Sidecar protocol header $path is missing static contract '$required'."
            }
        }
        foreach ($offset in @(
            @('magic', 0), @('mutex', 12), @('state', 16), @('generation', 48),
            @('retailPayloadLength', 88), @('sequenceId', 104), @('errorMessage', 232)
        )) {
            $fieldPattern = '(?i)(?:m)?' + [regex]::Escape([string]$offset[0]) + '\)\s*==\s*' + [string]$offset[1]
            if ($text -notmatch $fieldPattern) {
                throw "Sidecar protocol header $path is missing static offset $($offset[0])=$($offset[1])."
            }
        }
    }
    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-sidecar-protocol-source-preflight/v1'
        status = 'passed'
        protocol = 'NikamiFNVSidecar/v1'
        magic = '0x43534B4E'
        totalBytes = 65536
        headerBytes = 512
        payloadBytesPerEngine = 32512
        retailHeader = $retailHeader
        retailHeaderSha256 = (Get-FileHash -LiteralPath $retailHeader -Algorithm SHA256).Hash.ToLowerInvariant()
        openMwHeader = $openMwHeader
        openMwHeaderSha256 = (Get-FileHash -LiteralPath $openMwHeader -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-SidecarEndpointCapability([object]$ProtocolSourcePreflight) {
    $requiredRetailParameters = @(
        'PlanPath',
        'SharedMemoryName',
        'BarrierTimeoutMilliseconds'
    )
    $retailRunnerParameters = @()
    $retailRunnerParseError = $null
    try {
        $retailCommand = Get-Command -Name $retailRunner -CommandType ExternalScript -ErrorAction Stop
        $retailRunnerParameters = @($retailCommand.Parameters.Keys)
    }
    catch {
        $retailRunnerParseError = $_.Exception.Message
    }
    $missingRetailParameters = @($requiredRetailParameters | Where-Object {
        $_ -notin $retailRunnerParameters
    })

    $requiredOpenMwParameters = @('SidecarMode', 'SidecarSharedMemoryName', 'SidecarActionIds')
    $openMwRunnerParameters = @()
    $openMwRunnerParseError = $null
    try {
        $openMwCommand = Get-Command -Name $openMwRunner -CommandType ExternalScript -ErrorAction Stop
        $openMwRunnerParameters = @($openMwCommand.Parameters.Keys)
    }
    catch { $openMwRunnerParseError = $_.Exception.Message }
    $missingOpenMwParameters = @($requiredOpenMwParameters | Where-Object {
        $_ -notin $openMwRunnerParameters
    })

    $retailSourcePath = Join-Path $repoRoot 'oracles/xnvse/nvse_retail_oracle/main.cpp'
    $retailSourceText = if (Test-Path -LiteralPath $retailSourcePath -PathType Leaf) {
        Get-Content -LiteralPath $retailSourcePath -Raw
    } else { '' }
    $requiredRetailSourceTokens = @(
        'NIKAMI_ORACLE_PLAN_PATH',
        'NIKAMI_ORACLE_SHARED_MEMORY_NAME',
        'NIKAMI_ORACLE_BARRIER_TIMEOUT_MS',
        'loadSidecarPlan',
        'initializeSidecarSharedMemory',
        'RetailCompleteFlag'
    )
    $missingRetailSourceTokens = @($requiredRetailSourceTokens | Where-Object {
        -not $retailSourceText.Contains($_)
    })

    $openMwSourceRoot = 'D:\code\nikami-openmw-lab\apps\openmw'
    $openMwIntegrationFiles = [System.Collections.Generic.List[string]]::new()
    $openMwIntegrationText = [Text.StringBuilder]::new()
    if (Test-Path -LiteralPath $openMwSourceRoot -PathType Container) {
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $openMwSourceRoot -File -Recurse | Where-Object {
            $_.Extension -in @('.cpp', '.hpp') -and
            $_.Name -notin @('fnvsidecaripc.cpp', 'fnvsidecaripc.hpp')
        })) {
            $sourceText = [string](Get-Content -LiteralPath $sourceFile.FullName -Raw)
            if ($null -eq $sourceText) { continue }
            if ($sourceText.Contains('fnvsidecaripc.hpp') -or
                $sourceText.Contains('FNVSidecar::Client') -or
                $sourceText.Contains('publishReady(') -or
                $sourceText.Contains('markCaptured(')) {
                $openMwIntegrationFiles.Add($sourceFile.FullName) | Out-Null
                $openMwIntegrationText.AppendLine($sourceText) | Out-Null
            }
        }
    }
    $requiredOpenMwIntegrationTokens = @(
        'fnvsidecaripc.hpp',
        'FNVSidecar::Client',
        'publishReady(',
        'markCaptured(',
        'markComplete('
    )
    $missingOpenMwIntegrationTokens = @($requiredOpenMwIntegrationTokens | Where-Object {
        -not $openMwIntegrationText.ToString().Contains($_)
    })

    $retailRunnerReady = $null -eq $retailRunnerParseError -and $missingRetailParameters.Count -eq 0
    $openMwRunnerReady = $null -eq $openMwRunnerParseError -and $missingOpenMwParameters.Count -eq 0
    $retailSourceReady = $missingRetailSourceTokens.Count -eq 0
    $openMwSourceReady = $missingOpenMwIntegrationTokens.Count -eq 0
    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-parity-capability-preflight/v2'
        protocolSource = $ProtocolSourcePreflight
        lockstepReady = $retailRunnerReady -and $retailSourceReady -and
            $openMwRunnerReady -and $openMwSourceReady
        synchronizedStartBarrier = $retailRunnerReady -and $retailSourceReady -and
            $openMwRunnerReady -and $openMwSourceReady
        runtimeBinariesProven = $false
        coordinator = [pscustomobject][ordered]@{
            sharedMemoryProtocolEndpoint = $true
            filePollingPermitted = $false
            totalBytes = 65536
            headerBytes = 512
        }
        retail = [pscustomobject][ordered]@{
            runnerContractReady = $retailRunnerReady
            runnerParseError = $retailRunnerParseError
            requiredRunnerParameters = $requiredRetailParameters
            missingRunnerParameters = $missingRetailParameters
            sourceEndpointReady = $retailSourceReady
            sourcePath = $retailSourcePath
            missingSourceTokens = $missingRetailSourceTokens
            sharedMemoryProtocolEndpoint = $retailRunnerReady -and $retailSourceReady
        }
        openMw = [pscustomobject][ordered]@{
            runnerContractReady = $openMwRunnerReady
            runnerParseError = $openMwRunnerParseError
            requiredRunnerParameters = $requiredOpenMwParameters
            missingRunnerParameters = $missingOpenMwParameters
            sourceEndpointReady = $openMwSourceReady
            sourceRoot = $openMwSourceRoot
            integrationFiles = @($openMwIntegrationFiles)
            missingIntegrationTokens = $missingOpenMwIntegrationTokens
            sharedMemoryProtocolEndpoint = $openMwSourceReady
        }
        note = 'Source readiness is a fail-closed launch gate; the final shared header is the runtime completion proof.'
    }
}

function New-SidecarTransport([object]$Channel, [string]$SequenceId, [int]$ActionCount) {
    if ($ActionCount -lt 1 -or $ActionCount -gt 64) {
        throw 'NKSC action count must be in the endpoint range 1..64.'
    }
    $mapping = $null
    $handles = [ordered]@{}
    try {
        $mapping = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew(
            [string]$Channel.mappingName, [long]$Channel.capacity)
        foreach ($property in $Channel.events.PSObject.Properties) {
            $createdNew = $false
            $handle = [System.Threading.EventWaitHandle]::new(
                $false,
                [System.Threading.EventResetMode]::ManualReset,
                [string]$property.Value,
                [ref]$createdNew)
            if (-not $createdNew) {
                $handle.Dispose()
                throw "Named sidecar event already exists: $($property.Value)"
            }
            $handles[$property.Name] = $handle
        }
        $view = $mapping.CreateViewAccessor(0, [long]$Channel.capacity,
            [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        try {
            $view.Write([long]0, [uint32]0x43534B4E)
            $view.Write([long]4, [uint16]1)
            $view.Write([long]6, [uint16]$Channel.headerBytes)
            $view.Write([long]8, [uint32]$Channel.capacity)
            $view.Write([long]12, [int]0)
            $view.Write([long]16, [uint32]1) # State::PlanLoaded
            $view.Write([long]20, [int]0)
            $view.Write([long]24, [int]0)
            $view.Write([long]28, [int]0)
            $view.Write([long]32, [int]0)
            $view.Write([long]36, [uint32]$ActionCount)
            $sequenceBytes = [Text.Encoding]::UTF8.GetBytes($SequenceId)
            if ($sequenceBytes.Length -gt 127) { throw 'SequenceId exceeds the shared-header 127-byte UTF-8 limit.' }
            $view.WriteArray([long]104, [byte[]]$sequenceBytes, 0, $sequenceBytes.Length) | Out-Null
            $view.Flush()
        }
        finally {
            $view.Dispose()
        }
        return [pscustomobject][ordered]@{
            mapping = $mapping
            events = [pscustomobject]$handles
        }
    }
    catch {
        foreach ($handle in $handles.Values) { $handle.Dispose() }
        if ($null -ne $mapping) { $mapping.Dispose() }
        throw
    }
}

function Get-Crc32([byte[]]$Bytes) {
    [uint64]$mask = 4294967295
    [uint64]$polynomial = 3988292384
    [uint64]$crc = $mask
    foreach ($byte in $Bytes) {
        $crc = ($crc -bxor [uint64]$byte) -band $mask
        for ($bit = 0; $bit -lt 8; ++$bit) {
            if (($crc -band 1) -ne 0) {
                $crc = (($crc -shr 1) -bxor $polynomial) -band $mask
            }
            else { $crc = ($crc -shr 1) -band $mask }
        }
    }
    return [uint32](($crc -bxor $mask) -band $mask)
}

function Get-ByteSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function Get-SidecarTransportSnapshot([object]$Transport) {
    # NKSC v1 has no coordinator mutex API. Read the complete 64-KiB block
    # twice and accept it only when both copies are byte-identical and the
    # endpoint mutex was clear. This covers every header field plus both payload
    # regions and rejects a writer paused midway through publication.
    $last = $null
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    for ($attempt = 0; $attempt -lt 25; ++$attempt) {
        [byte[]]$first = New-Object byte[] 65536
        [byte[]]$second = New-Object byte[] 65536
        $view = $Transport.mapping.CreateViewAccessor(0, 65536,
            [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        try {
            $firstRead = $view.ReadArray([long]0, $first, 0, $first.Length)
            [Threading.Thread]::MemoryBarrier()
            $secondRead = $view.ReadArray([long]0, $second, 0, $second.Length)
        }
        finally { $view.Dispose() }

        $mutex = [BitConverter]::ToInt32($second, 12)
        $stable = $firstRead -eq 65536 -and $secondRead -eq 65536 -and $mutex -eq 0 -and
            [System.Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($first, $second)
        $sequenceBytes = New-Object byte[] 128
        $errorBytes = New-Object byte[] 256
        [Array]::Copy($second, 104, $sequenceBytes, 0, 128)
        [Array]::Copy($second, 232, $errorBytes, 0, 256)
        $sequenceTerminator = [Array]::IndexOf($sequenceBytes, [byte]0)
        $sequenceLength = if ($sequenceTerminator -lt 0) { 128 } else { $sequenceTerminator }
        $errorTerminator = [Array]::IndexOf($errorBytes, [byte]0)
        $errorLength = if ($errorTerminator -lt 0) { 256 } else { $errorTerminator }
        try {
            $sequenceId = $utf8.GetString($sequenceBytes, 0, $sequenceLength)
            $errorMessage = $utf8.GetString($errorBytes, 0, $errorLength)
        }
        catch {
            $sequenceId = ''
            $errorMessage = 'invalid-utf8-in-shared-header'
            $stable = $false
        }

        $retailLength = [BitConverter]::ToUInt32($second, 88)
        $retailCrc = [BitConverter]::ToUInt32($second, 92)
        $openMwLength = [BitConverter]::ToUInt32($second, 96)
        $openMwCrc = [BitConverter]::ToUInt32($second, 100)
        $retailReadLength = [int][Math]::Min([uint32]32512, $retailLength)
        $openMwReadLength = [int][Math]::Min([uint32]32512, $openMwLength)
        [byte[]]$retailBytes = New-Object byte[] $retailReadLength
        [byte[]]$openMwBytes = New-Object byte[] $openMwReadLength
        if ($retailReadLength -gt 0) { [Array]::Copy($second, 512, $retailBytes, 0, $retailReadLength) }
        if ($openMwReadLength -gt 0) { [Array]::Copy($second, 33024, $openMwBytes, 0, $openMwReadLength) }

        $state = [BitConverter]::ToUInt32($second, 16)
        $flags = [BitConverter]::ToUInt32($second, 20)
        $errorCode = [BitConverter]::ToUInt32($second, 24)
        $blockSha256 = Get-ByteSha256 $second
        $last = [pscustomobject][ordered]@{
            readStable = $stable
            blockBytes = $second
            blockSha256 = $blockSha256
            magic = ('0x{0:X8}' -f [BitConverter]::ToUInt32($second, 0))
            version = [BitConverter]::ToUInt16($second, 4)
            headerBytes = [BitConverter]::ToUInt16($second, 6)
            totalBytes = [BitConverter]::ToUInt32($second, 8)
            mutex = $mutex
            state = $state
            flags = $flags
            errorCode = $errorCode
            actorIndex = [BitConverter]::ToUInt32($second, 28)
            actionIndex = [BitConverter]::ToUInt32($second, 32)
            actionCount = [BitConverter]::ToUInt32($second, 36)
            generation = [BitConverter]::ToUInt64($second, 48)
            retailFrame = [BitConverter]::ToUInt64($second, 56)
            openMwFrame = [BitConverter]::ToUInt64($second, 64)
            captureOrdinal = [BitConverter]::ToUInt64($second, 72)
            deadlineTickMs = [BitConverter]::ToUInt64($second, 80)
            retailPayloadLength = $retailLength
            retailPayloadCrc32 = $retailCrc
            openMwPayloadLength = $openMwLength
            openMwPayloadCrc32 = $openMwCrc
            sequenceId = $sequenceId
            sequenceTerminated = $sequenceTerminator -ge 0
            errorMessage = $errorMessage
            errorMessageTerminated = $errorTerminator -ge 0
            retailPayloadBytes = $retailBytes
            openMwPayloadBytes = $openMwBytes
            retailComplete = ($flags -band 0x20) -ne 0
            openMwComplete = ($flags -band 0x40) -ne 0
            error = $state -eq [uint32]::MaxValue -or
                ($flags -band [uint32]2147483648) -ne 0 -or $errorCode -ne 0
            lockstepComplete = $state -eq 8 -and $flags -eq [uint32]0x7F -and $errorCode -eq 0
        }
        if ($stable) { return $last }
        Start-Sleep -Milliseconds 1
    }
    return $last
}

function ConvertTo-SidecarHeaderEvidence([object]$Snapshot) {
    return [pscustomobject][ordered]@{
        readStable = [bool]$Snapshot.readStable
        blockBytes = 65536
        blockSha256 = [string]$Snapshot.blockSha256
        magic = [string]$Snapshot.magic
        version = [int]$Snapshot.version
        headerBytes = [int]$Snapshot.headerBytes
        totalBytes = [long]$Snapshot.totalBytes
        mutex = [int]$Snapshot.mutex
        state = [long]$Snapshot.state
        flags = ('0x{0:X8}' -f [uint32]$Snapshot.flags)
        errorCode = [long]$Snapshot.errorCode
        errorMessage = [string]$Snapshot.errorMessage
        actorIndex = [long]$Snapshot.actorIndex
        actionIndex = [long]$Snapshot.actionIndex
        actionCount = [long]$Snapshot.actionCount
        generation = [uint64]$Snapshot.generation
        retailFrame = [uint64]$Snapshot.retailFrame
        openMwFrame = [uint64]$Snapshot.openMwFrame
        captureOrdinal = [uint64]$Snapshot.captureOrdinal
        deadlineTickMs = [uint64]$Snapshot.deadlineTickMs
        retailPayloadLength = [long]$Snapshot.retailPayloadLength
        retailPayloadCrc32 = ('0x{0:X8}' -f [uint32]$Snapshot.retailPayloadCrc32)
        openMwPayloadLength = [long]$Snapshot.openMwPayloadLength
        openMwPayloadCrc32 = ('0x{0:X8}' -f [uint32]$Snapshot.openMwPayloadCrc32)
        sequenceId = [string]$Snapshot.sequenceId
        sequenceTerminated = [bool]$Snapshot.sequenceTerminated
        retailComplete = [bool]$Snapshot.retailComplete
        openMwComplete = [bool]$Snapshot.openMwComplete
        error = [bool]$Snapshot.error
        lockstepComplete = [bool]$Snapshot.lockstepComplete
    }
}

function Close-SidecarTransport([object]$Transport) {
    if ($null -eq $Transport) { return }
    foreach ($property in $Transport.events.PSObject.Properties) {
        if ($null -ne $property.Value) { $property.Value.Dispose() }
    }
    if ($null -ne $Transport.mapping) { $Transport.mapping.Dispose() }
}

function Assert-SidecarHeaderContract([object]$Snapshot, [object]$Manifest) {
    if ($null -eq $Snapshot -or -not [bool]$Snapshot.readStable) {
        throw 'NKSC shared memory could not be read as one stable snapshot.'
    }
    if ([string]$Snapshot.magic -cne '0x43534B4E' -or [int]$Snapshot.version -ne 1 -or
        [int]$Snapshot.headerBytes -ne 512 -or [long]$Snapshot.totalBytes -ne 65536 -or
        [int]$Snapshot.mutex -ne 0) {
        throw ("NKSC header layout mismatch: magic=$($Snapshot.magic) version=$($Snapshot.version) " +
            "headerBytes=$($Snapshot.headerBytes) totalBytes=$($Snapshot.totalBytes).")
    }
    if (-not [bool]$Snapshot.sequenceTerminated -or -not [bool]$Snapshot.errorMessageTerminated -or
        [string]$Snapshot.sequenceId -cne [string]$Manifest.sequenceId) {
        throw "NKSC sequence identity mismatch: expected '$($Manifest.sequenceId)', got '$($Snapshot.sequenceId)'."
    }
    if ([long]$Snapshot.actionCount -lt 1 -or [long]$Snapshot.actionCount -gt 64 -or
        [long]$Snapshot.actionCount -ne @($Manifest.actions).Count) {
        throw "NKSC actionCount mismatch: expected $(@($Manifest.actions).Count), got $($Snapshot.actionCount)."
    }
    if ([long]$Snapshot.retailPayloadLength -gt 32512 -or
        [long]$Snapshot.openMwPayloadLength -gt 32512) {
        throw 'NKSC payload length exceeds its 32,512-byte engine region.'
    }
    if ([bool]$Snapshot.error) {
        throw "NKSC endpoint error $($Snapshot.errorCode): $($Snapshot.errorMessage)"
    }
}

function Assert-SidecarInitialSnapshot([object]$Snapshot, [object]$Manifest) {
    Assert-SidecarHeaderContract -Snapshot $Snapshot -Manifest $Manifest
    if ([long]$Snapshot.state -ne 1 -or [uint32]$Snapshot.flags -ne 0 -or
        [long]$Snapshot.errorCode -ne 0 -or [long]$Snapshot.actorIndex -ne 0 -or
        [long]$Snapshot.actionIndex -ne 0 -or [uint64]$Snapshot.generation -ne 0 -or
        [uint64]$Snapshot.retailFrame -ne 0 -or [uint64]$Snapshot.openMwFrame -ne 0 -or
        [uint64]$Snapshot.captureOrdinal -ne 0 -or [uint64]$Snapshot.deadlineTickMs -ne 0 -or
        [long]$Snapshot.retailPayloadLength -ne 0 -or
        [long]$Snapshot.openMwPayloadLength -ne 0) {
        throw 'Coordinator-owned NKSC mapping was not initialized to the exact PlanLoaded zero-generation contract.'
    }
    return ConvertTo-SidecarHeaderEvidence $Snapshot
}

function ConvertFrom-SidecarPayload(
    [object]$Snapshot,
    [ValidateSet('Retail', 'OpenMW')][string]$Lane,
    [object]$Manifest,
    [int]$ActorIndex,
    [int]$ActionIndex,
    [uint64]$Generation,
    [string[]]$AllowedScreenshotRoots,
    [string]$RelativeScreenshotRoot = ''
) {
    $length = if ($Lane -eq 'Retail') { [uint32]$Snapshot.retailPayloadLength } else {
        [uint32]$Snapshot.openMwPayloadLength
    }
    $expectedCrc = if ($Lane -eq 'Retail') { [uint32]$Snapshot.retailPayloadCrc32 } else {
        [uint32]$Snapshot.openMwPayloadCrc32
    }
    [byte[]]$bytes = if ($Lane -eq 'Retail') { $Snapshot.retailPayloadBytes } else {
        $Snapshot.openMwPayloadBytes
    }
    if ($length -eq 0 -or $length -gt 32512 -or $bytes.Length -ne $length) {
        throw "$Lane NKSC payload is empty, oversized, or truncated: header=$length bytes, read=$($bytes.Length)."
    }
    $actualCrc = Get-Crc32 $bytes
    if ($actualCrc -ne $expectedCrc) {
        throw ("$Lane NKSC payload CRC mismatch: header=0x{0:X8}, computed=0x{1:X8}." -f
            $expectedCrc, $actualCrc)
    }
    try {
        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $text = $utf8.GetString($bytes)
        $document = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw "$Lane NKSC payload is not strict UTF-8 JSON: $($_.Exception.Message)" }
    $expectedSchema = if ($Lane -eq 'Retail') {
        'nikami-fnv-sidecar-retail/v1'
    } else { 'nikami-fnv-sidecar-openmw/v1' }
    $payloadSchema = Get-JsonString (Get-RequiredProperty $document 'schema' "$Lane payload") `
        "$Lane payload.schema"
    if ($payloadSchema -cne $expectedSchema) {
        throw "$Lane NKSC payload schema is not '$expectedSchema'."
    }
    $sequenceId = Get-JsonString (Get-RequiredProperty $document 'sequenceId' "$Lane payload") `
        "$Lane payload.sequenceId"
    $key = Get-RequiredProperty $document 'key' "$Lane payload"
    Assert-ObjectProperties -Object $key -Allowed @('sequenceId', 'actorIndex', 'actionIndex') `
        -Required @('sequenceId', 'actorIndex', 'actionIndex') -Context "$Lane payload.key"
    $keySequence = Get-JsonString (Get-RequiredProperty $key 'sequenceId' "$Lane payload.key") `
        "$Lane payload.key.sequenceId"
    $keyActor = Get-JsonInteger (Get-RequiredProperty $key 'actorIndex' "$Lane payload.key") `
        "$Lane payload.key.actorIndex" 0 ([uint32]::MaxValue)
    $keyAction = Get-JsonInteger (Get-RequiredProperty $key 'actionIndex' "$Lane payload.key") `
        "$Lane payload.key.actionIndex" 0 63
    $payloadGeneration = Get-JsonInteger (Get-RequiredProperty $document 'generation' "$Lane payload") `
        "$Lane payload.generation" 1 ([long]::MaxValue)
    if ($sequenceId -cne [string]$Manifest.sequenceId -or $keySequence -cne $sequenceId -or
        $keyActor -ne $ActorIndex -or $keyAction -ne $ActionIndex -or
        $payloadGeneration -ne $Generation) {
        throw ("$Lane NKSC payload identity mismatch: sequence='$sequenceId' key='$keySequence/$keyActor/$keyAction' " +
            "generation=$payloadGeneration; expected '$($Manifest.sequenceId)/$ActorIndex/$ActionIndex' generation=$Generation.")
    }
    $expectedAction = $Manifest.actions[$ActionIndex]
    $action = Get-RequiredProperty $document 'action' "$Lane payload"
    $actionId = Get-JsonString (Get-RequiredProperty $action 'id' "$Lane payload.action") `
        "$Lane payload.action.id"
    $requestedFrames = Get-JsonInteger `
        (Get-RequiredProperty $action 'requestedFrames' "$Lane payload.action") `
        "$Lane payload.action.requestedFrames" 1 36000
    $accepted = Get-JsonBoolean (Get-RequiredProperty $action 'accepted' "$Lane payload.action") `
        "$Lane payload.action.accepted"
    if ($actionId -cne [string]$expectedAction.id -or
        $requestedFrames -ne [long]$expectedAction.frames -or -not $accepted) {
        throw "$Lane NKSC payload does not prove the requested action descriptor was accepted unchanged."
    }
    $groupProperty = if ($Lane -eq 'Retail') { 'retailPlayGroup' } else { 'openMwGroup' }
    $expectedGroup = if ($Lane -eq 'Retail') {
        [string]$expectedAction.retailPlayGroup
    } else { [string]$expectedAction.openMwPoseGroup }
    $observedGroup = Get-JsonString (Get-RequiredProperty $action $groupProperty "$Lane payload.action") `
        "$Lane payload.action.$groupProperty"
    if ($observedGroup -cne $expectedGroup) {
        throw "$Lane NKSC payload requested-group token does not match the manifest."
    }

    $actor = Get-RequiredProperty $document 'actor' "$Lane payload"
    $expectedActor = $Manifest.actors[$ActorIndex]
    if ($Lane -eq 'Retail') {
        $expectedRef = [Convert]::ToUInt32(([string]$expectedActor.actorFormId).Substring(2), 16)
        $expectedBase = [Convert]::ToUInt32(([string]$expectedActor.actorBaseId).Substring(2), 16)
        $observedRef = Get-JsonInteger (Get-RequiredProperty $actor 'refForm' 'Retail payload.actor') `
            'Retail payload.actor.refForm' 1 ([uint32]::MaxValue)
        $observedBase = Get-JsonInteger (Get-RequiredProperty $actor 'baseForm' 'Retail payload.actor') `
            'Retail payload.actor.baseForm' 1 ([uint32]::MaxValue)
        if ($observedRef -ne $expectedRef -or $observedBase -ne $expectedBase) {
            throw 'Retail NKSC payload actor reference/base does not match the manifest.'
        }
        $capture = Get-RequiredProperty $document 'capture' 'Retail payload'
        if (-not (Get-JsonBoolean (Get-RequiredProperty $capture 'screenshotReady' 'Retail payload.capture') `
                'Retail payload.capture.screenshotReady')) {
            throw 'Retail NKSC payload does not prove a complete screenshot file.'
        }
        $relocatedScreenshot = if (@($AllowedScreenshotRoots).Count -ge 2) {
            Join-Path ([string]$AllowedScreenshotRoots[1]) `
                ('frame-actor-{0:D4}-action-{1:D2}-{2}.bmp' -f
                    $ActorIndex, $ActionIndex, [string]$expectedAction.id)
        } else { '' }
        $screenshotEvidence = Get-ValidatedFileEvidence `
            -PathValue (Get-RequiredProperty $capture 'file' 'Retail payload.capture') `
            -SizeValue (Get-RequiredProperty $capture 'size' 'Retail payload.capture') `
            -Context 'Retail payload.capture' -AllowedRoots $AllowedScreenshotRoots `
            -RelativeRoot $RelativeScreenshotRoot -FallbackPaths @($relocatedScreenshot)
    }
    else {
        $observedBase = Get-JsonString (Get-RequiredProperty $actor 'base' 'OpenMW payload.actor') `
            'OpenMW payload.actor.base'
        if ($observedBase -ine
            [string]$expectedActor.openMwBaseId) {
            throw 'OpenMW NKSC payload actor base does not match the manifest.'
        }
        $screenshot = Get-RequiredProperty $document 'screenshot' 'OpenMW payload'
        if (-not (Get-JsonBoolean (Get-RequiredProperty $screenshot 'exists' 'OpenMW payload.screenshot') `
                'OpenMW payload.screenshot.exists')) {
            throw 'OpenMW NKSC payload does not prove a complete screenshot file.'
        }
        $screenshotEvidence = Get-ValidatedFileEvidence `
            -PathValue (Get-RequiredProperty $screenshot 'path' 'OpenMW payload.screenshot') `
            -SizeValue (Get-RequiredProperty $screenshot 'bytes' 'OpenMW payload.screenshot') `
            -Context 'OpenMW payload.screenshot' -AllowedRoots $AllowedScreenshotRoots `
            -RelativeRoot $RelativeScreenshotRoot
    }
    return [pscustomobject][ordered]@{
        lane = $Lane
        schema = $expectedSchema
        bytes = [long]$length
        crc32 = ('0x{0:X8}' -f $actualCrc)
        sha256 = Get-ByteSha256 $bytes
        sequenceId = $sequenceId
        actorIndex = $ActorIndex
        actionIndex = $ActionIndex
        generation = $Generation
        actionId = [string]$expectedAction.id
        requestedGroup = $expectedGroup
        screenshotPath = [string]$screenshotEvidence.path
        screenshotBytes = [long]$screenshotEvidence.bytes
        screenshotSha256 = [string]$screenshotEvidence.sha256
        document = $document
        text = $text
        rawBytes = $bytes
    }
}

function Assert-SidecarCaptureSnapshot(
    [object]$Snapshot,
    [object]$Manifest,
    [int]$ExpectedOrdinal,
    [string[]]$RetailScreenshotRoots,
    [string[]]$OpenMwScreenshotRoots
) {
    Assert-SidecarHeaderContract -Snapshot $Snapshot -Manifest $Manifest
    if (@($RetailScreenshotRoots).Count -lt 1) {
        throw 'Retail screenshot validation requires an approved endpoint working root.'
    }
    if ($ExpectedOrdinal -lt 0 -or $ExpectedOrdinal -ge @($Manifest.captures).Count) {
        throw "Unexpected NKSC capture ordinal $ExpectedOrdinal."
    }
    $expected = $Manifest.captures[$ExpectedOrdinal]
    $requiredCaptureFlags = [uint32]0x1F
    if (([uint32]$Snapshot.flags -band $requiredCaptureFlags) -ne $requiredCaptureFlags -or
        [long]$Snapshot.state -notin @(7, 8)) {
        throw "NKSC capture $ExpectedOrdinal was observed without both ready/captured flags and capture acknowledgement."
    }
    $expectedGeneration = [uint64]($ExpectedOrdinal + 1)
    if ([uint64]$Snapshot.captureOrdinal -ne [uint64]$ExpectedOrdinal -or
        [long]$Snapshot.actorIndex -ne [long]$expected.actorIndex -or
        [long]$Snapshot.actionIndex -ne [long]$expected.actionIndex -or
        [uint64]$Snapshot.generation -ne $expectedGeneration) {
        throw ("NKSC capture is partial, duplicate, stale, or out of order: observed ordinal/generation/key " +
            "$($Snapshot.captureOrdinal)/$($Snapshot.generation)/$($Snapshot.actorIndex)/$($Snapshot.actionIndex); " +
            "expected $ExpectedOrdinal/$expectedGeneration/$($expected.actorIndex)/$($expected.actionIndex).")
    }
    $retail = ConvertFrom-SidecarPayload -Snapshot $Snapshot -Lane Retail -Manifest $Manifest `
        -ActorIndex ([int]$expected.actorIndex) -ActionIndex ([int]$expected.actionIndex) `
        -Generation $expectedGeneration -AllowedScreenshotRoots $RetailScreenshotRoots `
        -RelativeScreenshotRoot ([string]$RetailScreenshotRoots[0])
    $openMw = ConvertFrom-SidecarPayload -Snapshot $Snapshot -Lane OpenMW -Manifest $Manifest `
        -ActorIndex ([int]$expected.actorIndex) -ActionIndex ([int]$expected.actionIndex) `
        -Generation $expectedGeneration -AllowedScreenshotRoots $OpenMwScreenshotRoots
    return [pscustomobject][ordered]@{
        captureOrdinal = $ExpectedOrdinal
        captureId = [string]$expected.captureId
        actorIndex = [int]$expected.actorIndex
        actionIndex = [int]$expected.actionIndex
        actionId = [string]$expected.actionId
        generation = $expectedGeneration
        header = ConvertTo-SidecarHeaderEvidence $Snapshot
        retail = $retail
        openMw = $openMw
    }
}

function Assert-SidecarFinalSnapshot(
    [object]$Snapshot,
    [object]$Manifest,
    [int]$ObservedCaptureCount,
    [string[]]$RetailScreenshotRoots,
    [string[]]$OpenMwScreenshotRoots,
    [object]$PreviouslyValidatedCapture
) {
    Assert-SidecarHeaderContract -Snapshot $Snapshot -Manifest $Manifest
    $expectedCaptureCount = @($Manifest.captures).Count
    if ($ObservedCaptureCount -ne $expectedCaptureCount) {
        throw "NKSC run is partial: coordinator observed $ObservedCaptureCount of $expectedCaptureCount acknowledgements."
    }
    $expectedLast = $Manifest.captures[$expectedCaptureCount - 1]
    if ([long]$Snapshot.state -ne 8 -or [uint32]$Snapshot.flags -ne [uint32]0x7F -or
        [long]$Snapshot.errorCode -ne 0 -or -not [string]::IsNullOrEmpty([string]$Snapshot.errorMessage) -or
        -not [bool]$Snapshot.lockstepComplete) {
        throw ("NKSC final gate failed: state=$($Snapshot.state), flags=0x{0:X8}, error=$($Snapshot.errorCode)." -f
            [uint32]$Snapshot.flags)
    }
    if ([long]$Snapshot.actorIndex -ne [long]$expectedLast.actorIndex -or
        [long]$Snapshot.actionIndex -ne [long]$expectedLast.actionIndex -or
        [uint64]$Snapshot.captureOrdinal -ne [uint64]$expectedLast.captureOrdinal -or
        [uint64]$Snapshot.generation -ne [uint64]$expectedCaptureCount -or
        [uint64]$Snapshot.retailFrame -eq 0 -or [uint64]$Snapshot.openMwFrame -eq 0) {
        throw 'NKSC final header identity, generation, capture ordinal, or engine frame is incomplete.'
    }
    if ($null -eq $PreviouslyValidatedCapture -or
        [int]$PreviouslyValidatedCapture.captureOrdinal -ne ($expectedCaptureCount - 1) -or
        [uint64]$PreviouslyValidatedCapture.generation -ne [uint64]$expectedCaptureCount) {
        throw 'NKSC final payloads have no immediately preceding validated capture to bind to.'
    }
    # The retail runner moves native screenshots only after the endpoint exits.
    # Reopening the original path here would make a valid final payload fail.
    # Instead require both current payload byte strings to be exactly identical
    # to the last payloads whose source screenshots were already hashed and
    # copied while the acknowledgement was live.
    foreach ($lane in @('retail', 'openMw')) {
        [byte[]]$currentBytes = if ($lane -eq 'retail') {
            $Snapshot.retailPayloadBytes
        } else { $Snapshot.openMwPayloadBytes }
        [uint32]$currentLength = if ($lane -eq 'retail') {
            $Snapshot.retailPayloadLength
        } else { $Snapshot.openMwPayloadLength }
        [uint32]$currentCrc = if ($lane -eq 'retail') {
            $Snapshot.retailPayloadCrc32
        } else { $Snapshot.openMwPayloadCrc32 }
        [byte[]]$validatedBytes = $PreviouslyValidatedCapture.$lane.rawBytes
        if ($currentLength -eq 0 -or $currentLength -gt 32512 -or
            $currentBytes.Length -ne $currentLength -or
            (Get-Crc32 $currentBytes) -ne $currentCrc -or
            $null -eq $validatedBytes -or
            -not [System.Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $currentBytes, $validatedBytes)) {
            throw "$lane final NKSC payload is not byte-identical to its already validated last-capture payload."
        }
    }
    $retail = $PreviouslyValidatedCapture.retail
    $openMw = $PreviouslyValidatedCapture.openMw
    return [pscustomobject][ordered]@{
        header = ConvertTo-SidecarHeaderEvidence $Snapshot
        retail = $retail
        openMw = $openMw
    }
}

function Write-SidecarSnapshotEvidence(
    [object]$Validated,
    [object]$Snapshot,
    [string]$Directory,
    [switch]$RefuseExisting,
    [object]$ReuseScreenshotEvidence
) {
    if ($RefuseExisting -and (Test-Path -LiteralPath $Directory)) {
        throw "Refusing duplicate NKSC evidence directory: $Directory"
    }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $headerPath = Join-Path $Directory 'header.json'
    $blockPath = Join-Path $Directory 'shared-block.bin'
    $retailPath = Join-Path $Directory 'retail-payload.json'
    $openMwPath = Join-Path $Directory 'openmw-payload.json'
    [byte[]]$stableBlockBytes = $Snapshot.blockBytes
    if ($null -eq $stableBlockBytes -or $stableBlockBytes.Length -ne 65536) {
        throw 'Refusing to persist NKSC evidence without the exact stable 65,536-byte snapshot.'
    }
    [IO.File]::WriteAllBytes($blockPath, $stableBlockBytes)
    [IO.File]::WriteAllBytes($retailPath, [byte[]]$Snapshot.retailPayloadBytes)
    [IO.File]::WriteAllBytes($openMwPath, [byte[]]$Snapshot.openMwPayloadBytes)
    $durableScreenshots = [ordered]@{}
    foreach ($lane in @('retail', 'openMw')) {
        $validatedLane = $Validated.$lane
        $reusePath = if ($null -eq $ReuseScreenshotEvidence) { '' } else {
            [string]$ReuseScreenshotEvidence.$lane
        }
        if (-not [string]::IsNullOrWhiteSpace($reusePath)) {
            if (-not (Test-Path -LiteralPath $reusePath -PathType Leaf) -or
                [IO.FileInfo]::new($reusePath).Length -ne [long]$validatedLane.screenshotBytes -or
                (Get-FileHash -LiteralPath $reusePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                    [string]$validatedLane.screenshotSha256) {
                throw "Previously persisted $lane screenshot evidence no longer matches its validated hash."
            }
            $durableScreenshots[$lane] = [IO.Path]::GetFullPath($reusePath)
            continue
        }
        $extension = [IO.Path]::GetExtension([string]$validatedLane.screenshotPath)
        if ($extension -notmatch '^\.[A-Za-z0-9]{1,8}$') { $extension = '.bin' }
        $destination = Join-Path $Directory ("$lane-screenshot$extension")
        [IO.File]::Copy([string]$validatedLane.screenshotPath, $destination, $false)
        if ([IO.FileInfo]::new($destination).Length -ne [long]$validatedLane.screenshotBytes -or
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                [string]$validatedLane.screenshotSha256) {
            throw "Persisted $lane screenshot copy does not match the validated source bytes."
        }
        $durableScreenshots[$lane] = $destination
    }
    $headerDocument = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-sidecar-shared-memory-evidence/v1'
        header = $Validated.header
        sharedBlock = [pscustomobject][ordered]@{
            path = $blockPath
            bytes = 65536
            sha256 = [string]$Snapshot.blockSha256
        }
        retail = [pscustomobject][ordered]@{
            path = $retailPath
            bytes = $Validated.retail.bytes
            crc32 = $Validated.retail.crc32
            sha256 = $Validated.retail.sha256
            screenshot = [pscustomobject][ordered]@{
                sourcePath = $Validated.retail.screenshotPath
                evidencePath = $durableScreenshots.retail
                bytes = $Validated.retail.screenshotBytes
                sha256 = $Validated.retail.screenshotSha256
            }
        }
        openMw = [pscustomobject][ordered]@{
            path = $openMwPath
            bytes = $Validated.openMw.bytes
            crc32 = $Validated.openMw.crc32
            sha256 = $Validated.openMw.sha256
            screenshot = [pscustomobject][ordered]@{
                sourcePath = $Validated.openMw.screenshotPath
                evidencePath = $durableScreenshots.openMw
                bytes = $Validated.openMw.screenshotBytes
                sha256 = $Validated.openMw.screenshotSha256
            }
        }
    }
    $headerDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $headerPath -Encoding UTF8
    return [pscustomobject][ordered]@{
        header = $headerPath
        sharedBlock = $blockPath
        retailPayload = $retailPath
        openMwPayload = $openMwPath
        retailScreenshot = $durableScreenshots.retail
        openMwScreenshot = $durableScreenshots.openMw
    }
}

function Wait-SidecarLaneJobs(
    [System.Management.Automation.Job]$RetailJob,
    [System.Management.Automation.Job]$OpenMwJob,
    [object]$Transport,
    [object]$Manifest,
    [string]$EvidenceRoot,
    [string[]]$RetailScreenshotRoots,
    [string[]]$OpenMwScreenshotRoots,
    [int]$TimeoutMinutes
) {
    $ledger = [System.Collections.Generic.List[object]]::new()
    $lastValidatedCapture = $null
    $lastEvidencePaths = $null
    $captureRoot = Join-Path $EvidenceRoot 'captures'
    New-Item -ItemType Directory -Path $captureRoot -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $waitHandles = [System.Threading.WaitHandle[]]@(
        $Transport.events.error,
        $Transport.events.captureAck
    )
    while ($true) {
        $snapshot = Get-SidecarTransportSnapshot -Transport $Transport
        if ($Transport.events.error.WaitOne(0) -or
            ($null -ne $snapshot -and [bool]$snapshot.readStable -and [bool]$snapshot.error)) {
            $detail = if ($null -eq $snapshot) { 'unreadable shared header' } else {
                "errorCode=$($snapshot.errorCode) state=$($snapshot.state) message='$($snapshot.errorMessage)'"
            }
            throw "NKSC error event signaled; $detail."
        }

        if ($null -ne $snapshot -and [bool]$snapshot.readStable -and
            (([uint32]$snapshot.flags -band [uint32]0x1F) -eq [uint32]0x1F)) {
            if ([uint64]$snapshot.generation -lt [uint64]$ledger.Count) {
                throw "NKSC stale acknowledgement generation $($snapshot.generation) after $($ledger.Count) captures."
            }
            if ([uint64]$snapshot.generation -gt [uint64]$ledger.Count) {
                $expectedOrdinal = $ledger.Count
                $validated = Assert-SidecarCaptureSnapshot -Snapshot $snapshot -Manifest $Manifest `
                    -ExpectedOrdinal $expectedOrdinal -RetailScreenshotRoots $RetailScreenshotRoots `
                    -OpenMwScreenshotRoots $OpenMwScreenshotRoots
                $captureDirectory = Join-Path $captureRoot ('{0:D8}-{1}' -f
                    $expectedOrdinal, (Get-SafeToken ([string]$validated.captureId)))
                $paths = Write-SidecarSnapshotEvidence -Validated $validated -Snapshot $snapshot `
                    -Directory $captureDirectory -RefuseExisting
                $lastValidatedCapture = $validated
                $lastEvidencePaths = $paths
                $ledger.Add([pscustomobject][ordered]@{
                    captureOrdinal = $validated.captureOrdinal
                    captureId = $validated.captureId
                    actorIndex = $validated.actorIndex
                    actionIndex = $validated.actionIndex
                    actionId = $validated.actionId
                    generation = $validated.generation
                    header = $paths.header
                    sharedBlock = $paths.sharedBlock
                    retailPayload = $paths.retailPayload
                    openMwPayload = $paths.openMwPayload
                    retailScreenshot = $paths.retailScreenshot
                    openMwScreenshot = $paths.openMwScreenshot
                    retailSha256 = $validated.retail.sha256
                    openMwSha256 = $validated.openMw.sha256
                    retailScreenshotSha256 = $validated.retail.screenshotSha256
                    openMwScreenshotSha256 = $validated.openMw.screenshotSha256
                }) | Out-Null
            }
            elseif ($ledger.Count -gt 0) {
                $prior = $ledger[$ledger.Count - 1]
                if ([uint64]$snapshot.captureOrdinal -ne [uint64]$prior.captureOrdinal -or
                    [long]$snapshot.actorIndex -ne [long]$prior.actorIndex -or
                    [long]$snapshot.actionIndex -ne [long]$prior.actionIndex) {
                    throw 'NKSC duplicate/stale acknowledgement changed identity without advancing generation.'
                }
            }
        }

        foreach ($lane in @(
            @('Retail', $RetailJob),
            @('OpenMW', $OpenMwJob)
        )) {
            $job = [System.Management.Automation.Job]$lane[1]
            if ($job.State -in @('Failed', 'Stopped', 'Blocked', 'Disconnected', 'AtBreakpoint')) {
                $reason = [string]$job.ChildJobs[0].JobStateInfo.Reason
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "state=$($job.State)" }
                throw "$($lane[0]) lane failed before lockstep completion: $reason"
            }
            if ($job.State -eq 'Completed') {
                $commonTerminal = $null -ne $snapshot -and [bool]$snapshot.readStable -and
                    [long]$snapshot.state -eq 8 -and [long]$snapshot.errorCode -eq 0 -and
                    ([uint32]$snapshot.flags -band [uint32]2147483648) -eq 0 -and
                    [bool]$snapshot.sequenceTerminated -and
                    [string]$snapshot.sequenceId -ceq [string]$Manifest.sequenceId
                $laneTerminal = if ($lane[0] -eq 'Retail') {
                    $commonTerminal -and (([uint32]$snapshot.flags -band [uint32]0x20) -ne 0)
                } else {
                    $commonTerminal -and [uint32]$snapshot.flags -eq [uint32]0x7F -and
                        (([uint32]$snapshot.flags -band [uint32]0x40) -ne 0)
                }
                if (-not $laneTerminal) {
                    throw "$($lane[0]) lane exited before its NKSC terminal flag/state contract was published."
                }
            }
        }
        if ($RetailJob.State -eq 'Completed' -and $OpenMwJob.State -eq 'Completed') { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "NKSC coordinator timed out after $TimeoutMinutes minutes while monitoring both lanes."
        }
        if ($Transport.events.captureAck.WaitOne(0)) { Start-Sleep -Milliseconds 10 }
        else { [System.Threading.WaitHandle]::WaitAny($waitHandles, 25) | Out-Null }
    }

    $finalSnapshot = Get-SidecarTransportSnapshot -Transport $Transport
    $finalValidated = Assert-SidecarFinalSnapshot -Snapshot $finalSnapshot -Manifest $Manifest `
        -ObservedCaptureCount $ledger.Count -RetailScreenshotRoots $RetailScreenshotRoots `
        -OpenMwScreenshotRoots $OpenMwScreenshotRoots -PreviouslyValidatedCapture $lastValidatedCapture
    $finalDirectory = Join-Path $EvidenceRoot 'final'
    $finalPaths = Write-SidecarSnapshotEvidence -Validated $finalValidated -Snapshot $finalSnapshot `
        -Directory $finalDirectory -RefuseExisting -ReuseScreenshotEvidence ([pscustomobject]@{
            retail = $lastEvidencePaths.retailScreenshot
            openMw = $lastEvidencePaths.openMwScreenshot
        })
    $ledgerPath = Join-Path $EvidenceRoot 'capture-ledger.json'
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-sidecar-observed-capture-ledger/v1'
        sequenceId = [string]$Manifest.sequenceId
        expectedCaptures = @($Manifest.captures).Count
        observedCaptures = $ledger.Count
        captures = @($ledger)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ledgerPath -Encoding UTF8

    $retailOutput = @(Receive-Job -Job $RetailJob -ErrorAction SilentlyContinue)
    $openMwOutput = @(Receive-Job -Job $OpenMwJob -ErrorAction SilentlyContinue)
    return [pscustomobject][ordered]@{
        retailOutput = $retailOutput
        openMwOutput = $openMwOutput
        captureLedger = $ledgerPath
        captures = @($ledger)
        final = [pscustomobject][ordered]@{
            header = $finalValidated.header
            headerEvidence = $finalPaths.header
            sharedBlock = $finalPaths.sharedBlock
            retailPayload = $finalPaths.retailPayload
            openMwPayload = $finalPaths.openMwPayload
            retailSha256 = $finalValidated.retail.sha256
            openMwSha256 = $finalValidated.openMw.sha256
        }
    }
}

function ConvertTo-NormalizedManifest([object]$Document, [string]$SourcePath) {
    Assert-ObjectProperties -Object $Document `
        -Allowed @('schema', 'sequenceId', 'scene', 'actions', 'openMw', 'actors') `
        -Required @('schema', 'sequenceId', 'scene', 'actions', 'openMw', 'actors') -Context 'manifest'
    $schema = Get-JsonString (Get-RequiredProperty $Document 'schema' 'manifest') 'manifest.schema'
    if ($schema -ne 'nikami-fnv-actor-parity-sidecar/v1') {
        throw "Unsupported actor-parity sidecar schema '$schema' in $SourcePath."
    }
    $sequenceId = Get-JsonString (Get-RequiredProperty $Document 'sequenceId' 'manifest') `
        'manifest.sequenceId'
    if ($sequenceId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'manifest.sequenceId must be a filesystem-safe nonempty token.'
    }
    if ([Text.Encoding]::UTF8.GetByteCount($sequenceId) -gt 127) {
        throw 'manifest.sequenceId exceeds the NKSC 127-byte UTF-8 header limit.'
    }

    $scene = Get-RequiredProperty $Document 'scene' 'manifest'
    Assert-ObjectProperties -Object $scene -Allowed @('cell', 'camera', 'time', 'weather') `
        -Required @('cell', 'camera', 'time', 'weather') -Context 'manifest.scene'
    $cell = Get-JsonString (Get-RequiredProperty $scene 'cell' 'manifest.scene') 'manifest.scene.cell'
    if ([string]::IsNullOrWhiteSpace($cell)) { throw 'manifest.scene.cell must not be empty.' }

    $camera = Get-RequiredProperty $scene 'camera' 'manifest.scene'
    $cameraProperties = @('stateId', 'shotKind', 'proofAnchorFormId', 'targetPosition',
        'targetYawRadians', 'playerPosition', 'fullBodyDistanceScale', 'minimumCameraHeight',
        'minimumAimHeight', 'initializationFrames', 'targetSettleFrames')
    Assert-ObjectProperties -Object $camera -Allowed $cameraProperties -Required $cameraProperties `
        -Context 'manifest.scene.camera'
    $cameraStateId = Get-JsonString `
        (Get-RequiredProperty $camera 'stateId' 'manifest.scene.camera') 'manifest.scene.camera.stateId'
    if ([string]::IsNullOrWhiteSpace($cameraStateId)) {
        throw 'manifest.scene.camera.stateId must not be empty.'
    }
    $shotKind = Get-JsonString `
        (Get-RequiredProperty $camera 'shotKind' 'manifest.scene.camera') 'manifest.scene.camera.shotKind'
    if ($shotKind -ne 'front-full-body') {
        throw "Only the current one-process front-full-body contract is supported; got '$shotKind'."
    }
    $proofAnchorFormId = Format-RetailFormId `
        (Get-RequiredProperty $camera 'proofAnchorFormId' 'manifest.scene.camera') `
        'manifest.scene.camera.proofAnchorFormId'
    $targetPosition = Get-Vector3 `
        (Get-RequiredProperty $camera 'targetPosition' 'manifest.scene.camera') `
        'manifest.scene.camera.targetPosition'
    $playerPosition = Get-Vector3 `
        (Get-RequiredProperty $camera 'playerPosition' 'manifest.scene.camera') `
        'manifest.scene.camera.playerPosition'
    $targetYawRadians = Get-FiniteNumber `
        (Get-RequiredProperty $camera 'targetYawRadians' 'manifest.scene.camera') `
        'manifest.scene.camera.targetYawRadians'
    $fullBodyDistanceScale = Get-FiniteNumber `
        (Get-RequiredProperty $camera 'fullBodyDistanceScale' 'manifest.scene.camera') `
        'manifest.scene.camera.fullBodyDistanceScale'
    if ($fullBodyDistanceScale -lt 1.25 -or $fullBodyDistanceScale -gt 10) {
        throw 'manifest.scene.camera.fullBodyDistanceScale must be between 1.25 and 10.'
    }
    $minimumCameraHeight = Get-FiniteNumber `
        (Get-RequiredProperty $camera 'minimumCameraHeight' 'manifest.scene.camera') `
        'manifest.scene.camera.minimumCameraHeight'
    $minimumAimHeight = Get-FiniteNumber `
        (Get-RequiredProperty $camera 'minimumAimHeight' 'manifest.scene.camera') `
        'manifest.scene.camera.minimumAimHeight'
    if ($minimumCameraHeight -lt $minimumAimHeight -or $minimumAimHeight -lt 0) {
        throw 'manifest.scene.camera heights must satisfy minimumCameraHeight >= minimumAimHeight >= 0.'
    }
    $initializationFrames = Get-JsonInteger `
        (Get-RequiredProperty $camera 'initializationFrames' 'manifest.scene.camera') `
        'manifest.scene.camera.initializationFrames' 1 1200
    $targetSettleFrames = Get-JsonInteger `
        (Get-RequiredProperty $camera 'targetSettleFrames' 'manifest.scene.camera') `
        'manifest.scene.camera.targetSettleFrames' 1 600

    $time = Get-RequiredProperty $scene 'time' 'manifest.scene'
    Assert-ObjectProperties -Object $time -Allowed @('gameHour', 'timeScale') `
        -Required @('gameHour', 'timeScale') -Context 'manifest.scene.time'
    $gameHour = Get-FiniteNumber (Get-RequiredProperty $time 'gameHour' 'manifest.scene.time') `
        'manifest.scene.time.gameHour'
    $timeScale = Get-FiniteNumber (Get-RequiredProperty $time 'timeScale' 'manifest.scene.time') `
        'manifest.scene.time.timeScale'
    if ($gameHour -lt 0 -or $gameHour -ge 24) { throw 'manifest.scene.time.gameHour must be in [0, 24).' }
    if ($timeScale -lt 0 -or $timeScale -gt 10000) {
        throw 'manifest.scene.time.timeScale must be in [0, 10000].'
    }

    $weather = Get-RequiredProperty $scene 'weather' 'manifest.scene'
    Assert-ObjectProperties -Object $weather -Allowed @('editorId', 'retailFormId', 'openMwId') `
        -Required @('editorId', 'retailFormId', 'openMwId') -Context 'manifest.scene.weather'
    $weatherEditorId = Get-JsonString `
        (Get-RequiredProperty $weather 'editorId' 'manifest.scene.weather') 'manifest.scene.weather.editorId'
    if ([string]::IsNullOrWhiteSpace($weatherEditorId)) {
        throw 'manifest.scene.weather.editorId must not be empty.'
    }
    $retailWeatherFormId = Format-RetailFormId `
        (Get-RequiredProperty $weather 'retailFormId' 'manifest.scene.weather') `
        'manifest.scene.weather.retailFormId'
    $openMwWeatherId = Format-OpenMwFormId `
        (Get-RequiredProperty $weather 'openMwId' 'manifest.scene.weather') `
        'manifest.scene.weather.openMwId'

    # Read array-valued properties directly. PowerShell 5.1 enumerates a
    # single-element array returned from a helper function, erasing the JSON
    # array shape before the strict type gate can inspect it.
    $actionSource = $Document.PSObject.Properties['actions'].Value
    # Do not pass a one-element Object[] through a scalar [object] function
    # parameter: Windows PowerShell 5.1 unwraps it. Inspect the JSON value
    # directly so a one-row array remains valid while an object impostor fails.
    if ($null -eq $actionSource -or $actionSource -isnot [System.Array]) {
        throw 'manifest.actions must be a JSON array.'
    }
    $actionValues = @($actionSource)
    if ($actionValues.Count -eq 0) { throw 'manifest.actions must contain at least one action descriptor.' }
    if ($actionValues.Count -gt 64) { throw 'manifest.actions exceeds the retail endpoint limit of 64.' }
    $normalizedActions = [System.Collections.Generic.List[object]]::new()
    $actionIdSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $actionValues.Count; ++$index) {
        $action = $actionValues[$index]
        Assert-ObjectProperties -Object $action -Allowed @('id', 'openMwPoseGroup', 'retailPlayGroup', 'frames') `
            -Required @('id', 'openMwPoseGroup', 'retailPlayGroup', 'frames') -Context "manifest.actions[$index]"
        $id = Get-JsonString (Get-RequiredProperty $action 'id' "manifest.actions[$index]") `
            "manifest.actions[$index].id"
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,126}$') {
            throw "manifest.actions[$index].id must be a nonempty transport-safe token no longer than 127 characters."
        }
        if (-not $actionIdSet.Add($id)) {
            throw "Duplicate action descriptor id in manifest: '$id'."
        }
        $openMwPoseGroup = Get-JsonString `
            (Get-RequiredProperty $action 'openMwPoseGroup' "manifest.actions[$index]") `
            "manifest.actions[$index].openMwPoseGroup"
        $retailPlayGroup = Get-JsonString `
            (Get-RequiredProperty $action 'retailPlayGroup' "manifest.actions[$index]") `
            "manifest.actions[$index].retailPlayGroup"
        if ([string]::IsNullOrWhiteSpace($openMwPoseGroup) -or
            [string]::IsNullOrWhiteSpace($retailPlayGroup)) {
            throw "manifest.actions[$index] must name both engine action groups."
        }
        if ($openMwPoseGroup -notmatch '^[A-Za-z0-9_.-]{1,127}$' -or
            $retailPlayGroup -notmatch '^[A-Za-z0-9_]{1,63}$') {
            throw "manifest.actions[$index] engine groups do not satisfy their endpoint token contracts."
        }
        $frames = Get-JsonInteger (Get-RequiredProperty $action 'frames' "manifest.actions[$index]") `
            "manifest.actions[$index].frames" 1 36000
        $normalizedActions.Add([pscustomobject][ordered]@{
            index = $index
            id = $id
            openMwPoseGroup = $openMwPoseGroup
            retailPlayGroup = $retailPlayGroup
            frames = $frames
            proofBoundary = 'requested-group-playback-transport-only'
        }) | Out-Null
    }

    $openMw = Get-RequiredProperty $Document 'openMw' 'manifest'
    Assert-ObjectProperties -Object $openMw -Allowed @('representativeOffset') `
        -Required @('representativeOffset') -Context 'manifest.openMw'
    $representativeOffset = Get-JsonInteger `
        (Get-RequiredProperty $openMw 'representativeOffset' 'manifest.openMw') `
        'manifest.openMw.representativeOffset' 0 ([uint32]::MaxValue)

    $actorSource = $Document.PSObject.Properties['actors'].Value
    if ($null -eq $actorSource -or $actorSource -isnot [System.Array]) {
        throw 'manifest.actors must be a JSON array.'
    }
    $actorValues = @($actorSource)
    if ($actorValues.Count -eq 0) { throw 'manifest.actors must contain at least one actor.' }
    if ($actorValues.Count -gt 8192) { throw 'manifest.actors exceeds the retail endpoint limit of 8192.' }
    $captureCount = [uint64]$actorValues.Count * [uint64]$actionValues.Count
    if ($captureCount -eq 0 -or $captureCount -gt [uint64][int]::MaxValue) {
        throw 'manifest actor/action product exceeds the coordinator capture-ordinal bound.'
    }
    $referenceSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $openMwBaseSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $normalizedActors = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $actorValues.Count; ++$index) {
        $actor = $actorValues[$index]
        Assert-ObjectProperties -Object $actor `
            -Allowed @('captureIndex', 'openMwRepresentativeIndex', 'actorFormId', 'actorBaseId',
                'openMwBaseId', 'editorId', 'displayName', 'visualTypeKey', 'selectedMainWeapon',
                'enableParentFormId') `
            -Required @('captureIndex', 'openMwRepresentativeIndex', 'actorFormId', 'actorBaseId',
                'openMwBaseId', 'selectedMainWeapon') -Context "manifest.actors[$index]"
        $captureIndex = Get-JsonInteger `
            (Get-RequiredProperty $actor 'captureIndex' "manifest.actors[$index]") `
            "manifest.actors[$index].captureIndex" 0 8191
        if ($captureIndex -ne $index) {
            throw "manifest.actors[$index].captureIndex must be $index; got $captureIndex."
        }
        $openMwRepresentativeIndex = Get-JsonInteger `
            (Get-RequiredProperty $actor 'openMwRepresentativeIndex' "manifest.actors[$index]") `
            "manifest.actors[$index].openMwRepresentativeIndex" 0 ([uint32]::MaxValue)
        $expectedOpenMwIndex = $representativeOffset + $index
        if ($openMwRepresentativeIndex -ne $expectedOpenMwIndex) {
            throw "manifest.actors[$index].openMwRepresentativeIndex must be contiguous and equal $expectedOpenMwIndex."
        }
        $actorFormId = Format-RetailFormId `
            (Get-RequiredProperty $actor 'actorFormId' "manifest.actors[$index]") `
            "manifest.actors[$index].actorFormId"
        $actorBaseId = Format-RetailFormId `
            (Get-RequiredProperty $actor 'actorBaseId' "manifest.actors[$index]") `
            "manifest.actors[$index].actorBaseId"
        $openMwBaseId = Format-OpenMwFormId `
            (Get-RequiredProperty $actor 'openMwBaseId' "manifest.actors[$index]") `
            "manifest.actors[$index].openMwBaseId"
        $visualTypeValue = Get-OptionalProperty $actor 'visualTypeKey' $null
        $visualTypeKey = if ($null -eq $visualTypeValue) { $null } else {
            $value = Get-JsonString $visualTypeValue "manifest.actors[$index].visualTypeKey"
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "manifest.actors[$index].visualTypeKey must not be empty when present."
            }
            $value
        }
        if (-not $referenceSet.Add($actorFormId)) {
            throw "Duplicate retail actor reference in manifest: $actorFormId"
        }
        if (-not $openMwBaseSet.Add($openMwBaseId)) {
            throw "Duplicate OpenMW actor base in manifest: $openMwBaseId"
        }
        $editorValue = Get-OptionalProperty $actor 'editorId' ''
        $editorId = Get-JsonString $editorValue "manifest.actors[$index].editorId"
        $displayValue = Get-OptionalProperty $actor 'displayName' $editorId
        $displayName = Get-JsonString $displayValue "manifest.actors[$index].displayName"
        $enableParentValue = Get-OptionalProperty $actor 'enableParentFormId' $null
        $enableParentFormId = if ($null -eq $enableParentValue -or
            [string]::IsNullOrWhiteSpace([string]$enableParentValue)) {
            $null
        } else {
            Format-RetailFormId $enableParentValue "manifest.actors[$index].enableParentFormId"
        }

        $weapon = Get-RequiredProperty $actor 'selectedMainWeapon' "manifest.actors[$index]"
        Assert-ObjectProperties -Object $weapon -Allowed @('editorId', 'formId') `
            -Required @('editorId', 'formId') -Context "manifest.actors[$index].selectedMainWeapon"
        $weaponEditorValue = Get-RequiredProperty $weapon 'editorId' "manifest.actors[$index].selectedMainWeapon"
        $weaponFormValue = Get-RequiredProperty $weapon 'formId' "manifest.actors[$index].selectedMainWeapon"
        $weaponEditorId = if ($null -eq $weaponEditorValue) { '' } else {
            Get-JsonString $weaponEditorValue "manifest.actors[$index].selectedMainWeapon.editorId"
        }
        $weaponFormId = if ($null -eq $weaponFormValue -or
            [string]::IsNullOrWhiteSpace([string]$weaponFormValue)) {
            $null
        } else {
            Format-RetailFormId $weaponFormValue "manifest.actors[$index].selectedMainWeapon.formId"
        }
        if ([string]::IsNullOrWhiteSpace($weaponEditorId) -ne ($null -eq $weaponFormId)) {
            throw "manifest.actors[$index].selectedMainWeapon must provide both editorId and formId, or null for both."
        }

        $captureId = '{0:D5}::{1}::front-full-body' -f $captureIndex,
            (Get-SafeToken $(if ([string]::IsNullOrWhiteSpace($editorId)) { $actorBaseId } else { $editorId }))
        $normalizedActors.Add([pscustomobject][ordered]@{
            captureIndex = $captureIndex
            captureId = $captureId
            openMwRepresentativeIndex = $openMwRepresentativeIndex
            actorFormId = $actorFormId
            actorBaseId = $actorBaseId
            openMwBaseId = $openMwBaseId
            editorId = $editorId
            displayName = $displayName
            visualTypeKey = $visualTypeKey
            selectedMainWeapon = [pscustomobject][ordered]@{
                editorId = if ([string]::IsNullOrWhiteSpace($weaponEditorId)) { $null } else { $weaponEditorId }
                formId = $weaponFormId
            }
            enableParentFormId = $enableParentFormId
        }) | Out-Null
    }

    $normalizedCaptures = [System.Collections.Generic.List[object]]::new()
    foreach ($actor in @($normalizedActors)) {
        $actorToken = Get-SafeToken $(if ([string]::IsNullOrWhiteSpace([string]$actor.editorId)) {
            [string]$actor.actorBaseId
        } else { [string]$actor.editorId })
        foreach ($action in @($normalizedActions)) {
            $ordinal = ([int]$actor.captureIndex * @($normalizedActions).Count) + [int]$action.index
            $normalizedCaptures.Add([pscustomobject][ordered]@{
                captureOrdinal = $ordinal
                actorIndex = [int]$actor.captureIndex
                actionIndex = [int]$action.index
                actionId = [string]$action.id
                captureId = '{0:D5}::{1}::{2}::front-full-body' -f @(
                    $ordinal, $actorToken, [string]$action.id)
            }) | Out-Null
        }
    }

    return [pscustomobject][ordered]@{
        schema = $schema
        source = $SourcePath
        sequenceId = $sequenceId
        scene = [pscustomobject][ordered]@{
            cell = $cell
            camera = [pscustomobject][ordered]@{
                stateId = $cameraStateId
                shotKind = $shotKind
                proofAnchorFormId = $proofAnchorFormId
                targetPosition = $targetPosition
                targetYawRadians = $targetYawRadians
                playerPosition = $playerPosition
                fullBodyDistanceScale = $fullBodyDistanceScale
                minimumCameraHeight = $minimumCameraHeight
                minimumAimHeight = $minimumAimHeight
                initializationFrames = $initializationFrames
                targetSettleFrames = $targetSettleFrames
            }
            time = [pscustomobject][ordered]@{ gameHour = $gameHour; timeScale = $timeScale }
            weather = [pscustomobject][ordered]@{
                editorId = $weatherEditorId
                retailFormId = $retailWeatherFormId
                openMwId = $openMwWeatherId
            }
        }
        actions = @($normalizedActions)
        openMw = [pscustomobject][ordered]@{ representativeOffset = $representativeOffset }
        actors = @($normalizedActors)
        captures = @($normalizedCaptures)
    }
}

function Assert-OpenMwRosterContract([object]$Manifest, [string]$RosterPath) {
    $resolved = Resolve-RepoPath $RosterPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Missing authoritative OpenMW representative roster: $resolved"
    }
    $roster = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    if ([string]$roster.schema -ne 'nikami-fnv-loaded-actor-roster/v1') {
        throw "Unsupported OpenMW representative roster schema in ${resolved}: $($roster.schema)"
    }
    $rows = @($roster.actors)
    if ($rows.Count -ne [int]$roster.selectedCount -or $rows.Count -ne [int]$roster.distinctVisualTypes) {
        throw "Authoritative roster is not a complete representative set: rows=$($rows.Count) selected=$($roster.selectedCount) distinct=$($roster.distinctVisualTypes)."
    }
    $defects = [System.Collections.Generic.List[object]]::new()
    foreach ($actor in @($Manifest.actors)) {
        $rosterIndex = [int]$actor.openMwRepresentativeIndex
        if ($rosterIndex -lt 0 -or $rosterIndex -ge $rows.Count) {
            throw "Manifest capture index $($actor.captureIndex) requests OpenMW representative index $rosterIndex outside 0..$($rows.Count - 1)."
        }
        $actual = $rows[$rosterIndex]
        if ([int]$actual.index -ne $rosterIndex) {
            throw "Authoritative OpenMW roster row $rosterIndex declares index $($actual.index)."
        }
        foreach ($comparison in @(
            @('openMwBaseId', [string]$actor.openMwBaseId, [string]$actual.form),
            @('visualTypeKey', [string]$actor.visualTypeKey, [string]$actual.visualSignature),
            @('selectedMainWeapon.editorId', [string]$actor.selectedMainWeapon.editorId, [string]$actual.selectedWeapon)
        )) {
            if ([string]$comparison[1] -cne [string]$comparison[2]) {
                $defects.Add([pscustomobject][ordered]@{
                    captureIndex = [int]$actor.captureIndex
                    openMwRepresentativeIndex = $rosterIndex
                    field = [string]$comparison[0]
                    expected = [string]$comparison[1]
                    actual = [string]$comparison[2]
                }) | Out-Null
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$actor.editorId) -and
            [string]$actor.editorId -cne [string]$actual.editorId) {
            $defects.Add([pscustomobject][ordered]@{
                captureIndex = [int]$actor.captureIndex
                openMwRepresentativeIndex = $rosterIndex
                field = 'editorId'
                expected = [string]$actor.editorId
                actual = [string]$actual.editorId
            }) | Out-Null
        }
    }
    if ($defects.Count -gt 0) {
        throw "Manifest disagrees with the authoritative OpenMW representative roster: $($defects | ConvertTo-Json -Depth 6 -Compress)"
    }
    return [pscustomobject][ordered]@{
        schema = 'nikami-fnv-openmw-representative-roster-preflight/v1'
        status = 'passed'
        path = $resolved
        sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
        selectedCount = [int]$roster.selectedCount
        distinctVisualTypes = [int]$roster.distinctVisualTypes
        manifestOffset = [int]$Manifest.openMw.representativeOffset
        manifestCount = @($Manifest.actors).Count
        matchedRows = @($Manifest.actors).Count
    }
}

function Write-RetailSidecarPlan([object]$Manifest, [string]$Path) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('nikami-fnv-retail-plan-v1')
    $lines.Add("sequence`t$($Manifest.sequenceId)")
    $sceneFields = @(
        'scene',
        [string]$Manifest.scene.camera.proofAnchorFormId,
        [string]$Manifest.scene.weather.retailFormId,
        (Get-Invariant ([double]$Manifest.scene.time.gameHour)),
        (Get-Invariant ([double]$Manifest.scene.time.timeScale)),
        (Get-Invariant ([double]$Manifest.scene.camera.targetPosition[0])),
        (Get-Invariant ([double]$Manifest.scene.camera.targetPosition[1])),
        (Get-Invariant ([double]$Manifest.scene.camera.targetPosition[2])),
        (Get-Invariant ([double]$Manifest.scene.camera.targetYawRadians)),
        (Get-Invariant ([double]$Manifest.scene.camera.playerPosition[0])),
        (Get-Invariant ([double]$Manifest.scene.camera.playerPosition[1])),
        (Get-Invariant ([double]$Manifest.scene.camera.playerPosition[2])),
        (Get-Invariant ([double]$Manifest.scene.camera.fullBodyDistanceScale)),
        (Get-Invariant ([double]$Manifest.scene.camera.minimumCameraHeight)),
        (Get-Invariant ([double]$Manifest.scene.camera.minimumAimHeight)),
        [string]$Manifest.scene.camera.initializationFrames,
        [string]$Manifest.scene.camera.targetSettleFrames
    )
    $lines.Add($sceneFields -join "`t")
    foreach ($action in @($Manifest.actions)) {
        $lines.Add((@('action', [string]$action.index, [string]$action.id,
            [string]$action.retailPlayGroup, [string]$action.frames) -join "`t"))
    }
    foreach ($actor in @($Manifest.actors)) {
        $weapon = if ($null -eq $actor.selectedMainWeapon.formId) { '0' } else {
            [string]$actor.selectedMainWeapon.formId
        }
        $enableParent = if ($null -eq $actor.enableParentFormId) { '0' } else {
            [string]$actor.enableParentFormId
        }
        $lines.Add((@('actor', [string]$actor.captureIndex, [string]$actor.actorFormId,
            [string]$actor.actorBaseId, $weapon, $enableParent) -join "`t"))
    }
    $lines.Add('end')
    # Windows PowerShell 5.1's `-Encoding UTF8` writes a BOM. The native
    # parser compares the first byte of the first line, so write strict
    # BOM-free UTF-8 explicitly.
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

function New-ChildInvocationPlan([object]$Manifest, [string]$RunRoot, [object]$Channel) {
    $retailRoot = Join-Path $RunRoot 'retail'
    $openMwRoot = Join-Path $RunRoot 'openmw'
    $retailOutput = Join-Path $retailRoot 'retail-oracle.jsonl'
    $retailScreens = Join-Path $retailRoot 'screens'
    $normalizedManifestPath = Join-Path $RunRoot 'normalized-manifest.json'
    $retailPlanPath = Join-Path $RunRoot 'retail-sidecar-plan.tsv'
    $lockstepRequested = $Engine -eq 'Both' -and -not $AllowStaticRetailProof
    $channelEnvironment = Get-SidecarChannelEnvironment -Channel $Channel -PlanPath $retailPlanPath `
        -BarrierTimeoutMilliseconds $BarrierTimeoutMilliseconds
    $actorCount = @($Manifest.actors).Count
    $actionFramesTotal = [long](@($Manifest.actions | Measure-Object -Property frames -Sum)[0].Sum)
    $maxFrames = [Math]::Max(300, [int]$Manifest.scene.camera.initializationFrames +
        ($actorCount * ($actionFramesTotal + (@($Manifest.actions).Count * 180))) + 120)
    # Invoke-FNVRetailOracle.ps1 intentionally caps its watchdog at 300 seconds.
    $timeoutSeconds = [Math]::Min(300, [Math]::Max(90, $actorCount * 8 + 60))
    $retailCommands = @(
        'Set GameHour To ' + (Get-Invariant ([double]$Manifest.scene.time.gameHour))
        'Set TimeScale To ' + (Get-Invariant ([double]$Manifest.scene.time.timeScale))
        'fw ' + ([string]$Manifest.scene.weather.retailFormId).Substring(2)
    )
    $enableParents = @($Manifest.actors | ForEach-Object { $_.enableParentFormId } |
        Where-Object { $null -ne $_ } | Select-Object -Unique)
    $retailArguments = @{
        GameRoot = Resolve-RepoPath $GameRoot
        RuntimeRoot = Resolve-RepoPath $RetailRuntimeRoot
        PluginDll = Resolve-RepoPath $RetailPluginDll
        OutputPath = $retailOutput
        ScreenshotDirectory = $retailScreens
        CameraShotKind = 'front-full-body'
        FullBodyDistanceScale = [float]$Manifest.scene.camera.fullBodyDistanceScale
        Command = $retailCommands
        BeforeFrame = 5
        CommandFrame = 10
        AfterFrame = 15
        MaxFrames = $maxFrames
        TimeoutSeconds = if ($AllowStaticRetailProof) { $timeoutSeconds } else {
            [Math]::Min([int]::MaxValue, [long]$TimeoutMinutes * 60)
        }
        SampleEvery = 1
        BackgroundDataMode = $true
        VisibleGame = [bool]$VisibleRetail
    }
    if ($AllowStaticRetailProof) {
        $retailArguments.BatchTargetForm = @($Manifest.actors.actorFormId)
        $retailArguments.BatchExpectedBaseForm = @($Manifest.actors.actorBaseId)
        $retailArguments.BatchEnableParentForm = $enableParents
        $retailArguments.BatchMoveToTargets = $true
        $retailArguments.BatchEnableTargets = $true
        $retailArguments.BatchProofStaging = $true
        $retailArguments.BatchProofAnchorForm = [string]$Manifest.scene.camera.proofAnchorFormId
        $retailArguments.BatchProofTargetX = [float]$Manifest.scene.camera.targetPosition[0]
        $retailArguments.BatchProofTargetY = [float]$Manifest.scene.camera.targetPosition[1]
        $retailArguments.BatchProofTargetZ = [float]$Manifest.scene.camera.targetPosition[2]
        $retailArguments.BatchProofTargetYaw = [float]$Manifest.scene.camera.targetYawRadians
        $retailArguments.BatchProofPlayerX = [float]$Manifest.scene.camera.playerPosition[0]
        $retailArguments.BatchProofPlayerY = [float]$Manifest.scene.camera.playerPosition[1]
        $retailArguments.BatchProofPlayerZ = [float]$Manifest.scene.camera.playerPosition[2]
        $retailArguments.BatchProofMinimumCameraHeight = [float]$Manifest.scene.camera.minimumCameraHeight
        $retailArguments.BatchProofMinimumAimHeight = [float]$Manifest.scene.camera.minimumAimHeight
        $retailArguments.BatchProofInitializationFrames = [int]$Manifest.scene.camera.initializationFrames
        $retailArguments.BatchProofTargetSettleFrames = [int]$Manifest.scene.camera.targetSettleFrames
        $retailArguments.BatchSettleFrames = $RetailBatchSettleFrames
        $retailArguments.BatchAdvanceFrames = $RetailBatchAdvanceFrames
        $retailArguments.BatchForceWeaponOut = $true
        $retailArguments.BatchWeaponProbeFrames = $RetailWeaponProbeFrames
    }
    elseif ($lockstepRequested) {
        $retailArguments.PlanPath = $retailPlanPath
        $retailArguments.SharedMemoryName = [string]$Channel.mappingName
        $retailArguments.BarrierTimeoutMilliseconds = $BarrierTimeoutMilliseconds
    }
    if (-not [string]::IsNullOrWhiteSpace($RetailSaveFixture)) {
        $retailArguments.SaveFixture = Resolve-RepoPath $RetailSaveFixture
    }

    $openMwEnvironment = @(
        'OPENMW_FNV_BOOTSTRAP_HOUR=' + (Get-Invariant ([double]$Manifest.scene.time.gameHour))
        'OPENMW_FNV_PROOF_WEATHER_ID=' + [string]$Manifest.scene.weather.openMwId
        'OPENMW_PROOF_ACTOR_STAGE_X=' + (Get-Invariant ([double]$Manifest.scene.camera.targetPosition[0]))
        'OPENMW_PROOF_ACTOR_STAGE_Y=' + (Get-Invariant ([double]$Manifest.scene.camera.targetPosition[1]))
        'OPENMW_PROOF_ACTOR_STAGE_Z=' + (Get-Invariant ([double]$Manifest.scene.camera.targetPosition[2]))
        'OPENMW_PROOF_ACTOR_STAGE_ROT_Z=' + (Get-Invariant ([double]$Manifest.scene.camera.targetYawRadians))
        'OPENMW_WORLD_VIEWER_START_POS_X=' + (Get-Invariant ([double]$Manifest.scene.camera.playerPosition[0]))
        'OPENMW_WORLD_VIEWER_START_POS_Y=' + (Get-Invariant ([double]$Manifest.scene.camera.playerPosition[1]))
        'OPENMW_WORLD_VIEWER_START_POS_Z=' + (Get-Invariant ([double]$Manifest.scene.camera.playerPosition[2]))
    )
    $openMwArguments = @{
        OutputRoot = $openMwRoot
        Offset = [int]$Manifest.openMw.representativeOffset
        Limit = $actorCount
        PoseFrames = [int]$Manifest.actions[0].frames
        PoseStartDelayFrames = 12
        NeutralFrames = 18
        PoseGroups = @($Manifest.actions.openMwPoseGroup)
        TimeoutMinutes = $TimeoutMinutes
        RepresentativeVisualTypes = $true
        SetEnv = $openMwEnvironment
        BackgroundWindow = [bool]$BackgroundOpenMW
    }
    if ($lockstepRequested) {
        $openMwArguments.SidecarMode = $true
        $openMwArguments.SidecarSharedMemoryName = [string]$Channel.mappingName
        $openMwArguments.SidecarActionIds = @($Manifest.actions.id)
    }

    return [pscustomobject][ordered]@{
        retail = [pscustomobject][ordered]@{
            script = $retailRunner
            arguments = $retailArguments
            output = $retailOutput
            screens = $retailScreens
            actionCoverage = if ($AllowStaticRetailProof) {
                'static-final-frame-only'
            } elseif ($lockstepRequested) { 'shared-memory-lockstep-requested-groups-transport-only' }
            else { 'not-executed' }
            environment = if ($lockstepRequested) { $channelEnvironment } else { @{} }
        }
        openMw = [pscustomobject][ordered]@{
            script = $openMwRunner
            arguments = $openMwArguments
            output = $openMwRoot
            actionCoverage = if ($lockstepRequested) {
                'shared-memory-lockstep-requested-groups-transport-only'
            } else { 'legacy-requested-groups-before-capture' }
            # SidecarMode parameters are the sole owner of the OpenMW mapping
            # and action-id environment; do not inject duplicate channel keys.
            environment = @{}
        }
        normalizedManifest = $normalizedManifestPath
        retailPlan = $retailPlanPath
        channel = $Channel
    }
}

function Invoke-PlannedChild([object]$Lane) {
    $scriptPath = [string]$Lane.script
    $arguments = [hashtable]$Lane.arguments
    $prior = @{}
    try {
        foreach ($entry in ([hashtable]$Lane.environment).GetEnumerator()) {
            $prior[$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
        }
        return @(& $scriptPath @arguments)
    }
    finally {
        foreach ($entry in $prior.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, 'Process')
        }
    }
}

function Receive-PlannedJob([System.Management.Automation.Job]$Job, [string]$Label) {
    Wait-Job -Job $Job | Out-Null
    $output = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue)
    $reason = $null
    if ($Job.State -ne 'Completed') {
        $reason = [string]$Job.ChildJobs[0].JobStateInfo.Reason
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "$Label job ended in state $($Job.State)." }
    }
    Remove-Job -Job $Job -Force
    if ($null -ne $reason) { throw "$Label lane failed: $reason" }
    return $output
}

function Assert-OpenMwResult([object]$Manifest, [object[]]$RunnerOutput, [switch]$Lockstep) {
    $result = @($RunnerOutput | Where-Object {
        $null -ne $_ -and ($_.PSObject.Properties['index'] -or $_.PSObject.Properties['sidecarMode'])
    } | Select-Object -Last 1)
    if ($result.Count -ne 1) { throw 'OpenMW lane did not return one terminal runner result.' }
    if ($Lockstep) {
        if (-not [bool](Get-RequiredProperty $result[0] 'sidecarMode' 'OpenMW sidecar result') -or
            [int](Get-RequiredProperty $result[0] 'processCount' 'OpenMW sidecar result') -ne 1 -or
            [bool](Get-RequiredProperty $result[0] 'runtimeContractProvenByRunner' 'OpenMW sidecar result')) {
            throw 'OpenMW lockstep lane did not return the one-process, coordinator-gated sidecar result.'
        }
        $rosterPath = [string](Get-RequiredProperty $result[0] 'roster' 'OpenMW sidecar result')
        $logPath = [string](Get-RequiredProperty $result[0] 'log' 'OpenMW sidecar result')
        foreach ($path in @($rosterPath, $logPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "OpenMW sidecar lane evidence is missing: $path"
            }
        }
        $observedActionIds = @((Get-RequiredProperty $result[0] 'actionIds' 'OpenMW sidecar result'))
        if ($observedActionIds.Count -ne @($Manifest.actions).Count) {
            throw 'OpenMW sidecar runner action-id count does not match the manifest.'
        }
        for ($index = 0; $index -lt $observedActionIds.Count; ++$index) {
            if ([string]$observedActionIds[$index] -cne [string]$Manifest.actions[$index].id) {
                throw "OpenMW sidecar runner action id $index does not match the manifest."
            }
        }
        return [pscustomobject][ordered]@{
            result = $result[0]
            index = $null
            rows = @()
            defects = @()
            evidenceBoundary = 'runner-lifecycle-only-nksc-final-header-required'
        }
    }
    $indexPath = [string]$result[0].index
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "OpenMW actor-sweep index is missing: $indexPath"
    }
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    $rows = @($index.rows)
    if ($rows.Count -ne @($Manifest.actors).Count) {
        throw "OpenMW returned $($rows.Count) rows; manifest requires $(@($Manifest.actors).Count)."
    }
    $defects = [System.Collections.Generic.List[object]]::new()
    for ($rowIndex = 0; $rowIndex -lt $rows.Count; ++$rowIndex) {
        $row = $rows[$rowIndex]
        $expected = $Manifest.actors[$rowIndex]
        foreach ($comparison in @(
            @('base-id', [string]$expected.openMwBaseId, [string]$row.form),
            @('visual-type', [string]$expected.visualTypeKey, [string]$row.visualSignature),
            @('main-weapon', [string]$expected.selectedMainWeapon.editorId, [string]$row.selectedWeapon)
        )) {
            if ([string]$comparison[1] -cne [string]$comparison[2]) {
                $defects.Add([pscustomobject][ordered]@{
                    captureIndex = $rowIndex
                    gate = [string]$comparison[0]
                    expected = [string]$comparison[1]
                    actual = [string]$comparison[2]
                }) | Out-Null
            }
        }
        if ([int]$row.posesRequested -ne @($Manifest.actions).Count -or
            [int]$row.posesPlayed -ne @($Manifest.actions).Count -or [int]$row.posesSkipped -ne 0) {
            $defects.Add([pscustomobject][ordered]@{
                captureIndex = $rowIndex
                gate = 'action-coverage'
                expected = "$(@($Manifest.actions).Count) played, 0 skipped"
                actual = "$($row.posesPlayed) played, $($row.posesSkipped) skipped"
            }) | Out-Null
        }
    }
    return [pscustomobject][ordered]@{
        result = $result[0]
        index = $indexPath
        rows = $rows
        defects = @($defects)
    }
}

function Assert-RetailResult([object]$Manifest, [object[]]$RunnerOutput, [switch]$Lockstep) {
    $result = @($RunnerOutput | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties['runManifest']
    } | Select-Object -Last 1)
    if ($result.Count -ne 1) { throw 'Retail lane did not return its oracle run manifest.' }
    $screens = @($result[0].screenshots)
    $expectedScreens = if ($Lockstep) { @($Manifest.captures).Count } else { @($Manifest.actors).Count }
    if ($screens.Count -ne $expectedScreens) {
        throw "Retail returned $($screens.Count) screenshots; this run requires $expectedScreens."
    }
    $completion = $null
    if ($Lockstep) {
        $outputPath = [string](Get-OptionalProperty $result[0] 'output' '')
        if ([string]::IsNullOrWhiteSpace($outputPath) -or
            -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw 'Retail lockstep lane did not return a readable oracle JSONL output path.'
        }
        foreach ($line in @(Select-String -LiteralPath $outputPath -SimpleMatch `
            '"event":"sidecar-sequence-complete"' | ForEach-Object { $_.Line })) {
            try {
                $candidate = $line | ConvertFrom-Json
                if ([string](Get-OptionalProperty $candidate 'sequenceId' '') -eq
                    [string]$Manifest.sequenceId) {
                    $completion = $candidate
                }
            }
            catch { }
        }
        if ($null -eq $completion) {
            throw "Retail JSONL does not prove sidecar-sequence-complete for '$($Manifest.sequenceId)'."
        }
    }
    return [pscustomobject][ordered]@{
        result = $result[0]
        runManifest = [string]$result[0].runManifest
        screens = $screens
        sidecarSequenceComplete = $completion
    }
}

function Write-PairedIndexes(
    [object]$Manifest,
    [object]$RetailEvidence,
    [object]$OpenMwEvidence,
    [string]$RunRoot
) {
    throw 'The coordinator does not generate inferred paired indexes. Use only observed NKSC capture-ledger payloads.'
    if ($null -eq $RetailEvidence -or $null -eq $OpenMwEvidence) { return $null }
    $retailRows = [System.Collections.Generic.List[object]]::new()
    $openMwRows = [System.Collections.Generic.List[object]]::new()
    $pairRows = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt @($Manifest.actors).Count; ++$index) {
        $actor = $Manifest.actors[$index]
        $requestedState = [pscustomobject][ordered]@{
            cameraStateId = [string]$Manifest.scene.camera.stateId
            actionSequence = @($Manifest.actions.id)
            selectedMainWeaponEditorId = [string]$actor.selectedMainWeapon.editorId
            selectedMainWeaponFormId = [string]$actor.selectedMainWeapon.formId
            retailWeatherFormId = [string]$Manifest.scene.weather.retailFormId
            openMwWeatherId = [string]$Manifest.scene.weather.openMwId
            gameHour = [double]$Manifest.scene.time.gameHour
        }
        $retailRows.Add([pscustomobject][ordered]@{
            captureId = [string]$actor.captureId
            actorId = if ([string]::IsNullOrWhiteSpace([string]$actor.editorId)) {
                [string]$actor.actorBaseId
            } else { [string]$actor.editorId }
            shotKind = 'front-full-body'
            screenshot = [string]$RetailEvidence.screens[$index]
            requestedState = $requestedState
            telemetry = [pscustomobject][ordered]@{
                poseState = 'static-final-frame-only'
                authoredWeaponDrawProbe = $true
                manifestWeaponApplied = $false
                manifestActionSequenceApplied = $false
                evaluatedTimeWeatherAtCapture = $false
            }
        }) | Out-Null
        $openMwRows.Add([pscustomobject][ordered]@{
            captureId = [string]$actor.captureId
            actorId = if ([string]::IsNullOrWhiteSpace([string]$actor.editorId)) {
                [string]$actor.actorBaseId
            } else { [string]$actor.editorId }
            shotKind = 'front-full-body'
            screenshot = [string]$OpenMwEvidence.rows[$index].screenshot
            requestedState = $requestedState
            telemetry = [pscustomobject][ordered]@{
                poseState = 'post-action-sequence'
                actionSequence = @($Manifest.actions.id)
                selectedWeaponEditorId = [string]$OpenMwEvidence.rows[$index].selectedWeapon
                posesRequested = [int]$OpenMwEvidence.rows[$index].posesRequested
                posesPlayed = [int]$OpenMwEvidence.rows[$index].posesPlayed
                posesSkipped = [int]$OpenMwEvidence.rows[$index].posesSkipped
            }
        }) | Out-Null
        $pairRows.Add([pscustomobject][ordered]@{
            actorId = if ([string]::IsNullOrWhiteSpace([string]$actor.editorId)) {
                [string]$actor.actorBaseId
            } else { [string]$actor.editorId }
            displayName = [string]$actor.displayName
            captureId = [string]$actor.captureId
            matchedCameraState = $false
            matchedStateFields = @()
        }) | Out-Null
    }
    $retailIndexPath = Join-Path $RunRoot 'retail-index.json'
    $openMwIndexPath = Join-Path $RunRoot 'openmw-index.json'
    $pairManifestPath = Join-Path $RunRoot 'paired-proof-manifest.json'
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-sidecar-index/v1'
        engine = 'retail'
        sequenceId = [string]$Manifest.sequenceId
        rows = @($retailRows)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $retailIndexPath -Encoding UTF8
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-sidecar-index/v1'
        engine = 'openmw'
        sequenceId = [string]$Manifest.sequenceId
        rows = @($openMwRows)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $openMwIndexPath -Encoding UTF8
    [pscustomobject][ordered]@{
        schema = 'nikami-fnv-paired-proof-manifest/v1'
        defaults = [pscustomobject][ordered]@{
            matchedCameraState = $false
            matchedStateFields = @()
        }
        actors = @($pairRows)
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pairManifestPath -Encoding UTF8
    return [pscustomobject][ordered]@{
        retailIndex = $retailIndexPath
        openMwIndex = $openMwIndexPath
        pairedProofManifest = $pairManifestPath
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

foreach ($requiredScript in @($retailRunner, $openMwRunner)) {
    if (-not (Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
        throw "Missing sidecar dependency: $requiredScript"
    }
}
$manifestFile = Resolve-RepoPath $ManifestPath
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    throw "Missing sidecar manifest: $manifestFile"
}
$document = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
$manifest = ConvertTo-NormalizedManifest -Document $document -SourcePath $manifestFile
$openMwRosterPreflight = Assert-OpenMwRosterContract -Manifest $manifest -RosterPath $OpenMwRosterPath
$sidecarProtocolPreflight = Assert-SidecarProtocolSourceContract
$runRoot = Join-Path (Resolve-RepoPath $OutputRoot) ([string]$manifest.sequenceId)
$channel = New-SidecarChannelContract -SequenceId $manifest.sequenceId -RequestedChannelId $ChannelId
$plan = New-ChildInvocationPlan -Manifest $manifest -RunRoot $runRoot -Channel $channel
$lockstepRequested = $Engine -eq 'Both' -and -not $AllowStaticRetailProof
$retailTargetListCharacters = (@($manifest.actors.actorFormId) -join ',').Length
$retailBaseListCharacters = (@($manifest.actors.actorBaseId) -join ',').Length
$retailEnvironmentListLimit = 4095
$retailStaticBatchRunnable = $retailTargetListCharacters -le $retailEnvironmentListLimit -and
    $retailBaseListCharacters -le $retailEnvironmentListLimit
$capabilityPreflight = Get-SidecarEndpointCapability -ProtocolSourcePreflight $sidecarProtocolPreflight
$capabilityPreflight.retail | Add-Member -NotePropertyName staticBatch -NotePropertyValue `
    ([pscustomobject][ordered]@{
        authoredReferenceLimit = 372
        targetFormListCharacters = $retailTargetListCharacters
        baseFormListCharacters = $retailBaseListCharacters
        environmentListCharacterLimit = $retailEnvironmentListLimit
        runnableForManifest = $retailStaticBatchRunnable
        watchdogMaximumSeconds = 300
    })
$capabilityPreflight.openMw | Add-Member -NotePropertyName representativeSweep -NotePropertyValue `
    ([pscustomobject][ordered]@{
        deterministicContiguousSlice = $true
        baseVisualTypeWeaponPostGate = $true
        explicitActorSelection = $false
        requestedGroupPlayback = 'transport-only-not-parity'
        actionDescriptorCount = @($manifest.actions).Count
    })

$publicPlan = [pscustomobject][ordered]@{
    schema = 'nikami-fnv-actor-parity-sidecar-plan/v1'
    status = if ($ValidateOnly) { 'validated-no-launch' } else { 'ready' }
    createdAt = (Get-Date).ToString('o')
    executionMode = $ExecutionMode
    engines = $Engine
    lockstepRequested = $lockstepRequested
    runRoot = $runRoot
    manifest = $manifest
    openMwRosterPreflight = $openMwRosterPreflight
    sidecarProtocolPreflight = $sidecarProtocolPreflight
    sharedMemoryChannel = $channel
    capabilityPreflight = $capabilityPreflight
    lanes = [pscustomobject][ordered]@{
        retail = [pscustomobject][ordered]@{
            enabled = $Engine -in @('Both', 'Retail')
            script = [string]$plan.retail.script
            output = [string]$plan.retail.output
            actorCount = @($manifest.actors).Count
            actionCoverage = [string]$plan.retail.actionCoverage
        }
        openMw = [pscustomobject][ordered]@{
            enabled = $Engine -in @('Both', 'OpenMW')
            script = [string]$plan.openMw.script
            output = [string]$plan.openMw.output
            representativeOffset = [int]$manifest.openMw.representativeOffset
            actorCount = @($manifest.actors).Count
            actionCoverage = [string]$plan.openMw.actionCoverage
        }
    }
    limitations = @(
        'Source-contract readiness does not prove that the installed retail DLL and OpenMW executable contain those sources; the final NKSC header state and flags are the runtime proof.',
        'AllowStaticRetailProof deliberately bypasses NKSC lockstep and captures one final retail frame per authored reference. Its 4095-character FormID-list cap limits one static retail batch to 372 canonical FormIDs.',
        'Static retail mode uses the legacy runner watchdog capped at 300 seconds and cannot claim manifest action, weapon, camera, time, or weather parity.',
        'The current OpenMW sweep selects only a contiguous slice of its deterministic representative roster. Full-roster and direct arbitrary actor selection are not supported until the engine exposes an explicit actor-selection endpoint.',
        'NKSC v1 action rows are arbitrary unique requested-group playback descriptors. Matching requested group names and frame counts proves transport only; it is not observed animation, root, bone, facial, dialogue, or visual parity.',
        'The NKSC v1 channel is 65536 bytes with a 512-byte header and four named events derived from the mapping name: retail-ready, openmw-ready, capture-ack, and error. Endpoints advance the state machine; the coordinator does not synthesize readiness.',
        'The coordinator emits no inferred paired indexes. It persists only capture payloads observed under the same NKSC generation/identity and rejects partial, duplicate, stale, or skipped acknowledgements.',
        'matchedCameraState remains false until both engines emit equivalent camera matrices/FOV and action-frame telemetry; the sidecar does not infer pixel comparability from matching inputs alone.'
    )
}
if ($ValidateOnly) {
    $publicPlan
    return
}

if ($Engine -eq 'Retail' -and -not $AllowStaticRetailProof) {
    throw 'Retail-only plan execution has no OpenMW barrier peer. Use -Engine Both for lockstep or explicitly select -AllowStaticRetailProof.'
}
if ($lockstepRequested -and $ExecutionMode -ne 'Parallel') {
    throw 'NKSC lockstep requires -ExecutionMode Parallel so both engine endpoints are alive at the barrier.'
}
if ($lockstepRequested -and -not [bool]$capabilityPreflight.lockstepReady) {
    throw ('Lockstep source preflight failed before launch. Run -ValidateOnly and resolve the reported retail runner/source ' +
        'or OpenMW integration gaps; -AllowStaticRetailProof is the explicit non-lockstep fallback.')
}
if ($AllowStaticRetailProof -and $Engine -in @('Both', 'Retail') -and -not $retailStaticBatchRunnable) {
    throw (("Retail static-batch preflight failed: canonical target/base FormID lists are {0}/{1} characters; " +
        "the installed oracle accepts at most {2}. Split the manifest into contiguous chunks of no more than 372 " +
        'or add a non-environment IPC manifest channel.') -f $retailTargetListCharacters,
        $retailBaseListCharacters, $retailEnvironmentListLimit)
}

if (Test-Path -LiteralPath $runRoot) {
    throw "Refusing to overwrite an existing sidecar run: $runRoot"
}
New-Item -ItemType Directory -Path $runRoot | Out-Null
$manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $plan.normalizedManifest -Encoding UTF8
Write-RetailSidecarPlan -Manifest $manifest -Path $plan.retailPlan
$transport = if ($lockstepRequested) {
    New-SidecarTransport -Channel $channel -SequenceId ([string]$manifest.sequenceId) `
        -ActionCount @($manifest.actions).Count
} else { $null }
try {
    $initialTransportSnapshot = if ($null -eq $transport) { $null } else {
        Assert-SidecarInitialSnapshot -Snapshot (Get-SidecarTransportSnapshot -Transport $transport) `
            -Manifest $manifest
    }
    $planPath = Join-Path $runRoot 'sidecar-plan.json'
    $publicPlan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $planPath -Encoding UTF8

    $retailOutput = @()
    $openMwOutput = @()
    $transportMonitor = $null
    if ($Engine -eq 'Both' -and $ExecutionMode -eq 'Parallel') {
        $retailJob = $null
        $openMwJob = $null
        try {
            $retailJob = Start-Job -ScriptBlock {
                param([string]$ScriptPath, [hashtable]$Arguments, [hashtable]$Environment)
                foreach ($entry in $Environment.GetEnumerator()) {
                    [System.Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
                }
                & $ScriptPath @Arguments
            } -ArgumentList ([string]$plan.retail.script), ([hashtable]$plan.retail.arguments),
                ([hashtable]$plan.retail.environment)
            $openMwJob = Start-Job -ScriptBlock {
                param([string]$ScriptPath, [hashtable]$Arguments, [hashtable]$Environment)
                foreach ($entry in $Environment.GetEnumerator()) {
                    [System.Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, 'Process')
                }
                & $ScriptPath @Arguments
            } -ArgumentList ([string]$plan.openMw.script), ([hashtable]$plan.openMw.arguments),
                ([hashtable]$plan.openMw.environment)
            if ($lockstepRequested) {
                # The coordinator owns every kernel object before either job starts, then
                # observes (but never synthesizes) the endpoint transitions concurrently.
                $transportMonitor = Wait-SidecarLaneJobs -RetailJob $retailJob -OpenMwJob $openMwJob `
                    -Transport $transport -Manifest $manifest -EvidenceRoot (Join-Path $runRoot 'transport') `
                    -RetailScreenshotRoots @(
                        [string]([hashtable]$plan.retail.arguments)['GameRoot'],
                        [string]$plan.retail.screens
                    ) `
                    -OpenMwScreenshotRoots @(
                        [string]$plan.openMw.output,
                        (Join-Path $repoRoot 'profiles\fallout_new_vegas')
                    ) `
                    -TimeoutMinutes $TimeoutMinutes
                $retailOutput = @($transportMonitor.retailOutput)
                $openMwOutput = @($transportMonitor.openMwOutput)
            }
            else {
                $jobDeadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
                while ($retailJob.State -ne 'Completed' -or $openMwJob.State -ne 'Completed') {
                    foreach ($lane in @(@('Retail', $retailJob), @('OpenMW', $openMwJob))) {
                        if ($lane[1].State -in @('Failed', 'Stopped', 'Blocked', 'Disconnected', 'AtBreakpoint')) {
                            throw "$($lane[0]) static lane ended in state $($lane[1].State)."
                        }
                    }
                    if ([DateTime]::UtcNow -ge $jobDeadline) {
                        throw "Static sidecar lanes timed out after $TimeoutMinutes minutes."
                    }
                    Start-Sleep -Milliseconds 50
                }
                $retailOutput = @(Receive-Job -Job $retailJob -ErrorAction SilentlyContinue)
                $openMwOutput = @(Receive-Job -Job $openMwJob -ErrorAction SilentlyContinue)
            }
        }
        finally {
            foreach ($job in @($retailJob, $openMwJob)) {
                if ($null -ne $job -and (Get-Job -Id $job.Id -ErrorAction SilentlyContinue)) {
                    Stop-Job -Job $job -ErrorAction SilentlyContinue
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        if ($Engine -in @('Both', 'Retail')) {
            $retailOutput = @(Invoke-PlannedChild -Lane $plan.retail)
        }
        if ($Engine -in @('Both', 'OpenMW')) {
            $openMwOutput = @(Invoke-PlannedChild -Lane $plan.openMw)
        }
    }

    $transportSnapshot = if ($null -eq $transportMonitor) { $null } else { $transportMonitor.final.header }
    $retailEvidence = if ($Engine -in @('Both', 'Retail')) {
        Assert-RetailResult -Manifest $manifest -RunnerOutput $retailOutput -Lockstep:$lockstepRequested
    } else { $null }
    $openMwEvidence = if ($Engine -in @('Both', 'OpenMW')) {
        Assert-OpenMwResult -Manifest $manifest -RunnerOutput $openMwOutput -Lockstep:$lockstepRequested
    } else { $null }
    # Native evidence is retained, but the coordinator never infers pairing from
    # filenames, row order, requested state, or independent static captures.
    $pairedIndexes = $null
    $defects = @()
    if ($null -ne $openMwEvidence) {
        $defects = @($openMwEvidence.defects)
    }
    $lockstepComplete = $lockstepRequested -and $null -ne $transportMonitor -and
        [bool]$transportMonitor.final.header.lockstepComplete
    $resultPath = Join-Path $runRoot 'sidecar-result.json'
    $result = [pscustomobject][ordered]@{
        schema = 'nikami-fnv-actor-parity-sidecar-result/v1'
        status = if ($lockstepRequested -and (-not $lockstepComplete -or $defects.Count -gt 0)) {
            'failed-transport-contract'
        } elseif ($lockstepRequested) { 'transport-complete' }
        elseif ($defects.Count -eq 0) { 'static-evidence-only' } else { 'static-evidence-with-contract-defects' }
        sequenceId = [string]$manifest.sequenceId
        plan = $planPath
        runRoot = $runRoot
        retailRunManifest = if ($null -eq $retailEvidence) { $null } else { $retailEvidence.runManifest }
        openMwIndex = if ($null -eq $openMwEvidence) { $null } else { $openMwEvidence.index }
        pairedIndexes = $pairedIndexes
        sharedMemoryChannel = [pscustomobject][ordered]@{
            protocol = [string]$channel.schema
            channelId = [string]$channel.channelId
            requested = $lockstepRequested
            lockstep = $lockstepComplete
            initialSnapshot = $initialTransportSnapshot
            snapshot = $transportSnapshot
            captureLedger = if ($null -eq $transportMonitor) { $null } else { $transportMonitor.captureLedger }
            finalHeaderEvidence = if ($null -eq $transportMonitor) { $null } else {
                $transportMonitor.final.headerEvidence
            }
            finalRetailPayload = if ($null -eq $transportMonitor) { $null } else {
                $transportMonitor.final.retailPayload
            }
            finalOpenMwPayload = if ($null -eq $transportMonitor) { $null } else {
                $transportMonitor.final.openMwPayload
            }
            filePollingUsedForBarrier = $false
        }
        defects = $defects
        limitations = @($publicPlan.limitations)
    }
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    if ($lockstepRequested -and (-not $lockstepComplete -or $defects.Count -gt 0)) {
        throw "NKSC lockstep or native evidence contract failed closed; inspect $resultPath."
    }
    $result
}
finally {
    Close-SidecarTransport -Transport $transport
}
