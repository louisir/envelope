[CmdletBinding()]
param(
    [string]$EtcdExe = (Join-Path $PSScriptRoot '..\target\tools\etcd-v3.6.14-windows-amd64\etcd.exe'),
    [string]$RunRoot = (Join-Path $PSScriptRoot "..\artifacts\ha-local-$((Get-Date).ToString('yyyyMMdd-HHmmss'))")
)
$ErrorActionPreference = 'Stop'
$EtcdExe = (Resolve-Path -LiteralPath $EtcdExe).Path
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
if (Test-Path -LiteralPath $RunRoot) { throw "Use a new test data directory: $RunRoot" }
$nodes = @(
    @{Name='s1'; Client=32379; Peer=32380},
    @{Name='s2'; Client=32381; Peer=32382},
    @{Name='q'; Client=32383; Peer=32384}
)
foreach ($node in $nodes) {
    foreach ($port in @($node.Client,$node.Peer)) {
        if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
            throw "Test port $port is already occupied"
        }
    }
}
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$cluster = ($nodes | ForEach-Object { "$($_.Name)=http://127.0.0.1:$($_.Peer)" }) -join ','
$token = 'envelope-local-' + [guid]::NewGuid().ToString('N')
$started = @()
try {
    foreach ($node in $nodes) {
        $data = Join-Path $RunRoot $node.Name
        $arguments = @('--name',$node.Name,'--data-dir',('"'+$data+'"'),
            '--listen-client-urls',"http://127.0.0.1:$($node.Client)",
            '--advertise-client-urls',"http://127.0.0.1:$($node.Client)",
            '--listen-peer-urls',"http://127.0.0.1:$($node.Peer)",
            '--initial-advertise-peer-urls',"http://127.0.0.1:$($node.Peer)",
            '--initial-cluster',$cluster,'--initial-cluster-state','new',
            '--initial-cluster-token',$token,'--logger','zap','--log-level','warn')
        $process = Start-Process -FilePath $EtcdExe -ArgumentList $arguments -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $RunRoot "$($node.Name).stdout.log") `
            -RedirectStandardError (Join-Path $RunRoot "$($node.Name).stderr.log")
        $started += @{name=$node.Name; pid=$process.Id; endpoint="http://127.0.0.1:$($node.Client)"; executable=$EtcdExe}
    }
    $manifest = Join-Path $RunRoot 'processes.json'
    $started | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding utf8
    Write-Output $manifest
} catch {
    foreach ($entry in $started) {
        $process = Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
        if ($process -and $process.Path -eq $EtcdExe) { Stop-Process -Id $entry.pid }
    }
    throw
}
