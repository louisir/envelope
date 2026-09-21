[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Read-Text {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Parity input is missing: $path"
    }
    return [System.IO.File]::ReadAllText($path)
}

function Get-CaptureSet {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    return @(
        [regex]::Matches($Text, $Pattern) |
            ForEach-Object { $_.Groups['name'].Value } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Assert-SameSet {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string[]]$Actual
    )

    $difference = @(Compare-Object -ReferenceObject $Expected -DifferenceObject $Actual)
    if ($difference.Count -gt 0) {
        $detail = $difference | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
        throw "$Label differs:`n$($detail -join [Environment]::NewLine)"
    }
}

function Assert-ContainsAll {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Values
    )

    $missing = @($Values | Where-Object {
        $Text.IndexOf($_, [System.StringComparison]::Ordinal) -lt 0
    })
    if ($missing.Count -gt 0) {
        throw "$Label is missing shared contract values: $($missing -join ', ')"
    }
}

$rustFfi = Read-Text 'crates\envelope-ffi\src\lib.rs'
$androidFfi = Read-Text 'apps\envelope_app\lib\envelope_native.dart'
$windowsFfi = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Native\NativeMethods.cs'

$rustExports = Get-CaptureSet $rustFfi 'pub\s+extern\s+"C"\s+fn\s+(?<name>envelope_ffi_[A-Za-z0-9_]+)'
$androidImports = Get-CaptureSet $androidFfi '(?<name>envelope_ffi_[A-Za-z0-9_]+)'
$windowsImports = Get-CaptureSet $windowsFfi 'EntryPoint\s*=\s*"(?<name>envelope_ffi_[A-Za-z0-9_]+)"'

if ($rustExports.Count -eq 0) {
    throw 'No Rust FFI exports were discovered.'
}
Assert-SameSet 'Android/Rust FFI symbol set' $rustExports $androidImports
Assert-SameSet 'Windows/Rust FFI symbol set' $rustExports $windowsImports

$androidMain = Read-Text 'apps\envelope_app\lib\main.dart'
$androidManifest = Read-Text 'apps\envelope_app\android\app\src\main\AndroidManifest.xml'
$androidActivity = Read-Text 'apps\envelope_app\android\app\src\main\kotlin\com\iamlouis\envelope\MainActivity.kt'
$androidDb = Read-Text 'apps\envelope_app\lib\android_db_store.dart'
$androidMailbox = Read-Text 'apps\envelope_app\lib\android_mailbox_reliability.dart'
$windowsEngine = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Application\EnvelopeClientEngine.cs'
$windowsFiles = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Application\EnvelopeClientEngine.Files.cs'
$windowsGroups = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Application\EnvelopeClientEngine.Groups.cs'
$windowsOfflineGroups = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Application\EnvelopeClientEngine.OfflineGroups.cs'
$windowsFileTransfer = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Files\FileTransferService.cs'
$windowsState = Read-Text 'apps\envelope_windows\Envelope.Windows.Core\Domain\ClientState.cs'
$windowsShell = Read-Text 'apps\envelope_windows\Envelope.Windows\Services\WindowsShellIntegration.cs'
$windowsExternalLaunch = Read-Text 'apps\envelope_windows\Envelope.Windows\Services\ExternalLaunchRequest.cs'

$sharedWireValues = @(
    'ENVELOPE_STREAM_V1',
    'ENVELOPE_GROUP_STREAM_V1',
    'application/vnd.westwardsoft.envelope.file-manifest+json',
    'application/vnd.westwardsoft.envelope.file-chunk+json',
    'application/vnd.westwardsoft.envelope.group-control+json',
    'application/vnd.westwardsoft.envelope.contact-control+json',
    'application/vnd.westwardsoft.envelope.offline-file-manifest+json',
    'application/vnd.westwardsoft.envelope.offline-file-chunk'
)
$windowsContracts = $windowsEngine + $windowsFiles + $windowsOfflineGroups
Assert-ContainsAll 'Android wire contract' $androidMain $sharedWireValues
Assert-ContainsAll 'Windows wire contract' $windowsContracts $sharedWireValues

Assert-ContainsAll 'Android external-open contract' ($androidManifest + $androidActivity) @(
    'android:scheme="envelope"',
    'android:host="yourturn"',
    'android:path="/open"',
    'application/vnd.westwardsoft.envelope',
    'uri.query != null',
    'uri.fragment != null'
)
Assert-ContainsAll 'Windows external-open contract' ($windowsShell + $windowsExternalLaunch) @(
    'envelope://yourturn/open',
    'application/vnd.westwardsoft.envelope'
)

Assert-ContainsAll 'Android file limits' $androidMain @(
    '64 * 1024 * 1024',
    '4 * 1024 * 1024',
    '256 * 1024 * 1024'
)
Assert-ContainsAll 'Windows file limits' ($windowsFileTransfer + $windowsFiles) @(
    '64L * 1024 * 1024',
    '4 * 1024 * 1024',
    '256L * 1024 * 1024'
)

Assert-ContainsAll 'Android durable client state' $androidDb @(
    'pending_envelopes',
    'is_read INTEGER NOT NULL DEFAULT 1'
)
Assert-ContainsAll 'Windows durable client state' $windowsState @(
    'PendingEnvelopeRecord',
    'bool IsRead = true'
)

Assert-ContainsAll 'Android mailbox reliability state' ($androidDb + $androidMailbox) @(
    'mailbox_quarantine',
    'deferred_mailbox_envelopes',
    'androidMaximumMailboxQuarantineRecords = 1000',
    'androidMaximumDeferredMailboxEnvelopeCount = 256',
    'androidMaximumDeferredMailboxEnvelopeBytes = 12 * 1024 * 1024',
    'androidMaximumDeferredMailboxTotalBytes = 64 * 1024 * 1024',
    'Duration(days: 7)',
    'authentication_failed',
    'missing_prerequisite'
)
Assert-ContainsAll 'Windows mailbox reliability state' ($windowsEngine + $windowsState) @(
    'MailboxQuarantineRecord',
    'DeferredMailboxEnvelopeRecord',
    'MaximumDeferredMailboxEnvelopeCount = 256',
    'MaximumDeferredMailboxEnvelopeBytes = 12 * 1024 * 1024',
    'MaximumDeferredMailboxTotalBytes = 64L * 1024 * 1024',
    'TimeSpan.FromDays(7)',
    'authentication_failed',
    'missing_prerequisite'
)
Assert-ContainsAll 'Android durable group control fan-out' ($androidMain + $androidDb) @(
    'group-event:',
    'AndroidPendingEnvelopeKind.groupControl',
    'stageGroupControlTransition',
    'importGroupControlTransition',
    'decodeAndroidGroupControlState',
    '_deliverAndroidPendingEnvelope(child)'
)
Assert-ContainsAll 'Windows durable group control fan-out' $windowsGroups @(
    'group-event:',
    'StageAndDeliverGroupBroadcastCoreAsync',
    'StageOutboundBatchCoreAsync',
    'DeliverEnvelopeCoreAsync'
)

Assert-ContainsAll 'Android five-page shell' $androidMain @(
    'enum _AndroidHomeTab { about, contacts, chat, unseal, settings }'
)
foreach ($page in @('About', 'Contacts', 'Chat', 'Unseal', 'Settings')) {
    $null = Read-Text "apps\envelope_windows\Envelope.Windows\Views\${page}Page.xaml"
    $null = Read-Text "apps\envelope_windows\Envelope.Windows\ViewModels\${page}ViewModel.cs"
}

Write-Host "[PASS] Android and Windows import the same $($rustExports.Count) Rust FFI symbols."
Write-Host '[PASS] Offline-stream magic, payload MIME values, deep link, file association, and file limits align.'
Write-Host '[PASS] Both clients persist fan-out outbox children and unread state.'
Write-Host '[PASS] Both clients quarantine mailbox poison, defer bounded causal items, and durably retry group control fan-out.'
Write-Host '[PASS] Both product clients expose About, Contacts, Chat, Unseal, and Settings pages.'
