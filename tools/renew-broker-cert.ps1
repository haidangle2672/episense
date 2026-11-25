<#
.SYNOPSIS
    Cap lai chung chi TLS (server.crt) cho broker Mosquitto cua du an EpiSense.

.DESCRIPTION
    Dung khi IP/ten may doi, hoac chung chi sap het han.
    Giu nguyen CA (ca.key, ca.crt) va khoa cua broker (server.key), vi vay KHONG phai
    nap lai firmware ESP32 vi chuyen chung chi (firmware chi ghim ca.crt).

    Cac buoc:
      1. Kiem tra Docker va file CA
      2. Xac dinh dia chi broker (IP tu do, hoac dung -Ip)
      3. Bo qua neu chung chi hien tai van khop (tru khi dung -Force)
      4. Sao luu chung chi cu vao pki\backup
      5. Tao yeu cau cap (csr) va de CA ky chung chi moi
      6. Kiem tra chung chi moi
      7. Chep vao mosquitto\certs, restart broker, kiem tra thuc te qua cong 8883

    Script khong bao gio chep ca.key ra khoi thu muc pki\.

.PARAMETER Ip
    IPv4 cua may chay broker. Bo trong de tu do theo card mang co default gateway.

.PARAMETER HostName
    Ten may ghi vao chung chi. Mac dinh la ten may Windows.

.PARAMETER ExtraNames
    Them ten hoac IP khac vao chung chi (vi du ten mien sau nay).

.PARAMETER Days
    So ngay hieu luc cua chung chi moi. Mac dinh 825.

.PARAMETER Force
    Cap lai ngay ca khi chung chi hien tai van khop dia chi va con han.

.PARAMETER NoRestart
    Chi cap va chep file, khong restart broker.

.EXAMPLE
    .\tools\renew-broker-cert.ps1

.EXAMPLE
    .\tools\renew-broker-cert.ps1 -Ip 192.168.1.40 -Force

.EXAMPLE
    .\tools\renew-broker-cert.ps1 -ExtraNames mqtt.ten-mien.com
#>
[CmdletBinding()]
param(
    [string]$Ip,
    [string]$HostName = $env:COMPUTERNAME,
    [string[]]$ExtraNames = @(),
    [ValidateRange(1, 1825)][int]$Days = 825,
    [switch]$Force,
    [switch]$NoRestart
)

function Step($n, $text) { Write-Host ""; Write-Host "[$n/7] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "  OK   $text" -ForegroundColor Green }
function Info($text)     { Write-Host "       $text" }
function Warn($text)     { Write-Host "  LUU Y $text" -ForegroundColor Yellow }
function Fail($text)     { Write-Host "  LOI  $text" -ForegroundColor Red; exit 1 }

# --- Xac dinh thu muc goc du an (script dat trong tools\ hoac o thu muc goc) ---
if (Test-Path (Join-Path $PSScriptRoot 'docker-compose.yml')) {
    $Root = $PSScriptRoot
} else {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$Pki     = Join-Path $Root 'pki'
$CertDir = Join-Path $Root 'mosquitto\certs'
$ServerCrt = Join-Path $Pki 'server.crt'
$ServerKey = Join-Path $Pki 'server.key'

# Chay openssl trong container, thu muc lam viec la pki\ (khong can cai OpenSSL cho Windows)
function ossl { docker run --rm -v "${Pki}:/pki" -w /pki alpine/openssl @args }

# ---------------------------------------------------------------------------
Step 1 "Kiem tra dieu kien"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "Khong tim thay lenh docker. Hay cai va mo Docker Desktop."
}
docker version --format '{{.Server.Version}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "Docker chua chay. Hay mo Docker Desktop, doi no san sang roi chay lai script."
}
foreach ($f in 'ca.key', 'ca.crt') {
    if (-not (Test-Path (Join-Path $Pki $f))) {
        Fail "Thieu file pki\$f. Script chi cap lai chung chi broker, khong tao CA. Hay tao CA truoc (Buoc 2b trong huong dan TLS)."
    }
}
Ok "Docker dang chay, tim thay CA trong $Pki"

# ---------------------------------------------------------------------------
Step 2 "Xac dinh dia chi broker"
if (-not $Ip) {
    $cfg = Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        Sort-Object { $_.NetIPv4Interface.InterfaceMetric } |
        Select-Object -First 1
    if (-not $cfg) {
        Fail "Khong tim thay card mang dang ra LAN. Hay chi dinh tay: -Ip 192.168.x.x"
    }
    $Ip = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
    Info "Card mang: $($cfg.InterfaceAlias)"
}
$addr = $null
if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr) -or
    $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    Fail "'$Ip' khong phai dia chi IPv4 hop le."
}
Ok "IP broker: $Ip    Ten may: $HostName"
Info "Neu IP nay khong dung voi IP ESP32 se goi toi, dung lai va chay lai voi -Ip."

# ---------------------------------------------------------------------------
Step 3 "Kiem tra chung chi hien tai"
if (Test-Path $ServerCrt) {
    Info "SAN hien tai:"
    ossl x509 -in server.crt -noout -ext subjectAltName 2>$null | ForEach-Object { Info "  $_" }

    ossl verify -CAfile ca.crt -verify_ip $Ip -verify_hostname $HostName server.crt 2>$null | Out-Null
    $matchOk = ($LASTEXITCODE -eq 0)
    ossl x509 -in server.crt -noout -checkend 2592000 2>$null | Out-Null   # con han it nhat 30 ngay?
    $dateOk = ($LASTEXITCODE -eq 0)

    if ($matchOk -and $dateOk -and -not $Force) {
        Ok "Chung chi hien tai da khop $Ip / $HostName va con han tren 30 ngay. Khong can cap lai."
        Info "Dung -Force neu van muon cap lai."
        exit 0
    }
    if (-not $matchOk) { Info "Chung chi hien tai KHONG khop dia chi moi, se cap lai." }
    elseif (-not $dateOk) { Info "Chung chi hien tai sap het han, se cap lai." }
    else { Info "Dung -Force, se cap lai." }
} else {
    Info "Chua co server.crt, se tao moi."
}

# ---------------------------------------------------------------------------
Step 4 "Sao luu chung chi cu va chuan bi khoa"
if (Test-Path $ServerCrt) {
    $backupDir = Join-Path $Pki 'backup'
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupFile = Join-Path $backupDir "server-$stamp.crt"
    Copy-Item $ServerCrt $backupFile
    Ok "Da sao luu: $backupFile"
}
if (-not (Test-Path $ServerKey)) {
    Info "Chua co server.key, tao khoa moi cho broker."
    ossl genrsa -out server.key 2048 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ServerKey)) { Fail "Khong tao duoc server.key." }
} else {
    Ok "Dung lai server.key hien co (khoa khong gan voi IP nen khong can doi)."
}

# ---------------------------------------------------------------------------
Step 5 "Tao yeu cau cap va de CA ky"
$names = @("IP:$Ip", "DNS:$Ip", "IP:127.0.0.1", "DNS:localhost", "DNS:mosquitto")
if ($HostName) { $names += "DNS:$HostName"; $names += "DNS:$HostName.local" }
foreach ($n in $ExtraNames) {
    $a = $null
    if ([System.Net.IPAddress]::TryParse($n, [ref]$a)) { $names += "IP:$n"; $names += "DNS:$n" }
    else { $names += "DNS:$n" }
}
# DNS:<ip> la phong xa: mot so ban thu vien TLS tren ESP32 chi doi chieu SAN kieu ten
$san = ($names | Select-Object -Unique) -join ','
Info "SAN se ghi: $san"

$ext = @"
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
"@
# Ghi file kieu Linux (LF, khong BOM), neu khong OpenSSL co the khong doc duoc
[System.IO.File]::WriteAllText((Join-Path $Pki 'server.ext'), ($ext.Replace("`r`n", "`n") + "`n"))

ossl req -new -key server.key -subj "/CN=$Ip" -out server.csr
if ($LASTEXITCODE -ne 0) { Fail "Tao server.csr that bai." }

ossl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days $Days -sha256 -extfile server.ext
if ($LASTEXITCODE -ne 0) { Fail "CA ky chung chi that bai." }
Ok "Da ky chung chi moi (hieu luc $Days ngay)."

# ---------------------------------------------------------------------------
Step 6 "Kiem tra chung chi moi"
ossl verify -CAfile ca.crt -verify_ip $Ip server.crt | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Chung chi moi khong qua kiem tra chuoi tin cay hoac khong khop IP $Ip." }
ossl x509 -in server.crt -noout -subject -dates -ext subjectAltName | ForEach-Object { Info $_ }
Ok "Chung chi do CA ky, khop IP $Ip."

# ---------------------------------------------------------------------------
Step 7 "Dua vao broker va kiem tra thuc te"
New-Item -ItemType Directory -Force $CertDir | Out-Null
Copy-Item $ServerCrt, $ServerKey, (Join-Path $Pki 'ca.crt') $CertDir -Force
# User 'mosquitto' trong container phai doc duoc khoa (cach tam; xem muc "Luu y" trong huong dan)
docker run --rm -v "${CertDir}:/certs" alpine chmod 644 /certs/server.key /certs/server.crt /certs/ca.crt
if ($LASTEXITCODE -ne 0) { Warn "Khong dat duoc quyen doc cho file trong mosquitto\certs." }
Ok "Da chep 3 file (ca.crt, server.crt, server.key) vao $CertDir"

if ($NoRestart) {
    Warn "Ban dung -NoRestart. Hay tu chay: docker compose restart mosquitto"
    exit 0
}

Push-Location $Root
docker compose restart mosquitto
$restartCode = $LASTEXITCODE
Pop-Location
if ($restartCode -ne 0) { Fail "Restart broker that bai. Xem: docker compose logs mosquitto" }

Info "Doi broker healthy (toi da 60 giay)..."
$deadline = (Get-Date).AddSeconds(60)
$status = ''
do {
    Start-Sleep -Seconds 2
    $status = (docker inspect -f '{{.State.Health.Status}}' episense-mosquitto 2>$null)
} until ($status -eq 'healthy' -or (Get-Date) -gt $deadline)
if ($status -ne 'healthy') {
    Fail "Broker khong len healthy (trang thai: '$status'). Xem: docker compose logs --tail 30 mosquitto"
}
Ok "Broker dang healthy."

# Kiem tra that: bat tay TLS toi cong 8883 va doi chieu chung chi broker DANG PHUC VU voi $Ip
$cmd = "echo Q | openssl s_client -connect 127.0.0.1:8883 -CAfile /certs/ca.crt -verify_ip $Ip 2>&1"
$out = docker run --rm --network container:episense-mosquitto -v "${CertDir}:/certs:ro" --entrypoint sh alpine/openssl -c $cmd | Out-String
$line = ($out -split "`r?`n" | Where-Object { $_ -match 'Verify return code' } | Select-Object -Last 1)
if ($out -match 'Verify return code: 0 \(ok\)') {
    Ok "Bat tay TLS thuc te thanh cong: $($line.Trim())"
} else {
    Warn "Bat tay TLS thuc te chua dat. $line"
    Info "Chay lai bang tay: docker compose logs --tail 30 mosquitto"
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "HOAN TAT." -ForegroundColor Green
Write-Host "Viec con lai phia ESP32:"
Write-Host "  - MQTT_HOST trong secrets.h phai la `"$Ip`" (hoac `"$HostName`" neu dung ten may)."
Write-Host "  - KHONG can sua ca_cert.h hay nap lai firmware vi chuyen chung chi."
Write-Host "  - ESP32 se tu noi lai trong toi da ~30 giay (nhip backoff), hoac bam nut EN de reset."