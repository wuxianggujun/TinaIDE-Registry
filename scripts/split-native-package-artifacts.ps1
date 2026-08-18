param(
    [string]$MetadataPath = "metadata/packages.json",
    [string]$WorkRoot = ".build/split-native-package-artifacts"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$registryRoot = Split-Path -Parent $PSScriptRoot
$metadataFile = Join-Path $registryRoot $MetadataPath
$workDirectory = Join-Path $registryRoot $WorkRoot

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

if (-not (Test-Path -LiteralPath $metadataFile -PathType Leaf)) {
    throw "Package metadata not found: $metadataFile"
}
if (Test-Path -LiteralPath $workDirectory) {
    Remove-Item -LiteralPath $workDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $workDirectory | Out-Null

$metadata = Get-Content -Raw -Encoding UTF8 $metadataFile | ConvertFrom-Json
foreach ($package in @($metadata.packages)) {
    if ($null -eq $package.PSObject.Properties["artifacts"]) {
        continue
    }

    $universalArchive = Join-Path $registryRoot ([string]$package.file)
    if (-not (Test-Path -LiteralPath $universalArchive -PathType Leaf)) {
        throw "Universal package archive not found: $universalArchive"
    }

    $extractRoot = Join-Path $workDirectory ("extract-{0}" -f $package.id)
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    & tar -xf $universalArchive -C $extractRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract package archive: $universalArchive"
    }

    foreach ($artifact in @($package.artifacts)) {
        $targetAbi = [string]$artifact.abi
        $stageRoot = Join-Path $workDirectory ("stage-{0}-{1}" -f $package.id, $targetAbi)
        Copy-DirectoryContents -Source $extractRoot -Destination $stageRoot

        $libRoot = Join-Path $stageRoot "lib"
        foreach ($declaredAbi in @($package.android.abi)) {
            if ([string]$declaredAbi -ne $targetAbi) {
                $otherAbiDirectory = Join-Path $libRoot ([string]$declaredAbi)
                if (Test-Path -LiteralPath $otherAbiDirectory) {
                    Remove-Item -LiteralPath $otherAbiDirectory -Recurse -Force
                }
            }
        }
        $targetLibraryDirectory = Join-Path $libRoot $targetAbi
        if (-not (Test-Path -LiteralPath $targetLibraryDirectory -PathType Container)) {
            throw "Package $($package.id) does not contain libraries for $targetAbi"
        }

        $packageManifestPath = Join-Path $stageRoot "package.json"
        $packageManifest = Get-Content -Raw -Encoding UTF8 $packageManifestPath | ConvertFrom-Json
        $packageManifest.abis = @($targetAbi)
        Write-Utf8NoBom `
            -Path $packageManifestPath `
            -Content (($packageManifest | ConvertTo-Json -Depth 20) + "`n")

        $buildInfoPath = Join-Path $stageRoot "BUILD-INFO.txt"
        if (Test-Path -LiteralPath $buildInfoPath -PathType Leaf) {
            $buildInfo = Get-Content -Raw -Encoding UTF8 $buildInfoPath
            $buildInfo = $buildInfo -replace '(?m)^abis=.*$', "abis=$targetAbi"
            Write-Utf8NoBom -Path $buildInfoPath -Content $buildInfo
        }

        $artifactPath = Join-Path $registryRoot ([string]$artifact.file)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $artifactPath) | Out-Null
        if (Test-Path -LiteralPath $artifactPath) {
            Remove-Item -LiteralPath $artifactPath -Force
        }
        Push-Location $stageRoot
        try {
            & tar --sort=name --mtime="UTC 1970-01-01" --owner=0 --group=0 --numeric-owner -caf $artifactPath *
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create ABI package artifact: $artifactPath"
            }
        } finally {
            Pop-Location
        }
        Write-Host "Created $($package.id) $targetAbi artifact: $artifactPath"
    }
}

Remove-Item -LiteralPath $workDirectory -Recurse -Force
