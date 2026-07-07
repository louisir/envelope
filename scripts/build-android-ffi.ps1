param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$AndroidTarget = "aarch64-linux-android",
    [string]$Abi = "arm64-v8a"
)

$ErrorActionPreference = "Stop"

function Add-PathIfExists {
    param([string]$Path)

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $env:Path = "$Path;$env:Path"
    }
}

function Find-AndroidNdkBin {
    $candidateRoots = @()

    if ($env:ANDROID_NDK_HOME) {
        $candidateRoots += $env:ANDROID_NDK_HOME
    }
    if ($env:ANDROID_NDK_ROOT) {
        $candidateRoots += $env:ANDROID_NDK_ROOT
    }
    if ($env:ANDROID_HOME) {
        $candidateRoots += (Join-Path $env:ANDROID_HOME "ndk")
    }
    if ($env:ANDROID_SDK_ROOT) {
        $candidateRoots += (Join-Path $env:ANDROID_SDK_ROOT "ndk")
    }

    $defaultSdk = Join-Path $env:LOCALAPPDATA "Android\Sdk\ndk"
    $candidateRoots += $defaultSdk

    foreach ($root in $candidateRoots | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        if (Test-Path -LiteralPath (Join-Path $root "toolchains\llvm\prebuilt\windows-x86_64\bin")) {
            return (Join-Path $root "toolchains\llvm\prebuilt\windows-x86_64\bin")
        }

        $versioned = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending

        foreach ($dir in $versioned) {
            $bin = Join-Path $dir.FullName "toolchains\llvm\prebuilt\windows-x86_64\bin"
            if (Test-Path -LiteralPath $bin) {
                return $bin
            }
        }
    }

    throw "Android NDK not found. Install it with Android Studio SDK Manager, or set ANDROID_NDK_HOME."
}

Add-PathIfExists (Join-Path $env:USERPROFILE "scoop\apps\rustup\current\.cargo\bin")
Add-PathIfExists (Join-Path $env:USERPROFILE ".cargo\bin")

$ndkBin = Find-AndroidNdkBin
Add-PathIfExists $ndkBin

$destDir = Join-Path $RepoRoot "apps\envelope_app\android\app\src\main\jniLibs\$Abi"
$source = Join-Path $RepoRoot "target\$AndroidTarget\release\libenvelope_ffi.so"
$dest = Join-Path $destDir "libenvelope_ffi.so"

Push-Location $RepoRoot
try {
    rustup target add $AndroidTarget
    cargo build -p envelope-ffi --target $AndroidTarget --release

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Rust build completed, but $source was not created."
    }

    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest -Force

    Write-Host "Android FFI library copied to $dest"
}
finally {
    Pop-Location
}
