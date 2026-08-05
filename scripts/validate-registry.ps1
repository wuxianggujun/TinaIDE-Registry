param(
    [switch]$SkipBuild,
    [switch]$SkipGitDiffCheck,
    [switch]$AllowLegacyV1
)

$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot

function Assert-RegistryCondition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function ConvertTo-VersionCode {
    param([Parameter(Mandatory = $true)][string]$Version)

    Assert-RegistryCondition `
        -Condition ($Version -match '^\d+(?:\.\d+){0,2}(?:-[0-9A-Za-z.-]+)?$') `
        -Message "Invalid version text: $Version"
    $parts = [regex]::Split($Version, "[^0-9]+") |
        Where-Object { $_ -ne "" } |
        ForEach-Object { [int]$_ }
    $major = $parts[0]
    $minor = if ($parts.Count -gt 1) { $parts[1] } else { 0 }
    $patch = if ($parts.Count -gt 2) { $parts[2] } else { 0 }
    return ($major * 10000) + ($minor * 100) + $patch
}

function Resolve-RegistryFile {
    param([Parameter(Mandatory = $true)][string]$UrlOrPath)

    $value = $UrlOrPath.Trim()
    if ($value.StartsWith("http://") -or $value.StartsWith("https://")) {
        return $null
    }

    $relative = $value.TrimStart("/", "\").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $registryRoot $relative))
    $rootPath = [System.IO.Path]::GetFullPath($registryRoot)
    Assert-RegistryCondition `
        -Condition $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase) `
        -Message "Registry path escapes repository root: $UrlOrPath"
    return $fullPath
}

function Assert-UniqueValues {
    param(
        [Parameter(Mandatory = $true)][object[]]$Values,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $duplicates = $Values |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Group-Object |
        Where-Object { $_.Count -gt 1 } |
        ForEach-Object { $_.Name }
    Assert-RegistryCondition `
        -Condition ($duplicates.Count -eq 0) `
        -Message ("Duplicate {0}: {1}" -f $Name, ($duplicates -join ", "))
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

function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-NoHeavyFields {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$ObjectName,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )

    foreach ($field in $Fields) {
        Assert-RegistryCondition `
            -Condition (-not (Test-JsonProperty -Object $Object -Name $field)) `
            -Message "$ObjectName must not contain heavy field: $field"
    }
}

function Assert-AndroidArtifactMetadata {
    param(
        [Parameter(Mandatory = $true)]$AndroidPackage,
        [Parameter(Mandatory = $true)][string]$PackageId
    )

    $validArtifactTypes = @("source", "header", "static", "shared", "executable", "mixed")
    $validAbis = @("arm64-v8a", "x86_64", "armeabi-v7a", "x86")
    $artifactType = ([string]$AndroidPackage.artifact_type).Trim()
    $abiValues = Get-StringArrayOrNull $AndroidPackage.abi

    Assert-RegistryCondition `
        -Condition (-not [string]::IsNullOrWhiteSpace($artifactType)) `
        -Message "Android package missing artifact_type: $PackageId"
    Assert-RegistryCondition `
        -Condition ($artifactType -in $validArtifactTypes) `
        -Message "Invalid artifact_type for ${PackageId}: $artifactType"

    if ($null -ne $abiValues) {
        Assert-UniqueValues -Values $abiValues -Name "ABI for $PackageId"
        foreach ($abi in $abiValues) {
            Assert-RegistryCondition `
                -Condition ($abi -in $validAbis) `
                -Message "Invalid ABI for ${PackageId}: $abi"
        }
    }

    if ($artifactType -in @("source", "header")) {
        Assert-RegistryCondition `
            -Condition ($null -eq $abiValues) `
            -Message "ABI-independent package must not declare abi: $PackageId"
    }

    if ($artifactType -in @("static", "shared", "executable")) {
        Assert-RegistryCondition `
            -Condition ($null -ne $abiValues -and $abiValues.Count -gt 0) `
            -Message "Binary Android package must declare abi: $PackageId"
    }
}

function Assert-LightweightPluginCatalogEntry {
    param([Parameter(Mandatory = $true)]$Plugin)

    Assert-NoHeavyFields `
        -Object $Plugin `
        -ObjectName "Plugin v2 catalog $($Plugin.plugin_id)" `
        -Fields @(
            "repository_url",
            "homepage_url",
            "license",
            "versions",
            "download_url",
            "file_hash",
            "file_size",
            "changelog",
            "download_count",
            "rating_avg",
            "rating_count"
        )
}

function Assert-LightweightPackageCatalogEntry {
    param([Parameter(Mandatory = $true)]$Package)

    if ($null -eq $Package.android) {
        return
    }

    Assert-AndroidArtifactMetadata -AndroidPackage $Package.android -PackageId ([string]$Package.id)
    Assert-NoHeavyFields `
        -Object $Package.android `
        -ObjectName "Package v2 catalog $($Package.id).android" `
        -Fields @(
            "download_url",
            "download_sources",
            "checksum",
            "dependencies",
            "release_notes"
        )
}

function Assert-FileDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$ExpectedSize = -1,
        [string]$ExpectedHash = ""
    )

    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $Path -PathType Leaf) -Message "File not found: $Path"

    $file = Get-Item -LiteralPath $Path
    if ($ExpectedSize -ge 0) {
        Assert-RegistryCondition `
            -Condition ($file.Length -eq $ExpectedSize) `
            -Message "File size mismatch: $Path expected=$ExpectedSize actual=$($file.Length)"
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
        $expected = $ExpectedHash.Substring($ExpectedHash.IndexOf(":") + 1).ToLowerInvariant()
        $actual = Get-FileSha256 -Path $Path
        Assert-RegistryCondition `
            -Condition ($actual -eq $expected) `
            -Message "File hash mismatch: $Path expected=$expected actual=$actual"
    }
}

function Assert-TinaPlugManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedPluginId = "",
        $ExpectedVersion = $null
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $manifestEntry = $zip.Entries | Where-Object { $_.FullName -eq "manifest.json" } | Select-Object -First 1
        Assert-RegistryCondition -Condition ($null -ne $manifestEntry) -Message "Tinaplug missing root manifest.json: $Path"
        $reader = [System.IO.StreamReader]::new($manifestEntry.Open(), [System.Text.Encoding]::UTF8)
        try {
            $manifest = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }
        if ($null -ne $ExpectedVersion) {
            $manifestApiVersion = if (Test-JsonProperty -Object $manifest -Name "apiVersion") {
                [int]$manifest.apiVersion
            } else {
                1
            }
            $detailApiVersion = if (Test-JsonProperty -Object $ExpectedVersion -Name "api_version") {
                [int]$ExpectedVersion.api_version
            } else {
                1
            }
            Assert-RegistryCondition -Condition ([string]$manifest.id -eq $ExpectedPluginId) -Message "Tinaplug id mismatch: $Path"
            Assert-RegistryCondition -Condition ([string]$manifest.version -eq [string]$ExpectedVersion.version) -Message "Tinaplug version mismatch: $Path"
            Assert-RegistryCondition -Condition ($manifestApiVersion -eq $detailApiVersion) -Message "Tinaplug apiVersion mismatch: $Path"
            Assert-RegistryCondition `
                -Condition ([string]$manifest.minAppVersion -eq [string]$ExpectedVersion.min_app_version) `
                -Message "Tinaplug minAppVersion mismatch: $Path"
        }
    } finally {
        $zip.Dispose()
    }
}

function Assert-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$UrlOrPath,
        [long]$ExpectedSize = -1,
        [string]$ExpectedHash = "",
        [switch]$RequireTinaplugManifest,
        [string]$ExpectedPluginId = "",
        $ExpectedPluginVersion = $null
    )

    Assert-RegistryCondition `
        -Condition (-not [string]::IsNullOrWhiteSpace($UrlOrPath)) `
        -Message "Download URL is blank"

    $downloadPath = Resolve-RegistryFile -UrlOrPath $UrlOrPath
    if ($null -eq $downloadPath) {
        return
    }

    Assert-FileDigest -Path $downloadPath -ExpectedSize $ExpectedSize -ExpectedHash $ExpectedHash
    if ($RequireTinaplugManifest) {
        Assert-TinaPlugManifest `
            -Path $downloadPath `
            -ExpectedPluginId $ExpectedPluginId `
            -ExpectedVersion $ExpectedPluginVersion
    }
}

function Assert-PackageArtifactAbi {
    param(
        [Parameter(Mandatory = $true)][string]$UrlOrPath,
        [Parameter(Mandatory = $true)][string]$ExpectedAbi,
        [Parameter(Mandatory = $true)][object[]]$DeclaredAbis
    )

    $archivePath = Resolve-RegistryFile -UrlOrPath $UrlOrPath
    if ($null -eq $archivePath) {
        return
    }
    $entries = @(& tar -tf $archivePath)
    Assert-RegistryCondition -Condition ($LASTEXITCODE -eq 0) -Message "Failed to list package archive: $archivePath"
    $normalizedEntries = @($entries | ForEach-Object { ([string]$_) -replace '^\./', '' })
    Assert-RegistryCondition `
        -Condition ([bool]($normalizedEntries | Where-Object { $_.StartsWith("lib/$ExpectedAbi/") } | Select-Object -First 1)) `
        -Message "Package ABI artifact has no lib/$ExpectedAbi content: $archivePath"
    foreach ($otherAbi in @($DeclaredAbis)) {
        if ([string]$otherAbi -eq $ExpectedAbi) {
            continue
        }
        Assert-RegistryCondition `
            -Condition (-not [bool]($normalizedEntries | Where-Object { $_.StartsWith("lib/$otherAbi/") } | Select-Object -First 1)) `
            -Message "Package $ExpectedAbi artifact contains $otherAbi libraries: $archivePath"
    }
}

function Invoke-PluginContractValidation {
    $validatorPath = Join-Path $registryRoot "sources/plugin-starters/shared/validate_core.py"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $validatorPath -PathType Leaf) -Message "Missing plugin contract validator"

    $pythonCommand = @("python3", "python", "py") |
        ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    Assert-RegistryCondition -Condition ($null -ne $pythonCommand) -Message "Python is required for plugin contract validation"
    foreach ($sourceDir in Get-ChildItem -LiteralPath (Join-Path $registryRoot "sources/plugins") -Directory) {
        $arguments = if ($pythonCommand.Name -eq "py.exe" -or $pythonCommand.Name -eq "py") {
            @("-3", "-B", $validatorPath, $sourceDir.FullName)
        } else {
            @("-B", $validatorPath, $sourceDir.FullName)
        }
        & $pythonCommand.Source @arguments
        Assert-RegistryCondition `
            -Condition ($LASTEXITCODE -eq 0) `
            -Message "Plugin host contract validation failed: $($sourceDir.Name)"
    }
}

function Assert-LinuxDistroManifest {
    $manifestPath = Join-Path $registryRoot "linux-distro/manifest.v1.json"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Message "Missing linux-distro/manifest.v1.json"
    $manifest = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
    Assert-RegistryCondition -Condition ([int]$manifest.schemaVersion -eq 1) -Message "Invalid Linux distro manifest schemaVersion"
    Assert-RegistryCondition -Condition ($null -ne $manifest.mirrors) -Message "Linux distro manifest must declare mirrors"
    Assert-RegistryCondition -Condition (-not (Test-JsonProperty -Object $manifest -Name "mirors")) -Message "Linux distro manifest contains misspelled mirors field"
    foreach ($distro in @($manifest.distros)) {
        foreach ($release in @($distro.releases)) {
            foreach ($artifact in @($release.artifacts)) {
                $checksum = [string]$artifact.checksum.value
                Assert-RegistryCondition `
                    -Condition ($checksum -match '^[0-9a-fA-F]{64}$') `
                    -Message "Invalid Linux distro SHA256: $($distro.id) $($release.id) $($artifact.architecture)"
                Assert-RegistryCondition `
                    -Condition (-not [string]::IsNullOrWhiteSpace([string]$artifact.url)) `
                    -Message "Linux distro artifact URL is blank: $($distro.id) $($artifact.architecture)"
            }
        }
    }
}

function Get-PackageVersionEntries {
    param($Versions)

    $entries = @()
    if ($null -eq $Versions) {
        return ,@($entries)
    }

    foreach ($packageVersionGroup in $Versions.PSObject.Properties) {
        foreach ($version in @($packageVersionGroup.Value)) {
            $entries += $version
        }
    }

    return ,@($entries)
}

if (-not $SkipBuild) {
    if ($AllowLegacyV1) {
        & (Join-Path $PSScriptRoot "build-registry.ps1") -IncludeLegacyV1
    } else {
        & (Join-Path $PSScriptRoot "build-registry.ps1")
    }
}

$pluginsIndexV2Path = Join-Path $registryRoot "plugins/index.v2.json"
$pluginsIndexV3Path = Join-Path $registryRoot "plugins/index.v3.json"
$packagesIndexV2Path = Join-Path $registryRoot "packages/index.v2.json"
$pluginsIndexPath = Join-Path $registryRoot "plugins/index.json"
$packagesIndexPath = Join-Path $registryRoot "packages/index.json"

Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexV2Path) -Message "Missing plugins/index.v2.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexV3Path) -Message "Missing plugins/index.v3.json"
Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexV2Path) -Message "Missing packages/index.v2.json"

if ($AllowLegacyV1) {
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $pluginsIndexPath) -Message "Missing legacy plugins/index.json"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $packagesIndexPath) -Message "Missing legacy packages/index.json"
} else {
    Assert-RegistryCondition -Condition (-not (Test-Path -LiteralPath $pluginsIndexPath)) -Message "Legacy plugins/index.json must not be generated by default"
    Assert-RegistryCondition -Condition (-not (Test-Path -LiteralPath $packagesIndexPath)) -Message "Legacy packages/index.json must not be generated by default"
}

$pluginsIndexV2 = Get-Content -Raw -Encoding UTF8 $pluginsIndexV2Path | ConvertFrom-Json
$pluginsIndexV3 = Get-Content -Raw -Encoding UTF8 $pluginsIndexV3Path | ConvertFrom-Json
$packagesIndexV2 = Get-Content -Raw -Encoding UTF8 $packagesIndexV2Path | ConvertFrom-Json

$pluginCatalog = @($pluginsIndexV3.plugins)
$legacyPluginCatalog = @($pluginsIndexV2.plugins)
$packageCatalog = @($packagesIndexV2.packages)
$packageCategories = @($packagesIndexV2.categories)

Assert-RegistryCondition -Condition ([int]$pluginsIndexV2.schema_version -eq 2) -Message "Invalid plugins/index.v2.json schema_version"
Assert-RegistryCondition -Condition ([int]$pluginsIndexV3.schema_version -eq 3) -Message "Invalid plugins/index.v3.json schema_version"
Assert-RegistryCondition -Condition ([int]$packagesIndexV2.schema_version -eq 2) -Message "Invalid packages/index.v2.json schema_version"
Assert-UniqueValues -Values @($pluginCatalog | ForEach-Object { $_.plugin_id }) -Name "plugin v3 plugin_id"
Assert-UniqueValues -Values @($legacyPluginCatalog | ForEach-Object { $_.plugin_id }) -Name "legacy plugin v2 plugin_id"
Assert-UniqueValues -Values @($packageCatalog | ForEach-Object { $_.id }) -Name "package v2 id"
Assert-UniqueValues -Values @($packageCategories | ForEach-Object { $_.id }) -Name "package category id"

$categoryIds = @($packageCategories | ForEach-Object { [string]$_.id })

$pluginDetailsV3 = @{}
foreach ($plugin in $pluginCatalog) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.plugin_id)) -Message "Plugin v3 id is blank"
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$plugin.detail_url)) -Message "Plugin v3 detail_url is blank: $($plugin.plugin_id)"
    Assert-LightweightPluginCatalogEntry -Plugin $plugin

    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$plugin.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath) -Message "Plugin v3 detail_url must be repository-relative: $($plugin.plugin_id)"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $detailPath -PathType Leaf) -Message "Plugin v3 detail file missing: $($plugin.detail_url)"

    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    $pluginDetailsV3[[string]$plugin.plugin_id] = $detail
    Assert-RegistryCondition -Condition ([string]$detail.plugin_id -eq [string]$plugin.plugin_id) -Message "Plugin v3 detail id mismatch: $($plugin.plugin_id)"

    $versions = @($detail.versions)
    Assert-RegistryCondition -Condition ($versions.Count -gt 0) -Message "Plugin v3 detail has no versions: $($plugin.plugin_id)"
    Assert-UniqueValues -Values @($versions | ForEach-Object { $_.version }) -Name "plugin version for $($plugin.plugin_id)"

    $versionNames = @($versions | ForEach-Object { [string]$_.version })
    Assert-RegistryCondition -Condition ([string]$plugin.latest_version -in $versionNames) -Message "Plugin v3 latest_version missing from detail versions: $($plugin.plugin_id)"

    foreach ($version in $versions) {
        Assert-RegistryCondition -Condition (Test-JsonProperty -Object $version -Name "api_version") -Message "Plugin v3 version missing api_version: $($plugin.plugin_id) $($version.version)"
        Assert-RegistryCondition -Condition ([int]$version.api_version -gt 0) -Message "Plugin v3 version has invalid api_version: $($plugin.plugin_id) $($version.version)"
        if (-not [string]::IsNullOrWhiteSpace([string]$version.min_app_version)) {
            [void](ConvertTo-VersionCode ([string]$version.min_app_version))
        }
        Assert-DownloadFile `
            -UrlOrPath ([string]$version.download_url) `
            -ExpectedSize ([long]$version.file_size) `
            -ExpectedHash ([string]$version.file_hash) `
            -RequireTinaplugManifest `
            -ExpectedPluginId ([string]$plugin.plugin_id) `
            -ExpectedPluginVersion $version
    }
}

$legacyHostVersion = [string]$pluginsIndexV2.compatibility.host_version
$legacyApiVersion = [int]$pluginsIndexV2.compatibility.api_version
[void](ConvertTo-VersionCode $legacyHostVersion)
foreach ($plugin in $legacyPluginCatalog) {
    Assert-LightweightPluginCatalogEntry -Plugin $plugin
    Assert-RegistryCondition `
        -Condition ($pluginDetailsV3.ContainsKey([string]$plugin.plugin_id)) `
        -Message "Plugin v2 entry missing from v3 catalog: $($plugin.plugin_id)"
    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$plugin.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath -and (Test-Path -LiteralPath $detailPath -PathType Leaf)) -Message "Plugin v2 detail missing: $($plugin.plugin_id)"
    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    $versions = @($detail.versions)
    Assert-RegistryCondition -Condition ($versions.Count -gt 0) -Message "Plugin v2 detail has no compatible versions: $($plugin.plugin_id)"
    Assert-UniqueValues -Values @($versions | ForEach-Object { $_.version }) -Name "plugin v2 version for $($plugin.plugin_id)"
    Assert-RegistryCondition -Condition ([string]$plugin.latest_version -eq [string]$versions[0].version) -Message "Plugin v2 latest_version is not the highest compatible version: $($plugin.plugin_id)"
    $fullVersionNames = @($pluginDetailsV3[[string]$plugin.plugin_id].versions | ForEach-Object { [string]$_.version })
    foreach ($version in $versions) {
        Assert-RegistryCondition -Condition ([string]$version.version -in $fullVersionNames) -Message "Plugin v2 version missing from v3 history: $($plugin.plugin_id) $($version.version)"
        Assert-RegistryCondition -Condition ([int]$version.api_version -eq $legacyApiVersion) -Message "Plugin v2 exposes unsupported api_version: $($plugin.plugin_id) $($version.version)"
        if (-not [string]::IsNullOrWhiteSpace([string]$version.min_app_version)) {
            Assert-RegistryCondition `
                -Condition ((ConvertTo-VersionCode ([string]$version.min_app_version)) -le (ConvertTo-VersionCode $legacyHostVersion)) `
                -Message "Plugin v2 exposes version requiring a newer host: $($plugin.plugin_id) $($version.version)"
        }
    }
}

foreach ($package in $packageCatalog) {
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.id)) -Message "Package v2 id is blank"
    Assert-RegistryCondition -Condition (-not [string]::IsNullOrWhiteSpace([string]$package.detail_url)) -Message "Package v2 detail_url is blank: $($package.id)"
    Assert-LightweightPackageCatalogEntry -Package $package

    if (-not [string]::IsNullOrWhiteSpace([string]$package.category)) {
        Assert-RegistryCondition -Condition ([string]$package.category -in $categoryIds) -Message "Package v2 category is not declared: $($package.id)"
    }

    $detailPath = Resolve-RegistryFile -UrlOrPath ([string]$package.detail_url)
    Assert-RegistryCondition -Condition ($null -ne $detailPath) -Message "Package v2 detail_url must be repository-relative: $($package.id)"
    Assert-RegistryCondition -Condition (Test-Path -LiteralPath $detailPath -PathType Leaf) -Message "Package v2 detail file missing: $($package.detail_url)"

    $detail = Get-Content -Raw -Encoding UTF8 $detailPath | ConvertFrom-Json
    Assert-RegistryCondition -Condition ([string]$detail.package.id -eq [string]$package.id) -Message "Package v2 detail id mismatch: $($package.id)"
    Assert-RegistryCondition -Condition ($null -ne $detail.versions) -Message "Package v2 detail has no versions: $($package.id)"

    if ($null -ne $detail.package.android) {
        Assert-AndroidArtifactMetadata -AndroidPackage $detail.package.android -PackageId ([string]$package.id)
        if (-not [string]::IsNullOrWhiteSpace([string]$detail.package.android.download_url)) {
            Assert-DownloadFile `
                -UrlOrPath ([string]$detail.package.android.download_url) `
                -ExpectedSize ([long]$detail.package.android.size) `
                -ExpectedHash ([string]$detail.package.android.checksum)
        }
    }

    $versionEntries = Get-PackageVersionEntries $detail.versions
    Assert-RegistryCondition -Condition ($versionEntries.Count -gt 0) -Message "Package v2 detail has no version entries: $($package.id)"
    Assert-UniqueValues `
        -Values @($versionEntries | ForEach-Object { "{0}:{1}" -f $_.platform, $_.version }) `
        -Name "package version for $($package.id)"

    foreach ($version in $versionEntries) {
        if ([string]$version.platform -eq "android") {
            Assert-AndroidArtifactMetadata -AndroidPackage $version -PackageId ([string]$version.package_id)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$version.download_url)) {
            Assert-DownloadFile `
                -UrlOrPath ([string]$version.download_url) `
                -ExpectedSize ([long]$version.download_size) `
                -ExpectedHash ([string]$version.checksum)
        }
    }

    if ($null -ne $detail.downloads) {
        foreach ($downloadEntry in $detail.downloads.PSObject.Properties) {
            $sourceAbis = @()
            foreach ($source in @($downloadEntry.Value.sources)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$source.url)) {
                    $sourceSize = if (Test-JsonProperty -Object $source -Name "size") {
                        [long]$source.size
                    } else {
                        [long]$downloadEntry.Value.size
                    }
                    $sourceChecksum = if (Test-JsonProperty -Object $source -Name "checksum") {
                        [string]$source.checksum
                    } else {
                        [string]$downloadEntry.Value.checksum
                    }
                    Assert-DownloadFile `
                        -UrlOrPath ([string]$source.url) `
                        -ExpectedSize $sourceSize `
                        -ExpectedHash $sourceChecksum
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$source.abi)) {
                    $sourceAbis += [string]$source.abi
                    Assert-PackageArtifactAbi `
                        -UrlOrPath ([string]$source.url) `
                        -ExpectedAbi ([string]$source.abi) `
                        -DeclaredAbis @($detail.package.android.abi)
                }
            }
            Assert-UniqueValues -Values $sourceAbis -Name "download source ABI for $($package.id)"
            $declaredAbis = @($detail.package.android.abi | Sort-Object -Unique)
            $resolvedSourceAbis = @($sourceAbis | Sort-Object -Unique)
            if ($resolvedSourceAbis.Count -gt 0) {
                Assert-RegistryCondition `
                    -Condition (($declaredAbis -join ",") -eq ($resolvedSourceAbis -join ",")) `
                    -Message "Download source ABIs do not match package ABI metadata: $($package.id)"
            }
        }
    }
}

if ($AllowLegacyV1) {
    $pluginsIndex = Get-Content -Raw -Encoding UTF8 $pluginsIndexPath | ConvertFrom-Json
    $packagesIndex = Get-Content -Raw -Encoding UTF8 $packagesIndexPath | ConvertFrom-Json
    $legacyPlugins = @($pluginsIndex.plugins)
    $legacyPackages = @($packagesIndex.packages)
    Assert-RegistryCondition -Condition ($legacyPlugins.Count -eq $legacyPluginCatalog.Count) -Message "Legacy plugin index count does not match v2 catalog"
    Assert-RegistryCondition -Condition ($legacyPackages.Count -eq $packageCatalog.Count) -Message "Legacy package index count does not match v2 catalog"
}

Invoke-PluginContractValidation
Assert-LinuxDistroManifest

if (-not $SkipGitDiffCheck) {
    $diff = git -C $registryRoot status --porcelain
    Assert-RegistryCondition -Condition ([string]::IsNullOrWhiteSpace(($diff -join "`n"))) -Message "Registry build produced uncommitted changes."
}

Write-Host ("Registry validation passed: pluginsV3={0}, pluginsV2={1}, packages={2}, legacyV1={3}" -f $pluginCatalog.Count, $legacyPluginCatalog.Count, $packageCatalog.Count, [bool]$AllowLegacyV1)
