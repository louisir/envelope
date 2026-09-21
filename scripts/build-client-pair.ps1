[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$AppVersion = '',
    [string]$BuildName = '',
    [ValidateSet('debug', 'release')]
    [string]$AndroidMode = 'release',
    [switch]$SkipAndroidFfiBuild,
    [switch]$SkipAndroidUpdateManifest,
    [switch]$WindowsFrameworkDependent,
    [switch]$SkipWindowsVerification
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

& (Join-Path $RepoRoot 'scripts\verify-client-parity.ps1') -RepoRoot $RepoRoot
if ($LASTEXITCODE -ne 0) {
    throw "Client parity verification failed with exit code $LASTEXITCODE"
}

$androidArguments = @{
    RepoRoot = $RepoRoot
    Mode = $AndroidMode
    AppVersion = $AppVersion
    BuildName = $BuildName
}
if ($SkipAndroidFfiBuild) {
    $androidArguments.SkipFfiBuild = $true
}
if ($SkipAndroidUpdateManifest) {
    $androidArguments.SkipUpdateManifest = $true
}
& (Join-Path $RepoRoot 'scripts\build-android-apk.ps1') @androidArguments
if ($LASTEXITCODE -ne 0) {
    throw "Android build failed with exit code $LASTEXITCODE"
}

$windowsArguments = @{
    AppVersion = $AppVersion
    BuildName = $BuildName
}
if (-not $WindowsFrameworkDependent) {
    $windowsArguments.SelfContained = $true
}
if ($SkipWindowsVerification) {
    $windowsArguments.SkipVerification = $true
}
& (Join-Path $RepoRoot 'scripts\build-windows-wpf.ps1') @windowsArguments
if ($LASTEXITCODE -ne 0) {
    throw "Windows build failed with exit code $LASTEXITCODE"
}

Write-Host "[PASS] Android and Windows packages share AppVersion $AppVersion and BuildName $BuildName."
