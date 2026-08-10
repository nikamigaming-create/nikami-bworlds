Set-StrictMode -Version Latest

function Get-OpenNVUiFallbackAssetNames {
    # These are the stock MyGUI skin/pointer resources that upstream OpenMW
    # normally obtains from Morrowind Data Files. Fallout profiles do not own
    # those assets, so OpenNV supplies generated, profile-local fallbacks.
    return @(
        "textures/cursor_drop_ground.dds",
        "textures/compass.dds",
        "textures/door_icon.dds",
        "textures/menu_bar_gray.dds",
        "textures/menu_button_frame_bottom.dds",
        "textures/menu_button_frame_bottom_left_corner.dds",
        "textures/menu_button_frame_bottom_right_corner.dds",
        "textures/menu_button_frame_left.dds",
        "textures/menu_button_frame_right.dds",
        "textures/menu_button_frame_top.dds",
        "textures/menu_button_frame_top_left_corner.dds",
        "textures/menu_button_frame_top_right_corner.dds",
        "textures/menu_head_block_bottom.dds",
        "textures/menu_head_block_bottom_left_corner.dds",
        "textures/menu_head_block_bottom_right_corner.dds",
        "textures/menu_head_block_left.dds",
        "textures/menu_head_block_middle.dds",
        "textures/menu_head_block_right.dds",
        "textures/menu_head_block_top.dds",
        "textures/menu_head_block_top_left_corner.dds",
        "textures/menu_head_block_top_right_corner.dds",
        "textures/menu_credits.dds",
        "textures/menu_exitgame.dds",
        "textures/menu_loadgame.dds",
        "textures/menu_newgame.dds",
        "textures/menu_options.dds",
        "textures/menu_return.dds",
        "textures/menu_savegame.dds",
        "textures/menu_rightbuttondown_bottom.dds",
        "textures/menu_rightbuttondown_bottom_left.dds",
        "textures/menu_rightbuttondown_bottom_right.dds",
        "textures/menu_rightbuttondown_center.dds",
        "textures/menu_rightbuttondown_left.dds",
        "textures/menu_rightbuttondown_right.dds",
        "textures/menu_rightbuttondown_top.dds",
        "textures/menu_rightbuttondown_top_left.dds",
        "textures/menu_rightbuttondown_top_right.dds",
        "textures/menu_rightbuttonup_bottom.dds",
        "textures/menu_rightbuttonup_bottom_left.dds",
        "textures/menu_rightbuttonup_bottom_right.dds",
        "textures/menu_rightbuttonup_center.dds",
        "textures/menu_rightbuttonup_left.dds",
        "textures/menu_rightbuttonup_right.dds",
        "textures/menu_rightbuttonup_top.dds",
        "textures/menu_rightbuttonup_top_left.dds",
        "textures/menu_rightbuttonup_top_right.dds",
        "textures/menu_small_energy_bar_bottom.dds",
        "textures/menu_small_energy_bar_top.dds",
        "textures/menu_small_energy_bar_vert.dds",
        "textures/menu_thick_border_bottom.dds",
        "textures/menu_thick_border_bottom_left_corner.dds",
        "textures/menu_thick_border_bottom_right_corner.dds",
        "textures/menu_thick_border_left.dds",
        "textures/menu_thick_border_right.dds",
        "textures/menu_thick_border_top.dds",
        "textures/menu_thick_border_top_left_corner.dds",
        "textures/menu_thick_border_top_right_corner.dds",
        "textures/menu_thin_border_bottom.dds",
        "textures/menu_thin_border_bottom_left_corner.dds",
        "textures/menu_thin_border_bottom_right_corner.dds",
        "textures/menu_thin_border_left.dds",
        "textures/menu_thin_border_right.dds",
        "textures/menu_thin_border_top.dds",
        "textures/menu_thin_border_top_left_corner.dds",
        "textures/menu_thin_border_top_right_corner.dds",
        "textures/player_hit_01.dds",
        "textures/scroll.dds",
        "textures/target.dds",
        "textures/tx_cursor.dds",
        "textures/tx_cursormove.dds",
        "textures/tx_menubook.dds",
        "textures/tx_menubook_bookmark.dds",
        "textures/tx_menubook_cancel_idle.dds",
        "textures/tx_menubook_close_idle.dds",
        "textures/tx_menubook_journal_idle.dds",
        "textures/tx_menubook_next_idle.dds",
        "textures/tx_menubook_prev_idle.dds",
        "textures/tx_menubook_take_idle.dds",
        "textures/tx_menubook_topics_idle.dds",
        "icons/k/stealth_handtohand.dds",
        "icons/k/stealth_sneak.dds",
        "icons/tx_goldicon.dds"
    )
}

function Get-OpenNVUiFallbackDdsBytes {
    # 4x4 BGRA8 DDS. A single neutral, opaque texel sheet keeps the generic
    # MyGUI skin valid until the native Fallout presentation replaces it.
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes("DDS "))
        $writer.Write([uint32]124)
        $writer.Write([uint32]0x0000100F)
        $writer.Write([uint32]4)
        $writer.Write([uint32]4)
        $writer.Write([uint32]16)
        $writer.Write([uint32]0)
        $writer.Write([uint32]0)
        for ($index = 0; $index -lt 11; ++$index) { $writer.Write([uint32]0) }
        $writer.Write([uint32]32)
        $writer.Write([uint32]0x00000041)
        $writer.Write([uint32]0)
        $writer.Write([uint32]32)
        $writer.Write([uint32]0x00ff0000)
        $writer.Write([uint32]0x0000ff00)
        $writer.Write([uint32]0x000000ff)
        $writer.Write([Convert]::ToUInt32("FF000000", 16))
        $writer.Write([uint32]0x00001000)
        $writer.Write([uint32]0)
        $writer.Write([uint32]0)
        $writer.Write([uint32]0)
        $writer.Write([uint32]0)
        for ($pixel = 0; $pixel -lt 16; ++$pixel) {
            $writer.Write([byte]0x19) # blue
            $writer.Write([byte]0x6e) # green
            $writer.Write([byte]0x50) # red
            $writer.Write([byte]0xff) # alpha
        }
        return [byte[]]$stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Get-OpenNVUiFallbackSha256 {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
    }
}

function Ensure-OpenNVUiFallback {
    param(
        [Parameter(Mandatory=$true)][string]$Root,
        [switch]$PreviewOnly
    )

    $Root = [IO.Path]::GetFullPath($Root)
    [byte[]]$bytes = Get-OpenNVUiFallbackDdsBytes
    $sha256 = Get-OpenNVUiFallbackSha256 -Bytes $bytes
    $records = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in @(Get-OpenNVUiFallbackAssetNames)) {
        $path = Join-Path $Root ($relativePath -replace '/', '\\')
        $status = ""
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualHash -cne $sha256) {
                throw "Existing OpenNV UI fallback asset has unexpected contents: $path"
            }
            $status = "unchanged"
        }
        elseif ($PreviewOnly) {
            $status = "preview"
        }
        else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllBytes($path, $bytes)
            $status = "written"
        }
        $records.Add([pscustomobject][ordered]@{
            relativePath = $relativePath
            path = $path
            sha256 = $sha256
            bytes = [long]$bytes.Length
            status = $status
        })
    }

    return [pscustomobject][ordered]@{
        schema = "nikami-opennv-ui-fallback/v1"
        root = $Root
        sha256 = $sha256
        assetCount = $records.Count
        assets = @($records.ToArray())
        sourceMutation = $false
        generatedProfileLocal = $true
    }
}
