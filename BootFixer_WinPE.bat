@echo off
chcp 437 >nul 2>&1
title BootFixer WinPE
color 0F
setlocal enabledelayedexpansion

cls
echo.
echo   =============================
echo        B O O T F I X E R
echo       WinPE Compatible v3.1
echo   =============================
echo.

:: =============================================
::   LEMEZEK LEKERDEZESE
:: =============================================

set DISKCOUNT=0
set "TMP_DIR=%TEMP%"
if "%TMP_DIR%"=="" set "TMP_DIR=X:\Windows\Temp"
set "DPSCRIPT=%TMP_DIR%\bf_dp.txt"

:: ---- Diskpart list disk - ez MINDENHOL mukodik ----
echo list disk > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" > "%TMP_DIR%\bf_disklist.txt" 2>nul

:: Diskpart "list disk" kimenet pelda:
::   Disk ###  Status         Size     Free     Dyn  Gpt
::   --------  -------------  -------  -------  ---  ---
::   Disk 0    Online          931 GB      0 B         *
::   Disk 1    Online           58 GB      0 B
::
:: A * az utolso oszlopban = GPT lemez

for /f "tokens=*" %%L in ('type "%TMP_DIR%\bf_disklist.txt" ^| findstr /b /c:"  Disk "') do (
    set "_line=%%L"
    :: Kiszurjuk a fejlec sort (Disk ### vagy Disk ---)
    echo !_line! | findstr /c:"---" >nul 2>&1
    if !errorlevel! neq 0 (
        echo !_line! | findstr /c:"###" >nul 2>&1
        if !errorlevel! neq 0 (
            :: Ez egy valos lemez sor
            set /a DISKCOUNT+=1

            :: Disk szam (2. token)
            for /f "tokens=2" %%n in ("!_line!") do (
                set "DNUM_!DISKCOUNT!=%%n"
            )

            :: Meret (4. es 5. token, pl "931 GB")
            for /f "tokens=4,5" %%s in ("!_line!") do (
                set "DSIZE_!DISKCOUNT!=%%s %%t"
            )

            :: GPT check (csillag a sorban)
            set "DTYPE_!DISKCOUNT!=Legacy/MBR"
            echo !_line! | findstr /c:"*" >nul 2>&1
            if !errorlevel! equ 0 (
                set "DTYPE_!DISKCOUNT!=UEFI/GPT"
            )

            :: Alapertelmezett ertekek
            set "DMODEL_!DISKCOUNT!=Lemez !DISKCOUNT!"
            set "DWIN_!DISKCOUNT!=Nincs Windows"
            set "DWINLETTER_!DISKCOUNT!="
            set "DEFI_!DISKCOUNT!="
        )
    )
)

if %DISKCOUNT% equ 0 (
    echo   Nem talalhato lemez!
    echo   [Debug] Diskpart kimenet:
    type "%TMP_DIR%\bf_disklist.txt"
    pause
    exit /b
)

:: ---- Lemez nevek lekerdezese WMIC-vel (ha elerheto) ----
where wmic >nul 2>&1
if %errorlevel% equ 0 (
    for /l %%i in (1,1,%DISKCOUNT%) do (
        for /f "tokens=2 delims==" %%m in ('wmic diskdrive where "Index=!DNUM_%%i!" get Model /value 2^>nul ^| findstr /i "Model"') do (
            :: Trailing space/CR eltavolitasa
            set "_rawmodel=%%m"
            for /f "tokens=*" %%c in ("!_rawmodel!") do set "DMODEL_%%i=%%c"
        )
    )
)

:: ---- EFI particio keresese lemezenként ----
for /l %%i in (1,1,%DISKCOUNT%) do (
    (
        echo select disk !DNUM_%%i!
        echo list partition
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" > "%TMP_DIR%\bf_parts_%%i.txt" 2>nul

    :: "System" tipusu particio = EFI particio GPT-nel
    for /f "tokens=*" %%P in ('type "%TMP_DIR%\bf_parts_%%i.txt" ^| findstr /i "System"') do (
        for /f "tokens=2" %%n in ("%%P") do (
            set "DEFI_%%i=%%n"
        )
    )
)

:: ---- Windows keresese: vegigmegyunk az osszes betujelen ----
:: Eloszor megnezzuk melyik betujel melyik lemezhez tartozik
for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%d:\Windows\System32\winload*" (
        :: Megtalaltuk a Windows-t a %%d meghajtón
        :: Most kideritjuk melyik fizikai lemezen van

        :: Diskpart-tal detail volume
        echo list volume > "%DPSCRIPT%"
        diskpart /s "%DPSCRIPT%" > "%TMP_DIR%\bf_volumes.txt" 2>nul

        :: Keressuk a volume-ot aminek %%d a betujele
        set "_volnum="
        for /f "tokens=*" %%V in ('type "%TMP_DIR%\bf_volumes.txt" ^| findstr /i /c:" %%d "') do (
            for /f "tokens=2" %%n in ("%%V") do (
                set "_volnum=%%n"
            )
        )

        if defined _volnum (
            :: Detail volume megmondja melyik disken van
            (
                echo select volume !_volnum!
                echo detail volume
            ) > "%DPSCRIPT%"
            diskpart /s "%DPSCRIPT%" > "%TMP_DIR%\bf_voldet.txt" 2>nul

            :: "Disk" sor keresese a detail volume kimenetben
            for /f "tokens=*" %%D in ('type "%TMP_DIR%\bf_voldet.txt" ^| findstr /r /c:"Disk [0-9]"') do (
                for /f "tokens=2" %%x in ("%%D") do (
                    :: Megvan a disk szam, hozzarendeljuk
                    for /l %%i in (1,1,%DISKCOUNT%) do (
                        if "!DNUM_%%i!"=="%%x" (
                            if "!DWINLETTER_%%i!"=="" (
                                set "DWIN_%%i=Windows %%d:\"
                                set "DWINLETTER_%%i=%%d"
                            )
                        )
                    )
                )
            )
        ) else (
            :: Fallback: ha nem talaltuk a volume-ot, rendeljuk az elso Windows-mentes lemezhez
            for /l %%i in (1,1,%DISKCOUNT%) do (
                if "!DWINLETTER_%%i!"=="" (
                    set "DWIN_%%i=Windows %%d:\"
                    set "DWINLETTER_%%i=%%d"
                    goto :WIN_ASSIGNED
                )
            )
            :WIN_ASSIGNED
        )
    )
)

:: =============================================
::   LEMEZEK KIIRASA
:: =============================================

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
    diskpart /s "%DPSCRIPT%" > "%TMP_DIR%\bf_efi.txt" 2>nul
    for /f "tokens=*" %%P in ('type "%TMP_DIR%\bf_efi.txt" ^| findstr /i "System"') do (
        for /f "tokens=2" %%n in ("%%P") do set "SELEFI=%%n"
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
diskpart /s "%DPSCRIPT%" > "%TMP_DIR%\bf_legp.txt" 2>nul

set "ACTIVEPART="
:: Elso particio mint default
for /f "tokens=*" %%P in ('type "%TMP_DIR%\bf_legp.txt" ^| findstr /r /c:"Partition [0-9]"') do (
    for /f "tokens=2" %%n in ("%%P") do (
        if "!ACTIVEPART!"=="" set "ACTIVEPART=%%n"
    )
)

:: Van-e mar aktiv? (csillag az aktiv particio soran)
findstr /c:"*" "%TMP_DIR%\bf_legp.txt" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK] Aktiv particio rendben.
) else (
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

del /q "%TMP_DIR%\bf_*.txt" >nul 2>&1
del /q "%DPSCRIPT%" >nul 2>&1

echo.
echo   =============================
echo     BOOT JAVITAS KESZ!
echo     Inditsd ujra a gepet.
echo   =============================
echo.
pause
