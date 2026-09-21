#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$ProbeState,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(1,10)][int]$Cycles=1,
    [switch]$ConfirmFaultInjection
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(!$ConfirmFaultInjection){throw 'This test stops only Envelope business and etcd services on the current leader. Explicit -ConfirmFaultInjection is required.'}
$repo=Split-Path $PSScriptRoot -Parent
Set-Location $repo
$manifest=Get-Content (Join-Path $Bundle 'manifest.json') -Raw | ConvertFrom-Json
$probe=Join-Path $repo 'target/debug/envelope-ha-probe.exe'
$bootstrap=Join-Path $repo 'deploy/envelope-server/ha/bootstrap.json'
$ProbeState=(Resolve-Path -LiteralPath $ProbeState).Path
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
if(Test-Path -LiteralPath $evidence){throw 'Evidence directory must be new; retain failed runs.'}
New-Item -ItemType Directory -Path $evidence | Out-Null
$rounds=@()
function Invoke-Probe {
    $output=(& $probe --bootstrap $bootstrap --state $ProbeState --mode verify 2>&1 | Out-String)
    [pscustomobject]@{exit_code=$LASTEXITCODE;output=$output}
}
function Invoke-Node($node,[string]$command) {
    & ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -i (Join-Path $repo $node.key) "$($node.user)@$($node.ip)" $command
    if($LASTEXITCODE -ne 0){throw "SSH command failed on $($node.id)"}
}
for($round=1;$round -le $Cycles;$round++) {
    $baseline=Invoke-Probe
    if($baseline.exit_code -ne 0){throw "Baseline probe failed: $($baseline.output)"}
    $before=$baseline.output | ConvertFrom-Json
    if($before.service_mode -ne 'normal'){throw 'Both business replicas must be ready before fault injection.'}
    $node=$manifest.nodes | Where-Object id -eq $before.leader
    if(!$node -or $node.id -notin @('s1','s2')){throw 'Unexpected leader identity.'}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $record=[ordered]@{round=$round;started_at=[DateTimeOffset]::UtcNow;fault_node=$node.id;fault='stop Envelope business and local etcd; SSH/nginx remain';baseline=$before;attempts=@();verified=$false}
    $file=Join-Path $evidence "round-$round.json"
    try {
        Invoke-Node $node 'sudo -n systemctl stop envelope-ha envelope-etcd'
        $record.stopped_ms=$timer.ElapsedMilliseconds
        while($timer.Elapsed.TotalSeconds -lt 90) {
            $attempt=Invoke-Probe
            $record.attempts+=@([pscustomobject]@{elapsed_ms=$timer.ElapsedMilliseconds;exit_code=$attempt.exit_code;output=$attempt.output})
            $record | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 $file
            if($attempt.exit_code -eq 0) {
                $after=$attempt.output | ConvertFrom-Json
                if($after.leader -eq $node.id -or !$after.decrypted -or $after.envelope_id -ne $before.envelope_id){throw 'Invalid takeover proof.'}
                $record.recovered_ms=$timer.ElapsedMilliseconds
                $record.within_60_seconds=$timer.Elapsed.TotalSeconds -le 60
                # Confirm that a second request survives while the failed node remains stopped.
                Start-Sleep -Seconds 5
                $continuous=Invoke-Probe
                if($continuous.exit_code -ne 0){throw "Takeover was not stable: $($continuous.output)"}
                $record.continuous=$continuous.output | ConvertFrom-Json
                $record.verified=$true
                break
            }
            Start-Sleep -Seconds 1
        }
        if(!$record.verified){throw 'No verified takeover within 90 seconds.'}
    } catch {
        $record.error=$_.Exception.Message
        throw
    } finally {
        Invoke-Node $node 'sudo -n systemctl start envelope-etcd; sudo -n systemctl start envelope-ha; sudo -n systemctl is-active envelope-etcd envelope-ha'
        $record.restored_at=[DateTimeOffset]::UtcNow
        $record | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 $file
    }
    $ready=$false
    $settle=[Diagnostics.Stopwatch]::StartNew()
    while($settle.Elapsed.TotalSeconds -lt 60) {
        $check=Invoke-Probe
        if($check.exit_code -eq 0 -and ($check.output | ConvertFrom-Json).service_mode -eq 'normal'){$ready=$true;break}
        Start-Sleep -Seconds 1
    }
    if(!$ready){throw 'Replica did not return to normal within 60 seconds; no next fault was injected.'}
    $rounds+=@([pscustomobject]$record)
    $rounds | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 (Join-Path $evidence 'summary.json')
    Write-Output "Round $round verified: $($node.id) loss, restored after $($record.recovered_ms) ms."
    if(!$record.within_60_seconds){throw 'Recovery exceeded the 60 second target.'}
}
