@echo off
chcp 437 >nul 2>&1
title BootFixer WinPE
color 0F
setlocal enabledelayedexpansion

cls
echo.
echo   =============================
echo        B O O T F I X E R
echo       WinPE Compatible v3.0
echo   =============================
echo.

:: =============================================
::   LEMEZEK LEKERDEZESE (WMIC + DISKPART)
:: =============================================

set DISKCOUNT=0
set "DPSCRIPT=%TEMP%\bf_dp.txt"

:: Megprobaljuk WMIC-vel eloszor (gyorsabb, megbizhatobb)
:: Ha nincs WMIC (egyes WinPE), fallback diskpart-ra
where wmic >nul 2>&1
if %errorlevel% equ 0 (
    goto :DETECT_WMIC
) else (
    goto :DETECT_DISKPART
)

:: ----- WMIC ALAPU FELISMERES -----
:DETECT_WMIC

:: Lemezek
for /f "tokens=1,2 delims==" %%a in ('wmic diskdrive get Index /format:list 2^>nul ^| findstr "Index"') do (
    set /a DISKCOUNT+=1
    set "DNUM_!DISKCOUNT!=%%b"
)

if %DISKCOUNT% equ 0 (
    echo   Nem talalhato lemez!
    pause
    exit /b
)

:: Minden lemezhez adatok
for /l %%i in (1,1,%DISKCOUNT%) do (
    set "DMODEL_%%i=Lemez !DNUM_%%i!"
    set "DSIZE_%%i=? GB"
    set "DTYPE_%%i=Ismeretlen"
    set "DWIN_%%i=Nincs Windows"
    set "DWINLETTER_%%i="
    set "DEFI_%%i="

    :: Model
    for /f "tokens=1,* delims==" %%a in ('wmic diskdrive where "Index=!DNUM_%%i!" get Model /format:list 2^>nul ^| findstr "Model"') do (
        set "DMODEL_%%i=%%b"
    )

    :: Size (GB-ba szamolva)
    for /f "tokens=1,* delims==" %%a in ('wmic diskdrive where "Index=!DNUM_%%i!" get Size /format:list 2^>nul ^| findstr "Size"') do (
        set /a "DSIZEGB=%%b / 1073741824"
        set "DSIZE_%%i=!DSIZEGB! GB"
    )

    :: Partition type - GPT vagy MBR
    for /f "tokens=1,* delims==" %%a in ('wmic partition where "DiskIndex=!DNUM_%%i!" get Type /format:list 2^>nul ^| findstr /i "Type"') do (
        set "_ptype=%%b"
        echo !_ptype! | findstr /i "GPT" >nul 2>&1
        if !errorlevel! equ 0 (
            set "DTYPE_%%i=UEFI/GPT"
        ) else (
            echo !_ptype! | findstr /i "Installable" >nul 2>&1
            if !errorlevel! equ 0 set "DTYPE_%%i=Legacy/MBR"
        )
    )

    :: Ha a tipus meg nem ismert, fallback
    if "!DTYPE_%%i!"=="Ismeretlen" (
        :: Legtobb esetben ha nincs GPT marker, MBR
        for /f "tokens=1,* delims==" %%a in ('wmic partition where "DiskIndex=!DNUM_%%i!" get Type /format:list 2^>nul ^| findstr /i "Type"') do (
            set "DTYPE_%%i=Legacy/MBR"
        )
    )

    :: EFI particio keresese (GPT: System tipus)
    for /f "tokens=1,* delims==" %%a in ('wmic partition where "DiskIndex=!DNUM_%%i! and Type like '%%System%%'" get Index /format:list 2^>nul ^| findstr "Index"') do (
        :: Diskpart-ban a partition number = Index + 1
        set /a "DEFI_%%i=%%b + 1"
    )
)

:: Windows keresese - vegigmegyunk a betujelen
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\Windows\System32\winload*" (
        :: Melyik lemezen van? - megnezzuk a volume meretet es a particio meretet
        for /l %%i in (1,1,%DISKCOUNT%) do (
            if "!DWINLETTER_%%i!"=="" (
                :: Ellenorizzuk: van-e particio ezen a disken ami megfelel
                for /f "tokens=1,* delims==" %%a in ('wmic partition where "DiskIndex=!DNUM_%%i!" get Size /format:list 2^>nul ^| findstr "Size"') do (
                    :: Logikai disk meret osszehasonlitas
                    for /f "tokens=1,* delims==" %%x in ('wmic logicaldisk where "DeviceID='%%d:'" get Size /format:list 2^>nul ^| findstr "Size"') do (
                        if "%%b"=="%%y" (
                            set "DWIN_%%i=Windows %%d:\"
                            set "DWINLETTER_%%i=%%d"
                        )
                    )
                )
            )
        )
    )
)

:: Fallback: ha nem talaltuk meg a lemez-betujel osszekottest, egyszerubb modszer
:: Megnezzuk melyik lemezen van C: altalaban
for /l %%i in (1,1,%DISKCOUNT%) do (
    if "!DWINLETTER_%%i!"=="" (
        :: Ha a disk 0 es van C:\Windows -> disk 0
        if "!DNUM_%%i!"=="0" (
            if exist "C:\Windows\System32\winload*" (
                set "DWIN_%%i=Windows C:\"
                set "DWINLETTER_%%i=C"
            )
        )
    )
)

:: Extra fallback - barmelyik drive letter-nel
for /l %%i in (1,1,%DISKCOUNT%) do (
    if "!DWINLETTER_%%i!"=="" (
        for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
            if "!DWINLETTER_%%i!"=="" (
                if exist "%%d:\Windows\System32\winload*" (
                    :: Diskpart detail volume-mal ellenorizzuk
                    set "_found=0"
                    for /f "tokens=2" %%v in ('echo list volume ^> "%DPSCRIPT%" ^& diskpart /s "%DPSCRIPT%" 2^>nul ^| findstr /i /c:" %%d "') do (
                        set "_found=1"
                    )
                    if "!_found!"=="0" (
                        set "DWIN_%%i=Windows %%d:\"
                        set "DWINLETTER_%%i=%%d"
                    )
                )
            )
        )
    )
)

goto :SHOW_DISKS

:: ----- DISKPART ALAPU FELISMERES (WMIC NELKUL) -----
:DETECT_DISKPART

echo list disk > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_dp.txt" 2>nul

:: Diskpart "list disk" kimenet formatum:
::   Disk ###  Status         Size     Free     Dyn  Gpt
::   --------  -------------  -------  -------  ---  ---
::   Disk 0    Online          931 GB      0 B         *
::   Disk 1    Online           58 GB      0 B

for /f "usebackq skip=1 tokens=*" %%a in ("%TEMP%\bf_dp.txt") do (
    set "_line=%%a"
    :: Csak "Disk " -el kezdodo sorok
    echo !_line! | findstr /b /c:"  Disk " >nul 2>&1
    if !errorlevel! equ 0 (
        :: Disk szam kinyerese
        for /f "tokens=2" %%n in ("!_line!") do (
            set /a DISKCOUNT+=1
            set "DNUM_!DISKCOUNT!=%%n"
            set "DMODEL_!DISKCOUNT!=Lemez %%n"
            set "DWIN_!DISKCOUNT!=Nincs Windows"
            set "DWINLETTER_!DISKCOUNT!="
            set "DEFI_!DISKCOUNT!="

            :: GPT flag check (csillag az utolso oszlopban)
            echo !_line! | findstr /c:"*" >nul 2>&1
            if !errorlevel! equ 0 (
                set "DTYPE_!DISKCOUNT!=UEFI/GPT"
            ) else (
                set "DTYPE_!DISKCOUNT!=Legacy/MBR"
            )

            :: Size kinyerese
            for /f "tokens=4,5" %%s in ("!_line!") do (
                set "DSIZE_!DISKCOUNT!=%%s %%t"
            )
        )
    )
)

if %DISKCOUNT% equ 0 (
    echo   Nem talalhato lemez!
    pause
    exit /b
)

:: EFI particio es Windows keresese - diskpart-tal
for /l %%i in (1,1,%DISKCOUNT%) do (
    (
        echo select disk !DNUM_%%i!
        echo list partition
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_parts.txt" 2>nul

    :: System particio (EFI)
    for /f "tokens=2" %%p in ('type "%TEMP%\bf_parts.txt" ^| findstr /i "System"') do (
        set "DEFI_%%i=%%p"
    )
)

:: Windows keresese betujel alapjan
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\Windows\System32\winload*" (
        :: Alapertelmezetten disk 0-hoz rendeljuk
        for /l %%i in (1,1,%DISKCOUNT%) do (
            if "!DWINLETTER_%%i!"=="" (
                set "DWIN_%%i=Windows %%d:\"
                set "DWINLETTER_%%i=%%d"
                goto :WINPE_FOUND
            )
        )
        :WINPE_FOUND
    )
)

goto :SHOW_DISKS

:: =============================================
::   LEMEZEK KIIRASA
:: =============================================
:SHOW_DISKS

echo   Talalt lemezek:
echo   -------------------------------------------------------
for /l %%i in (1,1,%DISKCOUNT%) do (
    echo   [%%i] !DMODEL_%%i! ^| !DSIZE_%%i! ^| !DTYPE_%%i! ^| !DWIN_%%i!
)
echo.
echo   [0] Kilepes
echo.

:: =============================================
::   KIVALASZTAS
:: =============================================

set /p "CHOICE=  Melyik lemezt javitsam? [szam]: "
if "%CHOICE%"=="0" exit /b

:: Validacio
set "VALID=0"
for /l %%i in (1,1,%DISKCOUNT%) do (
    if "%CHOICE%"=="%%i" set "VALID=1"
)
if "%VALID%"=="0" (
    echo   Ervenytelen valasztas!
    pause
    exit /b
)

set "SEL=%CHOICE%"
set "SELDISK=!DNUM_%SEL%!"
set "SELTYPE=!DTYPE_%SEL%!"
set "SELWIN=!DWINLETTER_%SEL%!"
set "SELSIZE=!DSIZE_%SEL%!"
set "SELEFI=!DEFI_%SEL%!"
set "SELMODEL=!DMODEL_%SEL%!"

if "!SELWIN!"=="" (
    echo.
    echo   [HIBA] Ezen a lemezen nincs Windows!
    pause
    exit /b
)

echo.
echo   Kivalasztva: !SELMODEL! ^| !SELSIZE! ^| !SELTYPE!
echo   Windows: !SELWIN!:\
echo.
set /p "CONFIRM=  Ujrairom a bootot es single boot lesz. Folytatod? (i/n): "
if /i not "%CONFIRM%"=="i" (
    echo   Megszakitva.
    pause
    exit /b
)

echo.

:: UEFI vagy Legacy?
echo !SELTYPE! | findstr /i "UEFI" >nul 2>&1
if !errorlevel! equ 0 (
    goto :FIX_UEFI
) else (
    goto :FIX_LEGACY
)

:: =============================================
::   UEFI BOOT JAVITAS
:: =============================================
:FIX_UEFI

echo   [1/4] EFI particio mountolasa...

:: Ha nincs EFI part szam, diskpart-tal keressuk
if "!SELEFI!"=="" (
    (
        echo select disk !SELDISK!
        echo list partition
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_efi.txt" 2>nul
    for /f "tokens=2" %%p in ('type "%TEMP%\bf_efi.txt" ^| findstr /i "System"') do (
        set "SELEFI=%%p"
    )
)

if "!SELEFI!"=="" (
    echo   [HIBA] Nem talalhato EFI particio!
    pause
    exit /b
)

:: Szabad betujel
set "EFILETTER="
for %%l in (Z Y X W V U T S R Q) do (
    if not exist "%%l:\" if "!EFILETTER!"=="" set "EFILETTER=%%l"
)

:: EFI mount
(
    echo select disk !SELDISK!
    echo select partition !SELEFI!
    echo assign letter=!EFILETTER!
) > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" >nul 2>&1

:: Varas
ping 127.0.0.1 -n 3 >nul 2>&1

if not exist "!EFILETTER!:\" (
    echo   [HIBA] EFI mount sikertelen!
    pause
    exit /b
)
echo   [OK] EFI mountolva: !EFILETTER!:\

:: Boot fajlok ujrairasa
echo   [2/4] Boot fajlok ujrairasa...
if exist "!EFILETTER!:\EFI\Microsoft\Boot" (
    rd /s /q "!EFILETTER!:\EFI\Microsoft\Boot" >nul 2>&1
)

bcdboot "!SELWIN!:\Windows" /s "!EFILETTER!:" /f UEFI /l hu-HU >nul 2>&1
if !errorlevel! neq 0 (
    bcdboot "!SELWIN!:\Windows" /s "!EFILETTER!:" /f UEFI >nul 2>&1
)
if !errorlevel! equ 0 (
    echo   [OK] BCDBoot UEFI sikeres!
) else (
    echo   [!] BCDBoot figyelmeztetes - ellenorizd
)

:: Single boot
echo   [3/4] Single boot beallitas...
set "BCDSTORE=!EFILETTER!:\EFI\Microsoft\Boot\BCD"
if exist "!BCDSTORE!" (
    for /f "tokens=2" %%e in ('bcdedit /store "!BCDSTORE!" /enum osloader 2^>nul ^| findstr "identifier"') do (
        if not "%%e"=="{default}" (
            bcdedit /store "!BCDSTORE!" /delete %%e /cleanup >nul 2>&1
        )
    )
    bcdedit /store "!BCDSTORE!" /timeout 0 >nul 2>&1
    echo   [OK] Single boot beallitva!
) else (
    echo   [!] BCD store nem talalhato
)

:: EFI unmount
echo   [4/4] EFI levalasztasa...
(
    echo select disk !SELDISK!
    echo select partition !SELEFI!
    echo remove letter=!EFILETTER!
) > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" >nul 2>&1
echo   [OK] Kesz!

goto :DONE

:: =============================================
::   LEGACY BOOT JAVITAS
:: =============================================
:FIX_LEGACY

:: Aktiv particio
echo   [1/4] Aktiv particio beallitasa...
(
    echo select disk !SELDISK!
    echo list partition
) > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_legp.txt" 2>nul

set "ACTIVEPART="
:: Elso particio mint default
for /f "tokens=2" %%a in ('type "%TEMP%\bf_legp.txt" ^| findstr /r /c:"Partition [0-9]"') do (
    if "!ACTIVEPART!"=="" set "ACTIVEPART=%%a"
)

:: Van-e mar aktiv?
findstr /i /c:"*" "%TEMP%\bf_legp.txt" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK] Aktiv particio rendben.
) else (
    :: Aktívva tesszük az elsőt
    (
        echo select disk !SELDISK!
        echo select partition !ACTIVEPART!
        echo active
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" >nul 2>&1
    echo   [OK] Particio !ACTIVEPART! aktivva teve!
)

:: MBR + boot szektor
echo   [2/4] MBR es boot szektor ujrairasa...
bootrec /fixmbr >nul 2>&1
bootrec /fixboot >nul 2>&1
bootrec /rebuildbcd >nul 2>&1
echo   [OK] MBR/bootszektor ujrairva!

:: BCDBoot
echo   [3/4] BCDBoot futtatasa...
set "TMPLETTER="
for %%l in (Z Y X W V U T S R Q) do (
    if not exist "%%l:\" if "!TMPLETTER!"=="" set "TMPLETTER=%%l"
)

if defined ACTIVEPART if defined TMPLETTER (
    (
        echo select disk !SELDISK!
        echo select partition !ACTIVEPART!
        echo assign letter=!TMPLETTER!
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" >nul 2>&1
    ping 127.0.0.1 -n 2 >nul 2>&1

    bcdboot "!SELWIN!:\Windows" /s "!TMPLETTER!:" /f BIOS /l hu-HU >nul 2>&1
    if !errorlevel! neq 0 (
        bcdboot "!SELWIN!:\Windows" /s "!TMPLETTER!:" /f BIOS >nul 2>&1
    )
    if !errorlevel! equ 0 (
        echo   [OK] BCDBoot BIOS sikeres!
    ) else (
        echo   [!] BCDBoot figyelmeztetes
    )

    :: Betujel eltavolitasa
    (
        echo select disk !SELDISK!
        echo select partition !ACTIVEPART!
        echo remove letter=!TMPLETTER!
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" >nul 2>&1
) else (
    bcdboot "!SELWIN!:\Windows" /f BIOS >nul 2>&1
    echo   [OK] BCDBoot fallback.
)

:: Single boot
echo   [4/4] Single boot beallitas...
for /f "tokens=2" %%e in ('bcdedit /enum osloader 2^>nul ^| findstr "identifier"') do (
    if not "%%e"=="{default}" if not "%%e"=="{current}" (
        bcdedit /delete %%e /cleanup >nul 2>&1
    )
)
bcdedit /timeout 0 >nul 2>&1
echo   [OK] Single boot beallitva!

goto :DONE

:: =============================================
::   KESZ
:: =============================================
:DONE

:: Takaritas
del /q "%TEMP%\bf_*.txt" >nul 2>&1
del /q "%DPSCRIPT%" >nul 2>&1

echo.
echo   =============================
echo     BOOT JAVITAS KESZ!
echo     Inditsd ujra a gepet.
echo   =============================
echo.
pause
