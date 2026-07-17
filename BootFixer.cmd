@echo off
setlocal EnableExtensions EnableDelayedExpansion
title BootFixer
rem =====================================================
rem   BOOTFIXER v5.1 - WinPE kompatibilis (Sergei Strelec)
rem   Nincs .NET fuggoseg - tiszta batch
rem   Minden diskpart/bcdboot/bootsect hivas a log fajlba kerul.
rem =====================================================

rem --- Temp konyvtar ---
set "TMPD=%TEMP%"
if not exist "%TMPD%" set "TMPD=X:\Windows\Temp"
if not exist "%TMPD%" set "TMPD=%SystemRoot%\Temp"
if not exist "%TMPD%" set "TMPD=%~dp0"
set "DPS=%TMPD%\bf_dp.txt"
set "DPO=%TMPD%\bf_out.txt"

rem --- Log fajl: eloszor a script mappaja (USB stick - ujrainditas utan is
rem     megmarad), ha az nem irhato, akkor a temp konyvtar ---
set "LOG=%~dp0bootfixer_log.txt"
(type nul >>"%LOG%") 2>nul || set "LOG=%TMPD%\bootfixer_log.txt"
>"%LOG%" echo ===== BootFixer v5.1 log - %DATE% %TIME% =====

rem --- Admin ellenorzes + UAC onfelemeles ---
rem WinPE alatt nincs UAC es minden eleve adminkent fut, de a fltmc ott
rem hibazhat - a csak WinPE-ben letezo MiniNT kulcsbol ismerjuk fel es kihagyjuk.
reg query HKLM\SYSTEM\CurrentControlSet\Control\MiniNT >nul 2>&1 && goto AdminOK
fltmc >nul 2>&1
if not errorlevel 1 goto AdminOK
if /i "%~1"=="ELEV" (
    echo.
    echo   [HIBA] Rendszergazdai jog szukseges, de nem sikerult megszerezni.
    echo.
    pause
    exit /b 1
)
echo.
echo   [INFO] Nincs rendszergazdai jog - ujrainditas emelt joggal...
echo   [INFO] A felugro UAC ablakban valaszd az Igen gombot.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList 'ELEV' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }" >nul 2>&1
if errorlevel 1 (
    echo.
    echo   [HIBA] Az emelt jogu inditas nem sikerult vagy el lett utasitva.
    echo   Inditsd kezzel rendszergazdakent.
    echo.
    pause
    exit /b 1
)
exit /b 0
:AdminOK

cls
echo.
echo   =============================
echo        B O O T F I X E R
echo        WinPE batch v5.1
echo   =============================
echo.
echo   Log: %LOG%
echo.
echo   Lemezek keresese...
echo.

rem =====================================================
rem   LEMEZEK FELDERITESE
rem =====================================================
>"%DPS%" echo list disk
call :DPRun
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

rem --- GPT/MBR meghatarozas (uniqueid disk - lokalizacio-fuggetlen) ---
for /L %%i in (1,1,%DCOUNT%) do call :DetectGPT %%i

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
set "ERRFLAG="

if "%SELGPT%"=="1" goto FIXUEFI
goto FIXLEGACY

rem =====================================================
rem   UEFI JAVITAS
rem =====================================================
:FIXUEFI
echo   [1/4] EFI particio mountolasa...
if "%SELEFI%"=="0" call :CreateEFI
if "%SELEFI%"=="0" (
    echo   [HIBA] Nem talalhato es nem sikerult letrehozni EFI particiot.
    echo   Reszletes log: %LOG%
    pause
    goto END
)
call :MountEFI
if defined ELOK goto EFIMOK
echo.
echo   [FIGYELEM] Az EFI particio mountolasa nem sikerult. Diskpart uzenete:
type "%TMPD%\bf_mount.txt" 2>nul
echo.
call :CheckEFIType
if defined EFIOK goto EFIREFMT
echo   [INFO] A korabban talalt EFI particio nem letezik vagy nem elerheto.
set "SELEFI=0"
call :CreateEFI
if "%SELEFI%"=="0" (
    echo   [HIBA] Nem sikerult EFI particiot letrehozni. Reszletes log: %LOG%
    pause
    goto END
)
call :MountEFI
goto EFIMCHK

:EFIREFMT
echo   [INFO] Az EFI particio letezik es a tipusa rendben van, de nem mountolhato.
echo   [INFO] Valoszinuleg serult vagy hianyzo rajta a fajlrendszer. Az ujraformazas
echo          ezt megoldja - a boot fajlokat a kovetkezo lepes ugyis ujrairja.
set "CONF3="
set /p "CONF3=  Ujraformazzam az EFI particiot FAT32-re es probaljam ujra? (i/n): "
if /i not "%CONF3%"=="i" (
    echo   Megszakitva.
    pause
    goto END
)
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %SELEFI%
    echo format fs=fat32 label=SYSTEM quick
)
call :DPRun
call :MountEFI

:EFIMCHK
if not defined ELOK (
    echo   [HIBA] Az EFI particio mountolasa ismet nem sikerult. Diskpart uzenete:
    type "%TMPD%\bf_mount.txt" 2>nul
    echo   Reszletes log: %LOG%
    pause
    goto END
)
:EFIMOK
echo   [OK] EFI mountolva: %EL%:\

echo   [2/4] Boot fajlok ujrairasa...
if exist "%EL%:\EFI\Microsoft\Boot" rmdir /s /q "%EL%:\EFI\Microsoft\Boot" 2>nul
bcdboot %WINDIRP% /s %EL%: /f UEFI /l hu-HU >"%DPO%" 2>&1
set "RC=%ERRORLEVEL%"
call :LogDPO "bcdboot UEFI hu-HU"
if not "%RC%"=="0" (
    bcdboot %WINDIRP% /s %EL%: /f UEFI >"%DPO%" 2>&1
    set "RC=!ERRORLEVEL!"
    call :LogDPO "bcdboot UEFI fallback"
)
if not "%RC%"=="0" (
    echo   [FIGYELEM] BCDBoot hibat jelzett - kimenete:
    type "%DPO%"
    set "ERRFLAG=1"
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
call :DPRun
echo   [OK] Kesz.
goto DONE

rem =====================================================
rem   LEGACY (MBR) JAVITAS
rem =====================================================
:FIXLEGACY
echo   [1/4] Aktiv particio beallitasa...
call :FindWinPart
>"%DPS%" (
    echo select disk %SELNUM%
    echo list partition
)
call :DPRun
set "FIRSTPART="
set "FIRSTPRIM="
for /f "usebackq delims=" %%L in ("%DPO%") do (
    set "LINE=%%L"
    call :ParsePart
)
if defined FIRSTPRIM set "FIRSTPART=%FIRSTPRIM%"
if not defined FIRSTPART set "FIRSTPART=1"
rem A Windowst tartalmazo particio elonyt elvez (elkeruli az adatparticiot)
if defined WINPART set "FIRSTPART=%WINPART%"

>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %FIRSTPART%
    echo active
)
call :DPRun
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
    call :DPRun
    call :Sleep 2
    if exist !TL!:\ set "MOUNTED=1"
)

echo   [3/4] MBR / bootszektor / BCDBoot...
if defined MOUNTED (
    bootsect /nt60 %TL%: /mbr >"%DPO%" 2>&1
    set "RC=!ERRORLEVEL!"
    call :LogDPO "bootsect nt60"
    if not "!RC!"=="0" (
        bootrec /fixmbr >"%DPO%" 2>&1
        call :LogDPO "bootrec fixmbr"
        bootrec /fixboot >"%DPO%" 2>&1
        call :LogDPO "bootrec fixboot"
    )
    bcdboot %WINDIRP% /s %TL%: /f BIOS /l hu-HU >"%DPO%" 2>&1
    set "RC=!ERRORLEVEL!"
    call :LogDPO "bcdboot BIOS hu-HU"
    if not "!RC!"=="0" (
        bcdboot %WINDIRP% /s %TL%: /f BIOS >"%DPO%" 2>&1
        set "RC=!ERRORLEVEL!"
        call :LogDPO "bcdboot BIOS fallback"
    )
    if not "!RC!"=="0" (
        echo   [FIGYELEM] BCDBoot hibat jelzett - kimenete:
        type "%DPO%"
        set "ERRFLAG=1"
    ) else (
        echo   [OK] MBR ujrairva, BCDBoot BIOS sikeres.
    )
) else (
    bootrec /fixmbr >"%DPO%" 2>&1
    call :LogDPO "bootrec fixmbr"
    bootrec /fixboot >"%DPO%" 2>&1
    call :LogDPO "bootrec fixboot"
    bcdboot %WINDIRP% /f BIOS >"%DPO%" 2>&1
    set "RC=!ERRORLEVEL!"
    call :LogDPO "bcdboot BIOS nomount"
    if not "!RC!"=="0" set "ERRFLAG=1"
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
    call :DPRun
) else (
    echo   [FIGYELEM] Nem sikerult mountolni - single boot kihagyva.
)
goto DONE

rem =====================================================
rem   KESZ
rem =====================================================
:DONE
echo.
if defined ERRFLAG (
    echo   =============================
    echo     BEFEJEZVE - VOLT FIGYELMEZTETES.
    echo     Ellenorizd a fenti uzeneteket,
    echo     mielott ujrainditasz.
    echo   =============================
) else (
    echo   =============================
    echo     BOOT JAVITAS KESZ.
    echo     Inditsd ujra a gepet.
    echo   =============================
)
echo.
echo   Reszletes log: %LOG%
goto END

:BADCHOICE
echo   Ervenytelen valasztas.
pause
goto END

:DPFAIL
echo   [HIBA] Diskpart nem erheto el vagy nem adott ertelmes kimenetet.
if exist "%DPO%" type "%DPO%"
echo   Reszletes log: %LOG%
pause
goto END

:END
del "%DPS%" >nul 2>&1
del "%DPO%" >nul 2>&1
del "%TMPD%\bf_mount.txt" >nul 2>&1
del "%TMPD%\bf_create.txt" >nul 2>&1
echo.
pause
exit /b 0

rem =====================================================
rem   SZUBRUTINOK
rem =====================================================

:DPRun
rem diskpart futtatasa a %DPS% szkripttel; kimenet a %DPO%-ba es a logba.
>>"%LOG%" echo.
>>"%LOG%" echo ===== diskpart =====
type "%DPS%" >>"%LOG%" 2>nul
>>"%LOG%" echo ----- kimenet -----
diskpart /s "%DPS%" >"%DPO%" 2>&1
type "%DPO%" >>"%LOG%" 2>nul
goto :eof

:LogDPO
rem A %DPO% tartalmat a logba fuzi %1 cimkevel (nem-diskpart eszkozokhoz).
>>"%LOG%" echo.
>>"%LOG%" echo ===== %~1 =====
type "%DPO%" >>"%LOG%" 2>nul
goto :eof

:MountEFI
rem A SELEFI particiot mountolja egy szabad betujelre. Siker: ELOK=1, EL=betu.
rem Legfeljebb 3 betuvel probalkozik; sikertelen probalkozas utan takarit.
rem Az assign kimenete a bf_mount.txt-be is kerul, hogy hibanal kiirhato legyen.
set "ELOK="
set "EL="
set /a MTRY=0
for %%L in (Z Y W V U T S R Q O) do if not defined ELOK if !MTRY! LSS 3 if not exist %%L:\ (
    set /a MTRY+=1
    >"%DPS%" (
        echo select disk %SELNUM%
        echo select partition %SELEFI%
        echo assign letter=%%L
    )
    call :DPRun
    copy /y "%DPO%" "%TMPD%\bf_mount.txt" >nul 2>&1
    call :Sleep 2
    if exist %%L:\ (
        set "ELOK=1"
        set "EL=%%L"
    ) else (
        >"%DPS%" (
            echo select disk %SELNUM%
            echo select partition %SELEFI%
            echo remove letter=%%L
        )
        call :DPRun
    )
)
goto :eof

:CheckEFIType
rem Letezik-e a SELEFI particio es tenyleg EFI System tipusu-e.
rem A GPT tipus-GUID (c12a7328-...) lokalizacio-fuggetlen ismertetojel.
set "EFIOK="
>"%DPS%" (
    echo select disk %SELNUM%
    echo select partition %SELEFI%
    echo detail partition
)
call :DPRun
findstr /i /c:"c12a7328" "%DPO%" >nul 2>&1 && set "EFIOK=1"
goto :eof

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
rem GPT/MBR kesobb, a :DetectGPT hatarozza meg (uniqueid disk)
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
call :DPRun
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
call :DPRun
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
rem WinRE / helyreallitasi (ramdisk) bejegyzest NEM torlunk
set "ISRAM="
for /f "usebackq tokens=1,*" %%x in (`bcdedit %SARG% /enum %1 2^>nul ^| findstr /i /c:"device"`) do (
    echo %%y| find /i "ramdisk" >nul && set "ISRAM=1"
)
if defined ISRAM goto :eof
>>"%LOG%" echo bcdedit delete: %1
bcdedit %SARG% /delete %1 /cleanup >nul 2>&1
goto :eof

:DetectGPT
rem GPT vs MBR: uniqueid disk -> GPT = GUID (kotojeles), MBR = 8 jegyu hex.
rem A GUID mintaja (-XXXX-) lokalizacio-fuggetlen, a gepnev kotojele nem zavarja.
set "N=!DNUM_%1!"
>"%DPS%" (
    echo select disk %N%
    echo uniqueid disk
)
call :DPRun
findstr /r /c:"-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-" "%DPO%" >nul 2>&1 && set "DGPT_%1=1"
goto :eof

:CreateEFI
rem Nincs EFI particio a GPT lemezen -> letrehozas a Windows kotet zsugoritasabol.
echo.
echo   [INFO] Ezen a lemezen nincs hasznalhato EFI particio.
echo   [INFO] Letrehozom: a Windows kotet (%SELWIN%:) zsugoritasa kb. 200 MB-tal,
echo          majd egy uj 100 MB-os EFI particio (FAT32).
echo   [INFO] A zsugoritas altalaban biztonsagos, de van hozza kockazat.
set "CONF2="
set /p "CONF2=  Folytatod az EFI particio letrehozasat? (i/n): "
if /i not "%CONF2%"=="i" goto :eof
>"%DPS%" (
    echo select disk %SELNUM%
    echo select volume %SELWIN%
    echo shrink desired=200 minimum=120
    echo create partition efi size=100
    echo format fs=fat32 label=SYSTEM quick
)
call :DPRun
copy /y "%DPO%" "%TMPD%\bf_create.txt" >nul 2>&1
call :Sleep 2
call :FindEFISel
if not "%SELEFI%"=="0" (
    echo   [OK] EFI particio letrehozva - particio: %SELEFI%
) else (
    echo   [HIBA] Az EFI particio letrehozasa nem sikerult. Diskpart kimenete:
    type "%TMPD%\bf_create.txt" 2>nul
)
goto :eof

:FindEFISel
rem A kivalasztott lemezen megkeresi az EFI (System) particiot es beallitja SELEFI-t.
>"%DPS%" (
    echo select disk %SELNUM%
    echo list partition
)
call :DPRun
for /f "usebackq tokens=2" %%p in (`findstr /i /c:"System" /c:"Rendszer" "%DPO%"`) do (
    echo %%p|findstr /r "^[0-9][0-9]*$" >nul && set "SELEFI=%%p"
)
goto :eof

:FindWinPart
rem Megkeresi, hogy a Windows melyik particion van (legacy: ez legyen az aktiv).
set "WINPART="
>"%DPS%" (
    echo select volume %SELWIN%
    echo detail partition
)
call :DPRun
for /f "usebackq delims=" %%L in ("%DPO%") do (
    set "PLINE=%%L"
    call :GrabWinPart
)
goto :eof

:GrabWinPart
for /f "tokens=1-2" %%a in ("!PLINE!") do (
    set "PW1=%%a"
    if /i "!PW1:~0,4!"=="Part" (
        echo %%b|findstr /r "^[0-9][0-9]*$" >nul && if not defined WINPART set "WINPART=%%b"
    )
)
goto :eof

:Sleep
ping -n %1 127.0.0.1 >nul 2>&1
goto :eof
