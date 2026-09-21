#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$OpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe',
    [string]$ServerBinary,
    [string]$RecoveryBinary,
    [long]$EtcdQuotaBytes = 1073741824
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repo 'keys/ha-v2-20260920/deployment' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $repo 'keys')) + [IO.Path]::DirectorySeparatorChar
if (!$OutputDirectory.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Private deployment bundle must remain under the ignored repository keys directory.' }
if (Test-Path $OutputDirectory) { throw 'Output directory already exists; do not silently rotate a deployed CA. Choose a new directory only for an intentional fresh installation.' }
if (!(Test-Path $OpenSsl)) { throw 'OpenSSL executable not found.' }
if ($EtcdQuotaBytes -lt 268435456 -or $EtcdQuotaBytes -gt 8589934592) { throw 'Invalid etcd quota.' }
$assets = Join-Path $repo 'deploy/envelope-server/ha'
$cluster = Get-Content (Join-Path $assets 'cluster.json') -Raw | ConvertFrom-Json
$bootstrap = Get-Content (Join-Path $assets 'bootstrap.json') -Raw | ConvertFrom-Json
if ($cluster.cluster_id -ne $bootstrap.cluster_id -or $cluster.cluster_id -notmatch '^[A-Za-z0-9_-]+$' -or $cluster.control_generation -notmatch '^[1-9][0-9]*$') { throw 'Invalid or mismatched cluster scope.' }
$archive = Join-Path $repo 'target/tools/etcd-v3.6.14-linux-amd64.tar.gz'
$archiveHash = 'ffe840ff9295808e88cce2794a18a5ac87f12a5203c8314d0bf6aa119b41bac5'
if (!(Test-Path $archive) -or (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash) { throw 'etcd 3.6.14 Linux archive missing or SHA256 mismatch.' }
if ($ServerBinary -and !(Test-Path $ServerBinary -PathType Leaf)) { throw 'Server binary not found.' }
if ($RecoveryBinary -and !(Test-Path $RecoveryBinary -PathType Leaf)) { throw 'Recovery binary not found.' }
$nodes = @(
    [ordered]@{ id='s1'; ip='121.199.52.175'; user='root'; key='keys/root@121.199.52.175_wxy@aliyun/id_ed25519'; domain='envelope.iamlouis.online'; peer='67.230.178.13' },
    [ordered]@{ id='s2'; ip='67.230.178.13'; user='louis'; key='keys/louis@67.230.178.13@bandwagon/vps_ed25519'; domain='npvwxzkfdqkck.work'; peer='121.199.52.175' },
    [ordered]@{ id='q-gcp'; ip='34.3.107.22'; user='louis'; key='keys/louis@34.3.107.22@google/gcp_oregon_ed25519'; domain=''; peer='' }
)
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false)) }
function Invoke-OpenSsl([string[]]$Arguments) {
    & $OpenSsl @Arguments 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "OpenSSL failed: $($Arguments[0])" }
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
# Protect every subsequently created private key; no CA or administrator private key is uploaded.
$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $OutputDirectory /inheritance:r /grant:r "*${owner}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to restrict bundle ACL.' }
$pki = Join-Path $OutputDirectory 'offline-pki'
New-Item -ItemType Directory -Path $pki | Out-Null
function New-Ca([string]$Name) {
    Invoke-OpenSsl @('genpkey','-algorithm','EC','-pkeyopt','ec_paramgen_curve:P-256','-out',"$pki/$Name.key")
    Invoke-OpenSsl @('req','-x509','-new','-sha256','-days','3650','-key',"$pki/$Name.key",'-out',"$pki/$Name.crt",'-subj',"/CN=Envelope HA $Name",'-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign')
}
function New-Certificate([string]$Name, [string]$Ca, [string]$Subject, [string]$Ip, [string]$Eku) {
    Invoke-OpenSsl @('genpkey','-algorithm','EC','-pkeyopt','ec_paramgen_curve:P-256','-out',"$pki/$Name.key")
    Invoke-OpenSsl @('req','-new','-sha256','-key',"$pki/$Name.key",'-out',"$pki/$Name.csr",'-subj',"/CN=$Subject")
    $extensions = "basicConstraints=critical,CA:FALSE`nkeyUsage=critical,digitalSignature`nextendedKeyUsage=$Eku`n"
    if ($Ip) { $extensions += "subjectAltName=IP:$Ip,IP:127.0.0.1,DNS:localhost`n" }
    Write-Lf "$pki/$Name.ext" $extensions
    $serialBytes = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Fill($serialBytes)
    $serial = [Convert]::ToHexString($serialBytes)
    Invoke-OpenSsl @('x509','-req','-sha256','-days','397','-in',"$pki/$Name.csr",'-CA',"$pki/$Ca.crt",'-CAkey',"$pki/$Ca.key",'-set_serial',"0x$serial",'-extfile',"$pki/$Name.ext",'-out',"$pki/$Name.crt")
    Invoke-OpenSsl @('verify','-CAfile',"$pki/$Ca.crt","$pki/$Name.crt")
}
New-Ca 'client-ca'
New-Ca 'peer-ca'
New-Certificate 'etcd-admin' 'client-ca' 'root' '' 'clientAuth'
$members = ($nodes | ForEach-Object { "$($_.id)=https://$($_.ip):2380" }) -join ','
$endpoints = @($nodes | ForEach-Object { "https://$($_.ip):2379" })
foreach ($node in $nodes) {
    $id = $node.id; $ip = $node.ip
    $destination = Join-Path $OutputDirectory $id
    New-Item -ItemType Directory -Path "$destination/pki" | Out-Null
    New-Certificate "$id-etcd" 'client-ca' "etcd-$id" $ip 'serverAuth'
    New-Certificate "$id-peer" 'peer-ca' "etcd-peer-$id" $ip 'serverAuth,clientAuth'
    foreach ($ca in @('client-ca','peer-ca')) { Copy-Item "$pki/$ca.crt" "$destination/pki/$ca.crt" }
    foreach ($purpose in @('etcd','peer')) {
        foreach ($extension in @('crt','key')) { Copy-Item "$pki/$id-$purpose.$extension" "$destination/pki/$purpose.$extension" }
    }
    Copy-Item $archive "$destination/etcd.tar.gz"
    Copy-Item "$assets/install-node.sh" "$destination/install-node.sh"
    Write-Lf "$destination/node.env" @"
NODE_ID=$id
NODE_IP=$ip
PEER_IP=$($node.peer)
PUBLIC_DOMAIN=$($node.domain)
ETCD_ARCHIVE_SHA256=$archiveHash
"@
    Write-Lf "$destination/etcd.env" @"
ETCD_NAME=$id
ETCD_DATA_DIR=/var/lib/envelope-etcd
ETCD_LISTEN_CLIENT_URLS=https://0.0.0.0:2379
ETCD_ADVERTISE_CLIENT_URLS=https://${ip}:2379
ETCD_LISTEN_PEER_URLS=https://0.0.0.0:2380
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://${ip}:2380
ETCD_INITIAL_CLUSTER=$members
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=$($cluster.cluster_id)-g$($cluster.control_generation)
ETCD_CERT_FILE=/etc/envelope-ha/etcd-pki/etcd.crt
ETCD_KEY_FILE=/etc/envelope-ha/etcd-pki/etcd.key
ETCD_TRUSTED_CA_FILE=/etc/envelope-ha/etcd-pki/client-ca.crt
ETCD_CLIENT_CERT_AUTH=true
ETCD_PEER_CERT_FILE=/etc/envelope-ha/etcd-pki/peer.crt
ETCD_PEER_KEY_FILE=/etc/envelope-ha/etcd-pki/peer.key
ETCD_PEER_TRUSTED_CA_FILE=/etc/envelope-ha/etcd-pki/peer-ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true
ETCD_TLS_MIN_VERSION=TLS1.2
ETCD_HEARTBEAT_INTERVAL=500
ETCD_ELECTION_TIMEOUT=5000
ETCD_SNAPSHOT_COUNT=10000
ETCD_AUTO_COMPACTION_MODE=periodic
ETCD_AUTO_COMPACTION_RETENTION=1h
ETCD_QUOTA_BACKEND_BYTES=$EtcdQuotaBytes
ETCD_LISTEN_METRICS_URLS=http://127.0.0.1:2381
ETCD_ENABLE_GRPC_GATEWAY=false
"@
    Copy-Item "$assets/envelope-etcd.service" "$destination/envelope-etcd.service"
    Copy-Item "$assets/envelope-ha-firewall.service" "$destination/envelope-ha-firewall.service"
    Copy-Item "$assets/firewall.sh" "$destination/firewall.sh"
    if ($id -eq 'q-gcp') { continue }
    New-Certificate "$id-app" 'client-ca' "envelope-$id" $ip 'serverAuth,clientAuth'
    foreach ($extension in @('crt','key')) { Copy-Item "$pki/$id-app.$extension" "$destination/pki/app.$extension" }
    Copy-Item "$assets/cluster.json" "$destination/cluster.json"
    Copy-Item (Join-Path $repo "keys/ha-v2-20260920/$id-signing-secret") "$destination/signing-secret"
    Copy-Item "$assets/envelope-ha.service" "$destination/envelope-ha.service"
    Copy-Item "$assets/nginx-public-v2.conf" "$destination/nginx-public-v2.conf"
    Copy-Item "$assets/nginx-internal.conf" "$destination/nginx-internal.conf"
    Copy-Item "$assets/nginx-http-limits.conf" "$destination/nginx-http-limits.conf"
    if ($ServerBinary) { Copy-Item $ServerBinary "$destination/envelope-server-ha" }
    if ($RecoveryBinary) { Copy-Item $RecoveryBinary "$destination/envelope-ha-recovery" }
    $runtime = [ordered]@{
        cluster_config='/etc/envelope-ha/cluster.json'; administrator_public=$bootstrap.admin_public
        node_id=$id; signing_secret_file='/etc/envelope-ha/signing-secret'; database='/var/lib/envelope-ha/envelope.sqlite3'
        public_bind='127.0.0.1:19093'; internal_bind='127.0.0.1:19094'
        peer_url="https://$($node.peer):19444"; etcd_endpoints=@('https://127.0.0.1:2379') + @($endpoints | Where-Object { $_ -ne "https://$($node.ip):2379" })
        tls_ca='/etc/envelope-ha/app-pki/client-ca.crt'; tls_cert='/etc/envelope-ha/app-pki/app.crt'; tls_key='/etc/envelope-ha/app-pki/app.key'
        archived_configs=@(); development_loopback=$false
    }
    Write-Lf "$destination/runtime.json" ($runtime | ConvertTo-Json -Depth 10)
}
$manifest = [ordered]@{ cluster_id=$cluster.cluster_id; control_generation=$cluster.control_generation; prefix="/envelope/$($cluster.cluster_id)/g/$($cluster.control_generation)/"; nodes=$nodes; etcd_version='3.6.14'; created_at=[DateTimeOffset]::UtcNow.ToString('O') }
Write-Lf "$OutputDirectory/manifest.json" ($manifest | ConvertTo-Json -Depth 10)
Write-Host "Prepared private bundle: $OutputDirectory"
Write-Host 'No remote changes made. Offline CA and etcd administrator private keys must remain local.'
