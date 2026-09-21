#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [ValidateSet('Bootstrap','Verify','Snapshot')][string]$Action = 'Verify',
    [string]$EtcdCtl,
    [string]$SnapshotPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
$Bundle = (Resolve-Path -LiteralPath $Bundle).Path
if (!$EtcdCtl) { $EtcdCtl = Join-Path $repo 'target/tools/etcd-v3.6.14-windows-amd64/etcdctl.exe' }
$manifest = Get-Content (Join-Path $Bundle 'manifest.json') -Raw | ConvertFrom-Json
$node = $manifest.nodes | Where-Object id -eq 's1'
$identity = (Resolve-Path -LiteralPath (Join-Path $repo $node.key)).Path
# A loopback tunnel lets the administrator certificate stay offline on this workstation.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
$info = [Diagnostics.ProcessStartInfo]::new('ssh.exe')
$info.UseShellExecute = $false; $info.CreateNoWindow = $true
foreach ($argument in @('-N','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=10','-i',$identity,'-L',"127.0.0.1:${port}:127.0.0.1:2379","$($node.user)@$($node.ip)")) { $info.ArgumentList.Add($argument) }
$tunnel = [Diagnostics.Process]::Start($info)
$arguments = @("--endpoints=https://127.0.0.1:$port","--cacert=$Bundle/offline-pki/client-ca.crt","--cert=$Bundle/offline-pki/etcd-admin.crt","--key=$Bundle/offline-pki/etcd-admin.key",'--dial-timeout=5s','--command-timeout=15s')
function Invoke-Etcd([string[]]$Command) { & $EtcdCtl @arguments @Command; if ($LASTEXITCODE -ne 0) { throw "etcdctl failed: $($Command -join ' ')" } }
try {
    $ready = $false
    for ($attempt=0; $attempt -lt 30; $attempt++) {
        if ($tunnel.HasExited) { throw 'SSH tunnel exited.' }
        $socket = [Net.Sockets.TcpClient]::new()
        try { $socket.Connect('127.0.0.1',$port); $ready=$true; break } catch { Start-Sleep -Milliseconds 200 } finally { $socket.Dispose() }
    }
    if (!$ready) { throw 'SSH tunnel did not open.' }
    Invoke-Etcd @('endpoint','health')
    switch ($Action) {
        'Bootstrap' {
            # Intended only for fresh control stores. Fail if any identity/role already exists.
            Invoke-Etcd @('user','add','root','--no-password')
            Invoke-Etcd @('user','grant-role','root','root')
            Invoke-Etcd @('role','add','envelope-business')
            Invoke-Etcd @('role','grant-permission','envelope-business','--prefix=true','readwrite',$manifest.prefix)
            foreach ($id in @('s1','s2')) {
                Invoke-Etcd @('user','add',"envelope-$id",'--no-password')
                Invoke-Etcd @('user','grant-role',"envelope-$id",'envelope-business')
            }
            Invoke-Etcd @('auth','enable')
        }
        'Snapshot' {
            if (!$SnapshotPath) { throw '-SnapshotPath is required.' }
            if (Test-Path -LiteralPath $SnapshotPath) { throw 'Snapshot destination already exists.' }
            Invoke-Etcd @('snapshot','save',[IO.Path]::GetFullPath($SnapshotPath))
        }
    }
    Invoke-Etcd @('auth','status')
    Invoke-Etcd @('member','list','--write-out=table')
    Invoke-Etcd @('role','get','envelope-business')
    # Verify business identities can read their own prefix but cannot escape it.
    foreach ($id in @('s1','s2')) {
        $appArguments = @("--endpoints=https://127.0.0.1:$port","--cacert=$Bundle/offline-pki/client-ca.crt","--cert=$Bundle/$id/pki/app.crt","--key=$Bundle/$id/pki/app.key",'--command-timeout=10s')
        & $EtcdCtl @appArguments get $manifest.prefix --prefix --limit=1 --count-only --write-out=fields
        if ($LASTEXITCODE -ne 0) { throw "Application prefix permission failed: $id" }
        & $EtcdCtl @appArguments get /unrelated/ --prefix --limit=1 --count-only --write-out=fields 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { throw "Application identity can read outside its scope: $id" }
    }
} finally {
    if (!$tunnel.HasExited) { $tunnel.Kill(); $tunnel.WaitForExit(5000) | Out-Null }
    $tunnel.Dispose()
}
