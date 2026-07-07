param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceQ,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceS,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceX,
    [string]$PackageName = "com.westwardsoft.envelope",
    [string]$ServerUrl = "https://node-a.example.com",
    [int]$CommandTimeoutSeconds = 60,
    [switch]$ResetIdentities,
    [switch]$SkipClearChatStores,
    [switch]$SkipGroupTests
)

$ErrorActionPreference = "Stop"

$runId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$artifactRoot = Join-Path (Resolve-Path ".").Path "artifacts\android-e2e\$runId"
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
$progressPath = Join-Path $artifactRoot "progress.log"

function Write-E2ELog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path $progressPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [string[]]$AdbArgs
    )

    if (-not $AdbArgs -or $AdbArgs.Count -eq 0) {
        throw "adb args are empty for $Device"
    }
    if ($AdbArgs | Where-Object { $_ -eq "" }) {
        throw "adb args contain an empty string for ${Device}: $($AdbArgs | ConvertTo-Json -Compress)"
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & adb -s $Device @AdbArgs 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -eq 0) {
            return $output
        }
        $outputText = $output | Out-String
        $adbDaemonUnavailable = $outputText -match "daemon still not running|cannot connect to daemon|127\.0\.0\.1:5037"
        if ($attempt -lt 2 -and $adbDaemonUnavailable) {
            & adb start-server | Out-Null
            Start-Sleep -Seconds 1
            continue
        }
        throw "adb failed for ${Device}: adb -s $Device $($AdbArgs -join ' ')`n$output"
    }
}

function ConvertTo-Base64Utf8 {
    param([Parameter(Mandatory = $true)][string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Test-EnvelopeResponseId {
    param(
        [Parameter(Mandatory = $true)][string]$Encoded,
        [Parameter(Mandatory = $true)][string]$RequestId
    )

    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
        $response = $json | ConvertFrom-Json
        return $response.request_id -eq $RequestId
    }
    catch {
        return $false
    }
}

function Invoke-EnvelopeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Extras = @{},
        [switch]$AllowFailure
    )

    Write-E2ELog "ADB start device=$Device command=$Command"
    Invoke-Adb -Device $Device -AdbArgs @("logcat", "-c") | Out-Null

    $activity = "${PackageName}/.MainActivity"
    $requestId = [Guid]::NewGuid().ToString("N")
    $adbStartArgs = @(
        "shell", "am", "start",
        "-a", "${PackageName}.ADB",
        "-n", $activity,
        "--es", "command", $Command,
        "--es", "request_id", $requestId
    )

    foreach ($key in $Extras.Keys) {
        $adbStartArgs += @("--es", [string]$key, [string]$Extras[$key])
    }

    Invoke-Adb -Device $Device -AdbArgs $adbStartArgs | Out-Null

    $deadline = (Get-Date).AddSeconds($CommandTimeoutSeconds)
    $encoded = $null
    $chunkId = $null
    $chunkTotal = 0
    $chunks = @{}
    do {
        Start-Sleep -Milliseconds 500
        $logs = & adb -s $Device logcat -d -s EnvelopeAdbBridge:I "*:S"
        if ($LASTEXITCODE -ne 0) {
            throw "adb logcat failed for $Device"
        }
        foreach ($line in $logs) {
            if ($line -match "ENVELOPE_ADB_RESULT\s+([A-Za-z0-9+/=]+)") {
                $candidate = $Matches[1]
                if (Test-EnvelopeResponseId -Encoded $candidate -RequestId $requestId) {
                    $encoded = $candidate
                }
            }
            elseif ($line -match "ENVELOPE_ADB_RESULT_CHUNK\s+(\S+)\s+(\d+)/(\d+)\s+([A-Za-z0-9+/=]*)") {
                $incomingChunkId = $Matches[1]
                $incomingIndex = [int]$Matches[2]
                if (-not $chunkId -or ($incomingChunkId -ne $chunkId -and $incomingIndex -eq 1)) {
                    $chunkId = $Matches[1]
                    $chunkTotal = [int]$Matches[3]
                    $chunks = @{}
                }
                if ($Matches[1] -eq $chunkId) {
                    $chunks[[int]$Matches[2]] = $Matches[4]
                    if ($chunks.Count -eq $chunkTotal) {
                        $parts = for ($i = 1; $i -le $chunkTotal; $i++) { $chunks[$i] }
                        $candidate = ($parts -join "")
                        if (Test-EnvelopeResponseId -Encoded $candidate -RequestId $requestId) {
                            $encoded = $candidate
                        }
                    }
                }
            }
        }
    } while (-not $encoded -and (Get-Date) -lt $deadline)

    if (-not $encoded) {
        throw "Timed out waiting for $Command result on $Device"
    }

    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    $response = $json | ConvertFrom-Json
    if (-not $response.ok -and -not $AllowFailure) {
        Write-E2ELog "ADB fail device=$Device command=$Command error=$($response.error)"
        throw "$Command failed on ${Device}: $($response.error)"
    }
    Write-E2ELog "ADB done device=$Device command=$Command ok=$($response.ok)"
    return $response
}

function Invoke-EnvelopeValue {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Extras = @{}
    )
    (Invoke-EnvelopeCommand -Device $Device -Command $Command -Extras $Extras).value
}

function Ensure-Identity {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    if ($ResetIdentities) {
        return Invoke-EnvelopeValue -Device $Device -Command "createIdentity" -Extras @{
            display_name = $DisplayName
        }
    }

    $store = Invoke-EnvelopeValue -Device $Device -Command "readStore"
    if ($store.identity) {
        return $store.identity
    }

    return Invoke-EnvelopeValue -Device $Device -Command "createIdentity" -Extras @{
        display_name = $DisplayName
    }
}

function Push-TestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemoteName
    )

    $safeName = ($RemoteName -replace '[^A-Za-z0-9._-]', '_')
    $payloadBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($LocalPath))
    $written = Invoke-EnvelopeValue -Device $Device -Command "writeTestFile" -Extras @{
        name = $safeName
        payload_base64 = $payloadBase64
    }
    return $written.path
}

function Resolve-AdbReadablePath {
    param([Parameter(Mandatory = $true)][string]$DisplayPath)

    $path = $DisplayPath.Trim() -replace "\\", "/"
    if ($path.StartsWith("/")) {
        return $path
    }
    if ($path.StartsWith("Download/")) {
        return "/sdcard/$path"
    }
    if ($path.StartsWith("Downloads/")) {
        return "/sdcard/Download/$($path.Substring(10))"
    }
    throw "Cannot resolve device file path for adb pull: $DisplayPath"
}

function Copy-DeviceFileToDevice {
    param(
        [Parameter(Mandatory = $true)][string]$FromDevice,
        [Parameter(Mandatory = $true)][string]$FromDisplayPath,
        [Parameter(Mandatory = $true)][string]$ToDevice,
        [Parameter(Mandatory = $true)][string]$ToName
    )

    $fromPath = Resolve-AdbReadablePath -DisplayPath $FromDisplayPath
    $localPath = Join-Path $artifactRoot $ToName
    Invoke-Adb -Device $FromDevice -AdbArgs @("pull", $fromPath, $localPath) | Out-Null
    return Push-TestFile -Device $ToDevice -LocalPath $localPath -RemoteName $ToName
}

function Wait-Store {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][scriptblock]$Predicate,
        [int]$TimeoutSeconds = 30
    )

    Write-E2ELog "WAIT start device=$Device timeout=${TimeoutSeconds}s"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $store = Invoke-EnvelopeValue -Device $Device -Command "readStore"
        if (& $Predicate $store) {
            Write-E2ELog "WAIT done device=$Device"
            return $store
        }
        Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
    Write-E2ELog "WAIT timeout device=$Device"
    throw "Timed out waiting for store predicate on $Device"
}

function Find-GroupId {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($group in @($Store.groups)) {
        if ($group.name -eq $Name) {
            return $group.group_id
        }
    }
    return $null
}

function Get-GroupMemberFromStore {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$KeyId
    )

    foreach ($member in @($Store.group_members)) {
        if ($member.group_id -eq $GroupId -and $member.key_id -eq $KeyId) {
            return $member
        }
    }
    return $null
}

function Get-GroupFromStore {
    param(
        [Parameter(Mandatory = $true)]$Store,
        [Parameter(Mandatory = $true)][string]$GroupId
    )

    foreach ($group in @($Store.groups)) {
        if ($group.group_id -eq $GroupId) {
            return $group
        }
    }
    return $null
}

function Assert-GroupEventsSigned {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string[]]$Types
    )

    foreach ($type in $Types) {
        $event = @($Snapshot.events) | Where-Object { $_.type -eq $type } | Select-Object -Last 1
        if (-not $event) {
            throw "group event not found: $type"
        }
        if ([string]::IsNullOrWhiteSpace([string]$event.signature)) {
            throw "group event signature is empty: $type"
        }
    }
}

function Assert-GroupEpochAdvanced {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After,
        [Parameter(Mandatory = $true)][string]$Action
    )

    if ([int64]$After.group.epoch -le [int64]$Before.group.epoch) {
        throw "group epoch did not advance after ${Action}: before=$($Before.group.epoch) after=$($After.group.epoch)"
    }
}

function Invoke-EndorseIfAccepted {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$MemberKeyId
    )

    $store = Invoke-EnvelopeValue -Device $Device -Command "readStore"
    $member = Get-GroupMemberFromStore -Store $store -GroupId $GroupId -KeyId $MemberKeyId
    if (-not $member) {
        throw "member not found for endorsement: group=$GroupId key=$MemberKeyId"
    }
    if ($member.status -eq "accepted") {
        Invoke-EnvelopeValue -Device $Device -Command "endorseGroupMember" -Extras @{ group_id = $GroupId; member_key_id = $MemberKeyId } | Out-Null
        return "endorsed"
    }
    if ($member.status -eq "active") {
        Write-E2ELog "ENDORSE skip device=$Device group=$GroupId member=$MemberKeyId status=active"
        return "already_active"
    }
    throw "member is not endorseable: group=$GroupId key=$MemberKeyId status=$($member.status)"
}

function Assert-MessageContains {
    param(
        [Parameter(Mandatory = $true)][string]$Device,
        [Parameter(Mandatory = $true)][string]$Needle,
        [int]$TimeoutSeconds = 30
    )

    Wait-Store -Device $Device -TimeoutSeconds $TimeoutSeconds -Predicate {
        param($store)
        foreach ($message in @($store.messages)) {
            if (($message.text | Out-String).Contains($Needle)) {
                return $true
            }
        }
        return $false
    } | Out-Null
}

$deviceMap = [ordered]@{
    Q = $DeviceQ
    S = $DeviceS
}
if (-not $SkipGroupTests) {
    $deviceMap["X"] = $DeviceX
}

$summary = [ordered]@{
    run_id = $runId
    artifact_root = $artifactRoot
    package = $PackageName
    server_url = $ServerUrl
    devices = $deviceMap
    steps = [ordered]@{}
    limitations = @()
}

foreach ($role in $deviceMap.Keys) {
    Invoke-Adb -Device $deviceMap[$role] -AdbArgs @("shell", "am", "force-stop", $PackageName) | Out-Null
}

$identities = [ordered]@{}
foreach ($role in $deviceMap.Keys) {
    $identities[$role] = Ensure-Identity -Device $deviceMap[$role] -DisplayName "Envelope-$role"
}
$summary.steps.identities = $identities

if (-not $SkipClearChatStores) {
    foreach ($role in $deviceMap.Keys) {
        Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "clearChatStore" | Out-Null
    }
}

$p2p = [ordered]@{}
foreach ($role in $deviceMap.Keys) {
    $p2p[$role] = Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "p2pRefresh"
}
$summary.steps.p2p_refresh = $p2p

$bundles = [ordered]@{}
foreach ($role in $deviceMap.Keys) {
    $bundles[$role] = Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "exportIntroBundle"
}

$contacts = [ordered]@{}
foreach ($role in $deviceMap.Keys) {
    foreach ($other in $deviceMap.Keys) {
        if ($role -eq $other) { continue }
        $contacts["$role->$other"] = Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "importIntroBundle" -Extras @{
            payload_base64 = (ConvertTo-Base64Utf8 $bundles[$other].bundle_json)
        }
    }
}
$summary.steps.contact_exchange = $contacts

foreach ($role in $deviceMap.Keys) {
    Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "serverRegister" -Extras @{
        server_url = $ServerUrl
    } | Out-Null
}

$p2pText = "e2e_direct_text_${runId}_Q_to_S"
$directText = Invoke-EnvelopeValue -Device $DeviceQ -Command "p2pSendText" -Extras @{
    recipient_key_id = $contacts["Q->S"].key_id
    text = $p2pText
    server_url = $ServerUrl
}
Assert-MessageContains -Device $DeviceS -Needle $p2pText

$localP2pFile = Join-Path $artifactRoot "p2p-file-$runId.txt"
Set-Content -Path $localP2pFile -Value "e2e_direct_file_$runId" -Encoding UTF8
$remoteP2pFile = Push-TestFile -Device $DeviceQ -LocalPath $localP2pFile -RemoteName "p2p-file-$runId.txt"
$directFile = Invoke-EnvelopeValue -Device $DeviceQ -Command "p2pSendFile" -Extras @{
    recipient_key_id = $contacts["Q->S"].key_id
    path = $remoteP2pFile
    name = "p2p-file-$runId.txt"
    mime = "text/plain"
    server_url = $ServerUrl
}
Assert-MessageContains -Device $DeviceS -Needle "p2p-file-$runId"
$summary.steps.direct_p2p = [ordered]@{
    text = $directText.ack
    file = $directFile.ack
}

Invoke-EnvelopeValue -Device $DeviceS -Command "p2pStop" | Out-Null
$relayTextPayload = "e2e_relay_text_${runId}_Q_to_S"
$relayText = Invoke-EnvelopeValue -Device $DeviceQ -Command "serverSendText" -Extras @{
    recipient_key_id = $contacts["Q->S"].key_id
    text = $relayTextPayload
    server_url = $ServerUrl
}
$localRelayFile = Join-Path $artifactRoot "relay-file-$runId.txt"
Set-Content -Path $localRelayFile -Value "e2e_relay_file_$runId" -Encoding UTF8
$remoteRelayFile = Push-TestFile -Device $DeviceQ -LocalPath $localRelayFile -RemoteName "relay-file-$runId.txt"
$relayFile = Invoke-EnvelopeValue -Device $DeviceQ -Command "serverSendFile" -Extras @{
    recipient_key_id = $contacts["Q->S"].key_id
    path = $remoteRelayFile
    name = "relay-file-$runId.txt"
    mime = "text/plain"
    server_url = $ServerUrl
}
$pullRelay = Invoke-EnvelopeValue -Device $DeviceS -Command "serverPullMailbox" -Extras @{
    server_url = $ServerUrl
}
Assert-MessageContains -Device $DeviceS -Needle $relayTextPayload
Assert-MessageContains -Device $DeviceS -Needle "relay-file-$runId"
Invoke-EnvelopeValue -Device $DeviceS -Command "p2pRefresh" | Out-Null
$summary.steps.server_relay = [ordered]@{
    text = $relayText.ack
    file = $relayFile.ack
    pull = $pullRelay
}

$sealedTextPayload = "e2e_sealed_text_${runId}_Q_to_S"
$sealedText = Invoke-EnvelopeValue -Device $DeviceQ -Command "sealText" -Extras @{
    recipient_key_id = $contacts["Q->S"].key_id
    text = $sealedTextPayload
}
$sealedTextRemoteOnS = Copy-DeviceFileToDevice -FromDevice $DeviceQ -FromDisplayPath $sealedText.path -ToDevice $DeviceS -ToName "sealed-text-$runId.envelope"
$unsealedText = Invoke-EnvelopeValue -Device $DeviceS -Command "importOfflineEnvelopeFile" -Extras @{
    path = $sealedTextRemoteOnS
}
Assert-MessageContains -Device $DeviceS -Needle $sealedTextPayload

$localSealFile = Join-Path $artifactRoot "offline-source-$runId.txt"
Set-Content -Path $localSealFile -Value "e2e_offline_sealed_file_$runId" -Encoding UTF8
$remoteSealFile = Push-TestFile -Device $DeviceQ -LocalPath $localSealFile -RemoteName "offline-source-$runId.txt"
$sealedFile = Invoke-EnvelopeValue -Device $DeviceQ -Command "sealFile" -Extras @{
    recipient_key_id = $contacts["Q->S"].key_id
    path = $remoteSealFile
    name = "offline-source-$runId.txt"
    mime = "text/plain"
}
$sealedFileRemoteOnS = Copy-DeviceFileToDevice -FromDevice $DeviceQ -FromDisplayPath $sealedFile.path -ToDevice $DeviceS -ToName "sealed-file-$runId.envelope"
$unsealedFile = Invoke-EnvelopeValue -Device $DeviceS -Command "importOfflineEnvelopeFile" -Extras @{
    path = $sealedFileRemoteOnS
}
Assert-MessageContains -Device $DeviceS -Needle "offline-source-$runId"
$summary.steps.offline_seal = [ordered]@{
    text_seal = $sealedText
    text_import = $unsealedText
    file_seal = $sealedFile
    file_import = $unsealedFile
    transfer_note = "Envelope files were copied across devices by adb pull/push. Bluetooth OPP UI handoff is not automated by this script."
}
$summary.limitations += "Bluetooth OPP file sending/receiving is not fully automatable through the app ADB bridge; this run validates cross-device envelope file portability with adb copy."

if ($SkipGroupTests) {
    $summary.steps.groups = [ordered]@{
        skipped = $true
        reason = "Skipped by -SkipGroupTests."
    }
    $summary.limitations += "Group chat automation was skipped by -SkipGroupTests."
}
else {
$groupResults = [ordered]@{}
foreach ($policy in @("normal", "verified", "consensus")) {
    foreach ($role in $deviceMap.Keys) {
        Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "p2pRefresh" | Out-Null
        Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "serverRegister" -Extras @{ server_url = $ServerUrl } | Out-Null
    }

    $groupName = "E2E-$policy-$runId"
    $created = Invoke-EnvelopeValue -Device $DeviceQ -Command "createGroup" -Extras @{
        name = $groupName
        policy = $policy
        member_key_ids = "$($contacts["Q->S"].key_id),$($contacts["Q->X"].key_id)"
    }
    $groupId = $created.group.group_id

    $storeS = Wait-Store -Device $DeviceS -Predicate { param($store) [bool](Find-GroupId -Store $store -Name $groupName) }
    $storeX = Wait-Store -Device $DeviceX -Predicate { param($store) [bool](Find-GroupId -Store $store -Name $groupName) }
    $groupS = Find-GroupId -Store $storeS -Name $groupName
    $groupX = Find-GroupId -Store $storeX -Name $groupName
    Invoke-EnvelopeValue -Device $DeviceS -Command "acceptGroup" -Extras @{ group_id = $groupS } | Out-Null
    Invoke-EnvelopeValue -Device $DeviceX -Command "acceptGroup" -Extras @{ group_id = $groupX } | Out-Null

    if ($policy -eq "verified") {
        Invoke-EnvelopeValue -Device $DeviceQ -Command "verifyGroupMember" -Extras @{ group_id = $groupId; member_key_id = $contacts["Q->S"].key_id } | Out-Null
        Invoke-EnvelopeValue -Device $DeviceQ -Command "verifyGroupMember" -Extras @{ group_id = $groupId; member_key_id = $contacts["Q->X"].key_id } | Out-Null
        Invoke-EnvelopeValue -Device $DeviceS -Command "verifyGroupMember" -Extras @{ group_id = $groupS; member_key_id = $contacts["S->X"].key_id } | Out-Null
        Invoke-EnvelopeValue -Device $DeviceX -Command "verifyGroupMember" -Extras @{ group_id = $groupX; member_key_id = $contacts["X->S"].key_id } | Out-Null
    }

    if ($policy -eq "consensus") {
        Invoke-EnvelopeValue -Device $DeviceQ -Command "serverPullMailbox" -Extras @{ server_url = $ServerUrl } | Out-Null
        Wait-Store -Device $DeviceQ -TimeoutSeconds 45 -Predicate {
            param($store)
            foreach ($member in @($store.group_members)) {
                if ($member.group_id -eq $groupId -and $member.key_id -eq $contacts["Q->S"].key_id -and ($member.status -eq "accepted" -or $member.status -eq "active")) {
                    return $true
                }
            }
            return $false
        } | Out-Null
        Wait-Store -Device $DeviceQ -TimeoutSeconds 45 -Predicate {
            param($store)
            foreach ($member in @($store.group_members)) {
                if ($member.group_id -eq $groupId -and $member.key_id -eq $contacts["Q->X"].key_id -and ($member.status -eq "accepted" -or $member.status -eq "active")) {
                    return $true
                }
            }
            return $false
        } | Out-Null
        Invoke-EndorseIfAccepted -Device $DeviceQ -GroupId $groupId -MemberKeyId $contacts["Q->S"].key_id | Out-Null
        Invoke-EndorseIfAccepted -Device $DeviceQ -GroupId $groupId -MemberKeyId $contacts["Q->X"].key_id | Out-Null
        Wait-Store -Device $DeviceS -Predicate {
            param($store)
            foreach ($member in @($store.group_members)) {
                if ($member.group_id -eq $groupS -and $member.key_id -eq $store.identity.key_id -and $member.status -eq "active") {
                    return $true
                }
            }
            return $false
        } | Out-Null
        Invoke-EndorseIfAccepted -Device $DeviceS -GroupId $groupS -MemberKeyId $contacts["S->X"].key_id | Out-Null
    }

    if ($policy -ne "consensus") {
        Wait-Store -Device $DeviceQ -TimeoutSeconds 45 -Predicate {
            param($store)
            $memberS = Get-GroupMemberFromStore -Store $store -GroupId $groupId -KeyId $contacts["Q->S"].key_id
            $memberX = Get-GroupMemberFromStore -Store $store -GroupId $groupId -KeyId $contacts["Q->X"].key_id
            return $memberS -and $memberX -and $memberS.status -eq "active" -and $memberX.status -eq "active"
        } | Out-Null
    }
    else {
        Wait-Store -Device $DeviceQ -TimeoutSeconds 45 -Predicate {
            param($store)
            $memberS = Get-GroupMemberFromStore -Store $store -GroupId $groupId -KeyId $contacts["Q->S"].key_id
            $memberX = Get-GroupMemberFromStore -Store $store -GroupId $groupId -KeyId $contacts["Q->X"].key_id
            return $memberS -and $memberX -and $memberS.status -eq "active" -and $memberX.status -eq "active"
        } | Out-Null
    }

    Assert-GroupEventsSigned -Snapshot $created -Types @("group_invite")
    $renamedGroupName = "$groupName-Renamed"
    $renamed = Invoke-EnvelopeValue -Device $DeviceQ -Command "renameGroup" -Extras @{
        group_id = $groupId
        name = $renamedGroupName
    }
    Assert-GroupEventsSigned -Snapshot $renamed -Types @("group_renamed")
    Assert-GroupEpochAdvanced -Before $created -After $renamed -Action "renameGroup"

    $avatarSeed = "avatar-$policy-$runId"
    $avatarUpdated = Invoke-EnvelopeValue -Device $DeviceQ -Command "updateGroupAvatar" -Extras @{
        group_id = $groupId
        avatar_seed = $avatarSeed
    }
    Assert-GroupEventsSigned -Snapshot $avatarUpdated -Types @("group_avatar_updated")
    Assert-GroupEpochAdvanced -Before $renamed -After $avatarUpdated -Action "updateGroupAvatar"
    if ($avatarUpdated.group.avatar_seed -ne $avatarSeed) {
        throw "avatar seed mismatch after update: $($avatarUpdated.group.avatar_seed) != $avatarSeed"
    }

    Wait-Store -Device $DeviceS -TimeoutSeconds 45 -Predicate {
        param($store)
        $group = Get-GroupFromStore -Store $store -GroupId $groupS
        return $group -and $group.name -eq $renamedGroupName -and $group.avatar_seed -eq $avatarSeed
    } | Out-Null
    Wait-Store -Device $DeviceX -TimeoutSeconds 45 -Predicate {
        param($store)
        $group = Get-GroupFromStore -Store $store -GroupId $groupX
        return $group -and $group.name -eq $renamedGroupName -and $group.avatar_seed -eq $avatarSeed
    } | Out-Null

    if ($policy -eq "normal") {
        $groupSealedTextPayload = "e2e_group_sealed_text_${runId}_Q_to_group"
        $groupSealedText = Invoke-EnvelopeValue -Device $DeviceQ -Command "groupSealText" -Extras @{
            group_id = $groupId
            text = $groupSealedTextPayload
        }
        $groupSealedTextRemoteOnS = Copy-DeviceFileToDevice -FromDevice $DeviceQ -FromDisplayPath $groupSealedText.path -ToDevice $DeviceS -ToName "group-sealed-text-S-$runId.envelope"
        $groupSealedTextRemoteOnX = Copy-DeviceFileToDevice -FromDevice $DeviceQ -FromDisplayPath $groupSealedText.path -ToDevice $DeviceX -ToName "group-sealed-text-X-$runId.envelope"
        $groupUnsealedTextS = Invoke-EnvelopeValue -Device $DeviceS -Command "importOfflineEnvelopeFile" -Extras @{ path = $groupSealedTextRemoteOnS }
        $groupUnsealedTextX = Invoke-EnvelopeValue -Device $DeviceX -Command "importOfflineEnvelopeFile" -Extras @{ path = $groupSealedTextRemoteOnX }
        Assert-MessageContains -Device $DeviceS -Needle $groupSealedTextPayload
        Assert-MessageContains -Device $DeviceX -Needle $groupSealedTextPayload

        $localGroupSealFile = Join-Path $artifactRoot "group-offline-source-$runId.txt"
        Set-Content -Path $localGroupSealFile -Value "e2e_group_offline_sealed_file_$runId" -Encoding UTF8
        $groupSealFileName = "group-offline-source-$runId.txt"
        $remoteGroupSealFile = Push-TestFile -Device $DeviceQ -LocalPath $localGroupSealFile -RemoteName $groupSealFileName
        $groupSealedFile = Invoke-EnvelopeValue -Device $DeviceQ -Command "groupSealFile" -Extras @{
            group_id = $groupId
            path = $remoteGroupSealFile
            name = $groupSealFileName
            mime = "text/plain"
        }
        $groupSealedFileRemoteOnS = Copy-DeviceFileToDevice -FromDevice $DeviceQ -FromDisplayPath $groupSealedFile.path -ToDevice $DeviceS -ToName "group-sealed-file-S-$runId.envelope"
        $groupSealedFileRemoteOnX = Copy-DeviceFileToDevice -FromDevice $DeviceQ -FromDisplayPath $groupSealedFile.path -ToDevice $DeviceX -ToName "group-sealed-file-X-$runId.envelope"
        $groupUnsealedFileS = Invoke-EnvelopeValue -Device $DeviceS -Command "importOfflineEnvelopeFile" -Extras @{ path = $groupSealedFileRemoteOnS }
        $groupUnsealedFileX = Invoke-EnvelopeValue -Device $DeviceX -Command "importOfflineEnvelopeFile" -Extras @{ path = $groupSealedFileRemoteOnX }
        Assert-MessageContains -Device $DeviceS -Needle $groupSealFileName
        Assert-MessageContains -Device $DeviceX -Needle $groupSealFileName

        $summary.steps.group_offline_seal = [ordered]@{
            text_seal = $groupSealedText
            text_import_s = $groupUnsealedTextS
            text_import_x = $groupUnsealedTextX
            file_seal = $groupSealedFile
            file_import_s = $groupUnsealedFileS
            file_import_x = $groupUnsealedFileX
        }
    }

    $groupText = "e2e_group_${policy}_direct_$runId"
    $groupTextSend = Invoke-EnvelopeValue -Device $DeviceQ -Command "groupSendText" -Extras @{
        group_id = $groupId
        text = $groupText
    }
    Assert-MessageContains -Device $DeviceS -Needle $groupText
    Assert-MessageContains -Device $DeviceX -Needle $groupText

    $localGroupFile = Join-Path $artifactRoot "group-$policy-direct-file-$runId.txt"
    Set-Content -Path $localGroupFile -Value "e2e_group_${policy}_direct_file_$runId" -Encoding UTF8
    $groupDirectFileName = "group-$policy-direct-file-$runId.txt"
    $remoteGroupFile = Push-TestFile -Device $DeviceQ -LocalPath $localGroupFile -RemoteName $groupDirectFileName
    $groupFileSend = Invoke-EnvelopeValue -Device $DeviceQ -Command "groupSendFile" -Extras @{
        group_id = $groupId
        path = $remoteGroupFile
        name = $groupDirectFileName
        mime = "text/plain"
        server_url = $ServerUrl
    }
    Assert-MessageContains -Device $DeviceS -Needle $groupDirectFileName
    Assert-MessageContains -Device $DeviceX -Needle $groupDirectFileName

    Invoke-EnvelopeValue -Device $DeviceX -Command "p2pStop" | Out-Null
    $groupRelayText = "e2e_group_${policy}_relay_$runId"
    $groupRelaySend = Invoke-EnvelopeValue -Device $DeviceQ -Command "groupSendText" -Extras @{
        group_id = $groupId
        text = $groupRelayText
    }
    $localGroupRelayFile = Join-Path $artifactRoot "group-$policy-relay-file-$runId.txt"
    Set-Content -Path $localGroupRelayFile -Value "e2e_group_${policy}_relay_file_$runId" -Encoding UTF8
    $groupRelayFileName = "group-$policy-relay-file-$runId.txt"
    $remoteGroupRelayFile = Push-TestFile -Device $DeviceQ -LocalPath $localGroupRelayFile -RemoteName $groupRelayFileName
    $groupRelayFileSend = Invoke-EnvelopeValue -Device $DeviceQ -Command "groupSendFile" -Extras @{
        group_id = $groupId
        path = $remoteGroupRelayFile
        name = $groupRelayFileName
        mime = "text/plain"
        server_url = $ServerUrl
    }
    $groupRelayPull = Invoke-EnvelopeValue -Device $DeviceX -Command "serverPullMailbox" -Extras @{ server_url = $ServerUrl }
    Assert-MessageContains -Device $DeviceX -Needle $groupRelayText
    Assert-MessageContains -Device $DeviceX -Needle $groupRelayFileName
    Invoke-EnvelopeValue -Device $DeviceX -Command "p2pRefresh" | Out-Null

    $left = Invoke-EnvelopeValue -Device $DeviceX -Command "leaveGroup" -Extras @{ group_id = $groupX }
    $afterLeaveQ = Wait-Store -Device $DeviceQ -Predicate {
        param($store)
        foreach ($group in @($store.groups)) {
            if ($group.group_id -eq $groupId) {
                return ($group.is_active -eq $false)
            }
        }
        return $false
    }

    $groupResults[$policy] = [ordered]@{
        created = $created
        renamed = $renamed
        avatar_updated = $avatarUpdated
        s_group_id = $groupS
        x_group_id = $groupX
        direct_text = $groupTextSend.message
        direct_file = $groupFileSend.message
        relay_text = $groupRelaySend.message
        relay_file = $groupRelayFileSend.message
        relay_pull = $groupRelayPull
        leave = $left
        final_q_group = (@($afterLeaveQ.groups) | Where-Object { $_.group_id -eq $groupId } | Select-Object -First 1)
    }
}
$summary.steps.groups = $groupResults
}

$finalStores = [ordered]@{}
foreach ($role in $deviceMap.Keys) {
    $finalStores[$role] = Invoke-EnvelopeValue -Device $deviceMap[$role] -Command "readStore"
}
$summary.steps.final_stores = $finalStores

$reportPath = Join-Path $artifactRoot "report.json"
$summary | ConvertTo-Json -Depth 60 | Set-Content -Path $reportPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 60
