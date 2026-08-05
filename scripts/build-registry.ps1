param(
    [switch]$SkipStarterBuild,
    [switch]$IncludeLegacyV1
)

$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $registryRoot ".build"

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Remove-RegistryFileIfExists {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-VersionCode {
    param([Parameter(Mandatory = $true)][string]$Version)

    $parts = [regex]::Split($Version, "[^0-9]+") |
        Where-Object { $_ -ne "" } |
        ForEach-Object { [int]$_ }

    if ($parts.Count -eq 0) {
        return 1
    }

    $major = $parts[0]
    $minor = if ($parts.Count -gt 1) { $parts[1] } else { 0 }
    $patch = if ($parts.Count -gt 2) { $parts[2] } else { 0 }
    return ($major * 10000) + ($minor * 100) + $patch
}

function Assert-VersionText {
    param(
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Version -notmatch '^\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.-]+)?$') {
        throw "Invalid ${Name}: $Version"
    }
}

function ConvertTo-IsoDateText {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [string]$Value
}

function Get-OptionalString {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

function Get-StringArrayOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $items = @($Value) |
        ForEach-Object { [string]$_ } |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($items.Count -eq 0) {
        return $null
    }

    return ,@($items)
}

function Add-OptionalField {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [array] -and $Value.Count -eq 0) {
        return
    }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    $Target[$Name] = $Value
}

function ConvertTo-PluginVersionEntry {
    param([Parameter(Mandatory = $true)]$Version)

    $apiVersion = if ($null -ne $Version.PSObject.Properties["api_version"]) {
        [int]$Version.api_version
    } else {
        1
    }
    $entry = [ordered]@{
        version = [string]$Version.version
        version_code = [int]$Version.version_code
        file_size = [long]$Version.file_size
        file_hash = [string]$Version.file_hash
        download_url = [string]$Version.download_url
        api_version = $apiVersion
        changelog = [string]$Version.changelog
        created_at = ConvertTo-IsoDateText $Version.created_at
    }
    Add-OptionalField -Target $entry -Name "min_app_version" -Value (Get-OptionalString $Version.min_app_version)
    return $entry
}

function Test-PluginVersionCompatible {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)][string]$HostVersion,
        [Parameter(Mandatory = $true)][int]$ApiVersion
    )

    if ([int]$Version.api_version -ne $ApiVersion) {
        return $false
    }
    $minAppVersion = Get-OptionalString $Version.min_app_version
    if ($null -eq $minAppVersion) {
        return $true
    }
    Assert-VersionText -Version $minAppVersion -Name "plugin min_app_version"
    return (ConvertTo-VersionCode $minAppVersion) -le (ConvertTo-VersionCode $HostVersion)
}

function New-PluginDetailEntry {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][object[]]$Versions
    )

    return [ordered]@{
        id = [string]$Manifest.id
        plugin_id = [string]$Manifest.id
        name = [string]$Manifest.name
        description = [string]$Manifest.description
        category = [string]$Metadata.category
        tags = @($Metadata.tags)
        repository_url = [string]$Metadata.repository_url
        homepage_url = [string]$Metadata.homepage_url
        license = [string]$Metadata.license
        publisher = [ordered]@{
            id = [string]$Metadata.publisher.id
            display_name = [string]$Metadata.publisher.display_name
        }
        versions = @($Versions)
        created_at = ConvertTo-IsoDateText $Metadata.created_at
        updated_at = ConvertTo-IsoDateText $Metadata.updated_at
    }
}

function New-PluginCatalogEntry {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$LatestVersion,
        [Parameter(Mandatory = $true)][string]$DetailUrl
    )

    return [ordered]@{
        id = [string]$Manifest.id
        plugin_id = [string]$Manifest.id
        name = [string]$Manifest.name
        description = [string]$Manifest.description
        category = [string]$Metadata.category
        tags = @($Metadata.tags)
        publisher = [ordered]@{
            id = [string]$Metadata.publisher.id
            display_name = [string]$Metadata.publisher.display_name
        }
        latest_version = $LatestVersion
        detail_url = $DetailUrl
        created_at = ConvertTo-IsoDateText $Metadata.created_at
        updated_at = ConvertTo-IsoDateText $Metadata.updated_at
    }
}

function Get-PackageArtifactType {
    param(
        $AndroidPackage,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    $artifactType = Get-OptionalString $AndroidPackage.artifact_type
    if ($null -ne $artifactType) {
        return $artifactType
    }

    throw "Android package metadata missing artifact_type: $PackageId"
}

function ConvertTo-JsonText {
    param([Parameter(Mandatory = $true)]$Value)

    $json = $Value | ConvertTo-Json -Depth 32 -Compress
    $builder = [System.Text.StringBuilder]::new()
    $indent = 0
    $inString = $false
    $escaped = $false

    foreach ($char in $json.ToCharArray()) {
        if ($inString) {
            [void]$builder.Append($char)
            if ($escaped) {
                $escaped = $false
            } elseif ($char -eq '\') {
                $escaped = $true
            } elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        switch ($char) {
            '"' {
                $inString = $true
                [void]$builder.Append($char)
            }
            { $_ -eq '{' -or $_ -eq '[' } {
                [void]$builder.Append($char)
                [void]$builder.Append("`n")
                $indent++
                [void]$builder.Append((' ' * ($indent * 2)))
            }
            { $_ -eq '}' -or $_ -eq ']' } {
                [void]$builder.Append("`n")
                $indent--
                [void]$builder.Append((' ' * ($indent * 2)))
                [void]$builder.Append($char)
            }
            ',' {
                [void]$builder.Append($char)
                [void]$builder.Append("`n")
                [void]$builder.Append((' ' * ($indent * 2)))
            }
            ':' {
                [void]$builder.Append(": ")
            }
            default {
                [void]$builder.Append($char)
            }
        }
    }

    return (($builder.ToString() -split "`n") | ForEach-Object { $_.TrimEnd() }) -join "`n"
}

function Get-ArchiveRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    try {
        return ([System.IO.Path]::GetRelativePath($BasePath, $FilePath)).Replace("\", "/")
    } catch {
        $baseUri = [Uri]($BasePath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar)
        return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri([Uri]$FilePath).ToString())
    }
}

function Get-Crc32 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($null -eq $script:Crc32Table) {
        $mask = [uint64]4294967295
        $polynomial = [uint64]3988292384
        $script:Crc32Table = @(for ($i = 0; $i -lt 256; $i++) {
            $crc = [uint32]$i
            for ($bit = 0; $bit -lt 8; $bit++) {
                if (($crc -band 1) -ne 0) {
                    $crc = [uint32]((([uint64]$crc -shr 1) -bxor $polynomial) -band $mask)
                } else {
                    $crc = [uint32](([uint64]$crc -shr 1) -band $mask)
                }
            }
            $crc
        })
    }

    $mask = [uint64]4294967295
    $value = [uint32]4294967295
    foreach ($byte in $Bytes) {
        $index = [int](($value -bxor [uint32]$byte) -band 0xFF)
        $value = [uint32]((([uint64]$value -shr 8) -bxor [uint64]$script:Crc32Table[$index]) -band $mask)
    }
    return [uint32](([uint64]$value -bxor $mask) -band $mask)
}

function Read-ArchiveEntryBytes {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    $textExtensions = @(
        ".json", ".md", ".txt", ".ps1", ".py", ".sh", ".lua", ".svg", ".xml", ".properties",
        ".gradle", ".kts", ".kt", ".java", ".c", ".cpp", ".h", ".hpp", ".cmake",
        ".pc"
    )
    $textFileNames = @(".gitignore")

    if ($File.Extension.ToLowerInvariant() -in $textExtensions -or $File.Name -in $textFileNames) {
        $text = [System.IO.File]::ReadAllText($File.FullName, [System.Text.Encoding]::UTF8)
        $normalized = $text -replace "`r`n", "`n" -replace "`r", "`n"
        return [System.Text.Encoding]::UTF8.GetBytes($normalized)
    }

    return [System.IO.File]::ReadAllBytes($File.FullName)
}

function New-TinaPlugArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )

    if (Test-Path -LiteralPath $OutputFile) {
        Remove-Item -LiteralPath $OutputFile -Force
    }

    $sourcePath = (Resolve-Path -LiteralPath $SourceDir).Path
    $entries = Get-ChildItem -LiteralPath $sourcePath -File -Recurse -Force |
        ForEach-Object {
            [pscustomobject]@{
                File = $_
                RelativePath = Get-ArchiveRelativePath -BasePath $sourcePath -FilePath $_.FullName
            }
        } |
        Sort-Object -Property RelativePath

    $outputParent = Split-Path -Parent $OutputFile
    if ($outputParent) {
        New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }

    $stream = [System.IO.File]::Open($OutputFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    $writer = [System.IO.BinaryWriter]::new($stream, [System.Text.Encoding]::UTF8)
    $centralRecords = @()
    $dosTime = [uint16]0
    $dosDate = [uint16]0x5021
    $utf8Flag = [uint16]0x0800
    try {
        foreach ($entry in $entries) {
            $data = Read-ArchiveEntryBytes -File $entry.File
            $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($entry.RelativePath)
            $crc = Get-Crc32 -Bytes $data
            $size = [uint32]$data.Length
            $offset = [uint32]$stream.Position

            $writer.Write([uint32]0x04034B50)
            $writer.Write([uint16]20)
            $writer.Write($utf8Flag)
            $writer.Write([uint16]0)
            $writer.Write($dosTime)
            $writer.Write($dosDate)
            $writer.Write($crc)
            $writer.Write($size)
            $writer.Write($size)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([byte[]]$nameBytes)
            $writer.Write([byte[]]$data)

            $centralRecords += [pscustomobject]@{
                NameBytes = $nameBytes
                Crc = $crc
                Size = $size
                Offset = $offset
            }
        }

        $centralOffset = [uint32]$stream.Position
        foreach ($record in $centralRecords) {
            $writer.Write([uint32]0x02014B50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]20)
            $writer.Write($utf8Flag)
            $writer.Write([uint16]0)
            $writer.Write($dosTime)
            $writer.Write($dosDate)
            $writer.Write([uint32]$record.Crc)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$record.Offset)
            $writer.Write([byte[]]$record.NameBytes)
        }
        $centralSize = [uint32]($stream.Position - $centralOffset)
        $entryCount = [uint16]$centralRecords.Count

        $writer.Write([uint32]0x06054B50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write($entryCount)
        $writer.Write($entryCount)
        $writer.Write($centralSize)
        $writer.Write($centralOffset)
        $writer.Write([uint16]0)
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

if (-not $SkipStarterBuild) {
    & (Join-Path $PSScriptRoot "build-plugin-starters.ps1")
}

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$pluginMetadata = Get-Content -Raw -Encoding UTF8 (Join-Path $registryRoot "metadata/plugins.json") |
    ConvertFrom-Json

$legacyHostVersion = [string]$pluginMetadata.compatibility.legacy_v2_host_version
$legacyApiVersion = [int]$pluginMetadata.compatibility.legacy_v2_api_version
Assert-VersionText -Version $legacyHostVersion -Name "legacy_v2_host_version"

$pluginEntriesV2 = @()
$pluginCatalogEntriesV2 = @()
$pluginEntriesV3 = @()
$pluginCatalogEntriesV3 = @()
foreach ($item in @($pluginMetadata.plugins)) {
    $sourceDir = Join-Path $registryRoot $item.source
    $manifestPath = Join-Path $sourceDir "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Plugin manifest not found: $manifestPath"
    }

    $manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
    $pluginId = [string]$manifest.id
    $version = [string]$manifest.version
    $apiVersion = if ($null -ne $manifest.PSObject.Properties["apiVersion"]) { [int]$manifest.apiVersion } else { 1 }
    $minAppVersion = Get-OptionalString $manifest.minAppVersion
    Assert-VersionText -Version $version -Name "plugin version for $pluginId"
    if ($null -ne $minAppVersion) {
        Assert-VersionText -Version $minAppVersion -Name "plugin minAppVersion for $pluginId"
    }
    $outputDir = Join-Path $registryRoot ("plugins/{0}/{1}" -f $pluginId, $version)
    $outputFile = Join-Path $outputDir ("{0}.tinaplug" -f $pluginId)
    $candidateFile = Join-Path $buildRoot ("{0}-{1}.tinaplug" -f $pluginId, $version)

    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    New-TinaPlugArchive -SourceDir $sourceDir -OutputFile $candidateFile
    if (Test-Path -LiteralPath $outputFile -PathType Leaf) {
        $existingHash = Get-FileSha256 $outputFile
        $candidateHash = Get-FileSha256 $candidateFile
        if ($existingHash -ne $candidateHash) {
            Remove-Item -LiteralPath $candidateFile -Force
            throw "Immutable plugin release changed without a version bump: $pluginId $version"
        }
        Remove-Item -LiteralPath $candidateFile -Force
    } else {
        Move-Item -LiteralPath $candidateFile -Destination $outputFile
    }

    $archive = Get-Item -LiteralPath $outputFile
    $currentVersionEntry = [ordered]@{
        version = $version
        version_code = ConvertTo-VersionCode $version
        file_size = $archive.Length
        file_hash = "sha256:{0}" -f (Get-FileSha256 $archive.FullName)
        download_url = "plugins/{0}/{1}/{0}.tinaplug" -f $pluginId, $version
        api_version = $apiVersion
        changelog = [string]$item.changelog
        created_at = ConvertTo-IsoDateText $item.updated_at
    }
    Add-OptionalField -Target $currentVersionEntry -Name "min_app_version" -Value $minAppVersion

    $detailV3Path = Join-Path $registryRoot ("plugins/{0}/plugin.v3.json" -f $pluginId)
    $detailV2Path = Join-Path $registryRoot ("plugins/{0}/plugin.json" -f $pluginId)
    $priorDetailPath = if (Test-Path -LiteralPath $detailV3Path -PathType Leaf) {
        $detailV3Path
    } elseif (Test-Path -LiteralPath $detailV2Path -PathType Leaf) {
        $detailV2Path
    } else {
        $null
    }
    $priorVersions = if ($null -ne $priorDetailPath) {
        @((Get-Content -Raw -Encoding UTF8 $priorDetailPath | ConvertFrom-Json).versions) |
            Where-Object { [string]$_.version -ne $version } |
            ForEach-Object { ConvertTo-PluginVersionEntry $_ }
    } else {
        @()
    }
    $allVersions = @(@($currentVersionEntry) + @($priorVersions))
    $allVersions = @($allVersions |
        Sort-Object -Property @{ Expression = { [int]$_.version_code }; Descending = $true }, @{ Expression = { [string]$_.version }; Descending = $true })
    $legacyVersions = @($allVersions | Where-Object {
        Test-PluginVersionCompatible -Version $_ -HostVersion $legacyHostVersion -ApiVersion $legacyApiVersion
    })

    $pluginEntryV3 = New-PluginDetailEntry -Manifest $manifest -Metadata $item -Versions $allVersions
    $pluginEntriesV3 += $pluginEntryV3
    $pluginCatalogEntriesV3 += New-PluginCatalogEntry `
        -Manifest $manifest `
        -Metadata $item `
        -LatestVersion ([string]($allVersions[0].version)) `
        -DetailUrl ("plugins/{0}/plugin.v3.json" -f $pluginId)
    Write-Utf8NoBom -Path $detailV3Path -Content (ConvertTo-JsonText $pluginEntryV3)

    if ($legacyVersions.Count -gt 0) {
        $pluginEntryV2 = New-PluginDetailEntry -Manifest $manifest -Metadata $item -Versions $legacyVersions
        $pluginEntriesV2 += $pluginEntryV2
        $pluginCatalogEntriesV2 += New-PluginCatalogEntry `
            -Manifest $manifest `
            -Metadata $item `
            -LatestVersion ([string]($legacyVersions[0].version)) `
            -DetailUrl ("plugins/{0}/plugin.json" -f $pluginId)
        Write-Utf8NoBom -Path $detailV2Path -Content (ConvertTo-JsonText $pluginEntryV2)
    } else {
        Remove-RegistryFileIfExists -Path $detailV2Path
    }
}

$pluginsIndexV2 = [ordered]@{
    schema_version = 2
    compatibility = [ordered]@{
        host_version = $legacyHostVersion
        api_version = $legacyApiVersion
    }
    plugins = @($pluginCatalogEntriesV2)
}
Write-Utf8NoBom `
    -Path (Join-Path $registryRoot "plugins/index.v2.json") `
    -Content (ConvertTo-JsonText $pluginsIndexV2)

$pluginsIndexV3 = [ordered]@{
    schema_version = 3
    plugins = @($pluginCatalogEntriesV3)
}
Write-Utf8NoBom `
    -Path (Join-Path $registryRoot "plugins/index.v3.json") `
    -Content (ConvertTo-JsonText $pluginsIndexV3)

if ($IncludeLegacyV1) {
    $pluginsIndex = [ordered]@{
        plugins = @($pluginEntriesV2)
    }
    Write-Utf8NoBom `
        -Path (Join-Path $registryRoot "plugins/index.json") `
        -Content (ConvertTo-JsonText $pluginsIndex)
} else {
    Remove-RegistryFileIfExists -Path (Join-Path $registryRoot "plugins/index.json")
}

$packageMetadata = Get-Content -Raw -Encoding UTF8 (Join-Path $registryRoot "metadata/packages.json") |
    ConvertFrom-Json

$packageEntries = @()
$packageCatalogEntries = @()
$versionMap = [ordered]@{}
$packageVersionId = 1
foreach ($pkg in @($packageMetadata.packages)) {
    $filePath = Join-Path $registryRoot $pkg.file
    if (-not (Test-Path -LiteralPath $filePath)) {
        throw "Package file not found: $filePath"
    }

    $file = Get-Item -LiteralPath $filePath
    $checksum = "sha256:{0}" -f (Get-FileSha256 $file.FullName)
    $artifactType = Get-PackageArtifactType -AndroidPackage $pkg.android -PackageId ([string]$pkg.id)
    $androidAbi = Get-StringArrayOrNull $pkg.android.abi
    $androidDependencies = Get-StringArrayOrNull $pkg.android.dependencies
    $abiArtifactSources = @()
    if ($null -ne $pkg.PSObject.Properties["artifacts"]) {
        $artifactSourceId = 2
        foreach ($artifact in @($pkg.artifacts)) {
            $artifactAbi = [string]$artifact.abi
            if ([string]::IsNullOrWhiteSpace($artifactAbi)) {
                throw "Package ABI artifact is missing abi: $($pkg.id)"
            }
            $artifactPath = Join-Path $registryRoot ([string]$artifact.file)
            if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
                throw "Package ABI artifact not found: $artifactPath"
            }
            $artifactFile = Get-Item -LiteralPath $artifactPath
            $abiArtifactSources += [ordered]@{
                id = $artifactSourceId
                name = "Registry $artifactAbi"
                url = [string]$artifact.file
                priority = 90
                supports_range = $true
                abi = $artifactAbi
                size = $artifactFile.Length
                checksum = "sha256:{0}" -f (Get-FileSha256 $artifactFile.FullName)
            }
            $artifactSourceId++
        }

        $declaredAbis = @($androidAbi | Sort-Object -Unique)
        $artifactAbis = @($abiArtifactSources | ForEach-Object { [string]$_.abi } | Sort-Object -Unique)
        if (($declaredAbis -join ",") -ne ($artifactAbis -join ",")) {
            throw "Package ABI artifacts do not match android.abi: $($pkg.id)"
        }
    }

    $androidEntry = [ordered]@{
        version = [string]$pkg.android.version
        artifact_type = $artifactType
        install_type = [string]$pkg.android.install_type
        size = $file.Length
        download_url = [string]$pkg.file
        checksum = $checksum
        is_latest = [bool]$pkg.android.is_latest
        release_notes = [string]$pkg.android.release_notes
    }
    Add-OptionalField -Target $androidEntry -Name "abi" -Value $androidAbi
    Add-OptionalField -Target $androidEntry -Name "dependencies" -Value $androidDependencies

    $packageEntry = [ordered]@{
        id = [string]$pkg.id
        name = [string]$pkg.name
        description = [string]$pkg.description
        category = [string]$pkg.category
        homepage = [string]$pkg.homepage
        android = $androidEntry
    }
    $packageEntries += $packageEntry

    $androidVersionEntry = [ordered]@{
        id = $packageVersionId
        package_id = [string]$pkg.id
        platform = "android"
        version = [string]$pkg.android.version
        artifact_type = $artifactType
        install_type = [string]$pkg.android.install_type
        download_size = $file.Length
        download_url = [string]$pkg.file
        checksum = $checksum
        is_latest = [bool]$pkg.android.is_latest
        release_notes = [string]$pkg.android.release_notes
    }
    Add-OptionalField -Target $androidVersionEntry -Name "abi" -Value $androidAbi
    Add-OptionalField -Target $androidVersionEntry -Name "dependencies" -Value $androidDependencies

    $versionMap[[string]$pkg.id] = [ordered]@{
        android = @($androidVersionEntry)
    }

    $androidCatalogEntry = [ordered]@{
        version = [string]$pkg.android.version
        artifact_type = $artifactType
        install_type = [string]$pkg.android.install_type
        size = $file.Length
        is_latest = [bool]$pkg.android.is_latest
    }
    Add-OptionalField -Target $androidCatalogEntry -Name "abi" -Value $androidAbi

    $packageCatalogEntries += [ordered]@{
        id = [string]$pkg.id
        name = [string]$pkg.name
        description = [string]$pkg.description
        category = [string]$pkg.category
        homepage = [string]$pkg.homepage
        detail_url = "packages/{0}/package.json" -f ([string]$pkg.id)
        android = $androidCatalogEntry
    }

    $downloads = [ordered]@{}
    if ($abiArtifactSources.Count -gt 0) {
        $downloadSources = @(
            [ordered]@{
                id = 1
                name = "Registry universal (legacy)"
                url = [string]$pkg.file
                priority = 100
                supports_range = $true
                size = $file.Length
                checksum = $checksum
            }
        ) + $abiArtifactSources
        $downloads["{0}:{1}" -f ([string]$pkg.id), $packageVersionId] = [ordered]@{
            package_id = [string]$pkg.id
            version = [string]$pkg.android.version
            platform = "android"
            install_type = [string]$pkg.android.install_type
            size = $file.Length
            checksum = $checksum
            sources = $downloadSources
        }
    }

    $packageDetail = [ordered]@{
        package = $packageEntry
        versions = $versionMap[[string]$pkg.id]
        downloads = $downloads
    }
    Write-Utf8NoBom `
        -Path (Join-Path $registryRoot ("packages/{0}/package.json" -f ([string]$pkg.id))) `
        -Content (ConvertTo-JsonText $packageDetail)

    $packageVersionId++
}

$packageCategories = @($packageMetadata.categories | ForEach-Object {
    [ordered]@{
        id = [string]$_.id
        name = [string]$_.name
        name_en = [string]$_.name_en
        sort_order = [int]$_.sort_order
    }
})

$packagesIndexV2 = [ordered]@{
    schema_version = 2
    categories = @($packageCategories)
    packages = @($packageCatalogEntries)
}
Write-Utf8NoBom `
    -Path (Join-Path $registryRoot "packages/index.v2.json") `
    -Content (ConvertTo-JsonText $packagesIndexV2)

if ($IncludeLegacyV1) {
    $packagesIndex = [ordered]@{
        categories = @($packageCategories)
        packages = @($packageEntries)
        versions = $versionMap
        downloads = [ordered]@{}
    }
    Write-Utf8NoBom `
        -Path (Join-Path $registryRoot "packages/index.json") `
        -Content (ConvertTo-JsonText $packagesIndex)
} else {
    Remove-RegistryFileIfExists -Path (Join-Path $registryRoot "packages/index.json")
}

if ($IncludeLegacyV1) {
    Write-Host "Registry indexes rebuilt, including v2/v3 plugin and legacy v1 compatibility indexes."
} else {
    Write-Host "Registry indexes rebuilt with v2 compatibility and v3 plugin views."
}
