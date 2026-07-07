param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [ValidateSet("debug", "release")]
    [string]$Mode = "debug",
    [string]$TargetPlatform = "android-arm64",
    [string]$ProxyHost = "127.0.0.1",
    [string]$ProxyPort = "10808",
    [string]$AppVersion = "",
    [string]$BuildName = "",
    [int]$BuildNumber = 0,
    [string]$UpdateChannel = "stable",
    [string]$UpdateBaseUrl = "",
    [switch]$NoProxy,
    [switch]$SkipFfiBuild,
    [switch]$SkipReleaseSigningInit,
    [switch]$SkipUpdateManifest,
    [switch]$EnableAdbBridge
)

$ErrorActionPreference = "Stop"

function Add-PathIfExists {
    param([string]$Path)

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $env:Path = "$Path;$env:Path"
    }
}

function Invoke-ManifestScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Arguments
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwsh) {
            & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
            if ($LASTEXITCODE -ne 0) {
                throw "$ScriptPath failed with exit code $LASTEXITCODE"
            }
            return
        }
    }

    if ($Arguments.Count % 2 -ne 0) {
        throw "Manifest script arguments must be -Name value pairs: $($Arguments -join ' ')"
    }
    $scriptArguments = @{}
    for ($i = 0; $i -lt $Arguments.Count; $i += 2) {
        $name = $Arguments[$i]
        if (-not $name.StartsWith("-", [System.StringComparison]::Ordinal)) {
            throw "Manifest script argument name must start with '-': $name"
        }
        $scriptArguments[$name.TrimStart("-")] = $Arguments[$i + 1]
    }
    & $ScriptPath @scriptArguments
}

Add-PathIfExists (Join-Path $env:USERPROFILE "scoop\apps\flutter\3.44.0\bin")
Add-PathIfExists (Join-Path $env:USERPROFILE "scoop\apps\flutter\current\bin")
Add-PathIfExists (Join-Path $env:USERPROFILE "scoop\persist\rustup\.cargo\bin")
Add-PathIfExists (Join-Path $env:USERPROFILE ".cargo\bin")

if (-not $NoProxy) {
    $proxyArgs = "-Dhttp.proxyHost=$ProxyHost -Dhttp.proxyPort=$ProxyPort -Dhttps.proxyHost=$ProxyHost -Dhttps.proxyPort=$ProxyPort"
    $env:JAVA_OPTS = (($env:JAVA_OPTS, $proxyArgs) -join " ").Trim()
    $env:GRADLE_OPTS = (($env:GRADLE_OPTS, $proxyArgs) -join " ").Trim()
    $env:HTTP_PROXY = "http://$ProxyHost`:$ProxyPort"
    $env:HTTPS_PROXY = "http://$ProxyHost`:$ProxyPort"
}

if (-not $SkipFfiBuild) {
    & (Join-Path $RepoRoot "scripts\build-android-ffi.ps1") -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Android FFI build failed with exit code $LASTEXITCODE"
    }
}

if ([string]::IsNullOrWhiteSpace($AppVersion)) {
    $AppVersion = "v1.0.0.$((Get-Date).ToString("yyyyMMddHHmmss.fff"))"
}

if ([string]::IsNullOrWhiteSpace($BuildName)) {
    $candidateBuildName = $AppVersion.Trim()
    if ($candidateBuildName.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidateBuildName = $candidateBuildName.Substring(1)
    }
    if ($candidateBuildName -match '^(\d+\.\d+\.\d+)') {
        $BuildName = $Matches[1]
    }
    else {
        $BuildName = "1.0.0"
    }
}

if ($BuildNumber -le 0) {
    $versionEpoch = [DateTime]::SpecifyKind([DateTime]"2026-01-01T00:00:00", [DateTimeKind]::Utc)
    $BuildNumber = [int][Math]::Max(
        1,
        [Math]::Floor(((Get-Date).ToUniversalTime() - $versionEpoch).TotalSeconds)
    )
}

if ($Mode -eq "release" -and -not $SkipReleaseSigningInit) {
    & (Join-Path $RepoRoot "scripts\init-android-release-signing.ps1") -RepoRoot $RepoRoot
}

$appRoot = Join-Path $RepoRoot "apps\envelope_app"
$manualSource = Join-Path $RepoRoot "docs\android-user-manual.html"
$manualAsset = Join-Path $appRoot "assets\manual\android-user-manual.html"
if (-not (Test-Path -LiteralPath $manualSource)) {
    throw "Android user manual source not found: $manualSource"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manualAsset) | Out-Null
Copy-Item -LiteralPath $manualSource -Destination $manualAsset -Force

Push-Location $appRoot
try {
    $buildArgs = @(
        "build",
        "apk",
        "--$Mode",
        "--target-platform",
        $TargetPlatform,
        "--android-skip-build-dependency-validation",
        "--build-name",
        $BuildName,
        "--build-number",
        $BuildNumber.ToString(),
        "--dart-define=ENVELOPE_APP_VERSION=$AppVersion"
    )
    if ($EnableAdbBridge) {
        $buildArgs += "--dart-define=ENVELOPE_ADB_BRIDGE=true"
    }
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Android $Mode build failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

$apkDir = Join-Path $appRoot "build\app\outputs\flutter-apk"
$defaultApk = Join-Path $apkDir "app-$Mode.apk"
if (Test-Path -LiteralPath $defaultApk) {
    $safeVersion = $AppVersion -replace '[^A-Za-z0-9._-]', '_'
    $versionedApk = Join-Path $apkDir "envelope-$safeVersion-$Mode.apk"
    Copy-Item -LiteralPath $defaultApk -Destination $versionedApk -Force
    Write-Host "App version: $AppVersion"
    Write-Host "Android build name: $BuildName"
    Write-Host "Android build number: $BuildNumber"
    Write-Host "Versioned APK: $versionedApk"
    if ($Mode -eq "release" -and -not $SkipUpdateManifest) {
        $writeManifestArgs = @(
            "-RepoRoot", $RepoRoot,
            "-ApkPath", $versionedApk,
            "-AppVersion", $AppVersion,
            "-VersionCode", $BuildNumber.ToString(),
            "-Channel", $UpdateChannel
        )
        if (-not [string]::IsNullOrWhiteSpace($UpdateBaseUrl)) {
            $writeManifestArgs += @("-BaseUrl", $UpdateBaseUrl)
        }
        Invoke-ManifestScript `
            -ScriptPath (Join-Path $RepoRoot "scripts\write-android-update-manifest.ps1") `
            -Arguments $writeManifestArgs
        $manifestPath = [IO.Path]::ChangeExtension($versionedApk, ".update.json")
        Invoke-ManifestScript `
            -ScriptPath (Join-Path $RepoRoot "scripts\verify-android-update-manifest.ps1") `
            -Arguments @(
                "-RepoRoot", $RepoRoot,
                "-ManifestPath", $manifestPath,
                "-ApkPath", $versionedApk
            )
    }
}
