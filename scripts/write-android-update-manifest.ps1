param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$AppVersion = "",
    [string]$VersionCode = "",
    [string]$Channel = "stable",
    [string]$BaseUrl = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd("=") -replace "\+", "-" -replace "/", "_"
}

function Get-Utf8Bytes {
    param([string]$Text)

    return [System.Text.Encoding]::UTF8.GetBytes($Text)
}

function Get-Sha256Bytes {
    param([byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return $sha256.ComputeHash($Bytes)
    }
    finally {
        $sha256.Dispose()
    }
}

function New-ManifestSigningKey {
    param(
        [string]$PrivateKeyPath,
        [string]$PublicKeyPath
    )

    $rsa = [System.Security.Cryptography.RSA]::Create(3072)
    try {
        $privatePem = $rsa.ExportPkcs8PrivateKeyPem()
        $publicPem = $rsa.ExportSubjectPublicKeyInfoPem()
        Set-Content -LiteralPath $PrivateKeyPath -Value $privatePem -Encoding ascii
        Set-Content -LiteralPath $PublicKeyPath -Value $publicPem -Encoding ascii
    }
    finally {
        $rsa.Dispose()
    }
}

$resolvedApk = Resolve-Path -LiteralPath $ApkPath
$apkFile = Get-Item -LiteralPath $resolvedApk.Path
$androidRoot = Join-Path $RepoRoot "apps\envelope_app\android"
$signingDir = Join-Path $androidRoot "signing"
$privateKeyPath = Join-Path $signingDir "update-manifest-private.pem"
$publicKeyPath = Join-Path $signingDir "update-manifest-public.pem"

New-Item -ItemType Directory -Path $signingDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $privateKeyPath) -or -not (Test-Path -LiteralPath $publicKeyPath)) {
    New-ManifestSigningKey -PrivateKeyPath $privateKeyPath -PublicKeyPath $publicKeyPath
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = [IO.Path]::ChangeExtension($apkFile.FullName, ".update.json")
}

$sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $apkFile.FullName).Hash.ToLowerInvariant()
$publicPem = Get-Content -LiteralPath $publicKeyPath -Raw
$publicHash = Get-Sha256Bytes (Get-Utf8Bytes $publicPem)
$keyId = -join ($publicHash[0..15] | ForEach-Object { $_.ToString("x2") })
$publicKeyOutputPath = Join-Path (Split-Path -Parent $OutputPath) "envelope-update-manifest-public-$keyId.pem"
Copy-Item -LiteralPath $publicKeyPath -Destination $publicKeyOutputPath -Force
$fileName = $apkFile.Name
$url = $null
if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
    $url = $BaseUrl.TrimEnd("/") + "/" + $fileName
}

$signed = [ordered]@{
    schema = "com.westwardsoft.envelope.update.v1"
    product = "envelope"
    platform = "android"
    package = "com.westwardsoft.envelope"
    channel = $Channel
    app_version = $AppVersion
    android_version_code = $VersionCode
    file_name = $fileName
    url = $url
    size_bytes = $apkFile.Length
    sha256 = $sha256
    created_at_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

$signedJson = $signed | ConvertTo-Json -Depth 16 -Compress
$privatePem = Get-Content -LiteralPath $privateKeyPath -Raw
$rsa = [System.Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem($privatePem)
    $signatureBytes = $rsa.SignData(
        (Get-Utf8Bytes $signedJson),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pss
    )
}
finally {
    $rsa.Dispose()
}

$manifest = [ordered]@{
    signed = $signed
    signature = [ordered]@{
        alg = "RSA-PSS-SHA256"
        key_id = $keyId
        public_key = (Split-Path -Leaf $publicKeyOutputPath)
        value = ConvertTo-Base64Url $signatureBytes
    }
}

$manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM

Write-Host "Update manifest: $OutputPath"
Write-Host "Manifest public key: $publicKeyOutputPath"
Write-Host "Manifest key id: $keyId"
