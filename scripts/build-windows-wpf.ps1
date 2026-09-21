[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('win-x64')]
    [string]$Runtime = 'win-x64',
    [string]$AppVersion = '',
    [string]$BuildName = '',
    [ValidatePattern('^[A-Za-z0-9.-]*$')]
    [string]$PackageSuffix = '',
    [switch]$SelfContained,
    [switch]$SkipVerification
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$solutionPath = Join-Path $repoRoot 'apps\envelope_windows\Envelope.Windows.sln'
$appProject = Join-Path $repoRoot 'apps\envelope_windows\Envelope.Windows\Envelope.Windows.csproj'
$verificationProject = Join-Path $repoRoot 'apps\envelope_windows\Envelope.Windows.Tests\Envelope.Windows.Tests.csproj'
$uiVerificationProject = Join-Path $repoRoot 'apps\envelope_windows\Envelope.Windows.UiTests\Envelope.Windows.UiTests.csproj'
$nativeDll = Join-Path $repoRoot 'target\release\envelope_ffi.dll'
$portableRoot = Join-Path $repoRoot 'target\portable'
$publishDir = Join-Path $portableRoot "Envelope-$Runtime"
if ($PackageSuffix) { $publishDir = "$publishDir-$PackageSuffix" }
$archivePath = "$publishDir.zip"
$archiveHashPath = "$archivePath.sha256"

if ([string]::IsNullOrWhiteSpace($AppVersion)) {
    $AppVersion = "v1.0.1.$((Get-Date).ToString('yyyyMMddHHmmss.fff'))"
}
if ([string]::IsNullOrWhiteSpace($BuildName)) {
    $candidateBuildName = $AppVersion.Trim()
    if ($candidateBuildName.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidateBuildName = $candidateBuildName.Substring(1)
    }
    $BuildName = if ($candidateBuildName -match '^(\d+\.\d+\.\d+)') {
        $Matches[1]
    } else {
        '1.0.1'
    }
}
if ($BuildName -notmatch '^\d+\.\d+\.\d+$') {
    throw "Windows BuildName must be a numeric major.minor.patch value: $BuildName"
}
$versionArguments = @(
    "-p:Version=$BuildName",
    "-p:AssemblyVersion=${BuildName}.0",
    "-p:FileVersion=${BuildName}.0",
    "-p:InformationalVersion=$AppVersion"
)

if (-not (Test-Path -LiteralPath $solutionPath -PathType Leaf)) {
    throw "WPF solution not found: $solutionPath"
}

Push-Location $repoRoot
try {
    & (Join-Path $PSScriptRoot 'sync-windows-brand-assets.ps1')
    cargo build --release -p envelope-ffi
    if ($LASTEXITCODE -ne 0) { throw "Rust FFI build failed: $LASTEXITCODE" }

    dotnet restore $solutionPath --ignore-failed-sources
    if ($LASTEXITCODE -ne 0) { throw "dotnet restore failed: $LASTEXITCODE" }

    if ($SelfContained) {
        # Self-contained publishing needs the RID runtime packs from NuGet.
        dotnet restore $appProject -r $Runtime --ignore-failed-sources
        if ($LASTEXITCODE -ne 0) { throw "RID restore failed: $LASTEXITCODE" }
    }

    dotnet build $solutionPath -c $Configuration --no-restore @versionArguments
    if ($LASTEXITCODE -ne 0) { throw "WPF solution build failed: $LASTEXITCODE" }

    if (-not $SkipVerification) {
        dotnet run --project $verificationProject -c $Configuration --no-build
        if ($LASTEXITCODE -ne 0) { throw "Windows verification failed: $LASTEXITCODE" }
        dotnet run --project $uiVerificationProject -c $Configuration --no-build -- (Join-Path $repoRoot 'target\ui-redesign-evidence')
        if ($LASTEXITCODE -ne 0) { throw "Windows UI verification failed: $LASTEXITCODE" }
    }

    $portableBase = [System.IO.Path]::GetFullPath($portableRoot)
    $resolvedPublish = [System.IO.Path]::GetFullPath($publishDir)
    if (-not $resolvedPublish.StartsWith($portableBase + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace a publish path outside target/portable: $resolvedPublish"
    }
    if (Test-Path -LiteralPath $resolvedPublish) {
        Remove-Item -LiteralPath $resolvedPublish -Recurse -Force
    }
    New-Item -ItemType Directory -Path $resolvedPublish -Force | Out-Null

    if ($SelfContained) {
        dotnet publish $appProject -c $Configuration -r $Runtime --self-contained true --no-restore -o $resolvedPublish @versionArguments
    } else {
        # Framework-dependent WPF publishing does not need RID runtime packs and
        # remains buildable in an offline/enterprise NuGet environment.
        dotnet publish $appProject -c $Configuration --self-contained false --no-restore -o $resolvedPublish @versionArguments
    }
    if ($LASTEXITCODE -ne 0) { throw "WPF publish failed: $LASTEXITCODE" }

    if (-not (Test-Path -LiteralPath $nativeDll -PathType Leaf)) {
        throw "Rust FFI DLL missing after build: $nativeDll"
    }
    Copy-Item -LiteralPath $nativeDll -Destination (Join-Path $resolvedPublish 'envelope_ffi.dll') -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $resolvedPublish 'LICENSE') -Force

    if ($SelfContained) {
        # Self-contained distributions include the .NET runtime itself. Copy
        # the exact resolved runtime-pack licenses/notices beside the app so
        # recipients do not need NuGet or the SDK to inspect those terms.
        $assetsPath = Join-Path (Split-Path $appProject -Parent) 'obj\project.assets.json'
        $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json
        $packageRoot = $assets.packageFolders.PSObject.Properties.Name | Select-Object -First 1
        [xml]$projectXml = Get-Content -LiteralPath $appProject -Raw
        $targetFramework = @($projectXml.Project.PropertyGroup.TargetFramework) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($packageRoot) -or
            [string]::IsNullOrWhiteSpace([string]$targetFramework) -or
            [string]$targetFramework -notmatch '^net(?<Major>\d+)\.') {
            throw 'Unable to resolve the NuGet package root or target framework for .NET runtime licenses.'
        }
        $runtimeMajor = $Matches.Major
        $resolveRuntimePack = {
            param(
                [string]$PackageId,
                [string]$RequiredFile
            )

            $packRoot = Join-Path $packageRoot $PackageId
            $versionPattern = "^$([System.Text.RegularExpressions.Regex]::Escape($runtimeMajor))\."
            $candidate = Get-ChildItem -LiteralPath $packRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -match $versionPattern -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName $RequiredFile) -PathType Leaf)
                } |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -First 1
            if ($null -eq $candidate) {
                throw "Unable to locate $PackageId runtime pack for .NET $runtimeMajor with $RequiredFile."
            }
            return $candidate.FullName
        }
        $coreRuntimeRoot = & $resolveRuntimePack 'microsoft.netcore.app.runtime.win-x64' 'LICENSE.TXT'
        $desktopRuntimeRoot = & $resolveRuntimePack 'microsoft.windowsdesktop.app.runtime.win-x64' 'LICENSE'
        $runtimeLicenseFiles = @(
            @((Join-Path $coreRuntimeRoot 'LICENSE.TXT'), 'DOTNET-RUNTIME-LICENSE.txt'),
            @((Join-Path $coreRuntimeRoot 'THIRD-PARTY-NOTICES.TXT'), 'DOTNET-RUNTIME-THIRD-PARTY-NOTICES.txt'),
            @((Join-Path $desktopRuntimeRoot 'LICENSE'), 'DOTNET-WINDOWSDESKTOP-LICENSE.txt')
        )
        foreach ($licenseFile in $runtimeLicenseFiles) {
            if (-not (Test-Path -LiteralPath $licenseFile[0] -PathType Leaf)) {
                throw "Resolved .NET runtime license is missing: $($licenseFile[0])"
            }
            Copy-Item -LiteralPath $licenseFile[0] -Destination (Join-Path $resolvedPublish $licenseFile[1]) -Force
        }
    }

    $hash = (Get-FileHash -LiteralPath (Join-Path $resolvedPublish 'Envelope.Windows.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        (Join-Path $resolvedPublish 'Envelope.Windows.exe.sha256'),
        "$hash  Envelope.Windows.exe`r`n",
        [System.Text.UTF8Encoding]::new($false))

    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    if (Test-Path -LiteralPath $archiveHashPath) {
        Remove-Item -LiteralPath $archiveHashPath -Force
    }
    Compress-Archive -Path (Join-Path $resolvedPublish '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        $archiveHashPath,
        "$archiveHash  $([System.IO.Path]::GetFileName($archivePath))`r`n",
        [System.Text.UTF8Encoding]::new($false))
    Write-Host "Windows package: $archivePath"
    Write-Host "App version: $AppVersion"
    Write-Host "Windows build name: $BuildName"
    Write-Host "Executable SHA-256: $hash"
    Write-Host "Package SHA-256: $archiveHash"
}
finally {
    Pop-Location
}
