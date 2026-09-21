#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][ValidateSet('prerequisites','etcd','runtime','acme','proxy','verify')][string]$Phase,
    [ValidateSet('s1','s2','q-gcp')][string[]]$Nodes = @('s1','s2','q-gcp'),
    [string]$AcmeEmail
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
$manifest = Get-Content (Join-Path $Bundle 'manifest.json') -Raw | ConvertFrom-Json
if ($AcmeEmail -and $AcmeEmail -notmatch '^[A-Za-z0-9._+%-]+@[A-Za-z0-9.-]+$') { throw 'Invalid ACME email.' }
if ($Phase -eq 'acme' -and ($Nodes.Count -ne 1 -or $Nodes[0] -ne 's1')) { throw 'ACME phase requires -Nodes s1.' }
if ($Phase -in @('runtime','proxy') -and $Nodes -contains 'q-gcp') { throw 'Q is a control voter only; select -Nodes s1,s2.' }
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8)
foreach ($node in $manifest.nodes | Where-Object { $_.id -in $Nodes }) {
    $identity = (Resolve-Path -LiteralPath (Join-Path $repo $node.key)).Path
    $sshOptions = @('-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8','-i',$identity)
    $destination = "$($node.user)@$($node.ip)"
    $remote = "/var/tmp/envelope-ha-stage-$stamp-$($node.id)"
    & ssh @sshOptions $destination "umask 077; mkdir '$remote'"
    if ($LASTEXITCODE -ne 0) { throw "SSH staging failed: $($node.id)" }
    # Only one node's leaf certificates and secret are transferred. offline-pki is never selected.
    $names = @('node.env','install-node.sh') + @(switch ($Phase) {
        'etcd' { 'etcd.tar.gz'; 'etcd.env'; 'pki'; 'firewall.sh'; 'envelope-ha-firewall.service'; 'envelope-etcd.service' }
        'runtime' { 'envelope-server-ha'; 'envelope-ha-recovery'; 'pki'; 'cluster.json'; 'runtime.json'; 'signing-secret'; 'envelope-ha.service' }
        'proxy' { 'nginx-public-v2.conf'; 'nginx-http-limits.conf'; 'nginx-internal.conf' }
    })
    $files = @($names | ForEach-Object { Get-Item -LiteralPath (Join-Path (Join-Path $Bundle $node.id) $_) })
    & scp @sshOptions -r @($files.FullName) "${destination}:${remote}/"
    if ($LASTEXITCODE -ne 0) { throw "SCP failed: $($node.id)" }
    $command = "sudo -n bash '$remote/install-node.sh' '$remote' '$Phase'"
    if ($Phase -eq 'acme' -and $AcmeEmail) { $command += " '$AcmeEmail'" }
    & ssh @sshOptions $destination $command
    if ($LASTEXITCODE -ne 0) { throw "Phase $Phase failed on $($node.id); stage retained at $remote for inspection." }
    # Remove only files we just uploaded; no recursive deletion and no unrelated remote paths.
    & ssh @sshOptions $destination "find '$remote' -type f -delete; find '$remote' -depth -type d -empty -delete"
    if ($LASTEXITCODE -ne 0) { Write-Warning "Inspect and remove private stage $remote on $($node.id)." }
}
