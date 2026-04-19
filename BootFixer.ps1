<#
    BootFixer - Lemez kivalasztas, boot ujrairasa, single boot
#>

$ErrorActionPreference = 'SilentlyContinue'
try { $Host.UI.RawUI.WindowTitle = "BootFixer" } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# --- Admin ellenorzes + auto-elevate ---
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath -match '\.exe$' -and $exePath -notmatch 'powershell|pwsh') {
            Start-Process -FilePath $exePath -Verb RunAs
        } else {
            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        }
    } catch {}
    exit
}

# =============================================
#   LEMEZEK OSSZEGYUJTESE
# =============================================

Clear-Host
Write-Host ""
Write-Host "  =============================" -ForegroundColor Cyan
Write-Host "       B O O T F I X E R" -ForegroundColor White
Write-Host "  =============================" -ForegroundColor Cyan
Write-Host ""

$disks = Get-Disk
$diskList = @()

foreach ($disk in $disks) {
    $partStyle = $disk.PartitionStyle
    $bootType = switch ($partStyle) {
        'GPT'   { 'UEFI' }
        'MBR'   { 'Legacy' }
        default { 'N/A' }
    }

    $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
    $winDrive = $null
    $efiPart = $null

    foreach ($p in $partitions) {
        if ($p.DriveLetter -and (Test-Path "$($p.DriveLetter):\Windows\System32")) {
            $winDrive = $p.DriveLetter
        }
        if ($p.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') {
            $efiPart = $p
        }
    }

    $sizeGB = [math]::Round($disk.Size / 1GB, 1)
    $model = if ($disk.FriendlyName) { $disk.FriendlyName } else { "Lemez" }

    $diskList += [PSCustomObject]@{
        Number    = $disk.Number
        Model     = $model
        SizeGB    = $sizeGB
        BootType  = $bootType
        WinDrive  = $winDrive
        EFIPart   = $efiPart
        PartStyle = $partStyle
    }
}

# =============================================
#   LEMEZEK KILISTAZASA
# =============================================

if ($diskList.Count -eq 0) {
    Write-Host "  Nem talalhato lemez!" -ForegroundColor Red
    Read-Host "  Nyomj ENTER-t"
    exit
}

$idx = 1
foreach ($d in $diskList) {
    $bootColor = if ($d.BootType -eq 'UEFI') { 'Cyan' } elseif ($d.BootType -eq 'Legacy') { 'Magenta' } else { 'DarkGray' }
    $winText = if ($d.WinDrive) { "Windows: $($d.WinDrive):\" } else { "Nincs Windows" }
    $winColor = if ($d.WinDrive) { 'Green' } else { 'DarkGray' }

    Write-Host "  [$idx]" -ForegroundColor White -NoNewline
    Write-Host " $($d.Model)" -ForegroundColor Yellow -NoNewline
    Write-Host " | $($d.SizeGB) GB | " -ForegroundColor Gray -NoNewline
    Write-Host "$($d.BootType)" -ForegroundColor $bootColor -NoNewline
    Write-Host " | " -ForegroundColor Gray -NoNewline
    Write-Host "$winText" -ForegroundColor $winColor
    $idx++
}

Write-Host ""
Write-Host "  [0] Kilepes" -ForegroundColor DarkGray
Write-Host ""

# =============================================
#   KIVALASZTAS
# =============================================

$choice = Read-Host "  Melyik lemezt javitsam? [szam]"
if ($choice -eq '0') { exit }

$sel = [int]$choice - 1
if ($sel -lt 0 -or $sel -ge $diskList.Count) {
    Write-Host "  Ervenytelen valasztas!" -ForegroundColor Red
    Read-Host "  Nyomj ENTER-t"
    exit
}

$disk = $diskList[$sel]

if (-not $disk.WinDrive) {
    Write-Host "  Ezen a lemezen nincs Windows telepites, nem tudom javitani!" -ForegroundColor Red
    Read-Host "  Nyomj ENTER-t"
    exit
}

Write-Host ""
Write-Host "  Kivalasztva: $($disk.Model) ($($disk.SizeGB) GB) [$($disk.BootType)]" -ForegroundColor Yellow
Write-Host "  Windows: $($disk.WinDrive):\" -ForegroundColor Green
Write-Host ""

$confirm = Read-Host "  Ujrairom a bootot es single boot-ta teszem. Folytatod? (i/n)"
if ($confirm -ne 'i') {
    Write-Host "  Megszakitva." -ForegroundColor Yellow
    Read-Host "  Nyomj ENTER-t"
    exit
}

$winPath = "$($disk.WinDrive):\Windows"
Write-Host ""

# =============================================
#   BOOT JAVITAS
# =============================================

if ($disk.BootType -eq 'UEFI') {
    # --- UEFI BOOT JAVITAS ---
    Write-Host "  [1/4] EFI particio mountolasa..." -ForegroundColor Cyan

    # Szabad betujel
    $usedLetters = (Get-Partition | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
    $efiLetter = $null
    foreach ($l in [char[]]('Z','Y','X','W','V','U','T','S')) {
        if ($l -notin $usedLetters) { $efiLetter = $l; break }
    }

    if (-not $disk.EFIPart) {
        Write-Host "  HIBA: Nincs EFI particio a lemezen!" -ForegroundColor Red
        Read-Host "  Nyomj ENTER-t"
        exit
    }

    # Mountolas diskpart-tal
    $dpScript = @"
select disk $($disk.Number)
select partition $($disk.EFIPart.PartitionNumber)
assign letter=$efiLetter
"@
    $dpScript | diskpart | Out-Null
    Start-Sleep -Seconds 1

    if (-not (Test-Path "${efiLetter}:\")) {
        Write-Host "  HIBA: EFI particio mountolasa sikertelen!" -ForegroundColor Red
        Read-Host "  Nyomj ENTER-t"
        exit
    }
    Write-Host "  [OK] EFI mountolva: ${efiLetter}:\" -ForegroundColor Green

    # Boot fajlok torlese + ujrairasa
    Write-Host "  [2/4] Boot fajlok ujrairasa..." -ForegroundColor Cyan
    $efiBoot = "${efiLetter}:\EFI\Microsoft\Boot"
    if (Test-Path $efiBoot) {
        Remove-Item -Path $efiBoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result = & bcdboot "$winPath" /s "${efiLetter}:" /f UEFI /l hu-HU 2>&1
    if ($LASTEXITCODE -ne 0) {
        $result = & bcdboot "$winPath" /s "${efiLetter}:" /f UEFI 2>&1
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] BCDBoot UEFI sikeres!" -ForegroundColor Green
    } else {
        Write-Host "  [!] BCDBoot: $result" -ForegroundColor Yellow
    }

    # Single boot - BCD tisztitas
    Write-Host "  [3/4] Single boot beallitas..." -ForegroundColor Cyan
    $bcdStore = "${efiLetter}:\EFI\Microsoft\Boot\BCD"
    if (Test-Path $bcdStore) {
        $entries = & bcdedit /store $bcdStore /enum osloader 2>&1 | Select-String "identifier" | ForEach-Object {
            if ($_ -match '\{[^}]+\}') { $Matches[0] }
        }
        $defaultId = & bcdedit /store $bcdStore /enum "{bootmgr}" 2>&1 | Select-String "default" | ForEach-Object {
            if ($_ -match '\{[^}]+\}') { $Matches[0] }
        }
        foreach ($entry in $entries) {
            if ($entry -ne $defaultId -and $entry -ne '{default}') {
                & bcdedit /store $bcdStore /delete $entry /cleanup 2>&1 | Out-Null
            }
        }
        & bcdedit /store $bcdStore /timeout 0 2>&1 | Out-Null
        Write-Host "  [OK] Single boot beallitva!" -ForegroundColor Green
    }

    # EFI unmount
    Write-Host "  [4/4] EFI particio levalasztasa..." -ForegroundColor Cyan
    $dpScript = @"
select disk $($disk.Number)
select partition $($disk.EFIPart.PartitionNumber)
remove letter=$efiLetter
"@
    $dpScript | diskpart | Out-Null
    Write-Host "  [OK] Kesz!" -ForegroundColor Green

} elseif ($disk.BootType -eq 'Legacy') {
    # --- LEGACY/MBR BOOT JAVITAS ---

    # Aktiv particio beallitas
    Write-Host "  [1/4] Aktiv particio beallitasa..." -ForegroundColor Cyan
    $partitions = Get-Partition -DiskNumber $disk.Number
    $activePart = $partitions | Where-Object { $_.IsActive -eq $true }
    if (-not $activePart) {
        $firstPart = $partitions | Sort-Object PartitionNumber | Select-Object -First 1
        $dpScript = @"
select disk $($disk.Number)
select partition $($firstPart.PartitionNumber)
active
"@
        $dpScript | diskpart | Out-Null
        Write-Host "  [OK] Particio $($firstPart.PartitionNumber) aktiv!" -ForegroundColor Green
    } else {
        Write-Host "  [OK] Aktiv particio rendben." -ForegroundColor Green
    }

    # MBR + boot szektor
    Write-Host "  [2/4] MBR es boot szektor ujrairasa..." -ForegroundColor Cyan
    & bootrec /fixmbr 2>&1 | Out-Null
    & bootrec /fixboot 2>&1 | Out-Null
    & bootrec /rebuildbcd 2>&1 | Out-Null
    Write-Host "  [OK] MBR/bootszektor ujrairva!" -ForegroundColor Green

    # BCDBoot
    Write-Host "  [3/4] BCDBoot futtatasa..." -ForegroundColor Cyan

    $sysPart = if ($activePart) { $activePart } else { $partitions | Sort-Object PartitionNumber | Select-Object -First 1 }
    $sysLetter = $sysPart.DriveLetter
    $tmpLetter = $null

    if (-not $sysLetter) {
        $usedLetters = (Get-Partition | Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter })
        foreach ($l in [char[]]('Z','Y','X','W','V','U','T','S')) {
            if ($l -notin $usedLetters) { $tmpLetter = $l; break }
        }
        if ($tmpLetter) {
            $dpScript = @"
select disk $($disk.Number)
select partition $($sysPart.PartitionNumber)
assign letter=$tmpLetter
"@
            $dpScript | diskpart | Out-Null
            Start-Sleep -Seconds 1
            $sysLetter = $tmpLetter
        }
    }

    if ($sysLetter) {
        $result = & bcdboot "$winPath" /s "${sysLetter}:" /f BIOS /l hu-HU 2>&1
        if ($LASTEXITCODE -ne 0) {
            $result = & bcdboot "$winPath" /s "${sysLetter}:" /f BIOS 2>&1
        }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] BCDBoot BIOS sikeres!" -ForegroundColor Green
        } else {
            Write-Host "  [!] BCDBoot: $result" -ForegroundColor Yellow
        }
        if ($tmpLetter) {
            $dpScript = @"
select disk $($disk.Number)
select partition $($sysPart.PartitionNumber)
remove letter=$tmpLetter
"@
            $dpScript | diskpart | Out-Null
        }
    } else {
        & bcdboot "$winPath" /f BIOS 2>&1 | Out-Null
        Write-Host "  [OK] BCDBoot fallback." -ForegroundColor Green
    }

    # Single boot
    Write-Host "  [4/4] Single boot beallitas..." -ForegroundColor Cyan
    $entries = & bcdedit /enum osloader 2>&1 | Select-String "identifier" | ForEach-Object {
        if ($_ -match '\{[^}]+\}') { $Matches[0] }
    }
    $defaultId = & bcdedit /enum "{bootmgr}" 2>&1 | Select-String "default" | ForEach-Object {
        if ($_ -match '\{[^}]+\}') { $Matches[0] }
    }
    foreach ($entry in $entries) {
        if ($entry -ne $defaultId -and $entry -ne '{default}' -and $entry -ne '{current}') {
            & bcdedit /delete $entry /cleanup 2>&1 | Out-Null
        }
    }
    & bcdedit /timeout 0 2>&1 | Out-Null
    Write-Host "  [OK] Single boot beallitva!" -ForegroundColor Green

} else {
    Write-Host "  Ez a lemez nem MBR es nem GPT - nem javithato!" -ForegroundColor Red
    Read-Host "  Nyomj ENTER-t"
    exit
}

# =============================================
#   KESZ
# =============================================

Write-Host ""
Write-Host "  =============================" -ForegroundColor Green
Write-Host "    BOOT JAVITAS KESZ!" -ForegroundColor Green
Write-Host "    Inditsd ujra a gepet." -ForegroundColor Green
Write-Host "  =============================" -ForegroundColor Green
Write-Host ""
Read-Host "  Nyomj ENTER-t a kilepeshez"
