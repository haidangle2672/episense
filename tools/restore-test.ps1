<#
.SYNOPSIS
    Thu khoi phuc ban sao luu vao mot container TAM (khong dung toi database that).

.DESCRIPTION
    1. Chon file .dump (mac dinh ban moi nhat trong backups\), kiem tra checksum
    2. Chay mot container TimescaleDB tam, cung image voi database that, khong mo cong
    3. Khoi phuc theo quy trinh chinh thuc cua TimescaleDB:
         CREATE EXTENSION -> timescaledb_pre_restore() -> pg_restore -> timescaledb_post_restore()
    4. Doi chieu: so dong, hypertable, nhat ky canh bao giua ban khoi phuc va database that
    5. Xoa container tam (tru khi dung -KeepContainer)

    Script KHONG sua gi trong database that, chi doc de doi chieu.

.PARAMETER File
    File .dump can thu. Bo trong = ban moi nhat trong backups\.

.PARAMETER ProdContainer
    Container database that. Mac dinh episense-db.

.PARAMETER KeepContainer
    Giu lai container tam (episense-restore-test) de ban tu kham pha.

.EXAMPLE
    .\tools\restore-test.ps1

.EXAMPLE
    .\tools\restore-test.ps1 -File .\backups\episense-20261123-120000.dump
#>
[CmdletBinding()]
param(
    [string]$File,
    [string]$ProdContainer = 'episense-db',
    [switch]$KeepContainer
)

function Step($n, $text) { Write-Host ""; Write-Host "[$n/6] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "  OK   $text" -ForegroundColor Green }
function Info($text)     { Write-Host "       $text" }
function Warn($text)     { Write-Host "  LUU Y $text" -ForegroundColor Yellow }
function Fail($text)     { Write-Host "  LOI  $text" -ForegroundColor Red; Cleanup; exit 1 }

$Scratch = 'episense-restore-test'
$ScratchDb = 'restoretest'

function Cleanup {
    if (-not $KeepContainer) {
        docker rm -f -v $Scratch 2>$null | Out-Null
    }
}

# Chay mot cau SQL tren mot container, tra ve chuoi ket qua (hoac $null neu loi)
function Sql($container, $user, $db, $sql) {
    $r = docker exec $container psql -U $user -d $db -tA -c $sql 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ("$r").Trim()
}

if (Test-Path (Join-Path $PSScriptRoot 'docker-compose.yml')) {
    $Root = $PSScriptRoot
} else {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

# ---------------------------------------------------------------------------
Step 1 "Chon file sao luu va kiem tra checksum"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Fail "Khong tim thay lenh docker." }
docker version --format '{{.Server.Version}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Docker chua chay. Hay mo Docker Desktop." }

if (-not $File) {
    $latest = Get-ChildItem -Path (Join-Path $Root 'backups') -Filter 'episense-*.dump' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Fail "Khong co file .dump nao trong backups\. Hay chay .\tools\backup-db.ps1 truoc." }
    $File = $latest.FullName
}
if (-not (Test-Path $File)) { Fail "Khong thay file: $File" }
$File = (Resolve-Path $File).Path
Info "File: $File"

$shaFile = "$File.sha256"
if (Test-Path $shaFile) {
    $expected = ((Get-Content $shaFile -TotalCount 1) -split '\s+')[0]
    $actual = (Get-FileHash $File -Algorithm SHA256).Hash
    if ($expected -ne $actual) { Fail "Checksum KHONG khop: file sao luu bi hong hoac bi sua." }
    Ok "Checksum SHA256 khop."
} else {
    Warn "Khong co file .sha256 di kem, bo qua kiem tra checksum."
}

# ---------------------------------------------------------------------------
Step 2 "Chay container tam (cung image voi database that)"
$prodUser = docker exec $ProdContainer printenv POSTGRES_USER
$prodDb   = docker exec $ProdContainer printenv POSTGRES_DB
$prodUser = "$prodUser".Trim()
$prodDb   = "$prodDb".Trim()
if (-not $prodUser -or -not $prodDb) { Fail "Khong doc duoc thong tin tu container '$ProdContainer'. No co dang chay khong?" }

$image = docker inspect -f '{{.Config.Image}}' $ProdContainer
$image = "$image".Trim()
Info "Image: $image"

docker rm -f -v $Scratch 2>$null | Out-Null
docker run -d --name $Scratch -e POSTGRES_PASSWORD=restore-test-only $image | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Khong chay duoc container tam." }

# Doi PostgreSQL khoi tao xong that su (image khoi dong 2 lan: tam thoi roi that)
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 2
    $log = cmd /c "docker logs $Scratch 2>&1" | Out-String
    if ($log -match 'init process complete') {
        docker exec $Scratch pg_isready -U postgres 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
}
if (-not $ready) { Fail "Container tam khong san sang sau 80 giay. Xem: docker logs $Scratch" }
Ok "Container tam san sang (khong mo cong ra ngoai)."

# ---------------------------------------------------------------------------
Step 3 "Khoi phuc theo quy trinh TimescaleDB"
docker cp $File "${Scratch}:/tmp/restore.dump"
if ($LASTEXITCODE -ne 0) { Fail "Khong chep duoc file vao container tam." }

docker exec $Scratch psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $ScratchDb"
if ($LASTEXITCODE -ne 0) { Fail "Khong tao duoc database tam." }
docker exec $Scratch psql -U postgres -d $ScratchDb -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS timescaledb"
if ($LASTEXITCODE -ne 0) { Fail "Khong tao duoc extension timescaledb." }
docker exec $Scratch psql -U postgres -d $ScratchDb -v ON_ERROR_STOP=1 -c "SELECT timescaledb_pre_restore()"
if ($LASTEXITCODE -ne 0) { Fail "timescaledb_pre_restore() that bai." }

# --no-owner / --no-privileges: container tam khong co cac role cua he thong that.
# KHONG dung -j (tai lieu TimescaleDB: -j khong khoi phuc dung catalog).
$restoreOut = cmd /c "docker exec $Scratch pg_restore -U postgres -d $ScratchDb --no-owner --no-privileges /tmp/restore.dump 2>&1" | Out-String
$restoreErrors = ($restoreOut -split "`r?`n") | Where-Object { $_ -match 'error' }
if ($restoreErrors) {
    Info "pg_restore bao cac dong sau (thuong chi la 'extension already exists', ket qua that duoc quyet dinh o buoc doi chieu):"
    $restoreErrors | Select-Object -First 8 | ForEach-Object { Info "  $_" }
} else {
    Info "pg_restore khong bao loi."
}

docker exec $Scratch psql -U postgres -d $ScratchDb -v ON_ERROR_STOP=1 -c "SELECT timescaledb_post_restore()"
if ($LASTEXITCODE -ne 0) { Fail "timescaledb_post_restore() that bai." }
Ok "Da chay xong quy trinh khoi phuc."

# ---------------------------------------------------------------------------
Step 4 "Doi chieu voi database that"
$allOk = $true
function Check($name, $pass, $detail) {
    if ($pass) { Ok "$name : $detail" } else { Write-Host "  LOI  $name : $detail" -ForegroundColor Red; $script:allOk = $false }
}

# a) telemetry la hypertable
$hyper = Sql $Scratch 'postgres' $ScratchDb "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name='telemetry'"
Check "telemetry la hypertable" ($hyper -eq '1') "ket qua = $hyper (mong doi 1)"

# b) so dong telemetry: database that co the da them dong moi sau luc sao luu,
#    nen chi dem cac dong co time <= dong moi nhat cua ban khoi phuc
$rCount = Sql $Scratch 'postgres' $ScratchDb "SELECT count(*) FROM telemetry"
$rMax   = Sql $Scratch 'postgres' $ScratchDb "SELECT max(time) FROM telemetry"
if ($rCount -and [int64]$rCount -gt 0 -and $rMax) {
    $pCount = Sql $ProdContainer $prodUser $prodDb "SELECT count(*) FROM telemetry WHERE time <= '$rMax'"
    Check "so dong telemetry" ($pCount -eq $rCount) "khoi phuc=$rCount, that (den $rMax)=$pCount"
} else {
    Warn "Bang telemetry trong ban khoi phuc rong, khong the doi chieu so dong."
    $allOk = $false
}

# c) nhat ky canh bao (neu co)
$rAlerts = Sql $Scratch 'postgres' $ScratchDb "SELECT count(*) FROM alert_events"
if ($null -ne $rAlerts -and [int64]$rAlerts -gt 0) {
    $rMaxId  = Sql $Scratch 'postgres' $ScratchDb "SELECT max(id) FROM alert_events"
    $pAlerts = Sql $ProdContainer $prodUser $prodDb "SELECT count(*) FROM alert_events WHERE id <= $rMaxId"
    Check "so dong alert_events" ($pAlerts -eq $rAlerts) "khoi phuc=$rAlerts, that (id<=$rMaxId)=$pAlerts"
} else {
    Info "alert_events rong hoac khong co: bo qua."
}

# d) bang trang thai thiet bi ton tai
$rStatus = Sql $Scratch 'postgres' $ScratchDb "SELECT count(*) FROM device_status"
Check "bang device_status" ($null -ne $rStatus) "so dong = $rStatus"

# ---------------------------------------------------------------------------
Step 5 "Don dep"
if ($KeepContainer) {
    Warn "Giu lai container tam. Vao kham pha: docker exec -it $Scratch psql -U postgres -d $ScratchDb"
    Warn "Khi xong: docker rm -f $Scratch"
} else {
    Cleanup
    Ok "Da xoa container tam."
}

Step 6 "Ket luan"
if ($allOk) {
    Write-Host "  DAT: ban sao luu khoi phuc duoc va khop voi database that." -ForegroundColor Green
    exit 0
} else {
    Write-Host "  KHONG DAT: xem cac dong LOI o tren. Dung tin vao ban sao luu nay cho den khi sua xong." -ForegroundColor Red
    exit 2
}