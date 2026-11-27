<#
.SYNOPSIS
    Cap chung chi TLS rieng cho broker Mosquitto tren VPS (khong dung vao chung chi o nha).

.DESCRIPTION
    Dung lai CA trong pki\ (ca.key khong roi khoi may nay) nhung tao khoa va chung chi
    RIENG trong pki\vps\. Ket qua: pki\vps\server.key va pki\vps\server.crt.

.PARAMETER Ip
    IPv4 cong khai cua VPS.

.PARAMETER ExtraNames
    Ten mien hoac IP khac ghi them vao chung chi (vi du mqtt.ten-mien.com).

.PARAMETER NewKey
    Tao lai khoa. Mac dinh dung lai khoa cu neu da co, de khi them ten mien chi can chep server.crt.

.EXAMPLE
    .\tools\issue-vps-cert.ps1 -Ip 160.250.5.157

.EXAMPLE
    .\tools\issue-vps-cert.ps1 -Ip 160.250.5.157 -ExtraNames mqtt.ten-mien.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [string[]]$ExtraNames = @(),
    [ValidateRange(1, 1825)][int]$Days = 825,
    [switch]$NewKey
)

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Pki = Join-Path $Root 'pki'
$Out = Join-Path $Pki 'vps'

# Chay openssl trong container, thu muc lam viec la pki\
function ossl { docker run --rm -v "${Pki}:/pki" -w /pki alpine/openssl @args }
function Check($msg) { if ($LASTEXITCODE -ne 0) { throw $msg } }

# --- 1. Dieu kien ---
docker version --format '{{.Server.Version}}' 2>$null | Out-Null
Check "Docker chua chay. Hay mo Docker Desktop."
foreach ($f in 'ca.key', 'ca.crt') {
    if (-not (Test-Path (Join-Path $Pki $f))) { throw "Thieu pki\$f" }
}
$addr = $null
if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$addr) -or
    $addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "'$Ip' khong phai dia chi IPv4 hop le."
}
New-Item -ItemType Directory -Force $Out | Out-Null

# --- 2. Khoa rieng cho VPS (khac khoa broker o nha) ---
if ($NewKey -or -not (Test-Path (Join-Path $Out 'server.key'))) {
    ossl genrsa -out vps/server.key 2048 2>$null | Out-Null
    Check "Khong tao duoc khoa."
    Write-Host "Da tao khoa moi: pki\vps\server.key"
}
else {
    Write-Host "Dung lai khoa hien co: pki\vps\server.key"
}

# --- 3. Danh sach ten trong chung chi (SAN) ---
# DNS:<ip> la phong xa: mot so ban thu vien TLS tren ESP32 chi doi chieu SAN kieu ten
$names = @("IP:$Ip", "DNS:$Ip", "IP:127.0.0.1", "DNS:localhost", "DNS:mosquitto")
foreach ($n in $ExtraNames) {
    $a = $null
    if ([System.Net.IPAddress]::TryParse($n, [ref]$a)) { $names += "IP:$n"; $names += "DNS:$n" }
    else { $names += "DNS:$n" }
}
$san = ($names | Select-Object -Unique) -join ','
Write-Host "SAN se ghi: $san"

$ext = @"
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
"@
# Ghi file kieu Linux (LF, khong BOM), neu khong OpenSSL co the khong doc duoc
[System.IO.File]::WriteAllText((Join-Path $Out 'server.ext'), ($ext.Replace("`r`n", "`n") + "`n"))

# --- 4. Tao yeu cau cap va de CA ky ---
ossl req -new -key vps/server.key -subj "/CN=$Ip" -out vps/server.csr
Check "Tao server.csr that bai."
ossl x509 -req -in vps/server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out vps/server.crt -days $Days -sha256 -extfile vps/server.ext
Check "CA ky chung chi that bai."

# --- 5. Kiem tra ---
ossl verify -CAfile ca.crt -verify_ip $Ip vps/server.crt
Check "Chung chi khong qua kiem tra chuoi tin cay hoac khong khop IP $Ip."

$m1 = (ossl x509 -in vps/server.crt -noout -modulus) -join ''
$m2 = (ossl rsa -in vps/server.key -noout -modulus) -join ''
if ($m1 -ne $m2) { throw "Khoa va chung chi KHONG khop nhau." }

ossl x509 -in vps/server.crt -noout -subject -dates -ext subjectAltName
Write-Host ""
Write-Host "HOAN TAT. File o pki\vps\ (thu muc pki\ da nam trong .gitignore)." -ForegroundColor Green
Write-Host "Buoc tiep: chep server.crt va server.key len VPS bang scp (xem huong dan)."