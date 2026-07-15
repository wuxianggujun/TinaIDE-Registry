param(
    [string]$OutputDir = "release-assets"
)

$ErrorActionPreference = "Stop"

$registryRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    Join-Path $registryRoot $OutputDir
}
$copiedAssets = @{}

function Resolve-RegistryFile {
    param([Parameter(Mandatory = $true)][string]$UrlOrPath)

    $value = $UrlOrPath.Trim()
    if ($value.StartsWith("http://") -or $value.StartsWith("https://")) {
        return $null
    }

    $relative = $value.TrimStart("/", "\").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $registryRoot $relative))
    $rootPath = [System.IO.Path]::GetFullPath($registryRoot)
    if (-not $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Registry path escapes repository root: $UrlOrPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Registry file not found: $UrlOrPath"
    }
    return $fullPath
}

function Copy-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    if ($copiedAssets.ContainsKey($AssetName)) {
        if ($copiedAssets[$AssetName] -eq $SourcePath) {
            return
        }
        throw "Duplicate release asset name: $AssetName"
    }

    $target = Join-Path $outputRoot $AssetName
    Copy-Item -LiteralPath $SourcePath -Destination $target -Force
    $copiedAssets[$AssetName] = $SourcePath
}

function Copy-RegistryAsset {
    param(
        [Parameter(Mandatory = $true)][string]$UrlOrPath,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    $source = Resolve-RegistryFile -UrlOrPath $UrlOrPath
    if ($null -eq $source) {
        return
    }
    Copy-ReleaseAsset -SourcePath $source -AssetName $AssetName
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

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

$pluginsIndexV2Path = Join-Path $registryRoot "plugins/index.v2.json"
$pluginsIndexV3Path = Join-Path $registryRoot "plugins/index.v3.json"
$packagesIndexV2Path = Join-Path $registryRoot "packages/index.v2.json"
Copy-ReleaseAsset -SourcePath $pluginsIndexV2Path -AssetName "plugins.index.v2.json"
Copy-ReleaseAsset -SourcePath $pluginsIndexV3Path -AssetName "plugins.index.v3.json"
Copy-ReleaseAsset -SourcePath $packagesIndexV2Path -AssetName "packages.index.v2.json"

$pluginCatalog = (Get-Content $pluginsIndexV2Path -Raw -Encoding UTF8 | ConvertFrom-Json).plugins
foreach ($plugin in @($pluginCatalog)) {
    $detailSource = Resolve-RegistryFile -UrlOrPath ([string]$plugin.detail_url)
    if ($null -eq $detailSource) {
        continue
    }

    $detailAssetName = "plugins.{0}.plugin.json" -f $plugin.plugin_id
    Copy-ReleaseAsset -SourcePath $detailSource -AssetName $detailAssetName

    $detail = Get-Content $detailSource -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($version in @($detail.versions)) {
        if ([string]::IsNullOrWhiteSpace([string]$version.download_url)) {
            continue
        }
        $assetName = "{0}-{1}.tinaplug" -f $detail.plugin_id, $version.version
        Copy-RegistryAsset -UrlOrPath ([string]$version.download_url) -AssetName $assetName
    }
}

$pluginCatalogV3 = (Get-Content $pluginsIndexV3Path -Raw -Encoding UTF8 | ConvertFrom-Json).plugins
foreach ($plugin in @($pluginCatalogV3)) {
    $detailSource = Resolve-RegistryFile -UrlOrPath ([string]$plugin.detail_url)
    if ($null -eq $detailSource) {
        continue
    }

    $detailAssetName = "plugins.{0}.plugin.v3.json" -f $plugin.plugin_id
    Copy-ReleaseAsset -SourcePath $detailSource -AssetName $detailAssetName

    $detail = Get-Content $detailSource -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($version in @($detail.versions)) {
        if ([string]::IsNullOrWhiteSpace([string]$version.download_url)) {
            continue
        }
        $assetName = "{0}-{1}.tinaplug" -f $detail.plugin_id, $version.version
        Copy-RegistryAsset -UrlOrPath ([string]$version.download_url) -AssetName $assetName
    }
}

$packageCatalog = (Get-Content $packagesIndexV2Path -Raw -Encoding UTF8 | ConvertFrom-Json).packages
foreach ($package in @($packageCatalog)) {
    $detailSource = Resolve-RegistryFile -UrlOrPath ([string]$package.detail_url)
    if ($null -eq $detailSource) {
        continue
    }

    $detailAssetName = "packages.{0}.package.json" -f $package.id
    Copy-ReleaseAsset -SourcePath $detailSource -AssetName $detailAssetName

    $detail = Get-Content $detailSource -Raw -Encoding UTF8 | ConvertFrom-Json
    $versionEntries = Get-PackageVersionEntries $detail.versions
    foreach ($version in $versionEntries) {
        if ([string]::IsNullOrWhiteSpace([string]$version.download_url)) {
            continue
        }
        $source = Resolve-RegistryFile -UrlOrPath ([string]$version.download_url)
        if ($null -eq $source) {
            continue
        }
        $leaf = Split-Path -Leaf $source
        $assetName = "{0}-{1}-{2}" -f $detail.package.id, $version.version, $leaf
        Copy-ReleaseAsset -SourcePath $source -AssetName $assetName
    }
}

$count = (Get-ChildItem -LiteralPath $outputRoot -File).Count
Write-Host "Prepared $count release asset(s): $outputRoot"
