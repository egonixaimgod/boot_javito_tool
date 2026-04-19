@echo off
chcp 65001 >nul 2>&1
title BootFixer CMD - WinPE Compatible
color 0F
setlocal enabledelayedexpansion

cls
echo.
echo   =============================
echo        B O O T F I X E R
echo       WinPE Compatible v2.0
echo   =============================
echo.

:: Admin check (WinPE-ben mindig admin)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo   [!] Rendszergazdai jog szukseges!
    echo   Jobb klikk - Futtatás rendszergazdakent
    pause
    exit /b
)

:: =============================================
::   LEMEZEK FELDERITESE
:: =============================================

set "DPSCRIPT=%TEMP%\bf_dps.txt"
set DISKCOUNT=0

echo list disk > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_dp.txt" 2>nul

:: Lemezek szama es alapadatok
for /f "tokens=1,2,3,4" %%a in ('type "%TEMP%\bf_dp.txt" ^| findstr /r /c:"Disk [0-9]"') do (
    set /a DISKCOUNT+=1
    set "DNUM_!DISKCOUNT!=%%b"
    set "DSIZE_!DISKCOUNT!=%%c %%d"
)

if %DISKCOUNT% equ 0 (
    echo   Nem talalhato lemez!
    pause
    exit /b
)

:: Particio tipus es Windows keresese lemezenként
for /l %%i in (1,1,%DISKCOUNT%) do (
    set "DTYPE_%%i=Legacy/MBR"
    set "DWIN_%%i=Nincs Windows"
    set "DWINLETTER_%%i="
    set "DEFI_%%i="

    :: GPT ellenorzes
    (
        echo select disk !DNUM_%%i!
        echo detail disk
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_det.txt" 2>nul
    findstr /i "GPT" "%TEMP%\bf_det.txt" >nul 2>&1
    if !errorlevel! equ 0 set "DTYPE_%%i=UEFI/GPT"

    :: Particiok listazasa
    (
        echo select disk !DNUM_%%i!
        echo list partition
    ) > "%DPSCRIPT%"
    diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_parts.txt" 2>nul

    :: EFI particio keresese (System tipusu)
    for /f "tokens=2" %%p in ('type "%TEMP%\bf_parts.txt" ^| findstr /i "System"') do (
        set "DEFI_%%i=%%p"
    )

    :: Minden particio - betujel es Windows keresese
    for /f "tokens=2" %%p in ('type "%TEMP%\bf_parts.txt" ^| findstr /r /c:"Partition [0-9]"') do (
        (
            echo select disk !DNUM_%%i!
            echo select partition %%p
            echo detail partition
        ) > "%DPSCRIPT%"
        diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_pdet.txt" 2>nul

        :: Drive letter keresese
        for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
            if "!DWINLETTER_%%i!"=="" (
                findstr /i /c:"%%d:" "%TEMP%\bf_pdet.txt" >nul 2>&1
                if !errorlevel! equ 0 (
                    if exist "%%d:\Windows\System32\winload*" (
                        set "DWIN_%%i=Windows: %%d:\"
                        set "DWINLETTER_%%i=%%d"
                    )
                )
            )
        )

        :: EFI GptType keresese ha meg nincs
        if "!DEFI_%%i!"=="" (
            findstr /i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" "%TEMP%\bf_pdet.txt" >nul 2>&1
            if !errorlevel! equ 0 set "DEFI_%%i=%%p"
        )
    )
)

:: =============================================
::   KIIRAS
:: =============================================

echo   Talalt lemezek:
echo   -------------------------------------------------------
for /l %%i in (1,1,%DISKCOUNT%) do (
    echo   [%%i] Disk !DNUM_%%i! ^| !DSIZE_%%i! ^| !DTYPE_%%i! ^| !DWIN_%%i!
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

if "!SELWIN!"=="" (
    echo.
    echo   [HIBA] Ezen a lemezen nincs Windows telepites!
    pause
    exit /b
)

echo.
echo   Kivalasztva: Disk !SELDISK! ^| !SELSIZE! ^| !SELTYPE!
echo   Windows: !SELWIN!:\
echo.
set /p "CONFIRM=  Ujrairom a bootot es single boot-ta teszem. Folytatod? (i/n): "
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
::   UEFI JAVITAS
:: =============================================
:FIX_UEFI

echo   [1/4] EFI particio mountolasa...

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

(
    echo select disk !SELDISK!
    echo select partition !SELEFI!
    echo assign letter=!EFILETTER!
) > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" >nul 2>&1
timeout /t 2 /nobreak >nul

if not exist "!EFILETTER!:\" (
    echo   [HIBA] EFI mount sikertelen!
    pause
    exit /b
)
echo   [OK] EFI mountolva: !EFILETTER!:\

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
    echo   [!] BCDBoot - ellenorizd manuálisan
)

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
)

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
::   LEGACY JAVITAS
:: =============================================
:FIX_LEGACY

echo   [1/4] Aktiv particio beallitasa...
(
    echo select disk !SELDISK!
    echo list partition
) > "%DPSCRIPT%"
diskpart /s "%DPSCRIPT%" > "%TEMP%\bf_legp.txt" 2>nul

set "ACTIVEPART="
findstr /i "Active" "%TEMP%\bf_legp.txt" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK] Aktiv particio rendben.
    for /f "tokens=2" %%a in ('type "%TEMP%\bf_legp.txt" ^| findstr /r /c:"Partition [0-9]"') do (
        if "!ACTIVEPART!"=="" set "ACTIVEPART=%%a"
    )
) else (
    for /f "tokens=2" %%a in ('type "%TEMP%\bf_legp.txt" ^| findstr /r /c:"Partition [0-9]"') do (
        if "!ACTIVEPART!"=="" (
            set "ACTIVEPART=%%a"
            (
                echo select disk !SELDISK!
                echo select partition %%a
                echo active
            ) > "%DPSCRIPT%"
            diskpart /s "%DPSCRIPT%" >nul 2>&1
            echo   [OK] Particio %%a aktivva teve!
        )
    )
)

echo   [2/4] MBR es boot szektor ujrairasa...
bootrec /fixmbr >nul 2>&1
bootrec /fixboot >nul 2>&1
bootrec /rebuildbcd >nul 2>&1
echo   [OK] MBR/bootszektor ujrairva!

echo   [3/4] BCDBoot futtatasa...
set "TMPLETTER="

:: System particiohoz betujel kell
set "SYSLETTER="
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
    timeout /t 1 /nobreak >nul
    set "SYSLETTER=!TMPLETTER!"
)

if defined SYSLETTER (
    bcdboot "!SELWIN!:\Windows" /s "!SYSLETTER!:" /f BIOS /l hu-HU >nul 2>&1
    if !errorlevel! neq 0 (
        bcdboot "!SELWIN!:\Windows" /s "!SYSLETTER!:" /f BIOS >nul 2>&1
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
:DONE
del /q "%TEMP%\bf_*.txt" >nul 2>&1
del /q "%DPSCRIPT%" >nul 2>&1

echo.
echo   =============================
echo     BOOT JAVITAS KESZ!
echo     Inditsd ujra a gepet.
echo   =============================
echo.
pause
