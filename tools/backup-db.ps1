<#
.SYNOPSIS
    Sao luu database EpiSense (TimescaleDB) bang pg_dump.

.DESCRIPTION
    Moi lan chay tao 4 file trong thu muc backups\ (khong dua len Git):
      episense-<thoi-gian>.dump          du lieu (pg_dump -Fc, da nen)
      episense-<thoi-gian>.dump.sha256   checksum de kiem tra file khong bi hong
      episense-<thoi-gian>.info.txt      phien ban PostgreSQL/TimescaleDB luc sao luu
      episense-globals-<thoi-gian>.sql   cac role (CO CHUA HASH MAT KHAU, giu bi mat)
    Sau do kiem tra file bang pg_restore --list va xoa cac ban cu hon so luong can giu.

    pg_dump chay BEN TRONG container roi docker cp ra ngoai. Khong dung redirect (>) cua
    PowerShell vi no lam hong file nhi phan.

.PARAMETER Container
    Ten container database. Mac dinh episense-db.

.PARAMETER OutDir
    Thu muc luu. Mac dinh <goc du an>\backups.

.PARAMETER Keep
    So ban sao luu giu lai. Mac dinh 7.

.EXAMPLE
    .\tools\backup-db.ps1

.EXAMPLE
    .\tools\backup-db.ps1 -OutDir E:\Backups\episense -Keep 14
#>
[CmdletBinding()]
param(
    [string]$Container = 'episense-db',
    [string]$OutDir,
    [ValidateRange(1, 365)][int]$Keep = 7
)

function Step($n, $text) { Write-Host ""; Write-Host "[$n/6] $text" -ForegroundColor Cyan }
function Ok($text)       { Write-Host "  OK   $text" -ForegroundColor Green }
function Info($text)     { Write-Host "       $text" }
function Warn($text)     { Write-Host "  LUU Y $text" -ForegroundColor Yellow }
function Fail($text)     { Write-Host "  LOI  $text" -ForegroundColor Red; exit 1 }

# --- Thu muc goc du an (script dat trong tools\ hoac o thu muc goc) ---
if (Test-Path (Join-Path $PSScriptRoot 'docker-compose.yml')) {
    $Root = $PSScriptRoot
} else {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
if (-not $OutDir) { $OutDir = Join-Path $Root 'backups' }

# ---------------------------------------------------------------------------
Step 1 "Kiem tra dieu kien"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Fail "Khong tim thay lenh docker. Hay mo Docker Desktop."
}
docker version --format '{{.Server.Version}}' 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "Docker chua chay. Hay mo Docker Desktop, doi san sang roi chay lai." }

$running = (docker inspect -f '{{.State.Running}}' $Container 2>$null)
if ("$running".Trim() -ne 'true') {
    Fail "Container '$Container' khong chay. Kiem tra bang: docker compose ps"
}
$db  = docker exec $Container printenv POSTGRES_DB
$usr = docker exec $Container printenv POSTGRES_USER
$db  = "$db".Trim()
$usr = "$usr".Trim()
if (-not $db -or -not $usr) { Fail "Khong doc duoc POSTGRES_DB / POSTGRES_USER tu container." }
Ok "Container $Container dang chay. Database: $db   User: $usr"

# ---------------------------------------------------------------------------
Step 2 "Ghi lai phien ban (can de khoi phuc dung)"
$sqlTs = "SELECT extversion FROM pg_extension WHERE extname='timescaledb'"
$tsVer = docker exec $Container psql -U $usr -d $db -tA -c $sqlTs
$pgVer = docker exec $Container psql -U $usr -d $db -tA -c "SHOW server_version"
$image = docker inspect -f '{{.Config.Image}}' $Container
$tsVer = "$tsVer".Trim()
$pgVer = "$pgVer".Trim()
$image = "$image".Trim()
Ok "Image: $image   PostgreSQL: $pgVer   TimescaleDB: $tsVer"

# ---------------------------------------------------------------------------
Step 3 "Chay pg_dump trong container"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$tmpDump    = "/tmp/episense-$stamp.dump"
$tmpGlobals = "/tmp/episense-globals-$stamp.sql"

docker exec $Container pg_dump -U $usr -d $db -Fc -f $tmpDump
if ($LASTEXITCODE -ne 0) { Fail "pg_dump that bai. Xem log o tren." }
Info "(Canh bao 'circular foreign-key' cua pg_dump voi TimescaleDB thuong la binh thuong.)"

docker exec $Container pg_dumpall -U $usr --globals-only -f $tmpGlobals
if ($LASTEXITCODE -ne 0) { Fail "pg_dumpall --globals-only that bai." }
Ok "Da tao file dump trong container."

# ---------------------------------------------------------------------------
Step 4 "Kiem tra file dump"
$entries = docker exec $Container pg_restore -l $tmpDump
if ($LASTEXITCODE -ne 0) { Fail "pg_restore --list khong doc duoc file dump (file hong)." }
$count = ($entries | Measure-Object).Count
if ($count -lt 10) { Fail "File dump co qua it muc ($count). Co the khong day du." }
Ok "File dump doc duoc, gom $count muc."

# ---------------------------------------------------------------------------
Step 5 "Chep ra may Windows, ghi checksum"
$dumpFile    = Join-Path $OutDir "episense-$stamp.dump"
$globalsFile = Join-Path $OutDir "episense-globals-$stamp.sql"
$infoFile    = Join-Path $OutDir "episense-$stamp.info.txt"

docker cp "${Container}:$tmpDump" $dumpFile
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dumpFile)) { Fail "docker cp file dump that bai." }
docker cp "${Container}:$tmpGlobals" $globalsFile
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $globalsFile)) { Fail "docker cp file globals that bai." }
docker exec $Container rm -f $tmpDump $tmpGlobals

$hash = (Get-FileHash $dumpFile -Algorithm SHA256).Hash
Set-Content -Path "$dumpFile.sha256" -Value "$hash  $(Split-Path $dumpFile -Leaf)" -Encoding ascii

$sizeKb = [math]::Round((Get-Item $dumpFile).Length / 1KB, 1)
$info = @(
    "Thoi gian sao luu : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Database          : $db",
    "Image             : $image",
    "PostgreSQL        : $pgVer",
    "TimescaleDB       : $tsVer",
    "File dump         : $(Split-Path $dumpFile -Leaf) ($sizeKb KB)",
    "SHA256            : $hash"
)
Set-Content -Path $infoFile -Value $info -Encoding ascii
Ok "Da luu: $dumpFile ($sizeKb KB)"

# ---------------------------------------------------------------------------
Step 6 "Don dep ban cu (giu $Keep ban moi nhat)"
$old = Get-ChildItem -Path $OutDir -Filter 'episense-*.dump' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $Keep
foreach ($f in $old) {
    $s = $f.BaseName -replace '^episense-', ''
    $targets = @(
        (Join-Path $OutDir "episense-$s.dump"),
        (Join-Path $OutDir "episense-$s.dump.sha256"),
        (Join-Path $OutDir "episense-$s.info.txt"),
        (Join-Path $OutDir "episense-globals-$s.sql")
    )
    Remove-Item -Force -ErrorAction SilentlyContinue $targets
    Info "Da xoa ban cu: $s"
}
if (-not $old) { Info "Chua co ban nao can xoa." }

Write-Host ""
Write-Host "HOAN TAT." -ForegroundColor Green
Write-Host "Thu muc sao luu: $OutDir"
Write-Host "Nhac nho:"
Write-Host "  - File globals va dump chua mat khau (dang hash) va du lieu that: KHONG commit len Git, KHONG gui qua chat."
Write-Host "  - Mot ban sao luu nam chung may voi du lieu chua du an toan. Hay chep them sang o dia/USB khac."
Write-Host "  - Chua khoi phuc thu thi chua phai la ban sao luu. Chay: .\tools\restore-test.ps1"