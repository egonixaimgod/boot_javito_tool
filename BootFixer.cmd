@echo off
setlocal EnableExtensions EnableDelayedExpansion
title BootFixer
rem =====================================================
rem   BOOTFIXER v5.0 - WinPE kompatibilis (Sergei Strelec)
rem   Nincs .NET fuggoseg - tiszta batch
rem =====================================================

rem --- Temp konyvtar ---
set "TMPD=%TEMP%"
if not exist "%TMPD%" set "TMPD=X:\Windows\Temp"
if not exist "%TMPD%" set "TMPD=%SystemRoot%\Temp"
if not exist "%TMPD%" set "TMPD=%~dp0"
set "DPS=%TMPD%\bf_dp.txt"
set "DPO=%TMPD%\bf_out.txt"

rem --- Admin ellenorzes ---
fltmc >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [HIBA] Rendszergazdai jog szukseges. Inditsd adminkent.
    echo.
    pause
    exit /b 1
)

cls
echo.
echo   =============================
echo        B O O T F I X E R
echo        WinPE batch v5.0
echo   =============================
echo.
echo   Lemezek keresese...
echo.

rem =====================================================
rem   LEMEZEK FELDERITESE
rem =====================================================
>"%DPS%" echo list disk
diskpart /s "%DPS%" >"%DPO%" 2>nul
if not exist "%DPO%" goto DPFAIL
findstr /r /c:"[0-9]" "%DPO%" >nul 2>&1 || goto DPFAIL

set /a DCOUNT=0
for /f "usebackq delims=" %%L in (`findstr /r /c:"Disk [0-9]" /c:"Lemez [0-9]" "%DPO%" ^| findstr /v /c:"###"`) do (
    set "LINE=%%L"
    call :AddDisk
)

if %DCOUNT%==0 (
    echo   Nem talalhato lemez.
    echo.
    echo   [Debug] Diskpart kimenet:
    type "%DPO%"
    pause
    goto END
)

rem --- Lemez modellek (wmic, opcionalis) ---
for /L %%i in (1,1,%DCOUNT%) do call :GetModel %%i

rem --- Windows telepitesek keresese (X: kihagyva, az a WinPE) ---
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do call :CheckWin %%D

rem --- EFI particiok keresese GPT lemezeken ---
for /L %%i in (1,1,%DCOUNT%) do call :FindEFI %%i

rem =====================================================
rem   LEMEZEK KIIRASA
rem =====================================================
echo   Talalt lemezek:
echo   -------------------------------------------------------
for /L %%i in (1,1,%DCOUNT%) do (
    set "BT=Legacy/MBR"
    if "!DGPT_%%i!"=="1" set "BT=UEFI/GPT"
    set "WT=Nincs Windows"
    if defined DWIN_%%i set "WT=Windows !DWIN_%%i!:\"
    echo   [%%i] !DMOD_%%i! ^| !DSIZE_%%i! ^| !BT! ^| !WT!
)
echo.
echo   [0] Kilepes
echo.

rem =====================================================
rem   VALASZTAS
rem =====================================================
set "CH="
set /p "CH=  Melyik lemezt javitsam? [szam]: "
if not defined CH goto END
if "%CH%"=="0" goto END
echo %CH%|findstr /r "^[0-9][0-9]*$" >nul || goto BADCHOICE
if %CH% LSS 1 goto BADCHOICE
if %CH% GTR %DCOUNT% goto BADCHOICE

set "SELNUM=!DNUM_%CH%!"
set "SELGPT=!DGPT_%CH%!"
set "SELEFI=!DEFI_%CH%!"
set "SELMOD=!DMOD_%CH%!"
set "SELSIZE=!DSIZE_%CH%!"
set "SELWIN="
if defined DWIN_%CH% set "SELWIN=!DWIN_%CH%!"

if not defined SELWIN (
    echo.
    echo   [HIBA] Ezen a lemezen nincs Windows.
    pause
    goto END
)

set "BT=Legacy/MBR"
if "%SELGPT%"=="1" set "BT=UEFI/GPT"
echo.
echo   Kivalasztva: %SELMOD% ^| %SELSIZE% ^| %BT%
echo   Windows: %SELWIN%:\
echo.
set "CONF="
set /p "CONF=  Ujrairom a bootot es single boot lesz. Folytatod? (i/n): "
if /i not "%CONF%"=="i" (
    echo   Megszakitva.
    pause
    goto END
)
echo.

set "WINDIRP=%SELWIN%:\Windows"

if "%SELGPT%"=="1" goto FIXUEFI
goto FIXLEGACY

rem =====================================================
rem   UEFI JAVITAS
rem =====================================================
:FIXUEFI
echo   [1/4] EFI particio mountolasa...
if "%SELEFI%"=="0" (
    echo   [HIBA] Nem talalhato EFI particio ezen a lemezen.
    pause
    goto END
)
set "EL="
for %%L in (Z Y W V U T S R Q O) do if not defined EL if not exist %%L:\ set "EL=%%L"
if not defined EL (
    echo   [HIBA] Nincs szabad betujel.
    pause
    goto END
)
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %SELEFI%
    echo assign letter=%EL%
)
diskpart /s "%DPS%" >nul 2>&1
call :Sleep 2
if not exist %EL%:\ (
    echo   [HIBA] EFI mount sikertelen.
    pause
    goto END
)
echo   [OK] EFI mountolva: %EL%:\

echo   [2/4] Boot fajlok ujrairasa...
if exist "%EL%:\EFI\Microsoft\Boot" rmdir /s /q "%EL%:\EFI\Microsoft\Boot" 2>nul
bcdboot %WINDIRP% /s %EL%: /f UEFI /l hu-HU >nul 2>&1
if errorlevel 1 bcdboot %WINDIRP% /s %EL%: /f UEFI >nul 2>&1
if errorlevel 1 (
    echo   [FIGYELEM] BCDBoot hibat jelzett - ellenorizd kezzel.
) else (
    echo   [OK] BCDBoot UEFI sikeres.
)

echo   [3/4] Single boot beallitas...
if exist "%EL%:\EFI\Microsoft\Boot\BCD" (
    call :SingleBoot %EL%:\EFI\Microsoft\Boot\BCD
    echo   [OK] Single boot beallitva.
) else (
    echo   [FIGYELEM] BCD store nem talalhato.
)

echo   [4/4] EFI levalasztasa...
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %SELEFI%
    echo remove letter=%EL%
)
diskpart /s "%DPS%" >nul 2>&1
echo   [OK] Kesz.
goto DONE

rem =====================================================
rem   LEGACY (MBR) JAVITAS
rem =====================================================
:FIXLEGACY
echo   [1/4] Aktiv particio beallitasa...
>"%DPS%" (
    echo select disk %SELNUM%
    echo list partition
)
diskpart /s "%DPS%" >"%DPO%" 2>nul
set "FIRSTPART="
set "FIRSTPRIM="
for /f "usebackq delims=" %%L in ("%DPO%") do (
    set "LINE=%%L"
    call :ParsePart
)
if defined FIRSTPRIM set "FIRSTPART=%FIRSTPRIM%"
if not defined FIRSTPART set "FIRSTPART=1"

>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %FIRSTPART%
    echo active
)
diskpart /s "%DPS%" >nul 2>&1
echo   [OK] Particio %FIRSTPART% aktivva teve.

echo   [2/4] Boot particio mountolasa...
set "TL="
for %%L in (Z Y W V U T S R Q O) do if not defined TL if not exist %%L:\ set "TL=%%L"
set "MOUNTED="
if defined TL (
    >"%DPS%" (
        echo select disk %SELNUM%
        echo select partition %FIRSTPART%
        echo assign letter=%TL%
    )
    diskpart /s "%DPS%" >nul 2>&1
    call :Sleep 2
    if exist !TL!:\ set "MOUNTED=1"
)

echo   [3/4] MBR / bootszektor / BCDBoot...
if defined MOUNTED (
    bootsect /nt60 %TL%: /mbr >nul 2>&1
    if errorlevel 1 (
        bootrec /fixmbr >nul 2>&1
        bootrec /fixboot >nul 2>&1
    )
    bcdboot %WINDIRP% /s %TL%: /f BIOS /l hu-HU >nul 2>&1
    if errorlevel 1 bcdboot %WINDIRP% /s %TL%: /f BIOS >nul 2>&1
    if errorlevel 1 (
        echo   [FIGYELEM] BCDBoot hibat jelzett - ellenorizd kezzel.
    ) else (
        echo   [OK] MBR ujrairva, BCDBoot BIOS sikeres.
    )
) else (
    bootrec /fixmbr >nul 2>&1
    bootrec /fixboot >nul 2>&1
    bcdboot %WINDIRP% /f BIOS >nul 2>&1
    echo   [OK] BCDBoot fallback lefutott.
)

echo   [4/4] Single boot beallitas...
if defined MOUNTED (
    if exist "%TL%:\Boot\BCD" (
        call :SingleBoot %TL%:\Boot\BCD
        echo   [OK] Single boot beallitva.
    ) else (
        echo   [FIGYELEM] BCD store nem talalhato: %TL%:\Boot\BCD
    )
    >"%DPS%" (
        echo select disk %SELNUM%
        echo select partition %FIRSTPART%
        echo remove letter=%TL%
    )
    diskpart /s "%DPS%" >nul 2>&1
) else (
    echo   [FIGYELEM] Nem sikerult mountolni - single boot kihagyva.
)
goto DONE

rem =====================================================
rem   KESZ
rem =====================================================
:DONE
echo.
echo   =============================
echo     BOOT JAVITAS KESZ.
echo     Inditsd ujra a gepet.
echo   =============================
goto END

:BADCHOICE
echo   Ervenytelen valasztas.
pause
goto END

:DPFAIL
echo   [HIBA] Diskpart nem erheto el.
pause
goto END

:END
del "%DPS%" >nul 2>&1
del "%DPO%" >nul 2>&1
echo.
pause
exit /b 0

rem =====================================================
rem   SZUBRUTINOK
rem =====================================================

:AddDisk
rem !LINE! = pl. "  Disk 0    Online          931 GB      0 B         *"
set "DN=" & set "DS1=" & set "DS2="
for /f "tokens=1-5" %%a in ("!LINE!") do (
    set "DN=%%b"
    set "DS1=%%d"
    set "DS2=%%e"
)
echo !DN!|findstr /r "^[0-9][0-9]*$" >nul || goto :eof
set "G=0"
echo !LINE!|find "*" >nul && set "G=1"
set /a DCOUNT+=1
set "DNUM_%DCOUNT%=%DN%"
set "DGPT_%DCOUNT%=%G%"
set "DSIZE_%DCOUNT%=%DS1% %DS2%"
set "DMOD_%DCOUNT%=Lemez %DN%"
set "DEFI_%DCOUNT%=0"
set "DWIN_%DCOUNT%="
goto :eof

:GetModel
set "N=!DNUM_%1!"
for /f "tokens=1* delims==" %%a in ('wmic diskdrive where "Index=%N%" get Model /value 2^>nul ^| find "="') do (
    for /f "delims=" %%c in ("%%b") do if not "%%c"=="" set "DMOD_%1=%%c"
)
goto :eof

:CheckWin
set "WL=%1"
set "HASWIN="
if exist "%WL%:\Windows\System32\winload.exe" set "HASWIN=1"
if exist "%WL%:\Windows\System32\winload.efi" set "HASWIN=1"
if not defined HASWIN goto :eof
>"%DPS%" (
    echo select volume %WL%
    echo detail volume
)
diskpart /s "%DPS%" >"%DPO%" 2>nul
set "WDN="
for /f "usebackq tokens=1-3" %%a in (`findstr /r /c:"Disk [0-9]" /c:"Lemez [0-9]" "%DPO%" ^| findstr /v /c:"###"`) do (
    if /i "%%a"=="Disk" set "WDN=%%b"
    if /i "%%a"=="Lemez" set "WDN=%%b"
    if /i "%%b"=="Disk" set "WDN=%%c"
    if /i "%%b"=="Lemez" set "WDN=%%c"
)
if not defined WDN goto :eof
for /L %%i in (1,1,%DCOUNT%) do (
    if "!DNUM_%%i!"=="%WDN%" if not defined DWIN_%%i set "DWIN_%%i=%WL%"
)
goto :eof

:FindEFI
if not "!DGPT_%1!"=="1" goto :eof
>"%DPS%" (
    echo select disk !DNUM_%1!
    echo list partition
)
diskpart /s "%DPS%" >"%DPO%" 2>nul
for /f "usebackq tokens=2" %%p in (`findstr /i /c:"System" /c:"Rendszer" "%DPO%"`) do (
    echo %%p|findstr /r "^[0-9][0-9]*$" >nul && set "DEFI_%1=%%p"
)
goto :eof

:ParsePart
rem !LINE! = pl. "  Partition 1    Primary  100 MB ..." vagy "* Partition 2 ..."
set "T1=" & set "T2=" & set "T3=" & set "T4="
for /f "tokens=1-4" %%a in ("!LINE!") do (
    set "T1=%%a" & set "T2=%%b" & set "T3=%%c" & set "T4=%%d"
)
if "!T1!"=="*" (
    set "T1=!T2!" & set "T2=!T3!" & set "T3=!T4!"
)
if /i not "!T1:~0,4!"=="Part" goto :eof
echo !T2!|findstr /r "^[0-9][0-9]*$" >nul || goto :eof
if not defined FIRSTPART set "FIRSTPART=!T2!"
if /i "!T3:~0,4!"=="Prim" if not defined FIRSTPRIM set "FIRSTPRIM=!T2!"
if /i "!T3:~0,3!"=="Els" if not defined FIRSTPRIM set "FIRSTPRIM=!T2!"
goto :eof

:SingleBoot
rem %1 = BCD store eleresi ut
set "SARG="
if not "%~1"=="" set "SARG=/store %~1"
set "DEFID="
for /f "tokens=1,2" %%a in ('bcdedit %SARG% /enum {bootmgr} 2^>nul') do (
    if /i "%%a"=="default" set "DEFID=%%b"
)
for /f "tokens=1,2" %%a in ('bcdedit %SARG% /enum osloader 2^>nul') do (
    if /i "%%a"=="identifier" call :DelEntry %%b
)
bcdedit %SARG% /timeout 0 >nul 2>&1
goto :eof

:DelEntry
if /i "%~1"=="{default}" goto :eof
if defined DEFID if /i "%~1"=="%DEFID%" goto :eof
bcdedit %SARG% /delete %1 /cleanup >nul 2>&1
goto :eof

:Sleep
ping -n %1 127.0.0.1 >nul 2>&1
goto :eof
