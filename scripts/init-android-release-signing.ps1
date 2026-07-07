param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function New-Base64UrlSecret {
    param([int]$ByteCount = 32)

    $bytes = [byte[]]::new($ByteCount)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd("=") -replace "\+", "-" -replace "/", "_"
}

$androidRoot = Join-Path $RepoRoot "apps\envelope_app\android"
$signingDir = Join-Path $androidRoot "signing"
$keyPropertiesPath = Join-Path $androidRoot "key.properties"
$keystoreRelativePath = "signing/envelope-release.p12"
$keystorePath = Join-Path $androidRoot ($keystoreRelativePath -replace "/", [IO.Path]::DirectorySeparatorChar)
$keyAlias = "envelope-release"

if ((Test-Path -LiteralPath $keyPropertiesPath) -and (Test-Path -LiteralPath $keystorePath) -and -not $Force) {
    Write-Host "Android release signing already initialized: $keyPropertiesPath"
    Write-Host "Keystore: $keystorePath"
    return
}

if ($Force -and (Test-Path -LiteralPath $keystorePath)) {
    Remove-Item -LiteralPath $keystorePath -Force
}

New-Item -ItemType Directory -Path $signingDir -Force | Out-Null

$storePassword = New-Base64UrlSecret
$keyPassword = $storePassword
$keytool = (Get-Command keytool -ErrorAction Stop).Source

& $keytool `
    -genkeypair `
    -v `
    -keystore $keystorePath `
    -storetype PKCS12 `
    -storepass $storePassword `
    -keypass $keyPassword `
    -alias $keyAlias `
    -keyalg RSA `
    -keysize 4096 `
    -validity 36500 `
    -dname "CN=Envelope Android Release, OU=Envelope, O=Envelope Project"

if ($LASTEXITCODE -ne 0) {
    throw "keytool failed with exit code $LASTEXITCODE"
}

@"
storeFile=$keystoreRelativePath
storePassword=$storePassword
keyAlias=$keyAlias
keyPassword=$keyPassword
"@ | Set-Content -LiteralPath $keyPropertiesPath -Encoding ascii

Write-Host "Created Android release signing config: $keyPropertiesPath"
Write-Host "Created Android release keystore: $keystorePath"
Write-Host "Back up both files. Losing them prevents compatible APK upgrades outside Play App Signing."
