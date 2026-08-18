param(
    [string]$OutputRoot = "",
    [string]$WorkRoot = "",
    [string[]]$PackageId = @(),
    [switch]$SkipExisting
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$registryRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputRoot) {
    $OutputRoot = Join-Path $registryRoot "packages"
}
if (-not $WorkRoot) {
    $runId = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss", [System.Globalization.CultureInfo]::InvariantCulture)
    $WorkRoot = Join-Path $registryRoot ".build\cpp-source-packages\$runId"
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Required file not found: $SourcePath"
    }

    $parent = Split-Path -Parent $DestinationPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Copy-RequiredDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Required directory not found: $SourcePath"
    }

    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    Get-ChildItem -LiteralPath $SourcePath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $DestinationPath -Recurse -Force
    }
}

function Copy-RequiredGlob {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $files = @(Get-ChildItem -Path (Join-Path $SourceRoot $Pattern) -File)
    if ($files.Count -eq 0) {
        throw "Required glob matched no files: $Pattern"
    }

    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $DestinationPath $file.Name) -Force
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = ""
    )

    if ($WorkingDirectory) {
        & git -C $WorkingDirectory @Arguments 1>$null
    } else {
        & git @Arguments 1>$null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git failed: git $($Arguments -join ' ')"
    }
}

function Get-UpstreamSource {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $sourceDir = Join-Path $Root $Package.Id
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDir ".git"))) {
        New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
        Invoke-Git -Arguments @("init") -WorkingDirectory $sourceDir
        Invoke-Git -Arguments @("remote", "add", "origin", $Package.Repository) -WorkingDirectory $sourceDir
    }

    Invoke-Git -Arguments @("config", "core.sparseCheckout", "true") -WorkingDirectory $sourceDir
    $sparseCheckoutPath = Join-Path $sourceDir ".git\info\sparse-checkout"
    Write-Utf8NoBom -Path $sparseCheckoutPath -Content (($Package.SparsePaths -join "`n") + "`n")

    Invoke-Git -Arguments @("fetch", "--depth", "1", "origin", $Package.Ref) -WorkingDirectory $sourceDir
    Invoke-Git -Arguments @("checkout", "--detach", "FETCH_HEAD") -WorkingDirectory $sourceDir
    $actualCommit = (& git -C $sourceDir rev-parse HEAD).Trim()
    if ($actualCommit -ne $Package.Commit) {
        throw "Unexpected commit for $($Package.Id): expected=$($Package.Commit) actual=$actualCommit"
    }
    return $sourceDir
}

function Write-PkgConfigFile {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $content = @"
prefix=`${pcfiledir}/..
includedir=`${prefix}/include
sourcedir=`${prefix}/src

Name: $($Package.PkgConfigName)
Description: $($Package.Description)
Version: $($Package.Version)
Cflags: -I`${includedir}
"@

    Write-Utf8NoBom -Path $Path -Content $content
}

function Write-PackageJson {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $files = [ordered]@{
        include = "include"
        pkgconfig = "pkgconfig/$($Package.Id).pc"
    }
    if ($Package.ArtifactType -eq "source") {
        $files.source = "src"
    }

    $metadata = [ordered]@{
        id = $Package.Id
        name = $Package.Name
        version = $Package.Version
        packageRevision = 1
        upstreamName = $Package.UpstreamName
        upstreamVersion = $Package.UpstreamVersion
        upstreamTag = $Package.UpstreamTag
        upstreamCommit = $Package.Commit
        description = $Package.Description
        platform = "android"
        artifactType = $Package.ArtifactType
        installType = "download"
        category = "library"
        homepage = $Package.Homepage
        license = $Package.License
        files = $files
    }

    Write-Utf8NoBom -Path $Path -Content (($metadata | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
}

function Copy-PackageFiles {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    foreach ($rule in @($Package.Copies)) {
        $from = Join-Path $SourceDir $rule.From
        $to = Join-Path $PackageRoot $rule.To
        switch ($rule.Kind) {
            "file" { Copy-RequiredFile -SourcePath $from -DestinationPath $to }
            "dir" { Copy-RequiredDirectory -SourcePath $from -DestinationPath $to }
            "glob" { Copy-RequiredGlob -SourceRoot $SourceDir -Pattern $rule.From -DestinationPath $to }
            default { throw "Unknown copy rule kind for $($Package.Id): $($rule.Kind)" }
        }
    }

    if ($Package.LicenseNote) {
        Write-Utf8NoBom -Path (Join-Path $PackageRoot "LICENSE.txt") -Content ($Package.LicenseNote + [Environment]::NewLine)
    }
}

function New-PackageArchive {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Archive already exists: $ArchivePath"
    }

    Push-Location $PackageRoot
    try {
        tar -caf $ArchivePath *
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create archive: $ArchivePath"
        }
    } finally {
        Pop-Location
    }

    $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Built package: $ArchivePath"
    Write-Host "Package version: $($Package.Version)"
    Write-Host "Artifact type: $($Package.ArtifactType)"
    Write-Host "ABI: none"
    Write-Host "SHA256: $hash"
}

$packages = @(
    [pscustomobject]@{
        Id = "nlohmann-json"
        Name = "JSON for Modern C++"
        UpstreamName = "JSON for Modern C++"
        Version = "3.12.0"
        UpstreamVersion = "3.12.0"
        UpstreamTag = "v3.12.0"
        Repository = "https://github.com/nlohmann/json.git"
        Ref = "v3.12.0"
        Commit = "55f93686c01528224f448c19128836e7df245f72"
        ArtifactType = "header"
        Description = "JSON for Modern C++ single-header library"
        Homepage = "https://github.com/nlohmann/json"
        License = "MIT"
        PkgConfigName = "nlohmann_json"
        LicenseNote = ""
        SparsePaths = @(
            "/single_include/nlohmann/",
            "/LICENSE.MIT"
        )
        Copies = @(
            [pscustomobject]@{ Kind = "dir"; From = "single_include\nlohmann"; To = "include\nlohmann" },
            [pscustomobject]@{ Kind = "file"; From = "LICENSE.MIT"; To = "LICENSE.MIT" }
        )
    },
    [pscustomobject]@{
        Id = "glm"
        Name = "GLM"
        UpstreamName = "OpenGL Mathematics"
        Version = "1.0.3"
        UpstreamVersion = "1.0.3"
        UpstreamTag = "1.0.3"
        Repository = "https://github.com/g-truc/glm.git"
        Ref = "1.0.3"
        Commit = "8d1fd52e5ab5590e2c81768ace50c72bae28f2ed"
        ArtifactType = "header"
        Description = "OpenGL Mathematics header-only C++ mathematics library"
        Homepage = "https://github.com/g-truc/glm"
        License = "MIT"
        PkgConfigName = "glm"
        LicenseNote = ""
        SparsePaths = @(
            "/glm/",
            "/copying.txt"
        )
        Copies = @(
            [pscustomobject]@{ Kind = "dir"; From = "glm"; To = "include\glm" },
            [pscustomobject]@{ Kind = "file"; From = "copying.txt"; To = "copying.txt" }
        )
    },
    [pscustomobject]@{
        Id = "stb"
        Name = "stb"
        UpstreamName = "stb"
        Version = "2026.04.15"
        UpstreamVersion = "2026.04.15"
        UpstreamTag = "master"
        Repository = "https://github.com/nothings/stb.git"
        Ref = "31c1ad37456438565541f4919958214b6e762fb4"
        Commit = "31c1ad37456438565541f4919958214b6e762fb4"
        ArtifactType = "header"
        Description = "Single-file public domain C/C++ libraries"
        Homepage = "https://github.com/nothings/stb"
        License = "MIT OR Public-Domain"
        PkgConfigName = "stb"
        LicenseNote = "stb libraries are dual-licensed as public domain or MIT; see the license text embedded in the upstream header files."
        SparsePaths = @(
            "/*.h"
        )
        Copies = @(
            [pscustomobject]@{ Kind = "glob"; From = "*.h"; To = "include\stb" }
        )
    },
    [pscustomobject]@{
        Id = "fmt"
        Name = "fmt"
        UpstreamName = "fmt"
        Version = "12.1.0"
        UpstreamVersion = "12.1.0"
        UpstreamTag = "12.1.0"
        Repository = "https://github.com/fmtlib/fmt.git"
        Ref = "12.1.0"
        Commit = "407c905e45ad75fc29bf0f9bb7c5c2fd3475976f"
        ArtifactType = "source"
        Description = "Modern formatting library for C++"
        Homepage = "https://github.com/fmtlib/fmt"
        License = "MIT"
        PkgConfigName = "fmt"
        LicenseNote = ""
        SparsePaths = @(
            "/include/fmt/",
            "/src/*.cc",
            "/LICENSE"
        )
        Copies = @(
            [pscustomobject]@{ Kind = "dir"; From = "include\fmt"; To = "include\fmt" },
            [pscustomobject]@{ Kind = "glob"; From = "src\*.cc"; To = "src" },
            [pscustomobject]@{ Kind = "file"; From = "LICENSE"; To = "LICENSE" }
        )
    },
    [pscustomobject]@{
        Id = "tinyxml2"
        Name = "TinyXML-2"
        UpstreamName = "TinyXML-2"
        Version = "11.0.0"
        UpstreamVersion = "11.0.0"
        UpstreamTag = "11.0.0"
        Repository = "https://github.com/leethomason/tinyxml2.git"
        Ref = "11.0.0"
        Commit = "9148bdf719e997d1f474be6bcc7943881046dba1"
        ArtifactType = "source"
        Description = "Simple, small C++ XML parser"
        Homepage = "https://github.com/leethomason/tinyxml2"
        License = "Zlib"
        PkgConfigName = "tinyxml2"
        LicenseNote = ""
        SparsePaths = @(
            "/tinyxml2.h",
            "/tinyxml2.cpp",
            "/LICENSE.txt"
        )
        Copies = @(
            [pscustomobject]@{ Kind = "file"; From = "tinyxml2.h"; To = "include\tinyxml2.h" },
            [pscustomobject]@{ Kind = "file"; From = "tinyxml2.cpp"; To = "src\tinyxml2.cpp" },
            [pscustomobject]@{ Kind = "file"; From = "LICENSE.txt"; To = "LICENSE.txt" }
        )
    },
    [pscustomobject]@{
        Id = "googletest"
        Name = "GoogleTest"
        UpstreamName = "GoogleTest"
        Version = "1.17.0"
        UpstreamVersion = "1.17.0"
        UpstreamTag = "v1.17.0"
        Repository = "https://github.com/google/googletest.git"
        Ref = "v1.17.0"
        Commit = "52eb8108c5bdec04579160ae17225d66034bd723"
        ArtifactType = "source"
        Description = "C++ testing and mocking framework"
        Homepage = "https://github.com/google/googletest"
        License = "BSD-3-Clause"
        PkgConfigName = "gtest"
        LicenseNote = "GoogleTest is distributed under the BSD 3-Clause license; see LICENSE in the package source."
        SparsePaths = @(
            "/CMakeLists.txt",
            "/cmake/",
            "/googletest/",
            "/googlemock/",
            "/LICENSE"
        )
        Copies = @(
            [pscustomobject]@{ Kind = "file"; From = "CMakeLists.txt"; To = "CMakeLists.txt" },
            [pscustomobject]@{ Kind = "dir"; From = "cmake"; To = "cmake" },
            [pscustomobject]@{ Kind = "dir"; From = "googletest"; To = "googletest" },
            [pscustomobject]@{ Kind = "dir"; From = "googlemock"; To = "googlemock" },
            [pscustomobject]@{ Kind = "file"; From = "LICENSE"; To = "LICENSE" }
        )
    }
)

if ($PackageId.Count -gt 0) {
    $requestedPackageIds = @($PackageId | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $packages = @($packages | Where-Object { $_.Id -in $requestedPackageIds })
    $missingPackageIds = @($requestedPackageIds | Where-Object { $_ -notin @($packages | ForEach-Object { $_.Id }) })
    if ($missingPackageIds.Count -gt 0) {
        throw "Unknown C++ source package id(s): $($missingPackageIds -join ', ')"
    }
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$WorkRoot = (Resolve-Path -LiteralPath $WorkRoot).Path
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

foreach ($package in $packages) {
    $sourceDir = Get-UpstreamSource -Package $package -Root (Join-Path $WorkRoot "upstreams")
    $packageRoot = Join-Path $WorkRoot "packages\$($package.Id)-$($package.Version)"
    if (Test-Path -LiteralPath $packageRoot) {
        throw "Package work directory already exists: $packageRoot"
    }
    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

    Copy-PackageFiles -Package $package -SourceDir $sourceDir -PackageRoot $packageRoot

    $pkgConfigDir = Join-Path $packageRoot "pkgconfig"
    New-Item -ItemType Directory -Force -Path $pkgConfigDir | Out-Null
    Write-PkgConfigFile -Package $package -Path (Join-Path $pkgConfigDir "$($package.Id).pc")

    Write-PackageJson -Package $package -Path (Join-Path $packageRoot "package.json")

    $buildInfo = @"
package_id=$($package.Id)
package_version=$($package.Version)
package_revision=1
artifact_type=$($package.ArtifactType)
upstream_tag=$($package.UpstreamTag)
upstream_commit=$($package.Commit)
upstream_version=$($package.UpstreamVersion)
"@
    Write-Utf8NoBom -Path (Join-Path $packageRoot "BUILD-INFO.txt") -Content $buildInfo

    $archiveDir = Join-Path $OutputRoot "$($package.Id)\$($package.Version)"
    New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
    $archivePath = Join-Path $archiveDir "$($package.Id).tar.xz"
    if ($SkipExisting -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-Host "Skipping existing package archive: $archivePath"
        continue
    }
    New-PackageArchive -Package $package -PackageRoot $packageRoot -ArchivePath $archivePath
}
