param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$ApkPath = "",
    [string]$PublicKeyPath = ""
)

$ErrorActionPreference = "Stop"

function ConvertFrom-Base64Url {
    param([string]$Text)

    $value = $Text.Replace("-", "+").Replace("_", "/")
    switch ($value.Length % 4) {
        2 { $value += "==" }
        3 { $value += "=" }
        1 { throw "Invalid base64url length" }
    }
    return [Convert]::FromBase64String($value)
}

function Get-Utf8Bytes {
    param([string]$Text)

    return [System.Text.Encoding]::UTF8.GetBytes($Text)
}

function ConvertFrom-ManifestJson {
    param([string]$Json)

    $convertFromJson = Get-Command ConvertFrom-Json
    if ($convertFromJson.Parameters.ContainsKey("DateKind")) {
        return $Json | ConvertFrom-Json -DateKind String
    }

    return $Json | ConvertFrom-Json
}

$manifest = ConvertFrom-ManifestJson (Get-Content -LiteralPath $ManifestPath -Raw)
if ($manifest.signature.alg -ne "RSA-PSS-SHA256") {
    throw "Unsupported update manifest signature algorithm: $($manifest.signature.alg)"
}

if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
    $manifestPublicKey = [string]$manifest.signature.public_key
    if (-not [string]::IsNullOrWhiteSpace($manifestPublicKey)) {
        if ([System.IO.Path]::IsPathRooted($manifestPublicKey)) {
            $candidatePublicKeyPath = $manifestPublicKey
        }
        else {
            $manifestDir = Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).Path
            $candidatePublicKeyPath = Join-Path $manifestDir $manifestPublicKey
        }

        if (Test-Path -LiteralPath $candidatePublicKeyPath -PathType Leaf) {
            $PublicKeyPath = $candidatePublicKeyPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($PublicKeyPath)) {
        $PublicKeyPath = Join-Path $RepoRoot "apps\envelope_app\android\signing\update-manifest-public.pem"
    }
}

if (-not (Test-Path -LiteralPath $PublicKeyPath -PathType Leaf)) {
    throw "Update manifest public key not found: $PublicKeyPath"
}

$publicPem = Get-Content -LiteralPath $PublicKeyPath -Raw
$signedJson = $manifest.signed | ConvertTo-Json -Depth 16 -Compress
$signatureBytes = ConvertFrom-Base64Url $manifest.signature.value
$rsa = [System.Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem($publicPem)
    $verified = $rsa.VerifyData(
        (Get-Utf8Bytes $signedJson),
        $signatureBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pss
    )
}
finally {
    $rsa.Dispose()
}

if (-not $verified) {
    throw "Update manifest signature verification failed."
}

if (-not [string]::IsNullOrWhiteSpace($ApkPath)) {
    $expectedHash = $manifest.signed.sha256.ToString().ToLowerInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ApkPath).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "APK SHA256 mismatch: $actualHash != $expectedHash"
    }
}

Write-Host "Update manifest signature verified: $ManifestPath"
