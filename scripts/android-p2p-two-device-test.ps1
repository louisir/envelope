param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceA,
    [Parameter(Mandatory = $true)]
    [string]$DeviceB,
    [string]$PackageName = "com.westwardsoft.envelope",
    [int]$CommandTimeoutSeconds = 45,
    [switch]$ResetIdentities,
    [switch]$ClearChatStores
)

$ErrorActionPreference = "Stop"

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Device,
        [Parameter(Mandatory = $true)]
        [string[]]$AdbArgs
    )

    & adb -s $Device @AdbArgs
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed for ${Device}: adb -s $Device $($AdbArgs -join ' ')"
    }
}

function ConvertTo-Base64Utf8 {
    param([Parameter(Mandatory = $true)][string]$Text)

    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Invoke-EnvelopeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Device,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [hashtable]$Extras = @{}
    )

    Invoke-Adb -Device $Device -AdbArgs @("logcat", "-c")

    $activity = "$PackageName/.MainActivity"
    $args = @(
        "shell", "am", "start",
        "-a", "$PackageName.ADB",
        "-n", $activity,
        "--es", "command", $Command
    )

    foreach ($key in $Extras.Keys) {
        $args += @("--es", [string]$key, [string]$Extras[$key])
    }

    Invoke-Adb -Device $Device -AdbArgs $args | Out-Null

    $deadline = (Get-Date).AddSeconds($CommandTimeoutSeconds)
    $encoded = $null
    do {
        Start-Sleep -Milliseconds 500
        $logs = & adb -s $Device logcat -d -s EnvelopeAdbBridge:I "*:S"
        if ($LASTEXITCODE -ne 0) {
            throw "adb logcat failed for $Device"
        }

        foreach ($line in $logs) {
            if ($line -match "ENVELOPE_ADB_RESULT\s+([A-Za-z0-9+/=]+)") {
                $encoded = $Matches[1]
            }
        }
    } while (-not $encoded -and (Get-Date) -lt $deadline)

    if (-not $encoded) {
        throw "Timed out waiting for $Command result on $Device"
    }

    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    $response = $json | ConvertFrom-Json
    if (-not $response.ok) {
        throw "$Command failed on ${Device}: $($response.error)"
    }
    return $response.value
}

function Ensure-EnvelopeIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Device,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if ($ResetIdentities) {
        return Invoke-EnvelopeCommand -Device $Device -Command "createIdentity" -Extras @{
            display_name = $DisplayName
        }
    }

    $store = Invoke-EnvelopeCommand -Device $Device -Command "readStore"
    if ($store.identity) {
        return $store.identity
    }

    return Invoke-EnvelopeCommand -Device $Device -Command "createIdentity" -Extras @{
        display_name = $DisplayName
    }
}

$identityA = Ensure-EnvelopeIdentity -Device $DeviceA -DisplayName "Envelope-A"
$identityB = Ensure-EnvelopeIdentity -Device $DeviceB -DisplayName "Envelope-B"

if ($ClearChatStores) {
    Invoke-EnvelopeCommand -Device $DeviceA -Command "clearChatStore" | Out-Null
    Invoke-EnvelopeCommand -Device $DeviceB -Command "clearChatStore" | Out-Null
}

$ticketA = Invoke-EnvelopeCommand -Device $DeviceA -Command "p2pRefresh"
$ticketB = Invoke-EnvelopeCommand -Device $DeviceB -Command "p2pRefresh"

$bundleA = Invoke-EnvelopeCommand -Device $DeviceA -Command "exportIntroBundle"
$bundleB = Invoke-EnvelopeCommand -Device $DeviceB -Command "exportIntroBundle"
$contactBOnA = Invoke-EnvelopeCommand -Device $DeviceA -Command "importIntroBundle" -Extras @{
    payload_base64 = ConvertTo-Base64Utf8 $bundleB.bundle_json
}
$contactAOnB = Invoke-EnvelopeCommand -Device $DeviceB -Command "importIntroBundle" -Extras @{
    payload_base64 = ConvertTo-Base64Utf8 $bundleA.bundle_json
}

$sendAText = "双机 P2P A->B：$(Get-Date -Format o)"
$sendBText = "双机 P2P B->A：$(Get-Date -Format o)"

$sendA = Invoke-EnvelopeCommand -Device $DeviceA -Command "p2pSendText" -Extras @{
    recipient_key_id = $contactBOnA.key_id
    payload_base64 = ConvertTo-Base64Utf8 $sendAText
}
$sendB = Invoke-EnvelopeCommand -Device $DeviceB -Command "p2pSendText" -Extras @{
    recipient_key_id = $contactAOnB.key_id
    payload_base64 = ConvertTo-Base64Utf8 $sendBText
}

$storeA = Invoke-EnvelopeCommand -Device $DeviceA -Command "readStore"
$storeB = Invoke-EnvelopeCommand -Device $DeviceB -Command "readStore"

[PSCustomObject]@{
    device_a = $DeviceA
    device_b = $DeviceB
    identity_a = $identityA
    identity_b = $identityB
    ticket_a = $ticketA
    ticket_b = $ticketB
    contact_b_on_a = $contactBOnA
    contact_a_on_b = $contactAOnB
    send_a_to_b = $sendA.ack
    send_b_to_a = $sendB.ack
    store_a_messages = @($storeA.messages).Count
    store_b_messages = @($storeB.messages).Count
    store_a = $storeA
    store_b = $storeB
} | ConvertTo-Json -Depth 20
